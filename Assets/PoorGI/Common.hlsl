#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

////////////////////////////
/// DEPTH TRANSFORMATION ///
////////////////////////////

// Z buffer to linear view space (eye) depth.
// Does NOT correctly handle oblique view frustums.
// Does NOT work with orthographic projection.
// zBufferParam (UNITY_REVERSED_Z) = { f/n - 1,   1, (1/n - 1/f), 1/f }
// zBufferParam                    = { 1 - f/n, f/n, (1/f - 1/n), 1/n }
half LinearEyeDepth(half depth, half4 zBufferParam)
{
    return 1.0 / (zBufferParam.z * depth + zBufferParam.w);
}

// Z buffer to linear view space (eye) depth.
// Does NOT correctly handle oblique view frustums.
// Does NOT work with orthographic projection.
// zBufferParam (UNITY_REVERSED_Z) = { f/n - 1,   1, (1/n - 1/f), 1/f }
// zBufferParam                    = { 1 - f/n, f/n, (1/f - 1/n), 1/n }
half2 LinearEyeDepth(half2 depth, half4 zBufferParam)
{
    return 1.0 / (zBufferParam.z * depth + zBufferParam.w);
}

// Z buffer to linear view space (eye) depth.
// Does NOT correctly handle oblique view frustums.
// Does NOT work with orthographic projection.
// zBufferParam (UNITY_REVERSED_Z) = { f/n - 1,   1, (1/n - 1/f), 1/f }
// zBufferParam                    = { 1 - f/n, f/n, (1/f - 1/n), 1/n }
half4 LinearEyeDepth(half4 depth, half4 zBufferParam)
{
    return 1.0 / (zBufferParam.z * depth + zBufferParam.w);
}

half3 TransformWorldToCameraNormal(half3 normalWS)
{
    return normalize(mul(unity_WorldToCamera, half4(normalWS, 0.0h)).xyz);
}

half3 TransformScreenUVToView(half2 uv, half depth)
{
    half4 positionVS = mul(
        UNITY_MATRIX_I_P,
        half4(mad(uv, half2(2.0h, -2.0h), half2(-1.0h, 1.0h)), depth, 1.0h)
    );
    positionVS.z = -positionVS.z;
    return positionVS.xyz / positionVS.w;
}

half3 TransformScreenUVToViewLinear(half2 uv, half linearDepth)
{
    half4 positionVS = mul(
        UNITY_MATRIX_I_P,
        half4(mad(uv, half2(-2.0h, 2.0h), half2(1.0h, -1.0h)), UNITY_RAW_FAR_CLIP_VALUE, 1.0h)
    );
    positionVS.xyz /= positionVS.w;
    positionVS.xyz *= linearDepth / positionVS.z;
    return positionVS.xyz;
}


/////////////
/// NOISE ///
/////////////

/// SpatioTemporal Blue Noise ref.: https://github.com/NVIDIA-RTX/STBN
float4 _STBN_TexelSize;
Texture2D<half2> _STBN;
half2 STBN(half2 coords)
{
    return SAMPLE_TEXTURE2D_LOD(_STBN, sampler_PointRepeat, coords * _STBN_TexelSize.xy, 0);
}

Texture2D<half4> _BayerMatrix;
half BayerNoise(uint2 coords)
{
    return LOAD_TEXTURE2D(_BayerMatrix, coords % 4).a;
}


////////////////
/// SAMPLING ///
////////////////

half4 GetBilinearWeights(half2 ratio)
{
    half4 bilinearWeights = half4(ratio, 1.0h - ratio);
    bilinearWeights = half4(
        bilinearWeights.z * bilinearWeights.w,
        bilinearWeights.x * bilinearWeights.w,
        bilinearWeights.z * bilinearWeights.y,
        bilinearWeights.x * bilinearWeights.y
    );
    return bilinearWeights;
}

