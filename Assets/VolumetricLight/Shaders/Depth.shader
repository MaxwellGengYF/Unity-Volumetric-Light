// Upgrade NOTE: replaced 'mul(UNITY_MATRIX_MVP,*)' with 'UnityObjectToClipPos(*)'

Shader "Hidden/DepthVolume"
{
	SubShader
	{
		
		Tags{"Queue" = "Transparent"}
		Pass
		{
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#include "UnityCG.cginc"
			float4x4 _CurrentMVP;
			float4 vert (float4 vertex : POSITION) : SV_POSITION
			{
				
				return mul(_CurrentMVP, vertex);
				
			}
			
			float frag (float4 vertex : SV_POSITION) : SV_Target
			{
				vertex /= vertex.w;
				return vertex.z;
			}
			ENDCG
		}
	}
}
