Shader "Hidden/PoorGI"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }

    SubShader
    {
        Tags
        {
            "RenderType"="Opaque"
        }
        LOD 100

        Cull Front
        ZTest Off
        ZWrite Off

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/GlobalSamplers.hlsl"

        half4 _MainTex_TexelSize;
        TEXTURE2D(_MainTex);

        struct Attributes
        {
            half3 postionOS : POSITION;
            half2 texcoord : TEXCOORD0;
        };

        struct Varyings
        {
            half2 uv : TEXCOORD0;
            half4 postionCS : SV_POSITION;
        };

        Varyings FulscreenVertex(Attributes input)
        {
            Varyings output;
            output.uv = input.texcoord;
            #if UNITY_UV_STARTS_AT_TOP
            output.uv.y = 1.0h - output.uv.y;
            #endif

            output.postionCS = half4(input.postionOS.xy * 2.0h - 1.0h, 0.0f, 1.0h);
            return output;
        }
        ENDHLSL

        Pass
        {
            Name "DownSampleDepthX4"

            Blend One Zero
            ColorMask R

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half4 Fragmet(Varyings input) : SV_Target
            {
                return LinearEyeDepth(SAMPLE_DEPTH_TEXTURE_LOD(_MainTex, sampler_PointClamp, input.uv, 0), _ZBufferParams);
                half depth = UNITY_RAW_FAR_CLIP_VALUE;
                int2 coord = floor(input.postionCS.xy) * 4;

                UNITY_LOOP
                for (int y = 0; y < 4; y++)
                {
                    UNITY_LOOP
                    for (int x = 0; x < 4; x++)
                    {
                        depth = max(depth, LOAD_TEXTURE2D_LOD(_MainTex, coord + int2(x, y), 0).x);
                    }
                }

                return LinearEyeDepth(depth, _ZBufferParams);
            }
            ENDHLSL
        }

        Pass
        {
            Name "GI Trace"

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half GRnoise2(half2 xy)
            {
                const half2 igr2 = half2(0.754877666, 0.56984029);
                xy *= igr2;
                half n = frac(xy.x + xy.y);
                return n < 0.5 ? 2.0 * n : 2.0 - 2.0 * n;
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

            half3 TransformWorldToCameraNormal(half3 normalWS)
            {
                return normalize(mul(unity_WorldToCamera, half4(normalWS, 0.0h)).xyz);
            }

            half3 SampleTraceLighting(half2 uv)
            {
                // TODO: Blur SceneColor!
                half3 color = SAMPLE_TEXTURE2D_LOD(_CameraOpaqueTexture, sampler_LinearClamp, uv, 0).rgb;
                half luminance = Luminance(color) - 0.9h;
                return color * max(0.0h, luminance);
            }

            half SampleTraceDepth(half2 uv)
            {
                return SAMPLE_DEPTH_TEXTURE_LOD(_MainTex, sampler_PointClamp, uv, 0);
            }
            half LoadTraceDepth(uint2 coord)
            {
                return LOAD_TEXTURE2D_LOD(_MainTex, coord, 0).r;
            }

            half3 SamplerTraceNormals(half2 uv)
            {
                return normalize(SAMPLE_TEXTURE2D_LOD(_CameraNormalsTexture, sampler_LinearClamp, uv, 0).xyz);
            }

            half4 Fragmet(Varyings input) : SV_Target
            {
                half3 gi = 0.0h;

                half2 traceUV = input.uv - _MainTex_TexelSize.xy * 0.5h;
                
                half probeDepth = LoadTraceDepth(input.postionCS.xy);
                half3 probeNormalWS = SamplerTraceNormals(traceUV);
                half3 probeNormalVS = TransformWorldToCameraNormal(probeNormalWS);

                half3 probeVS = TransformScreenUVToView(traceUV, probeDepth);
                half3 viewDirectionVS = -normalize(probeVS);

                const int raySteps = 4;
                const half rayLength = 0.5f;
                const half rayCount = 32.0h;
                const half deltaAngle = TWO_PI / rayCount;

                UNITY_LOOP
                for (half alpha = deltaAngle * 0.5h; alpha < TWO_PI; alpha += deltaAngle)
                {
                    half2 rayDirection;
                    half jitter = GRnoise2(floor(input.postionCS.xy));
                    sincos(alpha, rayDirection.y, rayDirection.x);
                    rayDirection /= normalize(_ScreenSize.xy);

                    UNITY_LOOP
                    for (half step = 0; step < raySteps; step++)
                    {
                        half ji = (jitter + step) / raySteps;
                        half noff = ji * ji;

                        half2 rayUV = traceUV + rayDirection * noff * rayLength;

                        if (any(rayUV < 0.0h || rayUV > 1.0h)) break;

                        half depth = SampleTraceDepth(rayUV);
                        half3 lingting = SampleTraceLighting(rayUV);
                        half3 surfNormalWS = SamplerTraceNormals(rayUV);
                        half3 surfNormalVS = TransformWorldToCameraNormal(surfNormalWS);

                        half3 rayVS = TransformScreenUVToView(rayUV, depth);
                        half3 rayDirectionVS = normalize(rayVS - probeVS);

                        half NdotR = dot(probeNormalVS, rayDirectionVS);
                        half VdotR = dot(viewDirectionVS, rayDirectionVS);
                        half surfNdotR = dot(surfNormalVS, -rayDirectionVS);
                        half surfNdotN = 1.0h - abs(dot(surfNormalVS, probeNormalVS));

                        gi += lingting * saturate(NdotR) / raySteps;
                    }
                }

                // return half4(0.1h * probeDepth.xxx, probeDepth);
                return half4(gi / rayCount, probeDepth);
            }
            ENDHLSL
        }

        Pass
        {
            Name "BlurH"

            Blend One Zero

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half4 Fragmet(Varyings input) : SV_Target
            {
                half4 color = 0.0h;
                for (half i = -4.0h; i <= 4.1h; i++)
                {
                    color += SAMPLE_TEXTURE2D(
                        _MainTex,
                        sampler_LinearClamp,
                        input.uv + half2(_MainTex_TexelSize.x * i, 0.0h)
                    );
                }
                return color / 9.0h;
            }
            ENDHLSL
        }

        Pass
        {
            Name "BlurV"

            Blend One Zero

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half4 Fragmet(Varyings input) : SV_Target
            {
                half4 color = 0.0h;
                for (half i = -4.0h; i <= 4.1h; i++)
                {
                    color += SAMPLE_TEXTURE2D(
                        _MainTex,
                        sampler_LinearClamp,
                        input.uv + half2(0.0h, _MainTex_TexelSize.y * i)
                    );
                }
                return color / 9.0h;
            }
            ENDHLSL
        }

        Pass
        {
            Name "BilateralUpsample"

            Blend One One

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half4 _TraceSize;
            half4 _TraceDepth_TexelSize;
            TEXTURE2D(_TraceDepth);

            half4 LinearEyeDepth(half4 depth)
            {
                return 1.0h / (_ZBufferParams.z * depth + _ZBufferParams.w);
            }

            inline half4 LoadGI(uint2 coord)
            {
                // return SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, coord * _MainTex_TexelSize.xy, 0);
                return LOAD_TEXTURE2D_LOD(_MainTex, coord, 0);
            }
            inline half LoadTraceDepth(uint2 coord)
            {
                return LOAD_TEXTURE2D_LOD(_TraceDepth, coord, 0).x;
            }

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

            half4 Fragmet2(Varyings input) : SV_Target
            {
                uint2 traceCoord = floor(input.postionCS.xy) / 4;
                half hiDepth = LinearEyeDepth(LoadSceneDepth(floor(input.postionCS.xy)), _ZBufferParams);

                half4 giDepthC = LoadGI(traceCoord);
                half4 giDepthT = LoadGI(traceCoord + int2(0, 1));
                half4 giDepthL = LoadGI(traceCoord + int2(-1, 0));
                half4 giDepthR = LoadGI(traceCoord + int2(1, 0));
                half4 giDepthB = LoadGI(traceCoord + int2(0, -1));

                half lowDepthC = giDepthC.a;
                half centerWeight = 1.0h / (1.0h + abs(hiDepth - lowDepthC));
                
                half4 lowDepthTLRB = half4(giDepthT.a, giDepthL.a, giDepthR.a, giDepthB.a);
                half4 weights = 1.0h / (1.0h + abs(hiDepth - lowDepthTLRB));

                half totalWeight = dot(1.0h, weights) + centerWeight;
                centerWeight /= totalWeight;
                weights /= totalWeight;

                return
                    giDepthC * centerWeight +
                    giDepthT * weights.x +
                    giDepthL * weights.y +
                    giDepthR * weights.z +
                    giDepthB * weights.w
                ;
            }

            half4 Fragmet(Varyings input) : SV_Target
            {
                int2 traceCoord = floor(input.postionCS.xy) / 4;

                half hiDepth = LoadSceneDepth(floor(input.postionCS.xy));

                half4 giDepthA = LoadGI(traceCoord);
                half4 giDepthB = LoadGI(traceCoord + int2(1, 0));
                half4 giDepthC = LoadGI(traceCoord + int2(0, 1));
                half4 giDepthD = LoadGI(traceCoord + int2(1, 1));

                hiDepth = LinearEyeDepth(hiDepth, _ZBufferParams);
                half4 lowDepthABCD = half4(giDepthA.a, giDepthB.a, giDepthC.a, giDepthD.a);

                // TODO: Bilinear weight???
                half2 ratio = frac(floor(input.postionCS.xy) * 0.25h);
                half4 bilinearWeights = GetBilinearWeights(ratio);

                if (true)
                {
                    half4 w = bilinearWeights * saturate(exp(-1.0h * abs(hiDepth - lowDepthABCD)));
                    half tw = dot(1.0h, w);
                    w = saturate(w / tw);
                    half4 res =
                        giDepthA * w.x + 
                        giDepthB * w.y + 
                        giDepthC * w.z + 
                        giDepthD * w.w;

                    return res;
                }

                half _UpsampleTolerance = 1.0h;
                half _NoiseFilterStrength = 0.9h;
                half4 initialWeight = half4(9, 3, 3, 1); // ???
                half4 weights = initialWeight / (100.0h * abs(hiDepth.xxxx - lowDepthABCD) + 1.0h);
                half totalWeight = dot(weights, 1.0h);
                weights /= totalWeight;

                // weights *= bilinearWeights;

                // https://github.com/Polish-Miko/GravityEngine/blob/6fad1bd3140ccf5f656197374fe32c7defa3987c/GEngine/GDxRenderer/Shaders/GtaoUpsamplePS.hlsl#L22
                // half4 w = saturate(1.0h - abs(hiDepth.xxxx - lowDepthABCD) / 2.5h);
                // half3 colorAB = lerp(depthA * w.x, depthB * w.y, localOffset.x);
                // half3 colorCD = lerp(depthC * w.z, depthD * w.w, localOffset.x);
                // return half4(lerp(colorAB, colorCD, localOffset.y) * 0.1h, 1.0h);

                // #define DEBUG 
                #ifdef DEBUG
                half4 result =
                    giDepthA.a * weights.x +
                    giDepthB.a * weights.y +
                    giDepthC.a * weights.z +
                    giDepthD.a * weights.w;
                result = abs(result - hiDepth);
                #else

                half4 result =
                    giDepthA * weights.x +
                    giDepthB * weights.y +
                    giDepthC * weights.z +
                    giDepthD * weights.w;

                #endif

                return result;
            }
            ENDHLSL
        }
    }
}