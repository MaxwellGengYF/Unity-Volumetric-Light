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

[RequireComponent(typeof(Camera))]
public class VolumetricLightRenderer : MonoBehaviour
{
    Vector2Int blurPass;
    public enum DownSample
    {
        x2 = 2,
        x3 = 3,
        x4 = 4,
        x8 = 8,
        x16 = 16
    };
    public static event Action<VolumetricLightRenderer> onImageEvent;
    public static event Action<VolumetricLightRenderer, Matrix4x4> PreRenderEvent;
    private static Mesh _pointLightMesh;
    private static Mesh _spotLightMesh;
    private static Material _lightMaterial;

    private Camera _camera;
    private CommandBuffer _preLightPass;

    private Matrix4x4 _viewProj;
    private Material _blitAddMaterial;
    private Material _bilateralBlurMaterial;

    private RenderTexture _volumeLightTexture;
    private RenderTexture _halfVolumeLightTexture;
    private static Texture _defaultSpotCookie;

    private RenderTexture _halfDepthBuffer;
    private DownSample _currentResolution;
    public DownSample downSample = DownSample.x2;
    private Texture2D _ditheringTexture;
    private Texture3D _noiseTexture;
    public Texture DefaultSpotCookie;
    public CommandBuffer GlobalCommandBuffer { get { return _preLightPass; } }
    int halfPass;
    [System.NonSerialized]
    public RenderTexture volumeLightTexture;
    [System.NonSerialized]
    public RenderTexture volumeDepthTexture;
    static int _MaxRayLength = Shader.PropertyToID("_MaxRayLength");
    public float maxRayLength = 150f;
    /// <summary>
    /// 
    /// </summary>
    /// <returns></returns>
    public static Material GetLightMaterial()
    {
        return _lightMaterial;
    }

    /// <summary>
    /// 
    /// </summary>
    void Awake()
    {
        
        _camera = GetComponent<Camera>();
        if (_camera.actualRenderingPath == RenderingPath.Forward)
            _camera.depthTextureMode = DepthTextureMode.Depth;
        Shader shader = Shader.Find("Hidden/BlitAdd");
        if (shader == null)
            throw new Exception("Critical Error: \"Hidden/BlitAdd\" shader is missing. Make sure it is included in \"Always Included Shaders\" in ProjectSettings/Graphics.");
        _blitAddMaterial = new Material(shader);

        shader = Shader.Find("Hidden/BilateralBlur");
        if (shader == null)
            throw new Exception("Critical Error: \"Hidden/BilateralBlur\" shader is missing. Make sure it is included in \"Always Included Shaders\" in ProjectSettings/Graphics.");
        _bilateralBlurMaterial = new Material(shader);

        _preLightPass = new CommandBuffer();
        _preLightPass.name = "PreLight";

        ChangeResolution();
        volumeLightTexture = _halfVolumeLightTexture;
        volumeDepthTexture = _halfDepthBuffer;
        if (_pointLightMesh == null)
        {
            GameObject go = GameObject.CreatePrimitive(PrimitiveType.Sphere);
            _pointLightMesh = go.GetComponent<MeshFilter>().sharedMesh;
            Destroy(go);
        }

        if (_spotLightMesh == null)
        {
            _spotLightMesh = CreateSpotLightMesh();
        }

        if (_lightMaterial == null)
        {
            shader = Shader.Find("Sandbox/VolumetricLight");
            if (shader == null)
                throw new Exception("Critical Error: \"Sandbox/VolumetricLight\" shader is missing. Make sure it is included in \"Always Included Shaders\" in ProjectSettings/Graphics.");
            _lightMaterial = new Material(shader);
        }

        if (_defaultSpotCookie == null)
        {
            _defaultSpotCookie = DefaultSpotCookie;
        }
    }
    /// <summary>
    /// 
    /// </summary>
    void OnEnable()
    {
        //_camera.RemoveAllCommandBuffers();
        if (_camera.actualRenderingPath == RenderingPath.Forward)
            _camera.AddCommandBuffer(CameraEvent.AfterDepthTexture, _preLightPass);
        else
            _camera.AddCommandBuffer(CameraEvent.BeforeLighting, _preLightPass);
    }

    /// <summary>
    /// 
    /// </summary>
    void OnDisable()
    {
        //_camera.RemoveAllCommandBuffers();
        if (_camera.actualRenderingPath == RenderingPath.Forward)
            _camera.RemoveCommandBuffer(CameraEvent.AfterDepthTexture, _preLightPass);
        else
            _camera.RemoveCommandBuffer(CameraEvent.BeforeLighting, _preLightPass);
    }

