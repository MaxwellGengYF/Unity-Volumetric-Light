// Collects cascaded shadows into screen space buffer
Shader "Hidden/PCSS_Directional" {
Properties {
    _ShadowMapTexture ("", any) = "" {}
    _ODSWorldTexture("", 2D) = "" {}
}

CGINCLUDE

UNITY_DECLARE_SHADOWMAP(_ShadowMapTexture);
float4 _ShadowMapTexture_TexelSize;
#define SHADOWMAPSAMPLER_AND_TEXELSIZE_DEFINED
sampler2D _ODSWorldTexture;

#include "UnityCG.cginc"
#include "UnityShadowLibrary.cginc"

// Configuration


// Should receiver plane bias be used? This estimates receiver slope using derivatives,
// and tries to tilt the PCF kernel along it. However, since we're doing it in screenspace
// from the depth texture, the derivatives are wrong on edges or intersections of objects,
// leading to possible shadow artifacts. So it's disabled by default.
// See also UnityGetReceiverPlaneDepthBias in UnityShadowLibrary.cginc.
//#define UNITY_USE_RECEIVER_PLANE_BIAS


// Blend between shadow cascades to hide the transition seams?
#define UNITY_USE_CASCADE_BLENDING 0
#define UNITY_CASCADE_BLEND_DISTANCE 0.1


struct appdata {
    float4 vertex : POSITION;
    float2 texcoord : TEXCOORD0;
#ifdef UNITY_STEREO_INSTANCING_ENABLED
    float3 ray0 : TEXCOORD1;
    float3 ray1 : TEXCOORD2;
#else
    float3 ray : TEXCOORD1;
#endif
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct v2f {

    float4 pos : SV_POSITION;

    // xy uv / zw screenpos
    float4 uv : TEXCOORD0;
    // View space ray, for perspective case
    float3 ray : TEXCOORD1;
    // Orthographic view space positions (need xy as well for oblique matrices)
    float3 orthoPosNear : TEXCOORD2;
    float3 orthoPosFar  : TEXCOORD3;
    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

v2f vert (appdata v)
{
    v2f o;
    UNITY_SETUP_INSTANCE_ID(v);
    UNITY_TRANSFER_INSTANCE_ID(v, o);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
    float4 clipPos;
#if defined(STEREO_CUBEMAP_RENDER_ON)
    clipPos = mul(UNITY_MATRIX_VP, mul(unity_ObjectToWorld, v.vertex));
#else
    clipPos = UnityObjectToClipPos(v.vertex);
#endif
    o.pos = clipPos;
    o.uv.xy = v.texcoord;

    // unity_CameraInvProjection at the PS level.
    o.uv.zw = ComputeNonStereoScreenPos(clipPos);

    // Perspective case
#ifdef UNITY_STEREO_INSTANCING_ENABLED
    o.ray = unity_StereoEyeIndex ? v.ray1 : v.ray0;
#else
    o.ray = v.ray;
#endif

    // To compute view space position from Z buffer for orthographic case,
    // we need different code than for perspective case. We want to avoid
    // doing matrix multiply in the pixel shader: less operations, and less
    // constant registers used. Particularly with constant registers, having
    // unity_CameraInvProjection in the pixel shader would push the PS over SM2.0
    // limits.
    clipPos.y *= _ProjectionParams.x;
    float3 orthoPosNear = mul(unity_CameraInvProjection, float4(clipPos.x,clipPos.y,-1,1)).xyz;
    float3 orthoPosFar  = mul(unity_CameraInvProjection, float4(clipPos.x,clipPos.y, 1,1)).xyz;
    orthoPosNear.z *= -1;
    orthoPosFar.z *= -1;
    o.orthoPosNear = orthoPosNear;
    o.orthoPosFar = orthoPosFar;

    return o;
}

// ------------------------------------------------------------------
//  Helpers
// ------------------------------------------------------------------
UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);
// sizes of cascade projections, relative to first one
float4 unity_ShadowCascadeScales;

//
// Keywords based defines
//
#if defined (SHADOWS_SPLIT_SPHERES)
    #define GET_CASCADE_WEIGHTS(wpos, z)	getCascadeWeights_splitSpheres(wpos)
#else
    #define GET_CASCADE_WEIGHTS(wpos, z)    getCascadeWeights( wpos, z )
#endif

#if defined (SHADOWS_SINGLE_CASCADE)
    #define GET_SHADOW_COORDINATES(wpos,cascadeWeights) getShadowCoord_SingleCascade(wpos)
#else
    #define GET_SHADOW_COORDINATES(wpos,cascadeWeights) getShadowCoord(wpos,cascadeWeights)
#endif

/**
 * Gets the cascade weights based on the world position of the fragment.
 * Returns a float4 with only one component set that corresponds to the appropriate cascade.
 */
inline half4 getCascadeWeights(float3 wpos, float z)
{
    half4 zNear = float4( z >= _LightSplitsNear );
    half4 zFar = float4( z < _LightSplitsFar );
    half4 weights = zNear * zFar;
    return weights;
}

/**
 * Gets the cascade weights based on the world position of the fragment and the poisitions of the split spheres for each cascade.
 * Returns a float4 with only one component set that corresponds to the appropriate cascade.
 */
inline half4 getCascadeWeights_splitSpheres(float3 wpos)
{
    float3 fromCenter0 = wpos.xyz - unity_ShadowSplitSpheres[0].xyz;
    float3 fromCenter1 = wpos.xyz - unity_ShadowSplitSpheres[1].xyz;
    float3 fromCenter2 = wpos.xyz - unity_ShadowSplitSpheres[2].xyz;
    float3 fromCenter3 = wpos.xyz - unity_ShadowSplitSpheres[3].xyz;
    float4 distances2 = float4(dot(fromCenter0,fromCenter0), dot(fromCenter1,fromCenter1), dot(fromCenter2,fromCenter2), dot(fromCenter3,fromCenter3));
    half4 weights = float4(distances2 < unity_ShadowSplitSqRadii);
    weights.yzw = saturate(weights.yzw - weights.xyz);
    return weights;
}

/**
 * Returns the shadowmap coordinates for the given fragment based on the world position and z-depth.
 * These coordinates belong to the shadowmap atlas that contains the maps for all cascades.
 */
inline float4 getShadowCoord( float4 wpos, half4 cascadeWeights )
{
    float3 sc0 = mul (unity_WorldToShadow[0], wpos).xyz;
    float3 sc1 = mul (unity_WorldToShadow[1], wpos).xyz;
    float3 sc2 = mul (unity_WorldToShadow[2], wpos).xyz;
    float3 sc3 = mul (unity_WorldToShadow[3], wpos).xyz;
    float4 shadowMapCoordinate = float4(sc0 * cascadeWeights[0] + sc1 * cascadeWeights[1] + sc2 * cascadeWeights[2] + sc3 * cascadeWeights[3], 1);
#if defined(UNITY_REVERSED_Z)
    float  noCascadeWeights = 1 - dot(cascadeWeights, float4(1, 1, 1, 1));
    shadowMapCoordinate.z += noCascadeWeights;
#endif
    return shadowMapCoordinate;
}

/**
 * Same as the getShadowCoord; but optimized for single cascade
 */
inline float4 getShadowCoord_SingleCascade( float4 wpos )
{
    return float4( mul (unity_WorldToShadow[0], wpos).xyz, 0);
}

/**
* Get camera space coord from depth and inv projection matrices
*/
inline float3 computeCameraSpacePosFromDepthAndInvProjMat(v2f i)
{
    float zdepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, i.uv.xy);

    #if defined(UNITY_REVERSED_Z)
        zdepth = 1 - zdepth;
    #endif

    // View position calculation for oblique clipped projection case.
    // this will not be as precise nor as fast as the other method
    // (which computes it from interpolated ray & depth) but will work
    // with funky projections.
    float4 clipPos = float4(i.uv.zw, zdepth, 1.0);
    clipPos.xyz = 2.0f * clipPos.xyz - 1.0f;
    float4 camPos = mul(unity_CameraInvProjection, clipPos);
    camPos.xyz /= camPos.w;
    camPos.z *= -1;
    return camPos.xyz;
}

/**
* Get camera space coord from depth and info from VS
*/
inline float3 computeCameraSpacePosFromDepthAndVSInfo(v2f i)
{
    float zdepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, i.uv.xy);

    // 0..1 linear depth, 0 at camera, 1 at far plane.
    float depth = lerp(Linear01Depth(zdepth), zdepth, unity_OrthoParams.w);
#if defined(UNITY_REVERSED_Z)
    zdepth = 1 - zdepth;
#endif

    // view position calculation for perspective & ortho cases
    float3 vposPersp = i.ray * depth;
    float3 vposOrtho = lerp(i.orthoPosNear, i.orthoPosFar, zdepth);
    // pick the perspective or ortho position as needed
    float3 camPos = lerp(vposPersp, vposOrtho, unity_OrthoParams.w);
    return camPos.xyz;
}

