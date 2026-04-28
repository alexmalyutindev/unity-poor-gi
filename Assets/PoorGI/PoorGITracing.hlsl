#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SphericalHarmonics.hlsl"

#include "Common.hlsl"

TEXTURE2D(_TraceColor);
TEXTURE2D(_TraceDepth);

half2 Rotate(half2 v, half a)
{
    half s, c;
    sincos(a, s, c);
    return half2(
        v.x * c - v.y * s,
        v.x * s + v.y * c
    );
}

float2 GTAOFastAcos(float2 x)
{
    float2 outVal = -0.156583 * abs(x) + HALF_PI;
    outVal *= sqrt(1.0 - abs(x));
    return x >= 0 ? outVal : PI - outVal;
}

inline half3 SampleTraceLighting(half2 uv, int mipLevel)
{
    // TODO: Preprocess SceneColor!
    // TODO: I can use alpha for smthing.
    return SAMPLE_TEXTURE2D_LOD(_TraceColor, sampler_LinearClamp, uv, mipLevel).rgb;
}

inline half LoadLinearTraceDepth(uint2 coord)
{
    return LOAD_TEXTURE2D_LOD(_TraceDepth, coord, 0).x;
}

struct Output
{
    #if !defined(USE_SH01)
    half4 irradianceColor : SV_Target0;
    half4 irradianceSH : SV_Target1;
    #else
    half4 SHr : SV_Target0;
    half4 SHg : SV_Target1;
    half4 SHb : SV_Target2;
    #endif
};

