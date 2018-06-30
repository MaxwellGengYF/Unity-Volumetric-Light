using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using Random = System.Random;
[ExecuteInEditMode]
public class GenerateRandom : MonoBehaviour {

	// Use this for initialization
	void OnEnable () {
        Texture2D tex = new Texture2D(8192, 1, TextureFormat.RFloat, false, true);
        Color[] colors = new Color[8192];
        Random r = new Random();
        for (int i = 0; i < 8192; ++i) {
            colors[i] = new Color((float)r.NextDouble(), 0, 0, 0);
        }
        tex.SetPixels(colors);
        UnityEditor.AssetDatabase.CreateAsset(tex, "Assets/RandomTexture.asset");
	}
}
