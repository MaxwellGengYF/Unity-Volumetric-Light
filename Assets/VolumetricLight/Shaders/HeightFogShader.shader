// Upgrade NOTE: replaced 'mul(UNITY_MATRIX_MVP,*)' with 'UnityObjectToClipPos(*)'

Shader "Hidden/HeightFogShader"
{
	Properties
	{
		_MainTex ("Texture", 2D) = "white" {}
	}
	SubShader
	{

	CGINCLUDE
			Texture2D _MainTex; SamplerState sampler_MainTex;
			#pragma vertex vert
			#pragma fragment frag
			
			#include "UnityCG.cginc"

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

			v2f vert (appdata v)
			{
				v2f o;
				o.vertex = UnityObjectToClipPos(v.vertex);
				o.uv = v.uv;
				return o;
			}

	ENDCG
		// No culling or depth
		Cull Off ZWrite Off ZTest Always
		Pass
		{
			CGPROGRAM
			Texture2D _CameraDepthTexture;
			SamplerState sampler_CameraDepthTexture;
			float4x4 _InvVP;
			float4 frag (v2f i) : SV_Target
			{
				return _MainTex.SampleLevel(sampler_MainTex, i.uv, 4);
			}
			ENDCG
		}
	}
}
