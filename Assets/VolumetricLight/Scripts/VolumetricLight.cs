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



using UnityEngine;
using System.Collections;
using UnityEngine.Rendering;
using System;

[RequireComponent(typeof(Light))]
public class VolumetricLight : MonoBehaviour
{
    private Light _light;
    private Material _material;
    private CommandBuffer _commandBuffer;
    private CommandBuffer _cascadeShadowCommandBuffer;

    public float intensity = 1;
    [Range(1, 1024)]
    public int SampleCount = 8;
    [Range(0.0f, 1.0f)]
    public float SkyboxExtinctionCoef = 0.9f;
    [Range(0.0f, 0.999f)]
    public float MieG = 0.1f;
    public bool HeightFog = false;
    [Range(0, 0.5f)]
    public float HeightScale = 0.10f;
    public float GroundLevel = 0;
    public Light Light { get { return _light; } }
    public Material VolumetricMaterial { get { return _material; } }

    private Vector4[] _frustumCorners = new Vector4[4];

    private bool _reversedZ = false;
    static bool inited = false;
    [Header("Debug(Only in Editor)")]
    public bool debugMode = true;
    /// <summary>
    /// 
    /// </summary>
    void Init()
    {
#if UNITY_5_5_OR_NEWER
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Direct3D11 || SystemInfo.graphicsDeviceType == GraphicsDeviceType.Direct3D12 ||
            SystemInfo.graphicsDeviceType == GraphicsDeviceType.Metal || SystemInfo.graphicsDeviceType == GraphicsDeviceType.PlayStation4 ||
            SystemInfo.graphicsDeviceType == GraphicsDeviceType.Vulkan || SystemInfo.graphicsDeviceType == GraphicsDeviceType.XboxOne)
        {
            _reversedZ = true;
        }
#endif

        _commandBuffer = new CommandBuffer();
        _commandBuffer.name = "Light Command Buffer";

        _cascadeShadowCommandBuffer = new CommandBuffer();
        _cascadeShadowCommandBuffer.name = "Dir Light Command Buffer";
        _cascadeShadowCommandBuffer.SetGlobalTexture("_CascadeShadowMapTexture", UnityEngine.Rendering.BuiltinRenderTextureType.CurrentActive);

        _light.AddCommandBuffer(LightEvent.BeforeScreenspaceMask, _commandBuffer);
        _light.AddCommandBuffer(LightEvent.AfterShadowMap, _cascadeShadowCommandBuffer);