Output Trace(float2 positionCS, float2 uv, 
    float _RaysCount, 
    float _StepsCount, 
    float _DepthThickness, 
    float _RayLength,
    float _MipLevelFactor
)
{
    const half rayCount = floor(_RaysCount);
    const half raySteps = floor(_StepsCount);
    const half thickness = _DepthThickness;
    const half probOffsetZ = 0.02h;

    const half rayStepsRcp = rcp(raySteps);
    const half rayCountRcp = rcp(rayCount);

    uint2 tileCoord = floor(positionCS);
    half probeLinearDepth = LoadLinearTraceDepth(tileCoord);

    // NOTE: Hacky noise, STBN for step jitter, and regular pattern for angle jitter.
    half2 jitter = 0.0h;
    jitter.x = BayerNoise(tileCoord);
    jitter.y = BayerNoise(tileCoord + 1);

    const half deltaAngle = TWO_PI * rayCountRcp;
    const half2 rayNormalizationTerm = _ScreenSize.xx / _ScreenSize.xy;

    half2 traceUV = uv;

    // NOTE: Probe depth offseting.
    // probeLinearDepth -= probeLinearDepth * probOffsetZ;
    half3 probeVS = TransformScreenUVToViewLinear(traceUV, probeLinearDepth - 0.01h);
    half3 viewDirectionVS = -normalize(probeVS);

    #if !defined(USE_SH01)
    half3 finalColor = half(0.0h);
    half4 finalSH = half(0.0h);
    #else
    half3 sh0 = half3(0.0h, 0.0h, 0.0h);
    half3 shR = half3(0.0h, 0.0h, 0.0h);
    half3 shG = half3(0.0h, 0.0h, 0.0h);
    half3 shB = half3(0.0h, 0.0h, 0.0h);
    #endif

    UNITY_LOOP
    for (half alpha = 0.0h; alpha < TWO_PI - 0.01h; alpha += deltaAngle)
    {
        half2 rayDirection;
        sincos(alpha, rayDirection.x, rayDirection.y);
        rayDirection *= _RayLength * 0.5f;

        int stepIndexI = 0;
        uint occlusion = 0u;
        half prevHorizon = 0.0h;
        UNITY_LOOP
        for (half stepIndexF = 0.0h; stepIndexF < raySteps; stepIndexF++, stepIndexI++)
        {
            half ji = (jitter.x + max(0.01f, stepIndexF)) / (raySteps - 1.0h);
            half noff = ji * ji;

            half2 offset = rayDirection * noff;
            int mipLevel = min(12, floor(length(offset * 2.0f) * _MipLevelFactor));

            // Mix step-dependent rotation with base jitter for per-step variation
            // half stepRotation = rayCountRcp * TWO_PI * (jitter.y - 0.5) + stepIndexF * rayCountRcp * PI;
            half stepRotation = rayCountRcp * TWO_PI * (jitter.y - 0.5h);
            offset = Rotate(offset, stepRotation);
            offset *= rayNormalizationTerm; // Re-enable for aspect-ratio correction
            half2 rayUV = traceUV + offset;

            if (any(rayUV < 0.0h || rayUV > 1.0h)) break;

            // TODO: Make depth pyramid for Pyramid HBAO: https://ceur-ws.org/Vol-3027/paper5.pdf
            // Use variance depth for more stable tracing, reduces firefly artifacts at edges
            // half linearDepth = SampleVarianceDepth(rayUV);

            // half linearDepth = SampleLinearTraceDepth(rayUV, 0);
            half4 depthNormal = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, rayUV, mipLevel);
            half linearDepth = depthNormal.x;

            // TODO: Generate blured frame color buffer mip chain!
            half3 lingting = SampleTraceLighting(rayUV, mipLevel);
            half3 currentLighting;

            half3 rayPositionVS_near = TransformScreenUVToViewLinear(rayUV, linearDepth);
            half3 rayDirectionVS = rayPositionVS_near - probeVS;
            half rayLength = length(rayDirectionVS);
            half3 rayDirectionVS_norm = rayDirectionVS / rayLength;

            half VdotR_near = dot(viewDirectionVS, rayDirectionVS_norm);
            half VdotR_far = dot(viewDirectionVS, normalize(rayDirectionVS - viewDirectionVS * thickness));

            #if !defined(USE_VISIBILITY_BITMASK)
            {
                half horizon = FastACos(-VdotR_near) * INV_PI;
                half visibility = clamp(horizon - prevHorizon, 0.0h, 1.0f / (2.0h + stepIndexF));
                currentLighting = lingting * visibility;
                prevHorizon = max(prevHorizon, horizon);
            }
            #else
            {
                half2 frontBackHorizon;
                frontBackHorizon.x = VdotR_near;
                frontBackHorizon.y = VdotR_far;
                frontBackHorizon = GTAOFastAcos(frontBackHorizon) * INV_PI;

                uint indirect = updateSectors(frontBackHorizon.x, frontBackHorizon.y, 0u);
                half visibility = half(bitCount(indirect & ~occlusion)) * sectorCountRcp;
                currentLighting = lingting * visibility;
                occlusion |= indirect;
            }
            #endif

            #if !defined(USE_SH01)
            // SH Ligting: https://deadvoxels.blogspot.com/2009/08/has-someone-tried-this-before.html
            // Half-Life 2 Shading: https://drivers.amd.com/developer/gdc/D3DTutorial10_Half-Life2_Shading.pdf
            half lum = Luminance(currentLighting);
            finalColor += currentLighting * rayCountRcp;
            finalSH += half4(kSHBasis1 * rayDirectionVS_norm, kSHBasis0) * lum;
            #else
            currentLighting *= rayCountRcp;
            sh0 += currentLighting * kSHBasis0;
            shR += currentLighting * rayDirectionVS_norm.x * kSHBasis1;
            shG += currentLighting * rayDirectionVS_norm.y * kSHBasis1;
            shB += currentLighting * rayDirectionVS_norm.z * kSHBasis1;
            #endif
        }
    }

    Output output;
    #if !defined(USE_SH01)
    output.irradianceColor = half4(finalColor, probeLinearDepth);
    output.irradianceSH = finalSH;
    #else
    output.SHr = half4(shR, sh0.r);
    output.SHg = half4(shG, sh0.g);
    output.SHb = half4(shB, sh0.b);
    #endif
    return output;
}
