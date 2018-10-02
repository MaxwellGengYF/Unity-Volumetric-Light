// Upgrade NOTE: replaced 'mul(UNITY_MATRIX_MVP,*)' with 'UnityObjectToClipPos(*)'

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



Shader "Hidden/BilateralBlur"
{
	Properties
	{
        _MainTex("Texture", any) = "" {}
	}
		SubShader
	{
		// No culling or depth
		Cull Off ZWrite Off ZTest Always

		CGINCLUDE

        //--------------------------------------------------------------------------------------------
        // Downsample, bilateral blur and upsample config
        //--------------------------------------------------------------------------------------------        
        // method used to downsample depth buffer: 0 = min; 1 = max; 2 = min/max in chessboard pattern
        #define DOWNSAMPLE_DEPTH_MODE 2
        #define UPSAMPLE_DEPTH_THRESHOLD 1.5f
        #define BLUR_DEPTH_FACTOR 0.5
        #define GAUSS_BLUR_DEVIATION 1.5    
        #define HALF_RES_BLUR_KERNEL_SIZE 6
		#define THIRD_RES_BLUR_KERNEL_SIZE 5
        #define QUARTER_RES_BLUR_KERNEL_SIZE 4
		#define HALF_RES_BLUR_KERNEL_WEIGHT 5.5
		#define THIRD_RES_BLUR_KERNEL_WEIGHT 4.5
        #define QUARTER_RES_BLUR_KERNEL_WEIGHT 3.5
        //--------------------------------------------------------------------------------------------

#include "UnityCG.cginc"	
			#define HORIZONTALOFFSET float2(1, 0)
			#define VERTICALOFFSET float2(0, 1)

        UNITY_DECLARE_TEX2D(_CameraDepthTexture);        
        UNITY_DECLARE_TEX2D(_Source);        
        UNITY_DECLARE_TEX2D(_QuarterResDepthBuffer);        
        UNITY_DECLARE_TEX2D(_HalfResColor);
        UNITY_DECLARE_TEX2D(_QuarterResColor);
        UNITY_DECLARE_TEX2D(_MainTex);

        float4 _CameraDepthTexture_TexelSize;
        float4 _Source_TexelSize;
        float4 _QuarterResDepthBuffer_TexelSize;
        
		struct appdata
		{
			float4 vertex : POSITION;
			float2 uv : TEXCOORD0;
		};

		struct v2f
		{
			float2 uv : TEXCOORD0;
			float4 vertex : SV_POSITION;
		};

		struct v2fDownsample
		{
#if SHADER_TARGET > 40
			float2 uv : TEXCOORD0;
#else
			float2 uv00 : TEXCOORD0;
			float2 uv01 : TEXCOORD1;
			float2 uv10 : TEXCOORD2;
			float2 uv11 : TEXCOORD3;
#endif
			float4 vertex : SV_POSITION;
		};

		struct v2fUpsample
		{
			float2 uv : TEXCOORD0;
			float2 uv00 : TEXCOORD1;
			float2 uv01 : TEXCOORD2;
			float2 uv10 : TEXCOORD3;
			float2 uv11 : TEXCOORD4;
			float4 vertex : SV_POSITION;
		};

		v2f vert(appdata v)
		{
			v2f o;
			o.vertex = UnityObjectToClipPos(v.vertex);
			o.uv = v.uv;
			return o;
		}

		//-----------------------------------------------------------------------------------------
		// vertDownsampleDepth
		//-----------------------------------------------------------------------------------------
		v2fDownsample vertDownsampleDepth(appdata v, float2 texelSize)
		{
			v2fDownsample o;
			o.vertex = UnityObjectToClipPos(v.vertex);
#if SHADER_TARGET > 40
			o.uv = v.uv;
#else
			o.uv00 = v.uv - 0.5 * texelSize.xy;
			o.uv10 = o.uv00 + float2(texelSize.x, 0);
			o.uv01 = o.uv00 + float2(0, texelSize.y);
			o.uv11 = o.uv00 + texelSize.xy;
#endif
			return o;
		}

		//-----------------------------------------------------------------------------------------
		// vertUpsample
		//-----------------------------------------------------------------------------------------
        v2fUpsample vertUpsample(appdata v, float2 texelSize)
        {
            v2fUpsample o;
            o.vertex = UnityObjectToClipPos(v.vertex);
            o.uv = v.uv;

            o.uv00 = v.uv - 0.5 * texelSize.xy;
            o.uv10 = o.uv00 + float2(texelSize.x, 0);
            o.uv01 = o.uv00 + float2(0, texelSize.y);
            o.uv11 = o.uv00 + texelSize.xy;
            return o;
        }

		//-----------------------------------------------------------------------------------------
		// BilateralUpsample
		//-----------------------------------------------------------------------------------------
		float4 BilateralUpsample(v2fUpsample input, Texture2D hiDepth, Texture2D loDepth, Texture2D loColor, SamplerState linearSampler, SamplerState pointSampler)
		{
            const float threshold = UPSAMPLE_DEPTH_THRESHOLD;
            float4 highResDepth = LinearEyeDepth(hiDepth.Sample(pointSampler, input.uv)).xxxx;
			float4 lowResDepth;

            lowResDepth[0] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv00));
            lowResDepth[1] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv10));
            lowResDepth[2] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv01));
            lowResDepth[3] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv11));

			float4 depthDiff = abs(lowResDepth - highResDepth);

			float accumDiff = dot(depthDiff, float4(1, 1, 1, 1));

			[branch]
			if (accumDiff < threshold) // small error, not an edge -> use bilinear filter
			{
				return loColor.Sample(linearSampler, input.uv);
			}
			float minDepthDiff = depthDiff[0];
			float2 nearestUv = input.uv00;
			[flatten]
			if (depthDiff[1] < minDepthDiff)
			{
				nearestUv = input.uv10;
				minDepthDiff = depthDiff[1];
			}
			[flatten]
			if (depthDiff[2] < minDepthDiff)
			{
				nearestUv = input.uv01;
				minDepthDiff = depthDiff[2];
			}
			[flatten]
			if (depthDiff[3] < minDepthDiff)
			{
				nearestUv = input.uv11;
				minDepthDiff = depthDiff[3];
			}

            return loColor.Sample(pointSampler, nearestUv);
		}
		//-----------------------------------------------------------------------------------------
		// DownsampleDepth
		//-----------------------------------------------------------------------------------------
		float DownsampleDepth(v2fDownsample input, Texture2D depthTexture, SamplerState depthSampler)
		{
#if SHADER_TARGET > 40
            float4 depth = depthTexture.Gather(depthSampler, input.uv);
#else
			float4 depth;
			depth.x = depthTexture.Sample(depthSampler, input.uv00).x;
			depth.y = depthTexture.Sample(depthSampler, input.uv01).x;
			depth.z = depthTexture.Sample(depthSampler, input.uv10).x;
			depth.w = depthTexture.Sample(depthSampler, input.uv11).x;

#endif

#if DOWNSAMPLE_DEPTH_MODE == 0 // min  depth
            return min(min(depth.x, depth.y), min(depth.z, depth.w));
#elif DOWNSAMPLE_DEPTH_MODE == 1 // max  depth
            return max(max(depth.x, depth.y), max(depth.z, depth.w));
#elif DOWNSAMPLE_DEPTH_MODE == 2 // min/max depth in chessboard pattern

			float minDepth = min(min(depth.x, depth.y), min(depth.z, depth.w));
			float maxDepth = max(max(depth.x, depth.y), max(depth.z, depth.w));

			// chessboard pattern
			int2 position = input.vertex.xy % 2;
			int index = position.x + position.y;
			return index == 1 ? minDepth : maxDepth;
#endif
		}
		
		//-----------------------------------------------------------------------------------------
		// GaussianWeight
		//-----------------------------------------------------------------------------------------
		#define PI 3.14159265359f
		#define GaussianWeight(offset, deviation2) (deviation2.y * exp(-(offset * offset) / (deviation2.x)))
		//-----------------------------------------------------------------------------------------
		// BilateralBlur
		//-----------------------------------------------------------------------------------------
		float4 BilateralBlur(float2 uv, const float2 direction, Texture2D depth, SamplerState depthSampler, const int kernelRadius, const float kernelWeight)
		{
			//const float deviation = kernelRadius / 2.5;
			const float dev = kernelWeight / GAUSS_BLUR_DEVIATION; // make it really strong
			const float dev2 = dev * dev * 2;
			const float2 deviation = float2(dev2, 1.0f / (dev2 * PI));
			float4 centerColor = _MainTex.Sample(sampler_MainTex, uv);
			float3 color = centerColor.xyz;
			//return float4(color, 1);
			float centerDepth = (LinearEyeDepth(depth.Sample(depthSampler, uv)));

			float weightSum = 0;

			// gaussian weight is computed from constants only -> will be computed in compile time
            float weight = GaussianWeight(0, deviation);
			color *= weight;
			weightSum += weight;
						
			[unroll] for (int i = -kernelRadius; i < 0; i += 1)
			{
                float2 offset = (direction * i);
                float3 sampleColor = _MainTex.Sample(sampler_MainTex, uv, offset);
                float sampleDepth = (LinearEyeDepth(depth.Sample(depthSampler, uv, offset)));

				float depthDiff = abs(centerDepth - sampleDepth);
                float dFactor = depthDiff * BLUR_DEPTH_FACTOR;	//Should be 0.5
				float w = exp(-(dFactor * dFactor));

				// gaussian weight is computed from constants only -> will be computed in compile time
				weight = GaussianWeight(i, deviation) * w;

				color += weight * sampleColor;
				weightSum += weight;
			}

			[unroll] for (i = 1; i <= kernelRadius; i += 1)
			{
				float2 offset = (direction * i);
                float3 sampleColor = _MainTex.Sample(sampler_MainTex, uv, offset);
                float sampleDepth = (LinearEyeDepth(depth.Sample(depthSampler, uv, offset)));

				float depthDiff = abs(centerDepth - sampleDepth);
                float dFactor = depthDiff * BLUR_DEPTH_FACTOR;	//Should be 0.5
				float w = exp(-(dFactor * dFactor));
				
				// gaussian weight is computed from constants only -> will be computed in compile time
				weight = GaussianWeight(i, deviation) * w;

				color += weight * sampleColor;
				weightSum += weight;
			}

			color /= weightSum;
			return float4(color, centerColor.w);
		}