    void UpdateMacroKeyword()
    {
        switch (_currentResolution)
        {
            case DownSample.x2:
                blurPass = new Vector2Int(2, 3);
                break;
            case DownSample.x3:
                blurPass = new Vector2Int(8, 9);
                break;
            default:
                blurPass = new Vector2Int(0, 1);
                break;
        }
        Vector2 jitter;
        jitter.x = 0.25f / _camera.pixelWidth;
        jitter.y = 0.25f / _camera.pixelHeight;
        Shader.SetGlobalVector(_JitterOffset, jitter);
    }

    /// <summary>
    /// 
    /// </summary>
    void ChangeResolution()
    {
        _currentResolution = downSample;
        int width = _camera.pixelWidth;
        int height = _camera.pixelHeight;

        if (_volumeLightTexture != null)
            Destroy(_volumeLightTexture);

        _volumeLightTexture = new RenderTexture(width, height, 0, RenderTextureFormat.ARGBHalf);
        _volumeLightTexture.name = "VolumeLightBuffer";
        _volumeLightTexture.filterMode = FilterMode.Point;

        if (_halfDepthBuffer != null)
            Destroy(_halfDepthBuffer);
        if (_halfVolumeLightTexture != null)
            Destroy(_halfVolumeLightTexture);

        _halfVolumeLightTexture = new RenderTexture(width / (int)_currentResolution, height / (int)_currentResolution, 0, RenderTextureFormat.ARGBHalf);
        _halfVolumeLightTexture.name = "VolumeLightBufferHalf";
        _halfVolumeLightTexture.filterMode = FilterMode.Point;

        _halfDepthBuffer = new RenderTexture(width / (int)_currentResolution, height / (int)_currentResolution, 0, RenderTextureFormat.RFloat);
        _halfDepthBuffer.name = "VolumeLightHalfDepth";
        _halfDepthBuffer.Create();
        _halfDepthBuffer.filterMode = FilterMode.Point;
        UpdateMacroKeyword();
    }

    void ReChangeResolution()
    {
        _currentResolution = downSample;
        int width = _camera.pixelWidth;
        int height = _camera.pixelHeight;

        _halfVolumeLightTexture.Release();
        _halfVolumeLightTexture.width = width / (int)_currentResolution;
        _halfVolumeLightTexture.height = height / (int)_currentResolution;

        _halfDepthBuffer.Release();
        _halfDepthBuffer.width = width / (int)_currentResolution;
        _halfDepthBuffer.height = height / (int)_currentResolution;
        _halfDepthBuffer.Create();

        _volumeLightTexture.Release();
        _volumeLightTexture.width = width;
        _volumeLightTexture.height = height;

        UpdateMacroKeyword();

    }

    public void OnPreRender()
    {
        maxRayLength = Mathf.Min(maxRayLength, QualitySettings.shadowDistance);
        Shader.SetGlobalFloat(_MaxRayLength, maxRayLength);
        int width = _halfVolumeLightTexture.width;
        int height = _halfVolumeLightTexture.height;
        Shader.SetGlobalVector(_RandomNumber, new Vector2(UnityEngine.Random.Range(0f, 1000f), Vector3.Dot(Vector3.Cross(transform.position, transform.eulerAngles), Vector3.one)));
        Matrix4x4 proj = GL.GetGPUProjectionMatrix(_camera.projectionMatrix, true);
        _viewProj = proj * _camera.worldToCameraMatrix;
        Shader.SetGlobalMatrix(_InvVP, (GL.GetGPUProjectionMatrix(_camera.projectionMatrix, false) * _camera.worldToCameraMatrix).inverse);
        _preLightPass.Clear();

        _preLightPass.Blit(null, _halfDepthBuffer, _bilateralBlurMaterial, 4);
        _preLightPass.SetRenderTarget(_halfVolumeLightTexture);

        _preLightPass.ClearRenderTarget(false, true, new Color(0, 0, 0, 1));

        UpdateMaterialParameters();

        if (PreRenderEvent != null)
            PreRenderEvent(this, _viewProj);
    }
    [ImageEffectOpaque]
    public void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        if (onImageEvent != null)
            onImageEvent(this);
        RenderTexture temp = RenderTexture.GetTemporary(_halfVolumeLightTexture.width, _halfVolumeLightTexture.height, 0, RenderTextureFormat.ARGBHalf);
        temp.filterMode = FilterMode.Point;
        // horizontal bilateral blur at x2 res
        Graphics.Blit(_halfVolumeLightTexture, temp, _bilateralBlurMaterial, blurPass.x);
        // vertical bilateral blur at x2 res
        Graphics.Blit(temp, _halfVolumeLightTexture, _bilateralBlurMaterial, blurPass.y);
        // upscale to full res
        Graphics.Blit(_halfVolumeLightTexture, _volumeLightTexture, _bilateralBlurMaterial, 5);
        RenderTexture.ReleaseTemporary(temp);