inline float3 computeCameraSpacePosFromDepth(v2f i);

//PCSS START--------------------------------------------------------------------------------------------------------------------------------------------------------------

// Tip: To enable a feature uncomment the #define line. To disable a feature comment the #define line.

// Should receiver plane bias be used? This estimates receiver slope using derivatives,
// and tries to tilt the PCF kernel along it. However, since we're doing it in screenspace
// from the depth texture, the derivatives are wrong on edges or intersections of objects,
// leading to possible shadow artifacts. So it's disabled by default.

//#define PCSS_USE_RECEIVER_PLANE_BIAS//If enabled you better disable light Bias and Normal Bias entirelly. Otherwise you are biasing shadows twice
#if defined(PCSS_USE_RECEIVER_PLANE_BIAS)
#define PCSS_RECEIVER_PLANE_BIAS 0.1
#endif

uniform float PCSS_CASCADE_BLEND_DISTANCE = 0.25;

#define PCSS_USE_POISSON_SAMPLING_DIR
uniform float PCSS_POISSON_SAMPLING_NOISE_DIR = 1.0;

//We dont need to bail out lower than 32 samplers
#if defined(PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR) && (defined(DIR_POISSON_32) || defined(DIR_POISSON_64))
#define PCSS_CAN_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
#endif

#if UNITY_VERSION > 565 && defined(PCSS_PCSS_FILTER_DIR) && (SHADER_TARGET >= 35)
SamplerState my_point_clamp_smp2;
#define PCSS_CAN_USE_PCSS_FILTER_DIR
#endif

uniform float PCSS_PCSS_GLOBAL_SOFTNESS = 0.01;
uniform float PCSS_PCSS_FILTER_DIR_MIN = 0.05;
uniform float PCSS_PCSS_FILTER_DIR_MAX = 0.25;
uniform float PCSS_BIAS_FADE_DIR = 0.001;

