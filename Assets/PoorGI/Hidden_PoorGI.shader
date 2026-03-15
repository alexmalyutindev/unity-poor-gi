Shader "Hidden/PoorGI"
{
    Properties
    {
        [HideInInspector]
        _MainTex("Texture", 2D) = "white" {}

        [Toggle(USE_VISIBILITY_BITMASK)]
        _UseVisibilityBitmask ("Use Visibility Bitmask", Float) = 1.0

        _BlurSize("Bilateral Blur Size", Range(1, 6)) = 4
        _EdgeSensitivity("Edge Sensitivity", Range(5, 50)) = 30
        _RayLength("Ray Length", Range(0.1, 1.0)) = 0.5
        _RaysCount("Rays Count", Range(2, 16)) = 4
        _StepsCount("Steps Count", Range(2, 16)) = 4
        _MipLevelFactor("MipLevel Factor", Range(1, 32)) = 8.0

        [NonModifiableTextureData][HideInInspector]
        _STBN("_STBN", 2D) = "black" {}
        [NonModifiableTextureData][HideInInspector]
        _BayerMatrix("_BayerMatrix", 2D) = "black" {}
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

        float _RaysCount;
        float _StepsCount;

        float4 _STBN_TexelSize;
        Texture2D<half2> _STBN;
        Texture2D<half4> _BayerMatrix;

        // Z buffer to linear view space (eye) depth.
        // Does NOT correctly handle oblique view frustums.
        // Does NOT work with orthographic projection.
        // zBufferParam (UNITY_REVERSED_Z) = { f/n - 1,   1, (1/n - 1/f), 1/f }
        // zBufferParam                    = { 1 - f/n, f/n, (1/f - 1/n), 1/n }
        half LinearEyeDepth(half depth, half4 zBufferParam)
        {
            return 1.0 / (zBufferParam.z * depth + zBufferParam.w);
        }
        half2 LinearEyeDepth(half2 depth, half4 zBufferParam)
        {
            return 1.0 / (zBufferParam.z * depth + zBufferParam.w);
        }
        half4 LinearEyeDepth(half4 depth, half4 zBufferParam)
        {
            return 1.0 / (zBufferParam.z * depth + zBufferParam.w);
        }

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

        int _MipLevelFactor;
        half _BlurSize = 4.0h;
        half _EdgeSensitivity = 30.0h;
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
            float4 positionCS : SV_POSITION;
        };


        Varyings FulscreenTriangleVertex(Attributes input)
        {
            Varyings output;
            output.uv = input.texcoord;
            output.positionCS = half4(input.postionOS.xy, 0.0h, 1.0h);
            return output;
        }

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
            Name "0 DownSampleDepthX4"

            Blend One Zero
            ColorMask RGB

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half Average(half4x4 value) { return dot(0.25h, value[0] + value[1] + value[2] + value[3]); }

            half3 ReconstructNormals(uint2 baseCoord, half4x4 depth4x4)
            {
                float dZdx = 0.0;
                float dZdy = 0.0;

                UNITY_UNROLL for (int y = 0; y < 4; y++)
                    UNITY_UNROLL for (int x = 0; x < 4; x++)
                    {
                        float wx = (float)x - 1.5;
                        float wy = (float)y - 1.5;
                        dZdx += depth4x4[x][y] * wx;
                        dZdy += depth4x4[x][y] * wy;
                    }

                // Σ w² = 5 per column/row × 4 = 20
                dZdx /= 20.0;
                dZdy /= 20.0;

                // Reconstruct the centre view-space position
                float2 uvCenter = (float2(baseCoord) + 2.0) * _MainTex_TexelSize.xy; // +2 = centre of 4x4
                float3 posC = TransformScreenUVToViewLinear(uvCenter, Average(depth4x4));

                // Build tangent vectors: step one texel in X or Y, displace Z by the fitted gradient
                float3 posR = TransformScreenUVToViewLinear(uvCenter + float2(_MainTex_TexelSize.x, 0), posC.z + dZdx);
                float3 posU = TransformScreenUVToViewLinear(uvCenter + float2(0, _MainTex_TexelSize.y), posC.z + dZdy);

                half3 normalVS = (half3)normalize(cross(posR - posC, posU - posC));
                normalVS *= sign(-normalVS.z);
                return normalVS;
            }
            
            // #define _2X2_BLUR_DEPTH

            half4 Fragmet(Varyings input) : SV_Target
            {
                #ifdef _4X4_BLUR_DEPTH
                {
                    int2 baseCoord = (int2)floor(input.positionCS.xy) * 4;

                    // NOTE: 4x4 depth downsampling.
                    half4x4 depth4x4;
                    UNITY_UNROLL for (int y = 0; y < 4; y++)
                    {
                        UNITY_UNROLL for (int x = 0; x < 4; x++)
                        {
                            depth4x4[x][y] = LOAD_TEXTURE2D_LOD(_MainTex, baseCoord + uint2(x, y), 0);
                        }
                    }

                    UNITY_UNROLL for (int i = 0; i < 4; i++) depth4x4[i] = LinearEyeDepth(depth4x4[i], _ZBufferParams);

                    half3 normalVS = ReconstructNormals(baseCoord, depth4x4);

                    half finalDepth = dot(0.25h * 0.25h, depth4x4[0] + depth4x4[1] + depth4x4[2] + depth4x4[3]);
                    half4(finalDepth, normalVS.xy, 0.0h);
                }
                #elifdef _2X2_BLUR_DEPTH
                {
                    // NOTE: 2x2 depth downsampling.
                    float4 offset = float4(-_MainTex_TexelSize.xy, _MainTex_TexelSize.xy) * 0.5f;
                    half4 depth2x2 = 0.0h;
                    depth2x2.x = SAMPLE_DEPTH_TEXTURE_LOD(_MainTex, sampler_LinearClamp, input.uv + offset.xy, 0);
                    depth2x2.y = SAMPLE_DEPTH_TEXTURE_LOD(_MainTex, sampler_LinearClamp, input.uv + offset.xw, 0);
                    depth2x2.z = SAMPLE_DEPTH_TEXTURE_LOD(_MainTex, sampler_LinearClamp, input.uv + offset.zy, 0);
                    depth2x2.w = SAMPLE_DEPTH_TEXTURE_LOD(_MainTex, sampler_LinearClamp, input.uv + offset.zw, 0);
                    return dot(LinearEyeDepth(depth2x2, _ZBufferParams), 0.25h);
                }
                #elifdef _4X4_MINMAX_DEPTH
                {
                    half2 depth = half2(UNITY_RAW_FAR_CLIP_VALUE, UNITY_NEAR_CLIP_VALUE);
                    int2 coord = floor(input.positionCS.xy) * 4;

                    UNITY_LOOP
                    for (int y = 0; y < 4; y++)
                    {
                        UNITY_LOOP
                        for (int x = 0; x < 4; x++)
                        {
                            half d = LOAD_TEXTURE2D_LOD(_MainTex, coord + int2(x, y), 0).x;
                            #if UNITY_REVERSED_Z
                            depth.x = max(depth.x, d);
                            depth.y = min(depth.y, d);
                            #else
                            depth.x = min(depth.x, d);
                            depth.y = max(depth.y, d);
                            #endif
                        }
                    }

                    return half4(LinearEyeDepth(depth, _ZBufferParams), 0.0, 0.0);
                }
                #else
                return LinearEyeDepth(
                    SAMPLE_DEPTH_TEXTURE_LOD(_MainTex, sampler_LinearClamp, input.uv, 0),
                    _ZBufferParams
                );
                #endif
            }
            ENDHLSL
        }

        Pass
        {
            Name "1 GI Trace"

            Cull Back

            HLSLPROGRAM
            #pragma vertex FulscreenTriangleVertex
            #pragma fragment Fragmet

            #pragma editor_sync_compilation
            #pragma multi_compile _ USE_VISIBILITY_BITMASK

            #pragma editor_sync_compilation
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SphericalHarmonics.hlsl"

            half _RayLength;
            float4 _TraceDepth_TexelSize;
            Texture2D<half4> _TraceDepth;
            Texture2D<half2> _VarianceDepth;
            Texture2D<half4> _TraceColor;
            SamplerState sampler_TraceColor;

            half2 STBN(half2 coords)
            {
                return SAMPLE_TEXTURE2D_LOD(_STBN, sampler_PointRepeat, coords * _STBN_TexelSize.xy, 0);
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

            inline half SampleLinearTraceDepth(half2 uv, uint lod = 0)
            {
                return SAMPLE_DEPTH_TEXTURE_LOD(_TraceDepth, sampler_LinearClamp, uv, lod);
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

            struct Output
            {
                half4 irradianceColor : SV_Target0;
                half4 irradianceSH : SV_Target1;
            };

            Output Fragmet(Varyings input)
            {
                const half rayCount = floor(_RaysCount);
                const half raySteps = floor(_StepsCount);
                const half thickness = 2.0h;
                const half probOffsetZ = 0.02h;
    
                const half rayStepsRcp = rcp(raySteps);
                const half rayCountRcp = rcp(rayCount);

                uint2 tileCoord = floor(input.positionCS);
                half probeLinearDepth = LoadLinearTraceDepth(tileCoord);

                // NOTE: Hacky noise, STBN for step jitter, and regular pattern for angle jitter. 
                half2 jitter = 0.0h;
                jitter.y = LOAD_TEXTURE2D(_BayerMatrix, tileCoord % 4).a;
                jitter.x = LOAD_TEXTURE2D(_BayerMatrix, (tileCoord + 1) % 4).a;
                // const float dispersion = 2.0f;
                // const float rcp_dispersion2 = rcp(dispersion * dispersion);
                // jitter.y = ((coords.x % dispersion) + dispersion * ((coords.y % dispersion)) + 0.5h) * rcp_dispersion2;

                // const float4 angleOffset = half4(0, 0.5, 0.25, 0.75) + 0.125f;
                // jitter.x = angleOffset[2* (coords.x % 2) + (coords.y % 2)];
                // jitter.y = angleOffset[tileCoord.x % 2 + 2 * (tileCoord.y % 2)];
                // jitter.y = LOAD_TEXTURE2D(_BayerMatrix, tileCoord % 4).a;
                
                // jitter.y = InterleavedGradientNoise(tileCoord, 0);
                
                // jitter.x = (tileCoord.y % 4 + tileCoord.x % 4 * 4) * 0.25h * 0.25h;
                // jitter.y = (tileCoord.x % 4 + tileCoord.y % 4 * 4) * 0.25h * 0.25h;

                // uint tileIndex = tileCoord.x + tileCoord.y * 4;
                // float baseAngle = float(tileIndex) / 16.0;   
                // float baseStep  = float(tileIndex % 4) / 4.0;
                // jitter.y += baseAngle;
                // jitter.x += baseStep;
                // jitter += (STBN(input.positionCS.xy) - 0.5h) * 0.5;

                const half deltaAngle = TWO_PI * rayCountRcp;
                const half2 rayNormalizationTerm = _ScreenSize.xx / _ScreenSize.xy;

                half2 traceUV = input.uv;

                // NOTE: Probe depth offseting.
                // probeLinearDepth -= probeLinearDepth * probOffsetZ;
                half3 probeVS = TransformScreenUVToViewLinear(traceUV, probeLinearDepth - 0.01h);
                half3 viewDirectionVS = -normalize(probeVS);

                half3 finalColor = half(0.0h);
                half4 finalSH = half(0.0h);

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
                        int mipLevel = min(4, floor(length(offset * 2.0f) * _MipLevelFactor));
                        
                        // Mix step-dependent rotation with base jitter for per-step variation
                        // half stepRotation = rayCountRcp * TWO_PI * (jitter.y - 0.5) + stepIndexF * rayCountRcp * PI;
                        half stepRotation = rayCountRcp * TWO_PI * (jitter.y - 0.5h);
                        offset = Rotate(offset, stepRotation);
                        offset *= rayNormalizationTerm;  // Re-enable for aspect-ratio correction
                        half2 rayUV = traceUV + offset;

                        if (any(rayUV < 0.0h || rayUV > 1.0h)) break;

                        // TODO: Make depth pyramid for Pyramid HBAO: https://ceur-ws.org/Vol-3027/paper5.pdf
                        // Use variance depth for more stable tracing, reduces firefly artifacts at edges
                        // half linearDepth = SampleVarianceDepth(rayUV);

                        // half linearDepth = SampleLinearTraceDepth(rayUV, floor(length(offset) * 8.0h));
                        half4 depthNormal = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, rayUV, 0);
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
            Name "2 BilateralBlur"

            Blend One Zero

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            float2 _Direction;
            float _RefrenceDepthLod;
            Texture2D<half> _RefrenceDepth;

            half4 Fragmet(Varyings input) : SV_Target
            {
                half steps = floor(_BlurSize);
                const half2 blurDirection = _MainTex_TexelSize.xy * _Direction;
                half centerDepth = SAMPLE_DEPTH_TEXTURE_LOD(_RefrenceDepth, sampler_LinearClamp, input.uv, _RefrenceDepthLod);

                half4 result = 0.0h;
                half totalWeight = 0.0h;
                for (half i = -steps; i <= steps + 0.1h; i++)
                {
                    half2 offset = blurDirection * i;
                    half4 color = SAMPLE_TEXTURE2D(_MainTex, sampler_LinearClamp, input.uv + offset);
                    half depth = SAMPLE_DEPTH_TEXTURE_LOD(_RefrenceDepth, sampler_LinearClamp, input.uv + offset, _RefrenceDepthLod);

                    float r = i / steps;
                    half diff = abs(centerDepth - depth);
                    half weight = exp(-r * r - _EdgeSensitivity * diff * diff);

                    result += color * weight;
                    totalWeight += weight;
                }

                return result / totalWeight;
            }
            ENDHLSL
        }

        Pass
        {
            Name "3 ResolveGI"

            Cull Back
            Blend One One

            HLSLPROGRAM
            #pragma vertex FulscreenTriangleVertex
            #pragma fragment Fragmet

            half _UpscaleFactor;
            half4 _TraceSize;
            half4 _Irradiance_TexelSize;

            Texture2D<half> _TraceDepth;
            Texture2D<half4> _Irradiance;
            Texture2D<half4> _SH;
            TEXTURE2D(_GBuffer0);

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
                half2 coord = positionCS / 4;
                half2 texel = _Irradiance_TexelSize.xy;

                half2 center = coord * texel;
                half3 normalWS = LoadSceneNormals(positionCS);

                half4 uv01;
                half4 uv23;
                uv01.xy = center + half2(texel.x, 0.0h);
                uv01.zw = center - half2(texel.x, 0.0h);
                uv23.xy = center + half2(0.0h, texel.y);
                uv23.zw = center - half2(0.0h, texel.y);

                // TODO: Put depth in _Irradiance.a channel to reduce sampling.
                half4 lowDepthABCD;
                lowDepthABCD.x = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, uv01.xy, 0).x;
                lowDepthABCD.y = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, uv01.zw, 0).x;
                lowDepthABCD.z = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, uv23.xy, 0).x;
                lowDepthABCD.w = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, uv23.zw, 0).x;

                half4 colorA = SAMPLE_TEXTURE2D_LOD(_Irradiance, sampler_LinearClamp, uv01.xy, 0);
                half4 colorB = SAMPLE_TEXTURE2D_LOD(_Irradiance, sampler_LinearClamp, uv01.zw, 0);
                half4 colorC = SAMPLE_TEXTURE2D_LOD(_Irradiance, sampler_LinearClamp, uv23.xy, 0);
                half4 colorD = SAMPLE_TEXTURE2D_LOD(_Irradiance, sampler_LinearClamp, uv23.zw, 0);

                half4 shA = SAMPLE_TEXTURE2D_LOD(_SH, sampler_LinearClamp, uv01.xy, 0);
                half4 shB = SAMPLE_TEXTURE2D_LOD(_SH, sampler_LinearClamp, uv01.zw, 0);
                half4 shC = SAMPLE_TEXTURE2D_LOD(_SH, sampler_LinearClamp, uv23.xy, 0);
                half4 shD = SAMPLE_TEXTURE2D_LOD(_SH, sampler_LinearClamp, uv23.zw, 0);

                half3 N = TransformWorldToCameraNormal(normalWS);
                half3 V = -normalize(TransformScreenUVToViewLinear(center, hiLinearDepth));
                half3 R = reflect(-V, N);

                half4 weights = exp2(-20.0h * abs(hiLinearDepth - lowDepthABCD));
                weights = saturate(weights / dot(1.0h, weights));

                half4 irradianceColor = mul(weights, half4x4(colorA, colorB, colorC, colorD));
                half4 SH = mul(weights, half4x4(shA, shB, shC, shD));

                half irradiance = max(0.0h, EvaluateIrradianceSH01(SH, N));
                half reflection = Pow4(saturate(EvaluateIrradianceSH1(SH, R)));

                const half smoothness = 0.2h;
                half4 ligting = lerp(irradiance, reflection, smoothness) * irradianceColor;
                // half4 ligting = (irradiance + reflection) * irradianceColor;
                return LinearToSRGB(ligting);
            }

            half4 Fragmet(Varyings input) : SV_Target
            {
                half3 gbuffer0 = LOAD_TEXTURE2D(_GBuffer0, input.positionCS.xy);
                half hiDepth = LoadSceneDepth(floor(input.positionCS.xy));
                hiDepth = LinearEyeDepth(hiDepth, _ZBufferParams);

                // DEBUG:
                // return SampleGI(input.positionCS.xy, hiDepth);
                // return LinearToSRGB(SAMPLE_TEXTURE2D(_Irradiance, sampler_PointClamp, input.uv));
                return half4(gbuffer0, 1.0h) * SampleGI(input.positionCS.xy, hiDepth);
            }
            ENDHLSL
        }
        Pass
        {
            Name "4 VarianceDepth"

            ColorMask RG

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half2 Fragmet(Varyings input) : SV_Target
            {
                half x = SAMPLE_TEXTURE2D(_MainTex, sampler_LinearClamp, input.uv).x;
                x = LinearEyeDepth(x, _ZBufferParams);
                return half2(x, x * x);
            }
            ENDHLSL
        }
        Pass
        {
            Name "5 Blit 5x5"

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half4 Fragmet(Varyings input) : SV_Target
            {
                half4 color = 0.0h;
                half4 totalWeight = 0.0h;
                const half range = 2.0h;
                const half samplesRcp = 1.0h / ((range * 2.0h + 1.0h) * (range * 2.0h + 1.0h));
                
                // Weighted gaussian filter for smoother color downsampling
                for (half y = -range; y < range + 0.1h; y++)
                {
                    for (half x = -range; x < range + 0.1h; x++)
                    {
                        half2 offset = half2(x, y);
                        half2 uv = input.uv + offset * _MainTex_TexelSize.xy * 4.0h;
                        half4 sample = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, uv, 0);
                        
                        // Gaussian weight relative to center
                        half dist2 = dot(offset, offset);
                        half weight = exp(-dist2 * 0.5h);
                        
                        color += sample * weight;
                        totalWeight += weight;
                    }
                }

                color /= totalWeight;
                return color;

                // NOTE: Luminance threshold.
                half lum = Luminance(color);
                return color * step(0.5h, lum);
            }
            ENDHLSL
        }

        Pass
        {
            Name "6 GaussianBlur Variance"

            ColorMask RG

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            half2 Fragmet(Varyings input) : SV_Target
            {
                // TODO: Make TwoTap version!
                half2 variance = 0.0h;
                for (half y = -2.0h; y < 2.1h; y++)
                {
                    for (half x = -2.0h; x < 2.1h; x++)
                    {
                        half2 uv = input.uv + half2(x, y) * _MainTex_TexelSize.xy;
                        variance += SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, uv, 0);
                    }
                }
                return variance / 25.0h;
            }
            ENDHLSL
        }

        Pass
        {
            Name "7 BoxFilter 4x4"
            Cull Front
            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet
            float2 _Direction;
            half4 SampleLinear(float2 uv){ return SAMPLE_TEXTURE2D(_MainTex, sampler_LinearClamp, uv); }
            half4 Fragmet(Varyings input) : SV_Target
            {
                half4 color = 0.0h;
                const float kernelSize = 4;
                const half kernelSizeRcp = 1.0h / kernelSize;
                const float halfKernel = (kernelSize - 1.0) * 0.5;

                for (float i = 0.0f; i < kernelSize; i++)
                {
                    float2 offset = (i - halfKernel) * _Direction * _MainTex_TexelSize.xy;
                    color += SampleLinear(input.uv + offset);
                }
                return color * kernelSizeRcp;
            }
            ENDHLSL
        }

        Pass
        {
            Name "9 BlitLinear"
            Cull Back
            HLSLPROGRAM
            #pragma vertex FulscreenTriangleVertex
            #pragma fragment Fragmet
            TEXTURE2D(_BlitTexture);
            float4 _BlitTexture_TexelSize;
            half4 Fragmet(Varyings input) : SV_Target
            {
                return SAMPLE_TEXTURE2D_LOD(_BlitTexture, sampler_LinearClamp, input.uv, 1);
            }
            ENDHLSL
        }
    }
}