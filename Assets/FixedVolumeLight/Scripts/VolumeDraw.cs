using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

public class VolumeDraw : MonoBehaviour
{
    private MeshFilter filter;
    public RenderTexture volumeTexture;
    private Material material; //TODO
    static int _SamplePos = Shader.PropertyToID("_SamplePos");
    public Texture3D volumeTex;
    [Range(0f, 1f)]
    public float samplePos;
    void Awake()
    {
        material = new Material(Shader.Find("Maxwell/GodRay"));
        filter = GetComponent<MeshFilter>();
        material.SetTexture("_VolumeTex", volumeTex);
    }

    void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        Shader.SetGlobalFloat(_SamplePos, samplePos);
        Graphics.Blit(null, destination, material, 0);
    }
    /*
    private void OnWillRenderObject()
    {
        if (!enabled) return;
        Camera cam = Camera.current;
        Matrix4x4 vp = GL.GetGPUProjectionMatrix(cam.projectionMatrix, true) * cam.worldToCameraMatrix;
        GL.PushMatrix();
        GL.LoadProjectionMatrix(vp);
        RenderTexture depthTexture = RenderTexture.GetTemporary(Screen.width, Screen.height, 16, RenderTextureFormat.ARGBFloat, RenderTextureReadWrite.Default);
        Graphics.SetRenderTarget(depthTexture);
        material.SetPass(1);        //Cull front local position
        Graphics.DrawMeshNow(filter.sharedMesh, transform.localToWorldMatrix);
        GL.PopMatrix();
    }*/

    void Get3DTex()
    {
        
    }
}
