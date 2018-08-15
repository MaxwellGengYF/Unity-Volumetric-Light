using UnityEngine;
using UnityEngine.Rendering;
[ExecuteInEditMode()]
public class PCSS_Directional : MonoBehaviour
{
    [Header("MAIN SETTINGS")]
    [Tooltip("If false, PCSS Directional shadows replacement will be removed from Graphics settings when OnDisable is called in this component.")]
    public bool KEEP_PCSS_ONDISABLE = true;

    [Header("OPTIMIZATION")]
    [Tooltip("Optimize shadows performance by skipping fragments that are either 100% lit or 100% shadowed. Some macro noisy artefacts can be seen if shadows are too soft or sampling amount is below 64.")]
    public bool EARLY_BAILOUT_OPTIMIZATION = true;

    public enum SAMPLER_COUNT { SAMPLERS_16, SAMPLERS_25, SAMPLERS_32, SAMPLERS_64 }
    [Tooltip("Recommended values: Mobile = 16, Consoles = 25, Desktop VR = 32, Desktop High = 64")]
    public SAMPLER_COUNT SAMPLERS_COUNT = SAMPLER_COUNT.SAMPLERS_64;

    [Header("SOFTNESS")]
    [Tooltip("Overall softness for both PCF and PCSS shadows.")]
    [Range(0f, 2f)]
    public float GLOBAL_SOFTNESS = 1f;

    [Header("CASCADES")]
    [Tooltip("Blends cascades at seams intersection.\nAdditional overhead required for this option.")]
    public bool CASCADES_BLENDING = true;
    [Tooltip("Blends cascades at seams intersection.\nAdditional overhead required for this option.")]
    [Range(0f, 2f)]
    public float CASCADES_BLENDING_VALUE = 1f;

    [Header("NOISE")]
    [Tooltip("If disabled, noise will be computed normally.\nIf enabled, noise will be computed statically from an internal screen-space texture.")]
    public bool NOISE_STATIC = false;
    [Tooltip("Amount of noise. The higher the value the more Noise.")]
    [Range(0f, 2f)]
    public float NOISE_SCALE_VALUE = 1f;
    /*
    [Header("BIAS")]
    [Tooltip("Fades out artifacts produced by shadow bias")]
    public bool BIAS_FADE = true;
    [Tooltip("Fades out artifacts produced by shadow bias")]
    [Range(0f, 2f)]
    public float BIAS_FADE_VALUE = 1f;
    */

#if UNITY_5_4 || UNITY_5_5 || UNITY_5_6

#else
    [Header("PCSS")]
    [Tooltip("PCSS Requires inline sampling and SM3.5, only available in Unity 2017.\nIt provides Area Light like soft-shadows.\nDisable it if you are looking for PCF filtering (uniform soft-shadows) which runs with SM3.0.")]
    public bool PCSS_ENABLED = true;
    [Tooltip("PCSS softness when shadows is close to caster.")]
    [Range(0f, 2f)]
    public float PCSS_SOFTNESS_MIN = 1f;
    [Tooltip("PCSS softness when shadows is far from caster.")]
    [Range(0f, 2f)]
    public float PCSS_SOFTNESS_MAX = 1f;
#endif



    //public Texture noiseTexture;
    private bool isInitialized = false;
    private bool isGraphicSet = false;
    
    void OnDisable()
    {
        isInitialized = false;

        if (KEEP_PCSS_ONDISABLE)
            return;

        if (isGraphicSet)
        {
            isGraphicSet = false;
            GraphicsSettings.SetCustomShader(BuiltinShaderType.ScreenSpaceShadows, Shader.Find("Hidden/Internal-ScreenSpaceShadows"));
            GraphicsSettings.SetShaderMode(BuiltinShaderType.ScreenSpaceShadows, BuiltinShaderMode.UseBuiltin);
        }
    }

    void OnEnable()
    {
        if (IsNotSupported())
        {
            Debug.LogWarning("Unsupported graphics API, PCSS requires at least SM3.0 or higher and DX9 is not supported.", this);
            this.enabled = false;
            return;
        }

        Init();
        VariableInit();
    }

    void Init()
    {
        if (isInitialized) { return; }

        if (isGraphicSet == false)
        {
            //QualitySettings.shadowProjection = ShadowProjection.StableFit;
            //QualitySettings.shadowCascades = 4;
            //QualitySettings.shadowCascade4Split = new Vector3(0.1f, 0.275f, 0.5f);
            GraphicsSettings.SetShaderMode(BuiltinShaderType.ScreenSpaceShadows, BuiltinShaderMode.UseCustom);
            GraphicsSettings.SetCustomShader(BuiltinShaderType.ScreenSpaceShadows, Shader.Find("Hidden/PCSS_Directional"));//Shader.Find can sometimes return null in Player builds (careful).
            isGraphicSet = true;
        }

        isInitialized = true;
    }