#if defined(DIR_POISSON_64)
static const float Dir_Samplers_Count = 64;
static const float2 DirPoissonDisks[64] =
{
	float2 ( 0.1187053, 0.7951565),
	float2 ( 0.1173675, 0.6087878),
	float2 ( -0.09958518, 0.7248842),
	float2 ( 0.4259812, 0.6152718),
	float2 ( 0.3723574, 0.8892787),
	float2 ( -0.02289676, 0.9972908),
	float2 ( -0.08234791, 0.5048386),
	float2 ( 0.1821235, 0.9673787),
	float2 ( -0.2137264, 0.9011746),
	float2 ( 0.3115066, 0.4205415),
	float2 ( 0.1216329, 0.383266),
	float2 ( 0.5948939, 0.7594361),
	float2 ( 0.7576465, 0.5336417),
	float2 ( -0.521125, 0.7599803),
	float2 ( -0.2923127, 0.6545699),
	float2 ( 0.6782473, 0.22385),
	float2 ( -0.3077152, 0.4697627),
	float2 ( 0.4484913, 0.2619455),
	float2 ( -0.5308799, 0.4998215),
	float2 ( -0.7379634, 0.5304936),
	float2 ( 0.02613133, 0.1764302),
	float2 ( -0.1461073, 0.3047384),
	float2 ( -0.8451027, 0.3249073),
	float2 ( -0.4507707, 0.2101997),
	float2 ( -0.6137282, 0.3283674),
	float2 ( -0.2385868, 0.08716244),
	float2 ( 0.3386548, 0.01528411),
	float2 ( -0.04230833, -0.1494652),
	float2 ( 0.167115, -0.1098648),
	float2 ( -0.525606, 0.01572019),
	float2 ( -0.7966855, 0.1318727),
	float2 ( 0.5704287, 0.4778273),
	float2 ( -0.9516637, 0.002725032),
	float2 ( -0.7068223, -0.1572321),
	float2 ( 0.2173306, -0.3494083),
	float2 ( 0.06100426, -0.4492816),
	float2 ( 0.2333982, 0.2247189),
	float2 ( 0.07270987, -0.6396734),
	float2 ( 0.4670808, -0.2324669),
	float2 ( 0.3729528, -0.512625),
	float2 ( 0.5675077, -0.4054544),
	float2 ( -0.3691984, -0.128435),
	float2 ( 0.8752473, 0.2256988),
	float2 ( -0.2680127, -0.4684393),
	float2 ( -0.1177551, -0.7205751),
	float2 ( -0.1270121, -0.3105424),
	float2 ( 0.5595394, -0.06309237),
	float2 ( -0.9299136, -0.1870008),
	float2 ( 0.974674, 0.03677348),
	float2 ( 0.7726735, -0.06944724),
	float2 ( -0.4995361, -0.3663749),
	float2 ( 0.6474168, -0.2315787),
	float2 ( 0.1911449, -0.8858921),
	float2 ( 0.3671001, -0.7970535),
	float2 ( -0.6970353, -0.4449432),
	float2 ( -0.417599, -0.7189326),
	float2 ( -0.5584748, -0.6026504),
	float2 ( -0.02624448, -0.9141423),
	float2 ( 0.565636, -0.6585149),
	float2 ( -0.874976, -0.3997879),
	float2 ( 0.9177843, -0.2110524),
	float2 ( 0.8156927, -0.3969557),
	float2 ( -0.2833054, -0.8395444),
	float2 ( 0.799141, -0.5886372)
};

#elif defined(DIR_POISSON_32)
static const float Dir_Samplers_Count = 32;
static const float2 DirPoissonDisks[32] =
{
	float2 ( 0.4873902, -0.8569599),
	float2 ( 0.3463737, -0.3387939),
	float2 ( 0.6290055, -0.4735314),
	float2 ( 0.1855854, -0.8848142),
	float2 ( 0.7677917, 0.02691162),
	float2 ( 0.3009142, -0.6365873),
	float2 ( 0.4268422, -0.006137629),
	float2 ( -0.06682982, -0.7833805),
	float2 ( 0.0347263, -0.3994124),
	float2 ( 0.4494694, 0.5206614),
	float2 ( 0.219377, 0.2438844),
	float2 ( 0.1285765, -0.1215554),
	float2 ( 0.8907049, 0.4334931),
	float2 ( 0.2556469, 0.766552),
	float2 ( -0.03692406, 0.3629236),
	float2 ( 0.6651103, 0.7286811),
	float2 ( -0.429309, -0.2282262),
	float2 ( -0.2730969, -0.4683513),
	float2 ( -0.2755986, 0.7327913),
	float2 ( -0.3329705, 0.1754638),
	float2 ( -0.1731326, -0.1087716),
	float2 ( 0.9212226, -0.3716638),
	float2 ( -0.5388235, 0.4603968),
	float2 ( -0.6307321, 0.7615924),
	float2 ( -0.7709175, -0.08894937),
	float2 ( -0.7205971, -0.3609493),
	float2 ( -0.5386202, -0.5847159),
	float2 ( -0.6520834, 0.1785284),
	float2 ( -0.9310582, 0.2040343),
	float2 ( -0.828178, 0.5559599),
	float2 ( 0.6297836, 0.2946501),
	float2 ( -0.05836084, 0.9006807)
};