        _blitAddMaterial.SetTexture(_Source, source);
        Graphics.Blit(_volumeLightTexture, destination, _blitAddMaterial, 0);
    }
    static int _Source = Shader.PropertyToID("_Source");
    static int _HalfResColor = Shader.PropertyToID("_HalfResColor");
    static int _RandomNumber = Shader.PropertyToID("_RandomNumber");
    static int _JitterOffset = Shader.PropertyToID("_JitterOffset");
    static int _InvVP = Shader.PropertyToID("_InvVP");
    private void UpdateMaterialParameters()
    {
        _bilateralBlurMaterial.SetTexture(_Source, _halfDepthBuffer);
        _bilateralBlurMaterial.SetTexture(_HalfResColor, _halfVolumeLightTexture);
    }

    /// <summary>
    /// 
    /// </summary>
    void Update()
    {

        if ((_volumeLightTexture.width != _camera.pixelWidth || _volumeLightTexture.height != _camera.pixelHeight))
            ReChangeResolution();
        //#endif
    }
    /// <summary>
    /// 
    /// </summary>
    /// <returns></returns>
    private Mesh CreateSpotLightMesh()
    {
        // copy & pasted from other project, the geometry is too complex, should be simplified
        Mesh mesh = new Mesh();

        const int segmentCount = 16;
        Vector3[] vertices = new Vector3[2 + segmentCount * 3];
        Color32[] colors = new Color32[2 + segmentCount * 3];

        vertices[0] = new Vector3(0, 0, 0);
        vertices[1] = new Vector3(0, 0, 1);

        float angle = 0;
        float step = Mathf.PI * 2.0f / segmentCount;
        float ratio = 0.9f;

        for (int i = 0; i < segmentCount; ++i)
        {
            vertices[i + 2] = new Vector3(-Mathf.Cos(angle) * ratio, Mathf.Sin(angle) * ratio, ratio);
            colors[i + 2] = new Color32(255, 255, 255, 255);
            vertices[i + 2 + segmentCount] = new Vector3(-Mathf.Cos(angle), Mathf.Sin(angle), 1);
            colors[i + 2 + segmentCount] = new Color32(255, 255, 255, 0);
            vertices[i + 2 + segmentCount * 2] = new Vector3(-Mathf.Cos(angle) * ratio, Mathf.Sin(angle) * ratio, 1);
            colors[i + 2 + segmentCount * 2] = new Color32(255, 255, 255, 255);
            angle += step;
        }

        mesh.vertices = vertices;
        mesh.colors32 = colors;

        int[] indices = new int[segmentCount * 3 * 2 + segmentCount * 6 * 2];
        int index = 0;

        for (int i = 2; i < segmentCount + 1; ++i)
        {
            indices[index++] = 0;
            indices[index++] = i;
            indices[index++] = i + 1;
        }

        indices[index++] = 0;
        indices[index++] = segmentCount + 1;
        indices[index++] = 2;

        for (int i = 2; i < segmentCount + 1; ++i)
        {
            indices[index++] = i;
            indices[index++] = i + segmentCount;
            indices[index++] = i + 1;

            indices[index++] = i + 1;
            indices[index++] = i + segmentCount;
            indices[index++] = i + segmentCount + 1;
        }

        indices[index++] = 2;
        indices[index++] = 1 + segmentCount;
        indices[index++] = 2 + segmentCount;

        indices[index++] = 2 + segmentCount;
        indices[index++] = 1 + segmentCount;
        indices[index++] = 1 + segmentCount + segmentCount;

        //------------
        for (int i = 2 + segmentCount; i < segmentCount + 1 + segmentCount; ++i)
        {
            indices[index++] = i;
            indices[index++] = i + segmentCount;
            indices[index++] = i + 1;

            indices[index++] = i + 1;
            indices[index++] = i + segmentCount;
            indices[index++] = i + segmentCount + 1;
        }

        indices[index++] = 2 + segmentCount;
        indices[index++] = 1 + segmentCount * 2;
        indices[index++] = 2 + segmentCount * 2;

        indices[index++] = 2 + segmentCount * 2;
        indices[index++] = 1 + segmentCount * 2;
        indices[index++] = 1 + segmentCount * 3;

        ////-------------------------------------
        for (int i = 2 + segmentCount * 2; i < segmentCount * 3 + 1; ++i)
        {
            indices[index++] = 1;
            indices[index++] = i + 1;
            indices[index++] = i;
        }

        indices[index++] = 1;
        indices[index++] = 2 + segmentCount * 2;
        indices[index++] = segmentCount * 3 + 1;

        mesh.triangles = indices;
        mesh.RecalculateBounds();
        return mesh;
    }
}
