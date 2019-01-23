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

		float4 _LightFinalColor;
		struct appdata
		{
			float4 vertex : POSITION;
		};
		
		float4x4 _WorldViewProj;
		float4x4 _MyLightMatrix0;
		float4x4 _MyWorld2Shadow;
		float3 _CameraForward;
		float4x4 _InvVP;

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
        inline void ApplyHeightFog(float3 wpos, inout float density)
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
		float _Density;
		float4 ScatterStep(float3 accumulatedLight, float accumulatedTransmittance, float sliceLight, float sliceDensity)
		{
			sliceDensity = max(sliceDensity, 0.000001);
			float  sliceTransmittance = exp(-sliceDensity / _SampleCount);

	// Seb Hillaire's improved transmission by calculating an integral over slice depth instead of
	// constant per slice value. Light still constant per slice, but that's acceptable. See slide 28 of
	// Physically-based & Unified Volumetric Rendering in Frostbite
	// http://www.frostbite.com/2015/08/physically-based-unified-volumetric-rendering-in-frostbite/
			float3 sliceLightIntegral = sliceLight * (1.0 - sliceTransmittance) / sliceDensity;

			accumulatedLight += sliceLightIntegral * accumulatedTransmittance;
			accumulatedTransmittance *= sliceTransmittance;
	
			return float4(accumulatedLight, accumulatedTransmittance);
		}
		//-----------------------------------------------------------------------------------------
		// RayMarch
		//-----------------------------------------------------------------------------------------
		float4 RayMarch(float2 screenPos, float3 rayStart, float3 final, float3 rayDir, float rate)
		{
			float4 vlight = float4(0, 0, 0, 1);
			rate *= _Density;
			float cosAngle;
#if defined (DIRECTIONAL) || defined (DIRECTIONAL_COOKIE)
			cosAngle = dot(_LightDir.xyz, -rayDir);
#else
			// we don't know about density between camera and light's volume, assume 0.5
#endif
			//float3 final = rayStart + rayDir * rayLength;
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
#ifdef HEIGHT_FOG
		ApplyHeightFog(currentPosition, atten);
#endif
#if defined (DIRECTIONAL) || defined (DIRECTIONAL_COOKIE)
			// apply phase function for dir light
			atten *= MieScattering(cosAngle, _MieG);
#endif
				vlight = ScatterStep(vlight.rgb, vlight.a, atten, rate);				
			}
			// apply light's color
			vlight.rgb *= _LightFinalColor;
			vlight.a = saturate(vlight.a);
			return vlight;
		}

		ENDCG
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
				float4 wpos = mul(_InvVP, float4(uv * 2 -1,depth, 1));
				wpos /= wpos.w;
				float3 rayDir = wpos.xyz - _WorldSpaceCameraPos;
				float rayLength = length(rayDir);
				rayDir /= rayLength;
				rayLength = min(rayLength, _MaxRayLength);
				float3 final = _WorldSpaceCameraPos + rayDir * rayLength;
				float4 color = RayMarch(uv, _WorldSpaceCameraPos, final, rayDir, rayLength / _MaxRayLength);
				if (Linear01Depth(depth) > 0.9999)
				{
					color.rgb *= _VolumetricLight.w;
				}
				return color;
			}
			ENDCG
		}
	}
}