#elif defined(DIR_POISSON_25)
static const float Dir_Samplers_Count = 25;
static const float2 DirPoissonDisks[25] =
{
	float2 ( -0.6351818f, 0.2172711f),
	float2 ( -0.1499606f, 0.2320675f),
	float2 ( -0.67978f, 0.6884924f),
	float2 ( -0.7758647f, -0.253409f),
	float2 ( -0.4731916f, -0.2832723f),
	float2 ( -0.3330079f, 0.6430059f),
	float2 ( -0.1384151f, -0.09830225f),
	float2 ( -0.8182327f, -0.5645939f),
	float2 ( -0.9198472f, 0.06549802f),
	float2 ( -0.1422085f, -0.4872109f),
	float2 ( -0.4980833f, -0.5885599f),
	float2 ( -0.3326159f, -0.8496148f),
	float2 ( 0.3066736f, -0.1401997f),
	float2 ( 0.1148317f, 0.374455f),
	float2 ( -0.0388568f, 0.8071329f),
	float2 ( 0.4102885f, 0.6960295f),
	float2 ( 0.5563877f, 0.3375377f),
	float2 ( -0.01786576f, -0.8873765f),
	float2 ( 0.234991f, -0.4558438f),
	float2 ( 0.6206775f, -0.1551005f),
	float2 ( 0.6640642f, -0.5691427f),
	float2 ( 0.7312726f, 0.5830168f),
	float2 ( 0.8879707f, 0.05715213f),
	float2 ( 0.3128296f, -0.830803f),
	float2 ( 0.8689764f, -0.3397973f)
};

#else
static const float Dir_Samplers_Count = 16;
static const float2 DirPoissonDisks[16] =
{
	float2( 0.1232981, -0.03923375),
	float2( -0.5625377, -0.3602428),
	float2( 0.6403719, 0.06821123),
	float2( 0.2813387, -0.5881588),
	float2( -0.5731218, 0.2700572),
	float2( 0.2033166, 0.4197739),
	float2( 0.8467958, -0.3545584),
	float2( -0.4230451, -0.797441),
	float2( 0.7190253, 0.5693575),
	float2( 0.03815468, -0.9914171),
	float2( -0.2236265, 0.5028614),
	float2( 0.1722254, 0.983663),
	float2( -0.2912464, 0.8980512),
	float2( -0.8984148, -0.08762786),
	float2( -0.6995085, 0.6734185),
	float2( -0.293196, -0.06289119)
};

#endif

static const float2 DirPoissonDisksTest[16] =
{
	float2( 0.1232981, -0.03923375),
	float2( -0.5625377, -0.3602428),
	float2( 0.6403719, 0.06821123),
	float2( 0.2813387, -0.5881588),
	float2( -0.5731218, 0.2700572),
	float2( 0.2033166, 0.4197739),
	float2( 0.8467958, -0.3545584),
	float2( -0.4230451, -0.797441),
	float2( 0.7190253, 0.5693575),
	float2( 0.03815468, -0.9914171),
	float2( -0.2236265, 0.5028614),
	float2( 0.1722254, 0.983663),
	float2( -0.2912464, 0.8980512),
	float2( -0.8984148, -0.08762786),
	float2( -0.6995085, 0.6734185),
	float2( -0.293196, -0.06289119)
};

//Will help store temporary rotations
float3 DirPoissonDisksOffsets[64];

//Returns projected value between 0 and 1
inline float DirRandValue01(float3 seed)
{
   float dt = dot(seed, float3(12.9898,78.233,45.5432) * _Time.xyz);// project seed on random constant vector   
   return frac(sin(dt) * 43758.5453);// return only fractional part
}

//Scales the value
float DirRandAngle(float3 seed)
{
	#if defined(PCSS_NOISE_STATIC_DIR)
	return DirRandValue01(seed);
	#else
	return DirRandValue01(seed) * PCSS_POISSON_SAMPLING_NOISE_DIR * 0.05;// clamp(PCSS_POISSON_SAMPLING_NOISE_DIR, 0.0, 10.0);
	#endif
}

float3 UnityGetReceiverPlaneDepthBiasPCSS(float3 shadowCoord, float biasMultiply)
{
	// Should receiver plane bias be used? This estimates receiver slope using derivatives,
	// and tries to tilt the PCF kernel along it. However, when doing it in screenspace from the depth texture
	// (ie all light in deferred and directional light in both forward and deferred), the derivatives are wrong
	// on edges or intersections of objects, leading to shadow artifacts. Thus it is disabled by default.
	float3 biasUVZ = 0;

#if defined(PCSS_USE_RECEIVER_PLANE_BIAS) && defined(SHADOWMAPSAMPLER_AND_TEXELSIZE_DEFINED)
	float3 dx = ddx(shadowCoord);
	float3 dy = ddy(shadowCoord);

	biasUVZ.x = dy.y * dx.z - dx.y * dy.z;
	biasUVZ.y = dx.x * dy.z - dy.x * dx.z;
	biasUVZ.xy *= biasMultiply / ((dx.x * dy.y) - (dx.y * dy.x));

	// Static depth biasing to make up for incorrect fractional sampling on the shadow map grid.
	//const float UNITY_RECEIVER_PLANE_MIN_FRACTIONAL_ERROR = 0.01f;
	float fractionalSamplingError = dot(_ShadowMapTexture_TexelSize.xy, abs(biasUVZ.xy));
	biasUVZ.z = -min(fractionalSamplingError, PCSS_RECEIVER_PLANE_BIAS);
#if defined(UNITY_REVERSED_Z)
	biasUVZ.z *= -1;
#endif
#endif

	return biasUVZ;
}