    bool IsNotSupported()
    {
#if UNITY_2017_3_OR_NEWER
        return (SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLES2 || SystemInfo.graphicsDeviceType == GraphicsDeviceType.PlayStationVita || SystemInfo.graphicsDeviceType == GraphicsDeviceType.N3DS);
#else
        return (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Direct3D9 || SystemInfo.graphicsDeviceType == GraphicsDeviceType.OpenGLES2 || SystemInfo.graphicsDeviceType == GraphicsDeviceType.PlayStationMobile || SystemInfo.graphicsDeviceType == GraphicsDeviceType.PlayStationVita || SystemInfo.graphicsDeviceType == GraphicsDeviceType.N3DS);
#endif
    }


    void VariableInit()
    {
        //if (BIAS_FADE) { Shader.EnableKeyword("PCSS_USE_BIAS_FADE_DIR"); Shader.SetGlobalFloat("PCSS_BIAS_FADE_DIR", BIAS_FADE_VALUE * 0.001f); } else { Shader.DisableKeyword("PCSS_USE_BIAS_FADE_DIR"); }
        if (NOISE_STATIC) { Shader.EnableKeyword("PCSS_NOISE_STATIC_DIR"); } else { Shader.DisableKeyword("PCSS_NOISE_STATIC_DIR"); }
        if (CASCADES_BLENDING && QualitySettings.shadowCascades > 1) { Shader.EnableKeyword("PCSS_USE_CASCADE_BLENDING"); Shader.SetGlobalFloat("PCSS_CASCADE_BLEND_DISTANCE", CASCADES_BLENDING_VALUE * 0.125f); } else { Shader.DisableKeyword("PCSS_USE_CASCADE_BLENDING"); }
        if (EARLY_BAILOUT_OPTIMIZATION) { Shader.EnableKeyword("PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR"); } else { Shader.DisableKeyword("PCSS_USE_EARLY_BAILOUT_OPTIMIZATION_DIR"); }        
        
        Shader.SetGlobalFloat("PCSS_POISSON_SAMPLING_NOISE_DIR", NOISE_SCALE_VALUE / 0.01f);
        Shader.SetGlobalFloat("PCSS_STATIC_NOISE_MOBILE_VALUE", NOISE_SCALE_VALUE * 0.5f);

        Shader.SetGlobalFloat("PCSS_PCSS_GLOBAL_SOFTNESS", GLOBAL_SOFTNESS / (QualitySettings.shadowDistance * 0.66f));
        Shader.SetGlobalFloat("PCSS_PCSS_GLOBAL_SOFTNESS_MOBILE", 1f - GLOBAL_SOFTNESS * 75f / QualitySettings.shadowDistance);
        

#if UNITY_5_4 || UNITY_5_5 || UNITY_5_6

#else
        if (PCSS_ENABLED) { Shader.EnableKeyword("PCSS_PCSS_FILTER_DIR"); } else { Shader.DisableKeyword("PCSS_PCSS_FILTER_DIR"); }
        float pcss_min = PCSS_SOFTNESS_MIN * 0.05f;
        float pcss_max = PCSS_SOFTNESS_MAX * 0.25f;
        Shader.SetGlobalFloat("PCSS_PCSS_FILTER_DIR_MIN", pcss_min > pcss_max ? pcss_max : pcss_min);
        Shader.SetGlobalFloat("PCSS_PCSS_FILTER_DIR_MAX", pcss_max < pcss_min ? pcss_min : pcss_max);
#endif

        Shader.DisableKeyword("DIR_POISSON_64"); Shader.DisableKeyword("DIR_POISSON_32"); Shader.DisableKeyword("DIR_POISSON_25"); Shader.DisableKeyword("DIR_POISSON_16");
        Shader.EnableKeyword(SAMPLERS_COUNT == SAMPLER_COUNT.SAMPLERS_64 ? "DIR_POISSON_64" : SAMPLERS_COUNT == SAMPLER_COUNT.SAMPLERS_32 ? "DIR_POISSON_32" : SAMPLERS_COUNT == SAMPLER_COUNT.SAMPLERS_25 ? "DIR_POISSON_25" : "DIR_POISSON_16");
    }
}