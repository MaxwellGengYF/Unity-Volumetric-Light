// Upgrade NOTE: replaced '_Object2World' with 'unity_ObjectToWorld'
// Upgrade NOTE: replaced 'mul(UNITY_MATRIX_MVP,*)' with 'UnityObjectToClipPos(*)'
// Upgrade NOTE: replaced 'unity_World2Shadow' with 'unity_WorldToShadow'

//  Copyright(c) 2016, Michal Skalsky
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without modification,
//  are permitted provided that the following conditions are met:
//
//  1. Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//
//  2. Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//
//  3. Neither the name of the copyright holder nor the names of its contributors
//     may be used to endorse or promote products derived from this software without
//     specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
//  EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
//  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.IN NO EVENT
//  SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
//  OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
//  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
//  TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
//  EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.



Shader "Sandbox/VolumetricLight"
{
	SubShader
	{
		Tags { "RenderType"="Opaque" }
		LOD 100

		CGINCLUDE

		#if SHADOWS_DEPTH || defined(SHADOWS_CUBE)
		
		#endif
		#include "VolumetricShadowLibrary.cginc"
		#include "UnityDeferredLibrary.cginc"

		float4 _FrustumCorners[4];
		float4 _LightFinalColor;
		struct appdata
		{
			float4 vertex : POSITION;
		};
		
		float4x4 _WorldViewProj;
		float4x4 _MyLightMatrix0;
		float4x4 _MyWorld2Shadow;
		float3 _CameraForward;

		// x: scattering coef, y: extinction coef, z: range w: skybox extinction coef
		float4 _VolumetricLight;
        // x: 1 - g^2, y: 1 + g^2, z: 2*g, w: 1/4pi
        float4 _MieG;

		// x: scale, y: intensity, z: intensity offset
		float4 _NoiseData;
        // x: x velocity, y: z velocity
		float4 _NoiseVelocity;
		// x:  ground level, y: height scale, z: unused, w: unused
		float4 _HeightFog;
		//float4 _LightDir;

		float _MaxRayLength;

		int _SampleCount;
		sampler3D _NoiseTexture;
		sampler2D _VolumeRandomTex;
		float4 _CameraDepthTexture_TexelSize;
		struct v2f
		{
			float4 pos : SV_POSITION;
			float4 uv : TEXCOORD0;
			float3 wpos : TEXCOORD1;
		};

		v2f vert(appdata v)
		{
			v2f o;
			o.pos = mul(_WorldViewProj, v.vertex);
			o.uv = ComputeScreenPos(o.pos);
			o.wpos = mul(unity_ObjectToWorld, v.vertex);
			return o;
		}


		#define fogFunc(height, intensity) exp(-height * intensity)

		inline float fogFuncIntegret(float2 height, float intensity){
			float2 result = exp(-height * intensity) / (-intensity);
			return result.x - result.y;
		}

		inline float getFog(float3 startPos, float3 endPos, float intensity, float height){
			float3 rayDir = endPos - startPos;
			rayDir = normalize(rayDir);
			float dotValue = dot(rayDir, float3(0,1,0));
		/*	if(abs(dotValue) < 0.002)		//Consider use 
			{
				 float average = dot(float2(rayStartHeight, rayEndHeight), 0.5);
				 float3 fogIntensity = float3(
					 fogFunc(rayStartHeight, intensity),
					 fogFunc(average, intensity),
					 fogFunc(rayEndHeight, intensity)
				 );
				 return dot(fogIntensity, 0.33333333);
			}
			else
			{*/
				return abs(fogFuncIntegret(float2(startPos.y, endPos.y) + height, intensity) / dotValue);
		//	}
		}



		//-----------------------------------------------------------------------------------------
		// GetCascadeWeights_SplitSpheres
		//-----------------------------------------------------------------------------------------
		inline float4 GetCascadeWeights_SplitSpheres(float3 wpos)
		{
			float3 fromCenter0 = wpos.xyz - unity_ShadowSplitSpheres[0].xyz;
			float3 fromCenter1 = wpos.xyz - unity_ShadowSplitSpheres[1].xyz;
			float3 fromCenter2 = wpos.xyz - unity_ShadowSplitSpheres[2].xyz;
			float3 fromCenter3 = wpos.xyz - unity_ShadowSplitSpheres[3].xyz;
			float4 distances2 = float4(dot(fromCenter0, fromCenter0), dot(fromCenter1, fromCenter1), dot(fromCenter2, fromCenter2), dot(fromCenter3, fromCenter3));

			float4 weights = float4(distances2 < unity_ShadowSplitSqRadii);
			weights.yzw = saturate(weights.yzw - weights.xyz);
			return weights;
		}

		//-----------------------------------------------------------------------------------------
		// GetCascadeShadowCoord
		//-----------------------------------------------------------------------------------------
		inline float3 GetCascadeShadowCoord(float4 wpos, float4 cascadeWeights)
		{
			float3 sc0 = mul(unity_WorldToShadow[0], wpos).xyz;
			float3 sc1 = mul(unity_WorldToShadow[1], wpos).xyz;
			float3 sc2 = mul(unity_WorldToShadow[2], wpos).xyz;
			float3 sc3 = mul(unity_WorldToShadow[3], wpos).xyz;
			
			float3 shadowMapCoordinate = float3(sc0 * cascadeWeights[0] + sc1 * cascadeWeights[1] + sc2 * cascadeWeights[2] + sc3 * cascadeWeights[3]);
#if defined(UNITY_REVERSED_Z)
			float  noCascadeWeights = 1 - dot(cascadeWeights, 1);
			shadowMapCoordinate.z += noCascadeWeights;
#endif
			return shadowMapCoordinate;
		}
		
		UNITY_DECLARE_SHADOWMAP(_CascadeShadowMapTexture);
		
		//-----------------------------------------------------------------------------------------
		// GetLightAttenuation
		//-----------------------------------------------------------------------------------------
		float GetLightAttenuation(float3 wpos)
		{
			float atten = 1;
#if SHADOWS_DEPTH_ON
			// sample cascade shadow map
			float4 cascadeWeights = GetCascadeWeights_SplitSpheres(wpos);
		//	float2 weightSum = cascadeWeights.xy + cascadeWeights.zw;
		//	weightSum.x += weightSum.y;
			float3 samplePos = GetCascadeShadowCoord(float4(wpos, 1), cascadeWeights);
			atten = UNITY_SAMPLE_SHADOW(_CascadeShadowMapTexture, samplePos.xyz);
#endif
			return atten;
		}

        //-----------------------------------------------------------------------------------------
        // ApplyHeightFog
        //-----------------------------------------------------------------------------------------
        inline void ApplyHeightFog(float3 wpos, inout float4 density)
        {
            density *= exp(-(wpos.y + _HeightFog.x) * _HeightFog.y);
			//density *= -2 * exp(-(wpos.y + _HeightFog.x) * _HeightFog.y)
        }

        //-----------------------------------------------------------------------------------------
        // GetDensity
        //-----------------------------------------------------------------------------------------
		float GetDensity(float3 wpos)
		{
            float density = 1;
			float noise = tex3D(_NoiseTexture, frac(wpos * _NoiseData.x + float3(_Time.y * _NoiseVelocity.x, 0, _Time.y * _NoiseVelocity.y)));
			noise = saturate(noise - _NoiseData.z) * _NoiseData.y;
			density = saturate(noise);
            return density;
		}        

		//-----------------------------------------------------------------------------------------
		// MieScattering
		//-----------------------------------------------------------------------------------------
		#define MieScattering(cosAngle, g) g.w * (g.x / (pow(g.y - g.z * cosAngle, 1.5)))
		#define random(seed) sin(seed * float2(641.5467987313875, 3154.135764) + float2(1.943856175, 631.543147))
		#define highQualityRandom(seed) cos(sin(seed * float2(641.5467987313875, 3154.135764) + float2(1.943856175, 631.543147)) * float2(4635.4668457, 84796.1653) + float2(6485.15686, 1456.3574563))
		float2 _RandomNumber;
		//-----------------------------------------------------------------------------------------
		// RayMarch
		//-----------------------------------------------------------------------------------------
		float4 RayMarch(float2 screenPos, float3 rayStart, float3 rayDir, float rayLength)
		{
			float4 vlight = 0;

			float cosAngle;
#if defined (DIRECTIONAL) || defined (DIRECTIONAL_COOKIE)
			cosAngle = dot(_LightDir.xyz, -rayDir);
#else
			// we don't know about density between camera and light's volume, assume 0.5
#endif
			float3 final = rayStart + rayDir * rayLength;
			float3 step = 1.0 / _SampleCount;
			step.yz *= float2(0.25, 0.2);
			float2 seed = random((_ScreenParams.y * screenPos.y + screenPos.x) * _ScreenParams.x + _RandomNumber);
			[loop]
			for (float i = step.x; i < 1; i += step.x)
			{
				seed = random(seed);
				float lerpValue = i + seed.y* step.y + seed.x * step.z;
				float3 currentPosition = lerp(rayStart, final, lerpValue);
				float atten = GetLightAttenuation(currentPosition);
				float4 light = atten;
#ifdef NOISE
			light *= GetDensity(currentPosition);
#endif
#ifdef HEIGHT_FOG
		ApplyHeightFog(currentPosition, light);
#endif
//#if PHASE_FUNCTOIN
#if !defined (DIRECTIONAL) && !defined (DIRECTIONAL_COOKIE)
			float extinction = -length(_WorldSpaceCameraPos - currentPosition) * 0.005;
			extinction = exp(-extinction);
				light *= extinction;
				// phase functino for spot and point lights
                float3 tolight = normalize(currentPosition - _LightPos.xyz);
                cosAngle = dot(tolight, -rayDir);
				light *= MieScattering(cosAngle, _MieG);
#endif          
//#endif
				vlight += light;				
			}
			vlight *= rayLength;

#if defined (DIRECTIONAL) || defined (DIRECTIONAL_COOKIE)
			// apply phase function for dir light
			vlight *= MieScattering(cosAngle, _MieG);
#endif

			// apply light's color
			vlight *= _LightFinalColor;

			vlight = max(0, vlight);
#if defined (DIRECTIONAL) || defined (DIRECTIONAL_COOKIE) // use "proper" out-scattering/absorption for dir light 
			vlight.w = 1;

#else
            vlight.w = 0;
#endif
			return vlight;
		}

		//-----------------------------------------------------------------------------------------
		// RayConeIntersect
		//-----------------------------------------------------------------------------------------
		float2 RayConeIntersect(in float3 f3ConeApex, in float3 f3ConeAxis, in float fCosAngle, in float3 f3RayStart, in float3 f3RayDir)
		{
			float inf = 10000;
			f3RayStart -= f3ConeApex;
			float a = dot(f3RayDir, f3ConeAxis);
			float b = dot(f3RayDir, f3RayDir);
			float c = dot(f3RayStart, f3ConeAxis);
			float d = dot(f3RayStart, f3RayDir);
			float e = dot(f3RayStart, f3RayStart);
			fCosAngle *= fCosAngle;
			float A = a*a - b*fCosAngle;
			float B = 2 * (c*a - d*fCosAngle);
			float C = c*c - e*fCosAngle;
			float D = B*B - 4 * A*C;

			if (D > 0)
			{
				D = sqrt(D);
				float2 t = (-B + sign(A)*float2(-D, +D)) / (2 * A);
				bool2 b2IsCorrect = c + a * t > 0 && t > 0;
				t = t * b2IsCorrect + !b2IsCorrect * (inf);
				return t;
			}
			else // no intersection
				return inf;
		}

		//-----------------------------------------------------------------------------------------
		// RayPlaneIntersect
		//-----------------------------------------------------------------------------------------
		float RayPlaneIntersect(in float3 planeNormal, in float planeD, in float3 rayOrigin, in float3 rayDir)
		{
			float NdotD = dot(planeNormal, rayDir);
			float NdotO = dot(planeNormal, rayOrigin);

			float t = -(NdotO + planeD) / NdotD;
			if (t < 0)
				t = 100000;
			return t;
		}

		ENDCG

		// pass 0 - point light, camera inside
		Pass
		{
			ZTest Off
			Cull Front
			ZWrite Off
			Blend One One

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment fragPointInside
			#pragma target 4.0

			#define UNITY_HDR_ON

			#pragma shader_feature HEIGHT_FOG
			#pragma shader_feature NOISE
			#pragma shader_feature SHADOWS_CUBE
			#pragma shader_feature POINT_COOKIE
			#pragma shader_feature POINT

			#ifdef SHADOWS_DEPTH
			
			#endif
						
			
			float4 fragPointInside(v2f i) : SV_Target
			{	
				float2 uv = i.uv.xy / i.uv.w;

				// read depth and reconstruct world position
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);			

				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;

				float linearDepth = LinearEyeDepth(depth);
				float projectedDepth = linearDepth / dot(_CameraForward, rayDir);
				rayLength = min(rayLength, projectedDepth);
				
				return RayMarch(i.pos.xy, rayStart, rayDir, rayLength);
			}
			ENDCG
		}

		// pass 1 - spot light, camera inside
		Pass
		{
			ZTest Off
			Cull Front
			ZWrite Off
			Blend One One

			CGPROGRAM
#pragma vertex vert
#pragma fragment fragPointInside
#pragma target 4.0

#define UNITY_HDR_ON

#pragma shader_feature HEIGHT_FOG
#pragma shader_feature NOISE
#pragma multi_compile SHADOWS_DEPTH_OFF SHADOWS_DEPTH_ON
#pragma shader_feature SPOT

#ifdef SHADOWS_DEPTH

#endif

			float4 fragPointInside(v2f i) : SV_Target
			{
				float2 uv = i.uv.xy / i.uv.w;

				// read depth and reconstruct world position
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);

				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;

				float linearDepth = LinearEyeDepth(depth);
				float projectedDepth = linearDepth / dot(_CameraForward, rayDir);
				rayLength = min(rayLength, projectedDepth);

				return RayMarch(i.pos.xy, rayStart, rayDir, rayLength);
			}
			ENDCG
		}

		// pass 2 - point light, camera outside
		Pass
		{
			//ZTest Off
			ZTest [_ZTest]
			Cull Back
			ZWrite Off
			Blend One One

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment fragPointOutside
			#pragma target 4.0

			#define UNITY_HDR_ON

			#pragma shader_feature HEIGHT_FOG
			#pragma shader_feature SHADOWS_CUBE
			#pragma shader_feature NOISE
			//#pragma multi_compile POINT POINT_COOKIE
			#pragma shader_feature POINT_COOKIE
			#pragma shader_feature POINT

			float4 fragPointOutside(v2f i) : SV_Target
			{
				float2 uv = i.uv.xy / i.uv.w;

				// read depth and reconstruct world position
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
			
				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;

				float3 lightToCamera = _WorldSpaceCameraPos - _LightPos;

				float b = dot(rayDir, lightToCamera);
				float c = dot(lightToCamera, lightToCamera) - (_VolumetricLight.z * _VolumetricLight.z);

				float d = sqrt((b*b) - c);
				float start = -b - d;
				float end = -b + d;

				float linearDepth = LinearEyeDepth(depth);
				float projectedDepth = linearDepth / dot(_CameraForward, rayDir);
				end = min(end, projectedDepth);

				rayStart = rayStart + rayDir * start;
				rayLength = end - start;

				return RayMarch(i.pos.xy, rayStart, rayDir, rayLength);
			}
			ENDCG
		}
				
		// pass 3 - spot light, camera outside
		Pass
		{
			//ZTest Off
			ZTest[_ZTest]
			Cull Back
			ZWrite Off
			Blend One One

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment fragSpotOutside
			#pragma target 4.0

			#define UNITY_HDR_ON

			#pragma shader_feature HEIGHT_FOG
			#pragma multi_compile SHADOWS_DEPTH_OFF SHADOWS_DEPTH_ON
			#pragma shader_feature NOISE
			#pragma shader_feature SPOT

			#ifdef SHADOWS_DEPTH
			
			#endif
			
			float _CosAngle;
			float4 _ConeAxis;
			float4 _ConeApex;
			float _PlaneD;

			float4 fragSpotOutside(v2f i) : SV_Target
			{
				float2 uv = i.uv.xy / i.uv.w;

				// read depth and reconstruct world position
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);

				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - _WorldSpaceCameraPos);
				float rayLength = length(rayDir);

				rayDir /= rayLength;


				// inside cone
				float3 r1 = rayEnd + rayDir * 0.001;

				// plane intersection
				float planeCoord = RayPlaneIntersect(_ConeAxis, _PlaneD, r1, rayDir);
				// ray cone intersection
				float2 lineCoords = RayConeIntersect(_ConeApex, _ConeAxis, _CosAngle, r1, rayDir);

				float linearDepth = LinearEyeDepth(depth);
				float projectedDepth = linearDepth / dot(_CameraForward, rayDir);

				float z = (projectedDepth - rayLength);
				rayLength = min(planeCoord, min(lineCoords.x, lineCoords.y));
				rayLength = min(rayLength, z);

				return RayMarch(i.pos.xy, rayEnd, rayDir, rayLength);
			}
			ENDCG
		}		

		// pass 4 - directional light
		Pass
		{
			ZTest Off
			Cull Off
			ZWrite Off
			Blend off

			CGPROGRAM

			#pragma vertex vertDir
			#pragma fragment fragDir
			#pragma target 4.0

			#define UNITY_HDR_ON

			#pragma shader_feature HEIGHT_FOG
			#pragma shader_feature NOISE
			#pragma multi_compile SHADOWS_DEPTH_OFF SHADOWS_DEPTH_ON
			#pragma shader_feature DIRECTIONAL_COOKIE
			#pragma shader_feature DIRECTIONAL

			#ifdef SHADOWS_DEPTH
			
			#endif

			struct VSInput
			{
				float4 vertex : POSITION;
				float2 uv : TEXCOORD0;
				uint vertexId : SV_VertexID;
			};

			struct PSInput
			{
				float4 pos : SV_POSITION;
				float2 uv : TEXCOORD0;
			};
			float2 _JitterOffset;			
			PSInput vertDir(VSInput i)
			{
				PSInput o;

				o.pos = UnityObjectToClipPos(i.vertex);
				o.uv = i.uv;

				return o;
			}
		
			float4 fragDir(PSInput i) : SV_Target
			{
				float2 uv = i.uv;
				float2 randomOffset = highQualityRandom((_ScreenParams.y * uv.y + uv.x) * _ScreenParams.x + _RandomNumber) * _JitterOffset;
				uv += randomOffset;
				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
				float linearDepth = Linear01Depth(depth);
				float3 down = lerp(_FrustumCorners[0], _FrustumCorners[1], uv.x);
				float3 up = lerp(_FrustumCorners[2], _FrustumCorners[3], uv.x);
				float3 wpos = lerp(down, up, uv.y);
				float3 rayDir = wpos - _WorldSpaceCameraPos;				
				rayDir *= linearDepth;

				float rayLength = length(rayDir);
				rayDir /= rayLength;

				rayLength = min(rayLength, _MaxRayLength);

				float4 color = RayMarch(uv, _WorldSpaceCameraPos, rayDir, rayLength);

				if (linearDepth > 0.9999)
				{
					color.rgb *= _VolumetricLight.w;
				}
				color.w = 0;
				return color;
			}
			ENDCG
		}
	}
}