/*
		float4 BilateralBlur(float2 uv, int2 direction, sampler2D depth, const int kernelRadius)
		{
			//const float deviation = kernelRadius / 2.5;
			const float dev = kernelRadius / GAUSS_BLUR_DEVIATION; // make it really strong
			const float dev2 = dev * dev * 2;
			const float2 deviation = float2(dev2, 1.0f / (dev2 * PI));
			float4 centerColor = tex2D(_MainTex, uv);
			float3 color = centerColor.xyz;
			//return float4(color, 1);
			float centerDepth = (LinearEyeDepth(tex2D(depth, uv)));

			float weightSum = 0;

			// gaussian weight is computed from constants only -> will be computed in compile time
            float weight = GaussianWeight(0, deviation);
			color *= weight;
			weightSum += weight;
						
			[unroll] for (int i = -kernelRadius; i < 0; i += 1)
			{
                float2 offset = (direction * i);
                float3 sampleColor = tex2D(_MainTex, uv + offset);
                float sampleDepth = (LinearEyeDepth(tex2D(depth,uv + offset)));

				float depthDiff = abs(centerDepth - sampleDepth);
                float dFactor = depthDiff * BLUR_DEPTH_FACTOR;	//Should be 0.5
				float w = exp(-(dFactor * dFactor));

				// gaussian weight is computed from constants only -> will be computed in compile time
				weight = GaussianWeight(i, deviation) * w;

				color += weight * sampleColor;
				weightSum += weight;
			}

			[unroll] for (i = 1; i <= kernelRadius; i += 1)
			{
				float2 offset = (direction * i);
                float3 sampleColor = tex2D(_MainTex, uv + offset);
                float sampleDepth = (LinearEyeDepth(tex2D(depth, uv + offset)));

				float depthDiff = abs(centerDepth - sampleDepth);
                float dFactor = depthDiff * BLUR_DEPTH_FACTOR;	//Should be 0.5
				float w = exp(-(dFactor * dFactor));
				weight = GaussianWeight(i, deviation) * w;
				color += weight * sampleColor;
				weightSum += weight;
			}

			color /= weightSum;
			return float4(color, centerColor.w);
		}
*/
		ENDCG


		// pass 0 - horizontal blur (Quater)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment horizontalFrag
            #pragma target 5.0

			float4 horizontalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input.uv, HORIZONTALOFFSET, _Source, sampler_Source, QUARTER_RES_BLUR_KERNEL_SIZE, QUARTER_RES_BLUR_KERNEL_WEIGHT);
		}

			ENDCG
		}

		// pass 1 - vertical blur (Quater)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment verticalFrag
            #pragma target 5.0

			float4 verticalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input.uv, VERTICALOFFSET, _Source, sampler_Source, QUARTER_RES_BLUR_KERNEL_SIZE, QUARTER_RES_BLUR_KERNEL_WEIGHT);
		}

			ENDCG
		}

		// pass 2 - horizontal blur (lores)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment horizontalFrag
            #pragma target 5.0

			float4 horizontalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input.uv, HORIZONTALOFFSET, _Source, sampler_Source, HALF_RES_BLUR_KERNEL_SIZE, HALF_RES_BLUR_KERNEL_WEIGHT);
		}

			ENDCG
		}

		// pass 3 - vertical blur (lores)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment verticalFrag
            #pragma target 5.0

			float4 verticalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input.uv, VERTICALOFFSET, _Source, sampler_Source, HALF_RES_BLUR_KERNEL_SIZE, HALF_RES_BLUR_KERNEL_WEIGHT);
		}

			ENDCG
		}

		// pass 4 - downsample depth to half
		Pass
		{
			CGPROGRAM
			#pragma vertex vertHalfDepth
			#pragma fragment frag
            #pragma target gl4.1

			v2fDownsample vertHalfDepth(appdata v)
			{
                return vertDownsampleDepth(v, _CameraDepthTexture_TexelSize);
			}

			float frag(v2fDownsample input) : SV_Target
			{
                return DownsampleDepth(input, _CameraDepthTexture, sampler_CameraDepthTexture);
			}

			ENDCG
		}

		// pass 5 - bilateral upsample
		Pass
		{
			Blend One Zero

			CGPROGRAM
			#pragma vertex vertUpsampleToFull
			#pragma fragment frag		
            #pragma target 5.0

			v2fUpsample vertUpsampleToFull(appdata v)
			{
                return vertUpsample(v, _Source_TexelSize);
			}
			float4 frag(v2fUpsample input) : SV_Target
			{
				return BilateralUpsample(input, _CameraDepthTexture, _Source, _HalfResColor, sampler_HalfResColor, sampler_Source);
			}

			ENDCG
		}

		// pass 6 - downsample depth to quarter
		Pass
		{
			CGPROGRAM
            #pragma vertex vertQuarterDepth
            #pragma fragment frag
            #pragma target gl4.1

			v2fDownsample vertQuarterDepth(appdata v)
			{
                return vertDownsampleDepth(v, _Source_TexelSize);
			}

			float frag(v2fDownsample input) : SV_Target
			{
                return DownsampleDepth(input, _Source, sampler_Source);
			}

			ENDCG
		}

		// pass 7 - bilateral upsample quarter to full
		Pass
		{
			Blend One Zero

			CGPROGRAM
            #pragma vertex vertUpsampleToFull
            #pragma fragment frag		
            #pragma target 5.0

			v2fUpsample vertUpsampleToFull(appdata v)
			{
                return vertUpsample(v, _QuarterResDepthBuffer_TexelSize);
			}
			float4 frag(v2fUpsample input) : SV_Target
			{
                return BilateralUpsample(input, _CameraDepthTexture, _QuarterResDepthBuffer, _QuarterResColor, sampler_QuarterResColor, sampler_QuarterResDepthBuffer);
			}

			ENDCG
		}

		// pass 8 - horizontal blur (Third)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment horizontalFrag
            #pragma target 5.0

			float4 horizontalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input.uv, HORIZONTALOFFSET, _Source, sampler_Source, THIRD_RES_BLUR_KERNEL_SIZE, THIRD_RES_BLUR_KERNEL_WEIGHT);
		}

			ENDCG
		}

		// pass 9 - vertical blur (Third)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment verticalFrag
            #pragma target 5.0

			float4 verticalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input.uv, VERTICALOFFSET, _Source, sampler_Source, THIRD_RES_BLUR_KERNEL_SIZE, THIRD_RES_BLUR_KERNEL_WEIGHT);
		}

			ENDCG
		}
	}
}