#if defined(PCSS_CAN_USE_PCSS_FILTER_DIR)
//BlockerSearch
float2 BlockerSearch(float2 uv, float receiver, float searchUV, float3 receiverPlaneDepthBias, float c, float s, float Sampler_Number)
{
	float avgBlockerDepth = 0.0;
	float numBlockers = 0.0;
	float blockerSum = 0.0;

	UNITY_LOOP
	for (int i = 0; i < Sampler_Number; i++)
	{
		float2 offset = DirPoissonDisks[i] * searchUV;
		
#if defined(PCSS_USE_POISSON_SAMPLING_DIR)		
		offset = float2(offset.x * c - offset.y * s, offset.y * c + offset.x * s);
#endif

		float depthBiased = receiver;
		
#if defined(PCSS_USE_RECEIVER_PLANE_BIAS)
		float shadowMapDepth = _ShadowMapTexture.SampleLevel(my_point_clamp_smp2, UnityCombineShadowcoordComponents(uv.xy, offset, depthBiased, receiverPlaneDepthBias).xy, 0.0);
#else
		float shadowMapDepth = _ShadowMapTexture.SampleLevel(my_point_clamp_smp2, uv + offset, 0.0);
#endif

#if defined(UNITY_REVERSED_Z)
		if (shadowMapDepth >= depthBiased)
#else
		if (shadowMapDepth <= depthBiased)
#endif
		{
			blockerSum += shadowMapDepth;
			numBlockers += 1.0;
		}
	}

	avgBlockerDepth = blockerSum / numBlockers;

#if defined(UNITY_REVERSED_Z)
	avgBlockerDepth = 1.0 - avgBlockerDepth;
#endif

	return float2(avgBlockerDepth, numBlockers);
}
#endif//PCSS_CAN_USE_PCSS_FILTER_DIR

//PCF
float PCF_FilterDir(float2 uv, float receiver, float diskRadius, float3 receiverPlaneDepthBias, float c, float s, float Sampler_Number)
{
	float sum = 0.0f;
	
#if defined(PCSS_CAN_USE_EARLY_BAILOUT_OPTIMIZATION_DIR) && !defined(PCSS_CAN_USE_PCSS_FILTER_DIR)//We dont need to overoptimize with too many branches
	UNITY_LOOP
	for (int i = 0; i < 16; i++)
	{
		float2 offset = DirPoissonDisksTest[i] * diskRadius;

#if defined(PCSS_USE_POISSON_SAMPLING_DIR)
		offset = float2(offset.x * c - offset.y * s, offset.y * c + offset.x * s);
#endif
		float depthBiased = receiver;
		
	#if defined(PCSS_USE_RECEIVER_PLANE_BIAS)
			float value = UNITY_SAMPLE_SHADOW(_ShadowMapTexture, UnityCombineShadowcoordComponents(uv.xy, offset, depthBiased, receiverPlaneDepthBias));
	#else
			float value = UNITY_SAMPLE_SHADOW(_ShadowMapTexture, float4(uv.xy + offset, depthBiased, 0.0));
	#endif
	
		sum += value;
	}

	sum /= 16;

	if (sum == 0.0)//If all pixels are shadowed early bail out
		return 0.0;
	else if (sum == 1.0)//If all pixels are lit early bail out
		return 1.0;
		
	sum = 0.0f;//if not 1 or 0 then reset
#endif//PCSS_CAN_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
	
	UNITY_LOOP
	for (int j = 0; j < Sampler_Number; j++)
	{
		float2 offset = DirPoissonDisks[j] * diskRadius;

#if defined(PCSS_USE_POISSON_SAMPLING_DIR)
		offset = float2(offset.x * c - offset.y * s, offset.y * c + offset.x * s);
#endif
		float depthBiased = receiver;
		
	#if defined(PCSS_USE_RECEIVER_PLANE_BIAS)
			float value = UNITY_SAMPLE_SHADOW(_ShadowMapTexture, UnityCombineShadowcoordComponents(uv.xy, offset, depthBiased, receiverPlaneDepthBias));
	#else
			float value = UNITY_SAMPLE_SHADOW(_ShadowMapTexture, float4(uv.xy + offset, depthBiased, 0.0));
	#endif
	
		sum += value;
	}

	sum /= Sampler_Number;

	return sum;
}

//Main Function
float PCSS_Main(float4 coords, float3 receiverPlaneDepthBias, float c, float s)
{
	float shadowSoftness = PCSS_PCSS_GLOBAL_SOFTNESS + 0.001;
	float2 uv = coords.xy;
	float receiver = coords.z;

	float Sampler_Number = Dir_Samplers_Count;//(int)clamp(Dir_Samplers_Count * (shadowSoftness / PCSS_PCSS_GLOBAL_SOFTNESS), Dir_Samplers_Count * 0.5, Dir_Samplers_Count);

#if defined(PCSS_CAN_USE_PCSS_FILTER_DIR)
	
	float2 blockerResults = BlockerSearch(uv, receiver, shadowSoftness, receiverPlaneDepthBias, c, s, Sampler_Number);

	if (blockerResults.y < 1.0)//There are no occluders so early out (this saves filtering)
		return 1.0;
#if defined(PCSS_CAN_USE_EARLY_BAILOUT_OPTIMIZATION_DIR)
	else if (blockerResults.y == Sampler_Number)//There are 100% occluders so early out (this saves filtering)
		return 0.0;//0.0
#endif

#if defined(UNITY_REVERSED_Z)
	float penumbra = ((1.0 - receiver) - blockerResults.x);// / (1 - blockerResults.x);
#else
	float penumbra = (receiver - blockerResults.x);// / blockerResults.x;
#endif
	
	float diskRadius = clamp(penumbra, PCSS_PCSS_FILTER_DIR_MIN, PCSS_PCSS_FILTER_DIR_MAX) * shadowSoftness;
#else
	float diskRadius = shadowSoftness * 0.15;//NO PCSS FILTERING
#endif//PCSS_CAN_USE_PCSS_FILTER_DIR

	//Sampler_Number = (int)clamp(Sampler_Number * (diskRadius / PCSS_PCSS_GLOBAL_SOFTNESS), Sampler_Number * 0.5, Sampler_Number);

	float shadow = PCF_FilterDir(uv, receiver, diskRadius, receiverPlaneDepthBias, c, s, Sampler_Number);

	return shadow;
}
//Soft shadow
half4 frag_pcfSoft(v2f i) : SV_Target
{
	//Return one if you want only ContactShadows, keep in mind that the cascaded depth are still rendered
	//return 1.0;
	
	UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i); // required for sampling the correct slice of the shadow map render texture array
    float4 wpos;
    float3 vpos;