        Shader shader = Shader.Find("Sandbox/VolumetricLight");
        if (shader == null)
            throw new Exception("Critical Error: \"Sandbox/VolumetricLight\" shader is missing. Make sure it is included in \"Always Included Shaders\" in ProjectSettings/Graphics.");
        _material = new Material(shader); // new Material(VolumetricLightRenderer.GetLightMaterial());
    }
    private bool isDirectional = false;
    /// <summary>
    /// 
    /// </summary>
    void OnEnable()
    {
        VolumetricLightRenderer.PreRenderEvent += initSet;
        VolumetricLightRenderer.PreRenderEvent += VolumetricLightRenderer_PreRenderEvent;
        VolumetricLightRenderer.onImageEvent += OnImageEvent;
    }

    /// <summary>
    /// 
    /// </summary>
    void OnDisable()
    {
        VolumetricLightRenderer.PreRenderEvent -= VolumetricLightRenderer_PreRenderEvent;
        VolumetricLightRenderer.onImageEvent -= OnImageEvent;
    }

    /// <summary>
    /// 
    /// </summary>
    public void OnDestroy()
    {
        Destroy(_material);
    }

    void Awake()
    {
        _light = GetComponent<Light>();
        if (_light.type != LightType.Directional)
        {
            Debug.LogError("Not support Un-Directional Light!");
            Destroy(this);
            return;
        }
        if (!inited)
        {
            InitVariable();
            inited = true;
        }
        Init();
    }


    static int _CameraForward;
    static int _SampleCount;
    static int _NoiseVelocity;
    static int _NoiseData;
    static int _MieG;
    static int _VolumetricLight;
    static int _CameraDepthTexture;
    static int _ZTest;
    static int _HeightFog;
    static int _WorldViewProj;
    static int _WorldView;
    static int _LightPos;
    static int _LightFinalColor;
    static int _MyLightMatrix0;
    static int _LightTexture0;
    static int _ShadowMapTexture;
    static int _PlaneD;
    static int _CosAngle;
    static int _ConeApex;
    static int _ConeAxis;
    static int _MyWorld2Shadow;
    static int _LightDir;
    
    static int _FrustumCorners;
    static int _DirectionalLightFlag;
    static void InitVariable()
    {
        _CameraForward = Shader.PropertyToID("_CameraForward");
        _SampleCount = Shader.PropertyToID("_SampleCount");
        _NoiseVelocity = Shader.PropertyToID("_NoiseVelocity");
        _NoiseData = Shader.PropertyToID("_NoiseData");
        _MieG = Shader.PropertyToID("_MieG");
        _VolumetricLight = Shader.PropertyToID("_VolumetricLight");
        _CameraDepthTexture = Shader.PropertyToID("_CameraDepthTexture");
        _ZTest = Shader.PropertyToID("_ZTest");
        _HeightFog = Shader.PropertyToID("_HeightFog");
        _WorldViewProj = Shader.PropertyToID("_WorldViewProj");
        _WorldView = Shader.PropertyToID("_WorldView");
        _LightPos = Shader.PropertyToID("_LightPos");
        _LightFinalColor = Shader.PropertyToID("_LightFinalColor");
        _MyLightMatrix0 = Shader.PropertyToID("_MyLightMatrix0");
        _LightTexture0 = Shader.PropertyToID("_LightTexture0");
        _ShadowMapTexture = Shader.PropertyToID("_ShadowMapTexture");
        _PlaneD = Shader.PropertyToID("_PlaneD");
        _CosAngle = Shader.PropertyToID("_CosAngle");
        _ConeApex = Shader.PropertyToID("_ConeApex");
        _ConeAxis = Shader.PropertyToID("_ConeAxis");
        _MyWorld2Shadow = Shader.PropertyToID("_MyWorld2Shadow");
        _LightDir = Shader.PropertyToID("_LightDir");
        
        _FrustumCorners = Shader.PropertyToID("_FrustumCorners");
        _DirectionalLightFlag = Shader.PropertyToID("_DirectionalLightFlag");
        
    }
    /// <summary>
    /// Inits the set.
    /// </summary>
    private void initSet(VolumetricLightRenderer renderer, Matrix4x4 viewProj)
    {
        _material.SetInt(_SampleCount, SampleCount);
        _material.SetVector(_MieG, new Vector4(1 - (MieG * MieG), 1 + (MieG * MieG), 2 * MieG, 1.0f / (4.0f * Mathf.PI)));
        _material.SetVector(_VolumetricLight, new Vector4(0, 0, _light.range, 1.0f - SkyboxExtinctionCoef));
        _material.SetTexture(_CameraDepthTexture, renderer.volumeDepthTexture);
        _material.SetFloat(_ZTest, (int)UnityEngine.Rendering.CompareFunction.Always);
        if (HeightFog)
        {
            _material.EnableKeyword("HEIGHT_FOG");

            _material.SetVector(_HeightFog, new Vector4(GroundLevel, HeightScale));
        }
        else
        {
            _material.DisableKeyword("HEIGHT_FOG");
        }
        InitdirectionalLight(renderer, viewProj);

        VolumetricLightRenderer.PreRenderEvent -= initSet;

    }
    /// <summary>
    /// 
    /// </summary>
    /// <param name="renderer"></param>
    /// <param name="viewProj"></param>
    private void VolumetricLightRenderer_PreRenderEvent(VolumetricLightRenderer renderer, Matrix4x4 viewProj)
    {

        // light was destroyed without deregistring, deregister now
        if (_light == null)
        {
            VolumetricLightRenderer.PreRenderEvent -= VolumetricLightRenderer_PreRenderEvent;
            return;
        }

        if (_light.enabled == false)
            return;

        _material.SetVector(_CameraForward, Camera.current.transform.forward);


        // downsampled light buffer can't use native zbuffer for ztest, try to perform ztest in pixel shader to avoid ray marching for occulded geometry 
        //_material.EnableKeyword("MANUAL_ZTEST");
#if UNITY_EDITOR
        if (debugMode)
            initSet(renderer, viewProj);
#endif
        SetupDirectionalLight(renderer, viewProj);
    }

    private void InitdirectionalLight(VolumetricLightRenderer renderer, Matrix4x4 viewProj)
    {
        if (_light.cookie == null)
        {
            _material.EnableKeyword("DIRECTIONAL");
            _material.DisableKeyword("DIRECTIONAL_COOKIE");
        }
        else
        {
            _material.EnableKeyword("DIRECTIONAL_COOKIE");
            _material.DisableKeyword("DIRECTIONAL");

            _material.SetTexture(_LightTexture0, _light.cookie);
        }
    }
    /// <summary>
    /// 
    /// </summary>
    /// <param name="renderer"></param>
    /// <param name="viewProj"></param>

    private void SetupDirectionalLight(VolumetricLightRenderer renderer, Matrix4x4 viewProj)
    {
        _commandBuffer.Clear();

        Vector3 forwd = _light.transform.forward;
        _material.SetVector(_LightDir, new Vector4(forwd.x, forwd.y, forwd.z, 1.0f / (_light.range * _light.range)));
        _material.SetVector(_LightFinalColor, _light.color * _light.intensity * intensity * (1f / SampleCount));
        if (_light.shadows != LightShadows.None)
        {
            _commandBuffer.SetGlobalFloat(_DirectionalLightFlag, 1);

            _commandBuffer.EnableShaderKeyword("SHADOWS_DEPTH_ON");
            _commandBuffer.Blit(null, renderer.volumeLightTexture, _material, 0);
        }
    }

    private void OnImageEvent(VolumetricLightRenderer renderer)
    {
        if (Shader.GetGlobalFloat(_DirectionalLightFlag) < 0.5f)
        {

            Graphics.Blit(null, renderer.volumeLightTexture, _material, 0);
        }
        else
        {
            Shader.SetGlobalFloat(_DirectionalLightFlag, 0);
            Shader.DisableKeyword("SHADOWS_DEPTH_ON");
        }
    }

    /// <summary>
    /// 
    /// </summary>
    /// <returns></returns>
    private bool IsCameraInPointLightBounds()
    {
        float distanceSqr = (_light.transform.position - Camera.current.transform.position).sqrMagnitude;
        float extendedRange = _light.range + 1;
        if (distanceSqr < (extendedRange * extendedRange))
            return true;
        return false;
    }

    /// <summary>
    /// 
    /// </summary>
    /// <returns></returns>
    private bool IsCameraInSpotLightBounds()
    {
        // check range
        float distance = Vector3.Dot(_light.transform.forward, (Camera.current.transform.position - _light.transform.position));
        float extendedRange = _light.range + 1;
        if (distance > (extendedRange))
            return false;

        // check angle
        float cosAngle = Vector3.Dot(transform.forward, (Camera.current.transform.position - _light.transform.position).normalized);
        if ((Mathf.Acos(cosAngle) * Mathf.Rad2Deg) > (_light.spotAngle + 3) * 0.5f)
            return false;
        return true;
    }
}