// Return 4 1-channel texture samples at uv0, uv1, uv2, uv3.
half4 Sample4(Texture2D<half> tex, float4 uv01, float4 uv23)
{
    half4 output;
    output.x = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv01.xy, 0).x;
    output.y = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv01.zw, 0).x;
    output.z = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv23.xy, 0).x;
    output.w = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv23.zw, 0).x;
    return output;
}

// Return 4 4-channel texture samples at uv0, uv1, uv2, uv3.
void Sample4(Texture2D<half4> tex, float4 uv01, float4 uv23,
    out half4 a, out half4 b, out half4 c, out half4 d)
{
    a = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv01.xy, 0);
    b = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv01.zw, 0);
    c = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv23.xy, 0);
    d = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv23.zw, 0);
}

// Return bilinear blended 4-channel texture sample. 
half4 Sample4_Bilinear(Texture2D<half4> tex, float4 uv01, float4 uv23, half4 weights)
{
    half4 a, b, c, d;
    Sample4(tex, uv01, uv23, a, b, c, d);
    return mul(weights, half4x4(a, b, c, d));
}


/////////////////
/// FILTERING ///
/////////////////

half4 GaussianBlurOneTap(Texture2D<half4> tex, float2 texel, float2 uv, half range = 2.0h)
{
    half4 color = 0.0h;
    half totalWeight = 0.0h;

    for (half y = -range; y < range + 0.1h; y++)
    {
        for (half x = -range; x < range + 0.1h; x++)
        {
            half2 offset = half2(x, y);
            half2 uv0 = uv + offset * texel.xy * 4.0h;
            half4 sample = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv0, 0);
                        
            // Gaussian weight relative to center
            half dist2 = dot(offset, offset);
            half weight = exp(-dist2 * 0.5h);
                        
            color += sample * weight;
            totalWeight += weight;
        }
    }

    return color / totalWeight;
}

half4 BilateralBlur(
    Texture2D<half4> tex, 
    Texture2D<half> depthTex, int depthLod,
    float2 texel,
    float2 uv,
    half edgeSensitivity, half blurSize, float2 direction)
{
    half steps = floor(blurSize);
    half stepsRcp = 1.0h / steps;
    const half2 blurDirection = texel.xy * direction;
    half centerDepth = SAMPLE_DEPTH_TEXTURE_LOD(depthTex, sampler_LinearClamp, uv, depthLod);

    half4 result = 0.0h;
    half totalWeight = 0.0h;
    for (half i = -steps; i <= steps + 0.1h; i++)
    {
        half2 offset = blurDirection * i;
        half4 color = SAMPLE_TEXTURE2D_LOD(tex, sampler_LinearClamp, uv + offset, 0);
        half depth = SAMPLE_DEPTH_TEXTURE_LOD(depthTex, sampler_LinearClamp, uv + offset, depthLod);

        half r = i * stepsRcp;
        half diff = abs(centerDepth - depth);
        half weight = exp(-r * r - edgeSensitivity * diff * diff);

        result += color * weight;
        totalWeight += weight;
    }

    return result / totalWeight;
}

// TODO: Add Box filter


///////////////////////////
/// SPHERICAL HARMONICS ///
///////////////////////////

// SH0: w; SH1 xyz;
inline half EvaluateIrradianceSH1(half4 sh, half3 v) { return dot(sh.xyz, v); }
// SH0: w; SH1 xyz;
inline half EvaluateIrradianceSH01(half4 sh, half3 v) { return sh.w + EvaluateIrradianceSH1(sh, v); }
// SH0: (shR.w, shG.w, shB.w), SH1R: shR.rgb, etc.
inline half3 EvaluateIrradianceSH01(half4 shR, half4 shG,half4  shB, half3 v)
{
    half3 gi = half3(shR.a, shG.a, shB.a);
    gi += shR.rgb * v.x;
    gi += shG.rgb * v.y;
    gi += shB.rgb * v.z;
    return gi;
}