#if defined(STEREO_CUBEMAP_RENDER_ON)
    wpos.xyz = tex2D(_ODSWorldTexture, i.uv.xy).xyz;
    wpos.w = 1.0f;
    vpos = mul(unity_WorldToCamera, wpos).xyz;
#else
    vpos = computeCameraSpacePosFromDepth(i);

    // sample the cascade the pixel belongs to
    wpos = mul(unity_CameraToWorld, float4(vpos,1));
#endif
	
	half4 cascadeWeights = GET_CASCADE_WEIGHTS(wpos, vpos.z);//linear
    float4 coord = GET_SHADOW_COORDINATES(wpos, cascadeWeights);

    float3 receiverPlaneDepthBias = 0.0;
#ifdef UNITY_USE_RECEIVER_PLANE_BIAS
    // Reveiver plane depth bias: need to calculate it based on shadow coordinate
    // as it would be in first cascade; otherwise derivatives
    // at cascade boundaries will be all wrong. So compute
    // it from cascade 0 UV, and scale based on which cascade we're in.
    float3 coordCascade0 = getShadowCoord_SingleCascade(wpos);
    float biasMultiply = dot(cascadeWeights,unity_ShadowCascadeScales);
    receiverPlaneDepthBias = UnityGetReceiverPlaneDepthBias(coordCascade0.xyz, biasMultiply);
#endif
/*
	//Reconstructing screen position using depth
	float zdepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, i.uv.xy);
#if defined(UNITY_REVERSED_Z)
	zdepth = 1 - zdepth;
#endif
	float4 clipPos = float4(i.uv.zw, zdepth, 1.0);
*/
#if defined(PCSS_USE_POISSON_SAMPLING_DIR)
#if defined (PCSS_NOISE_STATIC_DIR)
	//If unity_RandomRotation16 gets removed, can be worked around with a custom noise texture sets globally	
	//float4 rotation = tex2D(unity_RandomRotation16, i.uv.xy * _ScreenParams.xy * (PCSS_POISSON_SAMPLING_NOISE_DIR + 0.001));
	float4 rotation = tex2D(unity_RandomRotation16, i.uv.xy * PCSS_POISSON_SAMPLING_NOISE_DIR);
	float c = cos(rotation.x);
	float s = sin(rotation.y);
#else
	float randAngle = DirRandAngle(i.uv.zww);
	float c = cos(randAngle);
	float s = sin(randAngle);
#endif
#else
	float c = 1.0;
	float s = 1.0;
#endif
/*
#if defined(SHADER_API_MOBILE)
    half shadow = UnitySampleShadowmap_PCF5x5(coord, receiverPlaneDepthBias);
#else
    half shadow = UnitySampleShadowmap_PCF7x7(coord, receiverPlaneDepthBias);
#endif
*/
	float shadow = PCSS_Main(coord, receiverPlaneDepthBias, c, s);

	// Blend between shadow cascades if enabled. No need when 1 cascade

#if defined(PCSS_USE_CASCADE_BLENDING) && !defined(SHADOWS_SINGLE_CASCADE)
	
#if defined(SHADOWS_SPLIT_SPHERES)
	//clip(cascadeWeights.x - 1.0);//testing distances
	//float sphereDist = distance(wpos.xyz, unity_ShadowFadeCenterAndType.xyz);
    //float shadowFade = saturate(sphereDist * _LightShadowData.z + _LightShadowData.w);
	//half cascadeIndex = 4 - dot(cascadeWeights, half4(4, 3, 2, 1));
	/*
	float3 fromCenter0 = wpos.xyz - unity_ShadowSplitSpheres[0].xyz;
    float3 fromCenter1 = wpos.xyz - unity_ShadowSplitSpheres[1].xyz;
    float3 fromCenter2 = wpos.xyz - unity_ShadowSplitSpheres[2].xyz;
    float3 fromCenter3 = wpos.xyz - unity_ShadowSplitSpheres[3].xyz;
    float4 distances2 = float4(dot(fromCenter0,fromCenter0), dot(fromCenter1,fromCenter1), dot(fromCenter2,fromCenter2), dot(fromCenter3,fromCenter3));
    //half4 weights = float4(distances2 < unity_ShadowSplitSqRadii);
    //weights.yzw = saturate(weights.yzw - weights.xyz);	
	//-----------------------------------------
	//distances2 -= unity_ShadowSplitSqRadii;
	//distances2.yzw = saturate(distances2.yzw - distances2.xyz);
	*/	
	
	float dist2 = dot(vpos,vpos);
	float4 _LightSplitsNear2 = _LightSplitsNear*_LightSplitsNear;
	float4 _LightSplitsFar2 = _LightSplitsFar*_LightSplitsFar;
	half4 z4 = (dist2.xxxx - _LightSplitsNear2) / (_LightSplitsFar2 - _LightSplitsNear2);
	half alpha = dot(z4 * cascadeWeights, half4(1, 1, 1, 1));
	/*
	float dist = length(vpos);
	half4 z4 = (dist.xxxx - _LightSplitsNear) / (_LightSplitsFar - _LightSplitsNear);
	half alpha = dot(z4 * cascadeWeights, half4(1, 1, 1, 1));
	*/
	//first one
	//half z4 = (dist - _LightSplitsNear[0]) / (_LightSplitsFar[0] - _LightSplitsNear[0]);
	//half alpha = dot(z4.xxxx * cascadeWeights[0].xxxx, half4(1, 1, 1, 1));	
