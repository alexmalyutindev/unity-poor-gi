Shader "Hidden/PoorGI"
{
    Properties
    {
        [Toggle(USE_VISIBILITY_BITMASK)]
        _UseVisibilityBitmask ("Use Visibility Bitmask", Float) = 1.0

        _MainTex("Texture", 2D) = "white" {}
        _BlurSize("_BlurSize", Range(1, 6)) = 4
        _RayLength("_RayLength", Range(0.1, 1.0)) = 0.5

        [NonModifiableTextureData][HideInInspector]
        _STBN("_STBN", 2D) = "black" {}
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

        half4 _STBN_TexelSize;
        Texture2D<half2> _STBN;

        // Funcs
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

        half _BlurSize = 4.0h;
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
            half4 positionCS : SV_POSITION;
        };

        Varyings FulscreenVertex(Attributes input)
        {
            Varyings output;
            output.uv = input.texcoord;
            #if UNITY_UV_STARTS_AT_TOP
            output.uv.y = 1.0h - output.uv.y;
            #endif

            output.positionCS = half4(input.postionOS.xy * 2.0h - 1.0h, 0.0f, 1.0h);
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
                // return LinearEyeDepth(
                //     SAMPLE_DEPTH_TEXTURE_LOD(_MainTex, sampler_LinearClamp, input.uv, 0),
                //     _ZBufferParams
                // );

                half depth = UNITY_RAW_FAR_CLIP_VALUE;
                int2 coord = floor(input.positionCS.xy) * 4;

                UNITY_LOOP
                for (int y = 0; y < 4; y++)
                {
                    UNITY_LOOP
                    for (int x = 0; x < 4; x++)
                    {
                        half d = LOAD_TEXTURE2D_LOD(_MainTex, coord + int2(x, y), 0).x;
                        #if UNITY_REVERSED_Z
                        depth = max(depth, d);
                        #else
                        depth = min(depth, d);
                        #endif
                    }
                }

                return LinearEyeDepth(depth, _ZBufferParams);
            }
            ENDHLSL
        }

        Pass
        {
            Name "GI Trace"

            Cull Back

            HLSLPROGRAM
            #pragma vertex FulscreenTriangleVertex
            #pragma fragment Fragmet

            #pragma editor_sync_compilation
            #pragma multi_compile _ USE_VISIBILITY_BITMASK

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SphericalHarmonics.hlsl"

            half _RayLength;
            Texture2D<half> _TraceDepth;
            Texture2D<half2> _VarianceDepth;
            Texture2D<half4> _TraceColor;

            half2 STBN(half2 xy)
            {
                return SAMPLE_TEXTURE2D_LOD(_STBN, sampler_PointRepeat, xy * _STBN_TexelSize.xy, 0);
            }

            inline half3 SampleTraceLighting(half2 uv)
            {
                // TODO: Preprocess SceneColor!
                return SAMPLE_TEXTURE2D_LOD(_TraceColor, sampler_LinearClamp, uv, 0).rgb;
            }

            inline half LoadLinearTraceDepth(uint2 coord)
            {
                return LOAD_TEXTURE2D_LOD(_TraceDepth, coord, 0).x;
            }

            inline half SampleLinearTraceDepth(half2 uv)
            {
                return SAMPLE_DEPTH_TEXTURE_LOD(_TraceDepth, sampler_PointClamp, uv, 0);
            }

            half SampleVarianceDepth(half2 uv)
            {
                half2 moments = SAMPLE_TEXTURE2D_LOD(_VarianceDepth, sampler_LinearClamp, uv, 0).xy;
                return moments.x + sqrt(max(0.0, moments.y - moments.x * moments.x));
            }

            half3 SamplerTraceNormals(half2 uv)
            {
                return normalize(SAMPLE_TEXTURE2D_LOD(_CameraNormalsTexture, sampler_LinearClamp, uv, 0).xyz);
            }

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

            //////////////////////////
            /// BITMASK VISIBILITY ///
            //////////////////////////

            static const uint sectorCount = 32u;
            static const half sectorCountRcp = 1.0h / half(sectorCount);

            // https://graphics.stanford.edu/%7Eseander/bithacks.html
            uint bitCount(uint value)
            {
                value = value - ((value >> 1u) & 0x55555555u);
                value = (value & 0x33333333u) + ((value >> 2u) & 0x33333333u);
                return ((value + (value >> 4u) & 0xF0F0F0Fu) * 0x1010101u) >> 24u;
            }

            // https://cdrinmatane.github.io/posts/ssaovb-code/
            uint updateSectors(float minHorizon, float maxHorizon, uint outBitfield)
            {
                uint startBit = uint(minHorizon * float(sectorCount));
                uint horizonAngle = uint(ceil((maxHorizon - minHorizon) * float(sectorCount)));
                uint angleBit = horizonAngle > 0u ? uint(0xFFFFFFFFu >> (sectorCount - horizonAngle)) : 0u;
                uint currentBitfield = angleBit << startBit;
                return outBitfield | currentBitfield;
            }

            Varyings FulscreenTriangleVertex(Attributes input)
            {
                Varyings output;
                output.uv = input.texcoord;
                output.positionCS = half4(input.postionOS.xy, 0.0h, 1.0h);
                return output;
            }

            struct Output
            {
                half4 irradianceColor : SV_Target0;
                half4 irradianceSH : SV_Target1;
            };

            Output Fragmet(Varyings input)
            {
                half probeLinearDepth = LoadLinearTraceDepth(input.positionCS.xy);
                half2 jitter = STBN(floor(input.positionCS.xy));

                const half rayCount = 8.0h;
                const half raySteps = 16.0h;
                const half rayStepsRcp = rcp(raySteps);
                const half rayCountRcp = rcp(rayCount);

                const half deltaAngle = TWO_PI * rayCountRcp;
                const half2 rayNormalizationTerm = half(1.0h) / normalize(_ScreenSize.xy);
                half2 traceUV = input.uv;

                half3 probeVS = TransformScreenUVToViewLinear(traceUV, probeLinearDepth - half(0.01h));
                half3 viewDirectionVS = -normalize(probeVS);

                half3 finalColor = half(0.0h);
                half4 finalSH = half(0.0h);

                UNITY_LOOP
                for (half alpha = 0.0h; alpha < TWO_PI - 0.01h; alpha += deltaAngle)
                {
                    half2 rayDirection;
                    sincos(alpha, rayDirection.x, rayDirection.y);

                    uint occlusion = 0u;
                    half prevHorizon = 0.0h;
                    UNITY_LOOP
                    for (half stepIndex = 0.0h; stepIndex < raySteps; stepIndex++)
                    {
                        half ji = (jitter.x + stepIndex) / (raySteps - 1.0h);
                        half noff = ji * ji;

                        half2 offset = rayDirection * noff * _RayLength;
                        offset = Rotate(offset, rayCountRcp * TWO_PI * (jitter.y - 0.5));
                        offset *= rayNormalizationTerm;
                        half2 rayUV = traceUV + offset;

                        if (any(rayUV < 0.0h || rayUV > 1.0h)) break;

                        // TODO: Make depth pyramid for Pyramid HBAO: https://ceur-ws.org/Vol-3027/paper5.pdf
                        half linearDepth = SampleLinearTraceDepth(rayUV);
                        // TODO: Try out VarianceDepth sampling for more stable tracing
                        // half linearDepth = SampleVarianceDepth(rayUV);

                        half3 lingting = SampleTraceLighting(rayUV);
                        half3 currentLighting;

                        half3 rayPositionVS_near = TransformScreenUVToViewLinear(rayUV, linearDepth);
                        half3 rayDirectionVS = rayPositionVS_near - probeVS;
                        half rayLength = length(rayDirectionVS);
                        half3 rayDirectionVS_norm = rayDirectionVS / rayLength;

                        half VdotR_near = dot(viewDirectionVS, rayDirectionVS_norm);
                        half thickness = 1.0h;
                        half VdotR_far = dot(viewDirectionVS, normalize(rayDirectionVS - viewDirectionVS * thickness));

                        #if !defined(USE_VISIBILITY_BITMASK)

                        half horizon = FastACos(-VdotR_near) * INV_PI;
                        half visibility = clamp(horizon - prevHorizon, 0.0h, 0.5h);
                        currentLighting = lingting * visibility;
                        prevHorizon = max(prevHorizon, horizon);

                        #else

                        half2 frontBackHorizon;
                        frontBackHorizon.x = VdotR_near;
                        frontBackHorizon.y = VdotR_far;
                        frontBackHorizon = GTAOFastAcos(frontBackHorizon) * INV_PI;

                        uint indirect = updateSectors(frontBackHorizon.x, frontBackHorizon.y, 0u);
                        half visibility = half(bitCount(indirect & ~occlusion)) * sectorCountRcp;
                        currentLighting = lingting * visibility;
                        occlusion |= indirect;

                        #endif

                        // SH Ligting: https://deadvoxels.blogspot.com/2009/08/has-someone-tried-this-before.html
                        // Half-Life 2 Shading: https://drivers.amd.com/developer/gdc/D3DTutorial10_Half-Life2_Shading.pdf
                        half lum = Luminance(currentLighting);
                        finalColor += currentLighting * rayCountRcp;
                        finalSH += half4(kSHBasis1 * rayDirectionVS_norm, kSHBasis0) * lum;
                    }
                }

                Output output;
                output.irradianceColor = half4(finalColor, probeLinearDepth);
                output.irradianceSH = finalSH;
                return output;
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

            Texture2D<half> _RefrenceDepth;

            half4 Fragmet(Varyings input) : SV_Target
            {
                const half2 blurDirection = half2(_MainTex_TexelSize.x, 0.0h);
                half centerDepth = SAMPLE_DEPTH_TEXTURE(_RefrenceDepth, sampler_LinearClamp, input.uv);

                half4 result = 0.0h;
                half totalWeight = 0.0h;
                for (half i = -_BlurSize; i <= _BlurSize + 0.1h; i++)
                {
                    half2 offset = blurDirection * i;
                    half4 color = SAMPLE_TEXTURE2D(_MainTex, sampler_LinearClamp, input.uv + offset);
                    half depth = SAMPLE_DEPTH_TEXTURE(_RefrenceDepth, sampler_LinearClamp, input.uv + offset);

                    float r = i / _BlurSize;
                    half diff = abs(centerDepth - depth);
                    half weight = exp(-r * r - 20.0 * diff * diff);

                    result += color * weight;
                    totalWeight += weight;
                }

                return result / totalWeight;
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

            Texture2D<half> _RefrenceDepth;

            half4 Fragmet(Varyings input) : SV_Target
            {
                const half2 blurDirection = half2(0.0h, _MainTex_TexelSize.y);
                half centerDepth = SAMPLE_DEPTH_TEXTURE(_RefrenceDepth, sampler_LinearClamp, input.uv);

                half4 result = 0.0h;
                half totalWeight = 0.0h;
                for (half i = -_BlurSize; i <= _BlurSize + 0.1h; i++)
                {
                    half2 offset = blurDirection * i;
                    half4 color = SAMPLE_TEXTURE2D(_MainTex, sampler_LinearClamp, input.uv + offset);
                    half depth = SAMPLE_DEPTH_TEXTURE(_RefrenceDepth, sampler_LinearClamp, input.uv + offset);

                    float r = i / _BlurSize;
                    half diff = centerDepth - depth;
                    half weight = exp(-r * r - 20.0 * diff * diff);

                    result += color * weight;
                    totalWeight += weight;
                }

                return result / totalWeight;
            }
            ENDHLSL
        }

        Pass
        {
            Name "ResolveGI"

            Blend One One

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half4 _TraceSize;
            Texture2D<half> _TraceDepth;
            Texture2D<half4> _SHBuffer;

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

            // SH0: w; SH1 xyz;
            inline half EvaluateIrradianceSH1(half4 sh, half3 v) { return dot(sh.xyz, v); }
            // SH0: w; SH1 xyz;
            inline half EvaluateIrradianceSH01(half4 sh, half3 v) { return sh.w + EvaluateIrradianceSH1(sh, v); }

            half4 SampleGI(half2 positionCS, half hiLinearDepth)
            {
                half2 coord = positionCS * 0.25h;
                half2 texel = _MainTex_TexelSize.xy;

                half2 center = coord * texel;
                half3 normalWS = LoadSceneNormals(positionCS);

                half4 uv01;
                half4 uv23;
                uv01.xy = center + half2(texel.x, 0.0h);
                uv01.zw = center - half2(texel.x, 0.0h);
                uv23.xy = center + half2(0.0h, texel.y);
                uv23.zw = center - half2(0.0h, texel.y);

                // TODO: Keep depth in _GIBuffer.a to reduce sampling.
                half4 lowDepthABCD;
                lowDepthABCD.x = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, uv01.xy, 0);
                lowDepthABCD.y = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, uv01.zw, 0);
                lowDepthABCD.z = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, uv23.xy, 0);
                lowDepthABCD.w = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, uv23.zw, 0);

                half4 colorA = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, uv01.xy, 0);
                half4 colorB = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, uv01.zw, 0);
                half4 colorC = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, uv23.xy, 0);
                half4 colorD = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, uv23.zw, 0);

                half4 shA = SAMPLE_TEXTURE2D_LOD(_SHBuffer, sampler_LinearClamp, uv01.xy, 0);
                half4 shB = SAMPLE_TEXTURE2D_LOD(_SHBuffer, sampler_LinearClamp, uv01.zw, 0);
                half4 shC = SAMPLE_TEXTURE2D_LOD(_SHBuffer, sampler_LinearClamp, uv23.xy, 0);
                half4 shD = SAMPLE_TEXTURE2D_LOD(_SHBuffer, sampler_LinearClamp, uv23.zw, 0);

                half3 N = TransformWorldToCameraNormal(normalWS);
                half3 V = -normalize(TransformScreenUVToViewLinear(center, hiLinearDepth));
                half3 R = reflect(-V, N);

                half4 weights = exp2(-20.0h * abs(hiLinearDepth - lowDepthABCD));
                weights = saturate(weights / dot(1.0h, weights));

                half4 irradianceColor = mul(weights, half4x4(colorA, colorB, colorC, colorD));
                half4 SH = mul(weights, half4x4(shA, shB, shC, shD));

                half irradiance = max(0.0h, EvaluateIrradianceSH01(SH, N));
                half reflection = pow(saturate(EvaluateIrradianceSH1(SH, R)), 5.0h);

                // const half smoothness = 0.5h;
                // half4 ligting = lerp(irradiance, reflection, smoothness) * irradianceColor;
                half4 ligting = (irradiance + reflection) * irradianceColor;
                return LinearToSRGB(ligting);
            }

            TEXTURE2D(_GBuffer0);

            half4 Fragmet(Varyings input) : SV_Target
            {
                half3 gbuffer0 = LOAD_TEXTURE2D(_GBuffer0, input.positionCS.xy);
                half hiDepth = LoadSceneDepth(floor(input.positionCS.xy));
                hiDepth = LinearEyeDepth(hiDepth, _ZBufferParams);
                return half4(gbuffer0, 1.0h) * SampleGI(input.positionCS.xy, hiDepth);
            }
            ENDHLSL
        }
        Pass
        {
            Name "VarianceDepth"

            ColorMask RG

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            static const half Filter[4][4] =
            {
                1, 3, 3, 1,
                3, 9, 9, 3,
                3, 9, 9, 3,
                1, 3, 3, 1
            };

            half2 Fragmet(Varyings input) : SV_Target
            {
                half4x4 depth;
                int2 coord = floor(input.positionCS).xy * 4;

                UNITY_UNROLL
                for (int y = 0; y < 4; y++)
                {
                    UNITY_UNROLL
                    for (int x = 0; x < 4; x++)
                    {
                        depth[y][x] = LOAD_TEXTURE2D_LOD(_MainTex, coord + int2(x, y), 0).x;
                    }
                }

                half2 varianceDepth = 0.0h;
                {
                    for (int y = 0; y < 4; y++)
                    {
                        for (int x = 0; x < 4; x++)
                        {
                            half d = LinearEyeDepth(depth[y][x], _ZBufferParams);
                            // TODO: Gausian veights.
                            varianceDepth += half2(d, d * d) * Filter[y][x] / 64.0h;
                        }
                    }
                }
                return varianceDepth;
            }
            ENDHLSL
        }
        Pass
        {
            Name "Blit3x3"

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half4 Fragmet(Varyings input) : SV_Target
            {
                half4 color = 0.0h;
                for (half y = -1.0h; y < 1.1h; y++)
                {
                    for (half x = -1.0h; x <= 1.1h; x++)
                    {
                        color += SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp,
                                                      input.uv + half2(x, y) * _MainTex_TexelSize.xy * 4.0h, 0);
                    }
                }

                return color / 9.0h;
            }
            ENDHLSL
        }
    }
}