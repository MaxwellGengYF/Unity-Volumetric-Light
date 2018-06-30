Shader "Maxwell/GodRay"
{
	SubShader
	{
		//Get Random noise
		Pass{
			ZWrite off Cull off ZTest Always
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			#include "UnityCG.cginc"
			sampler3D_float _VolumeTex;
			float _SamplePos;
			struct appdata
			{
				float4 vertex : POSITION;
				float2 uv : TEXCOORD0;
			};

			struct v2f
			{
				float2 uv : TEXCOORD0;
				float4 pos : SV_POSITION;
			};

			v2f vert (appdata v)
			{
				v2f o;
				o.pos = UnityObjectToClipPos(v.vertex);
				o.uv = v.uv;
				return o;
			}
			
			float4 frag (v2f i) : SV_Target
			{
				float4 tex = tex3D(_VolumeTex, float3(i.uv, _SamplePos));
				return tex;
			}
			ENDCG
		}

		//Front localPos
		Pass
		{
			Cull Back
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			
			#include "UnityCG.cginc"

			struct v2f
			{
				float4 pos : SV_POSITION;
			};

			v2f vert (float4 vertex : POSITION)
			{
				v2f o;
				o.pos = UnityObjectToClipPos(vertex);
				return o;
			}
			
			float4 frag (v2f i) : SV_Target
			{
				i.pos /= i.pos.w;
				return i.pos.z;
			}
			ENDCG
		}

		Pass{
			Cull Front
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#include "UnityCG.cginc"
			sampler2D_float _FrontDepthTex;
			sampler2D _NoiseTex;
			float4x4 _InvVPMatrix;
			float4x4 _WorldToLocalMatrix;
			float4 _SunColor;
			struct v2f{
				float4 pos : SV_POSITION;
				float4 uv : TEXCOORD0;
				float3 worldPos : TEXCOORD1;
			};

			v2f vert(float4 vertex : POSITION){
				v2f o;
				o.pos = UnityObjectToClipPos(vertex);
				o.uv = ComputeScreenPos(o.pos);
				o.worldPos = mul(unity_ObjectToWorld, vertex);
				return o;
			}
#define STEP 64
			float4 frag(v2f i) : SV_Target{
				float depth = tex2Dproj(_FrontDepthTex, i.uv);
				float2 iPos = i.pos.xy / i.pos.w;
				float4 projPos = float4(iPos, depth, 1);
				float4 rayStart = mul(_InvVPMatrix, projPos);
				rayStart /= rayStart.w;
				float3 rayDir = i.worldPos - rayStart.xyz;
				float rayLength = length(rayDir);
				rayDir /= STEP;
				float3 currentPos = rayStart;
				float result = 0;
				for(int i = 0; i < STEP; ++i){
					currentPos += rayDir;
					float3 localPos = mul(_WorldToLocalMatrix, float4(currentPos, 1));
					result += tex2D(_NoiseTex, localPos.xz + 0.5);
				}
				result /= STEP;
				return result * rayLength * _SunColor;
			}
			ENDCG
		}
	}
}