#else
	half4 z4 = (float4(vpos.z, vpos.z, vpos.z, vpos.z) - _LightSplitsNear) / (_LightSplitsFar - _LightSplitsNear);
	half alpha = dot(z4 * cascadeWeights, half4(1, 1, 1, 1));
#endif
	
	alpha = saturate(alpha);
		
	UNITY_BRANCH
	if (alpha > 1.0 - PCSS_CASCADE_BLEND_DISTANCE)
	{
		// get alpha to 0..1 range over the blend distance
		alpha = (alpha - (1.0 - PCSS_CASCADE_BLEND_DISTANCE)) / PCSS_CASCADE_BLEND_DISTANCE;

		// sample next cascade
		cascadeWeights = half4(0, cascadeWeights.xyz);
		coord = GET_SHADOW_COORDINATES(wpos, cascadeWeights);

#if defined(PCSS_USE_RECEIVER_PLANE_BIAS)
		biasMultiply = dot(cascadeWeights, unity_ShadowCascadeScales);
		receiverPlaneDepthBias = UnityGetReceiverPlaneDepthBiasPCSS(coordCascade0.xyz, biasMultiply);
#endif

		//half shadowNextCascade = UnitySampleShadowmap_PCF3x3(coord, receiverPlaneDepthBias);
		half shadowNextCascade = PCSS_Main(coord, receiverPlaneDepthBias, c, s);

	#if UNITY_VERSION > 565
		shadow = lerp(shadow, min(shadow, shadowNextCascade), alpha);//saturate(alpha)
	#else
		shadow = lerp(shadow, shadowNextCascade, alpha);//saturate(alpha)
	#endif
	}
	
#endif
	
	//return lerp(_LightShadowData.r, 1.0, shadow);
	return shadow + _LightShadowData.r;
}
//Hard shadow
half4 frag_hard (v2f i) : SV_Target
{
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i); // required for sampling the correct slice of the shadow map render texture array
    float4 wpos;
    float3 vpos;

#if defined(STEREO_CUBEMAP_RENDER_ON)
    wpos.xyz = tex2D(_ODSWorldTexture, i.uv.xy).xyz;
    wpos.w = 1.0f;
    vpos = mul(unity_WorldToCamera, wpos).xyz;
#else
    vpos = computeCameraSpacePosFromDepth(i);
    wpos = mul (unity_CameraToWorld, float4(vpos,1));
#endif
    half4 cascadeWeights = GET_CASCADE_WEIGHTS (wpos, vpos.z);
    float4 shadowCoord = GET_SHADOW_COORDINATES(wpos, cascadeWeights);

    //1 tap hard shadow
    half shadow = UNITY_SAMPLE_SHADOW(_ShadowMapTexture, shadowCoord);
    //shadow = lerp(_LightShadowData.r, 1.0, shadow);
	shadow += _LightShadowData.r;

    half4 res = shadow;
    return res;
}
ENDCG

