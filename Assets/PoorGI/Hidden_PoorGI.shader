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

            half3 SamplerTraceNormals(half2 uv)
            {
                return normalize(SAMPLE_TEXTURE2D_LOD(_CameraNormalsTexture, sampler_LinearClamp, uv, 0).xyz);
            }

            half4 Fragmet(Varyings input) : SV_Target
            {
                half3 gi = 0.0h;

                half probeDepth = SampleTraceDepth(input.uv);
                half3 probeNormalWS = SamplerTraceNormals(input.uv);
                half3 probeNormalVS = TransformWorldToCameraNormal(probeNormalWS);

                half3 probeVS = TransformScreenUVToView(input.uv, probeDepth);
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

                        half2 rayUV = input.uv + rayDirection * noff * rayLength;

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

                return half4(gi / rayCount, 1.0h);
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
                return LOAD_TEXTURE2D_LOD(_MainTex, coord, 0);
            }
            inline half LoadTraceDepth(uint2 coord)
            {
                return LOAD_TEXTURE2D_LOD(_TraceDepth, coord, 0).x;
            }

            half4 Fragmet(Varyings input) : SV_Target
            {
                uint2 traceCoord = floor(input.postionCS.xy) / 4;

                half hiDepth = LoadSceneDepth(floor(input.postionCS.xy));

                half depthA =LoadTraceDepth(traceCoord).x;
                half depthB =LoadTraceDepth(traceCoord + uint2(1, 0)).x;
                half depthC =LoadTraceDepth(traceCoord + uint2(0, 1)).x;
                half depthD =LoadTraceDepth(traceCoord + uint2(1, 1)).x;

                half4 giA = LoadGI(traceCoord);
                half4 giB = LoadGI(traceCoord + uint2(1, 0));
                half4 giC = LoadGI(traceCoord + uint2(0, 1));
                half4 giD = LoadGI(traceCoord + uint2(1, 1));

                hiDepth = LinearEyeDepth(hiDepth, _ZBufferParams);
                half4 lowDepthABCD = half4(depthA, depthB, depthC, depthD);

                // TODO: Bilinear weight???
                // half2 localOffset = frac(floor(input.postionCS.xy) * 0.25h) / 0.75h;
                // half4 bilinearWeights = half4(localOffset, 1.0h - localOffset);
                // bilinearWeights = half4(
                //     bilinearWeights.z * bilinearWeights.w,
                //     bilinearWeights.x * bilinearWeights.w,
                //     bilinearWeights.z * bilinearWeights.y,
                //     bilinearWeights.x * bilinearWeights.y
                // );

                half _UpsampleTolerance = 0.01h;
                half _NoiseFilterStrength = 0.9h;
                half4 initialWeight = half4(9, 3, 1, 3); // ???
                half4 weights = 3.0h / (abs(hiDepth.xxxx - lowDepthABCD) + _UpsampleTolerance);
                half totalWeight = dot(weights, 1.0h) + 0.0001h;

                // https://github.com/Polish-Miko/GravityEngine/blob/6fad1bd3140ccf5f656197374fe32c7defa3987c/GEngine/GDxRenderer/Shaders/GtaoUpsamplePS.hlsl#L22
                // half4 w = saturate(1.0h - abs(hiDepth.xxxx - lowDepthABCD) / 2.5h);
                // half3 colorAB = lerp(depthA * w.x, depthB * w.y, localOffset.x);
                // half3 colorCD = lerp(depthC * w.z, depthD * w.w, localOffset.x);
                // return half4(lerp(colorAB, colorCD, localOffset.y) * 0.1h, 1.0h);

                // #define DEBUG 
                #ifdef DEBUG
                half4 result =
                    depthA * weights.x +
                    depthB * weights.y +
                    depthC * weights.z +
                    depthD * weights.w +
                    _NoiseFilterStrength;
                result *= 0.1h;
                #else

                half4 result =
                    giA * weights.x +
                    giB * weights.y +
                    giC * weights.z +
                    giD * weights.w;

                #endif

                result /= totalWeight;
                return result;
            }
            ENDHLSL
        }
    }
}