// ----------------------------------------------------------------------------------------
// Subshaders that does PCSS filterings while collecting shadows.
// Requires SM3.5+ GPU. Compatible with: DX11, DX12, PS4, XB1, GLES3.0, Metal, Vulkan.
// If having texture interpolators or instruction limit errors please set shader model target to 4.0 or 5.0. Otherwise leave it at 3.5
//SM 5.0
/*
Subshader
{
	Tags {"ShadowmapFilter" = "PCF_SOFT"}//Unity 2017
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_pcfSoft
		#pragma shader_feature PCSS_PCSS_FILTER_DIR
		#pragma shader_feature PCSS_USE_CASCADE_BLENDING
		#pragma shader_feature PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
		#pragma shader_feature PCSS_USE_BIAS_FADE_DIR
		#pragma shader_feature PCSS_NOISE_STATIC_DIR
		#pragma shader_feature DIR_POISSON_16 DIR_POISSON_25 DIR_POISSON_32 DIR_POISSON_64
		#pragma exclude_renderers gles d3d9
		#pragma multi_compile_shadowcollector			
		#pragma target 5.0

		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndVSInfo(i);
		}
		ENDCG
	}
}
// This version does inv projection at the PS level, slower and less precise however more general.
Subshader
{
	Tags{ "ShadowmapFilter" = "PCF_SOFT_FORCE_INV_PROJECTION_IN_PS" }//Unity 2017
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_pcfSoft
		#pragma shader_feature PCSS_PCSS_FILTER_DIR
		#pragma shader_feature PCSS_USE_CASCADE_BLENDING
		#pragma shader_feature PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
		#pragma shader_feature PCSS_USE_BIAS_FADE_DIR
		#pragma shader_feature PCSS_NOISE_STATIC_DIR
		#pragma shader_feature DIR_POISSON_16 DIR_POISSON_25 DIR_POISSON_32 DIR_POISSON_64
		#pragma exclude_renderers gles d3d9
		#pragma multi_compile_shadowcollector
		#pragma target 5.0

		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndInvProjMat(i);
		}
		ENDCG
	}
}
//SM 4.0
Subshader
{
	Tags {"ShadowmapFilter" = "PCF_SOFT"}//Unity 2017
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_pcfSoft
		#pragma shader_feature PCSS_PCSS_FILTER_DIR
		#pragma shader_feature PCSS_USE_CASCADE_BLENDING
		#pragma shader_feature PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
		#pragma shader_feature PCSS_USE_BIAS_FADE_DIR
		#pragma shader_feature PCSS_NOISE_STATIC_DIR
		#pragma shader_feature DIR_POISSON_16 DIR_POISSON_25 DIR_POISSON_32 DIR_POISSON_64
		#pragma exclude_renderers gles d3d9
		#pragma multi_compile_shadowcollector
		#pragma target 4.0

		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndVSInfo(i);
		}
		ENDCG
	}
}
// This version does inv projection at the PS level, slower and less precise however more general.
Subshader
{
	Tags{ "ShadowmapFilter" = "PCF_SOFT_FORCE_INV_PROJECTION_IN_PS" }//Unity 2017
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_pcfSoft
		#pragma shader_feature PCSS_PCSS_FILTER_DIR
		#pragma shader_feature PCSS_USE_CASCADE_BLENDING
		#pragma shader_feature PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
		#pragma shader_feature PCSS_USE_BIAS_FADE_DIR
		#pragma shader_feature PCSS_NOISE_STATIC_DIR
		#pragma shader_feature DIR_POISSON_16 DIR_POISSON_25 DIR_POISSON_32 DIR_POISSON_64
		#pragma exclude_renderers gles d3d9
		#pragma multi_compile_shadowcollector
		#pragma target 4.0

		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndInvProjMat(i);
		}
		ENDCG
	}
}*/
//SM 3.5
Subshader
{
	Tags {"ShadowmapFilter" = "PCF_SOFT"}//Unity 2017
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_pcfSoft
		#pragma shader_feature PCSS_PCSS_FILTER_DIR
		#pragma shader_feature PCSS_USE_CASCADE_BLENDING
		#pragma shader_feature PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
		#pragma shader_feature PCSS_USE_BIAS_FADE_DIR
		#pragma shader_feature PCSS_NOISE_STATIC_DIR
		#pragma shader_feature DIR_POISSON_16 DIR_POISSON_25 DIR_POISSON_32 DIR_POISSON_64
		#pragma exclude_renderers gles d3d9
		#pragma multi_compile_shadowcollector
		#pragma target 3.5

		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndVSInfo(i);
		}
		ENDCG
	}
}
// This version does inv projection at the PS level, slower and less precise however more general.
Subshader
{
	Tags{ "ShadowmapFilter" = "PCF_SOFT_FORCE_INV_PROJECTION_IN_PS" }//Unity 2017
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_pcfSoft
		#pragma shader_feature PCSS_PCSS_FILTER_DIR
		#pragma shader_feature PCSS_USE_CASCADE_BLENDING
		#pragma shader_feature PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
		#pragma shader_feature PCSS_USE_BIAS_FADE_DIR
		#pragma shader_feature PCSS_NOISE_STATIC_DIR
		#pragma shader_feature DIR_POISSON_16 DIR_POISSON_25 DIR_POISSON_32 DIR_POISSON_64
		#pragma exclude_renderers gles d3d9
		#pragma multi_compile_shadowcollector
		#pragma target 3.5

		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndInvProjMat(i);
		}
		ENDCG
	}
}
//SM 3.0
Subshader
{
	Tags {"ShadowmapFilter" = "PCF_SOFT"}//Unity 2017
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_pcfSoft
		#pragma shader_feature PCSS_PCSS_FILTER_DIR
		#pragma shader_feature PCSS_USE_CASCADE_BLENDING
		#pragma shader_feature PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
		#pragma shader_feature PCSS_USE_BIAS_FADE_DIR
		#pragma shader_feature PCSS_NOISE_STATIC_DIR
		#pragma shader_feature DIR_POISSON_16 DIR_POISSON_25 DIR_POISSON_32 DIR_POISSON_64
		#pragma exclude_renderers gles d3d9
		#pragma multi_compile_shadowcollector
		#pragma target 3.0

		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndVSInfo(i);
		}
		ENDCG
	}
}
// This version does inv projection at the PS level, slower and less precise however more general.
Subshader
{
	Tags{ "ShadowmapFilter" = "PCF_SOFT_FORCE_INV_PROJECTION_IN_PS" }//Unity 2017
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_pcfSoft
		#pragma shader_feature PCSS_PCSS_FILTER_DIR
		#pragma shader_feature PCSS_USE_CASCADE_BLENDING
		#pragma shader_feature PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR
		#pragma shader_feature PCSS_USE_BIAS_FADE_DIR
		#pragma shader_feature PCSS_NOISE_STATIC_DIR
		#pragma shader_feature DIR_POISSON_16 DIR_POISSON_25 DIR_POISSON_32 DIR_POISSON_64
		#pragma exclude_renderers gles d3d9
		#pragma multi_compile_shadowcollector
		#pragma target 3.0

		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndInvProjMat(i);
		}
		ENDCG
	}
}/*
//SM 2.0
SubShader
{
	Tags { "ShadowmapFilter" = "HardShadow" }
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_hard
		#pragma multi_compile_shadowcollector
		#pragma exclude_renderers gles d3d9
		
		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndVSInfo(i);
		}
		ENDCG
	}
}
// This version does inv projection at the PS level, slower and less precise however more general.
SubShader
{
	Tags { "ShadowmapFilter" = "HardShadow_FORCE_INV_PROJECTION_IN_PS" }
	Pass
	{
		ZWrite Off ZTest Always Cull Off

		CGPROGRAM
		#pragma vertex vert
		#pragma fragment frag_hard
		#pragma multi_compile_shadowcollector
		#pragma exclude_renderers gles d3d9
		
		inline float3 computeCameraSpacePosFromDepth(v2f i)
		{
			return computeCameraSpacePosFromDepthAndInvProjMat(i);
		}
		ENDCG
	}
}*/
//SM 1.1? Yeah right ^^
Fallback Off
}