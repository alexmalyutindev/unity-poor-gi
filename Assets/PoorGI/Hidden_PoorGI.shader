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

        static half _BlurSize = 4.0h;
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

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SphericalHarmonics.hlsl"

            Texture2D<half> _TraceDepth;
            Texture2D<half4> _TraceColor;

            half GRnoise2(half2 xy)
            {
                const half2 igr2 = half2(0.754877666, 0.56984029);
                xy *= igr2;
                half n = frac(xy.x + xy.y);
                return n < 0.5 ? 2.0 * n : 2.0 - 2.0 * n;
            }

            half3 SampleTraceLighting(half2 uv)
            {
                // TODO: Blur SceneColor!
                half3 color = SAMPLE_TEXTURE2D_LOD(_TraceColor, sampler_LinearClamp, uv, 0).rgb;
                half luminance = Luminance(color);
                return color * smoothstep(0.5h, 1.0h, luminance);
            }

            half LoadTraceDepth(uint2 coord)
            {
                return LOAD_TEXTURE2D_LOD(_TraceDepth, coord, 0).r;
            }

            half SampleTraceLinearDepth(half2 uv)
            {
                return SAMPLE_DEPTH_TEXTURE_LOD(_TraceDepth, sampler_PointClamp, uv, 0);
            }

            half3 SamplerTraceNormals(half2 uv)
            {
                return normalize(SAMPLE_TEXTURE2D_LOD(_CameraNormalsTexture, sampler_LinearClamp, uv, 0).xyz);
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
                half3 finalColor = 0.0h;
                half4 finalSH = 0.0h;

                half2 traceUV = input.uv;

                half probeLinearDepth = LoadTraceDepth(input.positionCS.xy);
                half3 probeNormalWS = SamplerTraceNormals(traceUV);
                half3 probeNormalVS = TransformWorldToCameraNormal(probeNormalWS);

                half3 probeVS = TransformScreenUVToViewLinear(traceUV, probeLinearDepth);

                half3 viewDirectionVS = -normalize(probeVS);

                const int raySteps = 4;
                const half rayStepsRcp = rcp(raySteps);
                const half rayLength = 0.5f;
                const half rayCount = 32.0h;
                const half deltaAngle = TWO_PI / rayCount;

                UNITY_LOOP
                for (half alpha = deltaAngle * 0.5h; alpha < TWO_PI; alpha += deltaAngle)
                {
                    half2 rayDirection;
                    half jitter = GRnoise2(floor(input.positionCS.xy));
                    sincos(alpha, rayDirection.x, rayDirection.y);
                    rayDirection /= normalize(_ScreenSize.xy);

                    half prevOcclusionFactor = -1.0h;
                    UNITY_LOOP
                    for (half stepIndex = 0.01h; stepIndex < raySteps; stepIndex++)
                    {
                        half ji = (jitter + stepIndex) * rayStepsRcp;
                        half noff = ji * ji;

                        half2 rayUV = traceUV + rayDirection * noff * rayLength;

                        if (any(rayUV < 0.0h || rayUV > 1.0h))
                        {
                            break;
                        }

                        half linearDepth = SampleTraceLinearDepth(rayUV);
                        half3 lingting = SampleTraceLighting(rayUV);

                        half3 rayPositionVS = TransformScreenUVToViewLinear(rayUV, linearDepth);
                        half3 rayVS = rayPositionVS - probeVS;
                        half3 rayDirectionVS = normalize(rayVS);
                        half VdotR = dot(viewDirectionVS, rayDirectionVS);
                        half traceDistance = length(rayVS);

                        half OcclusionFactor = VdotR;
                        half occlusion = smoothstep(prevOcclusionFactor - 0.02h, prevOcclusionFactor, OcclusionFactor);
                        prevOcclusionFactor = max(prevOcclusionFactor, OcclusionFactor);

                        half3 current = lingting * occlusion * rayStepsRcp;
                        half lum = Luminance(current);

                        // SH Ligting: https://deadvoxels.blogspot.com/2009/08/has-someone-tried-this-before.html
                        // Half-Life 2 Shading: https://drivers.amd.com/developer/gdc/D3DTutorial10_Half-Life2_Shading.pdf
                        finalColor += current;
                        finalSH += half4(kSHBasis1 * rayDirectionVS.xyz, kSHBasis0) * lum;
                    }
                }

                finalColor /= rayCount;

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

                half4 centerColor = SAMPLE_TEXTURE2D(_MainTex, sampler_LinearClamp, input.uv);
                half centerDepth = SAMPLE_DEPTH_TEXTURE(_RefrenceDepth, sampler_LinearClamp, input.uv);
                half centerLum = Luminance(centerColor.rgb);

                // TODO: Bilateral blur
                half4 result = 0.0h;
                half totalWeight = 0.0h;
                for (half i = -_BlurSize; i <= _BlurSize + 0.1h; i++)
                {
                    half2 offset = blurDirection * i;
                    half4 color = SAMPLE_TEXTURE2D(_MainTex, sampler_LinearClamp, input.uv + offset);
                    half depth = SAMPLE_DEPTH_TEXTURE(_RefrenceDepth, sampler_LinearClamp, input.uv + offset);
                    half lum = Luminance(color.rgb);

                    // TODO: Fix gaussian weight
                    half weight = exp(-i * i) / exp(1.0h * abs(centerDepth - depth) * abs(centerLum - lum));
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

                half4 centerColor = SAMPLE_TEXTURE2D(_MainTex, sampler_LinearClamp, input.uv);
                half centerDepth = SAMPLE_DEPTH_TEXTURE(_RefrenceDepth, sampler_LinearClamp, input.uv);
                half centerLum = Luminance(centerColor.rgb);

                // TODO: Bilateral blur
                half4 result = 0.0h;
                half totalWeight = 0.0h;
                for (half i = -_BlurSize; i <= _BlurSize + 0.1h; i++)
                {
                    half2 offset = blurDirection * i;
                    half4 color = SAMPLE_TEXTURE2D(_MainTex, sampler_LinearClamp, input.uv + offset);
                    half depth = SAMPLE_DEPTH_TEXTURE(_RefrenceDepth, sampler_LinearClamp, input.uv + offset);
                    half lum = Luminance(color.rgb);

                    // TODO: Fix gaussian weight
                    half weight = exp(-i * i) / exp(1.0h * abs(centerDepth - depth) * abs(centerLum - lum));
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
            inline half EvaluateIrradianceSH1(half4 sh, half3 v) { return dot(sh, v); }
            // SH0: w; SH1 xyz;
            inline half EvaluateIrradianceSH01(half4 sh, half3 v) { return sh.w + EvaluateIrradianceSH1(sh, v); }

            half4 SampleGI(half2 positionCS, half hiLinearDepth)
            {
                half2 coord = positionCS * 0.25h - 0.5h;
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

                half4 weights = exp2(-10.0h * abs(hiLinearDepth - lowDepthABCD));
                weights = saturate(weights / dot(1.0h, weights));

                half4 irradianceColor = mul(weights, half4x4(colorA, colorB, colorC, colorD));
                half4 SH = mul(weights, half4x4(shA, shB, shC, shD));

                half irradiance = EvaluateIrradianceSH01(SH, N); // * 0.5 + 0.5;
                half reflection = pow(saturate(EvaluateIrradianceSH1(SH, R)), 5.0h);

                const half smoothness = 0.2h;
                half4 ligting = lerp(irradiance, reflection, smoothness) * irradianceColor;
                return ligting;
            }

            half4 Fragmet(Varyings input) : SV_Target
            {
                half hiDepth = LoadSceneDepth(floor(input.positionCS.xy));
                hiDepth = LinearEyeDepth(hiDepth, _ZBufferParams);
                return SampleGI(input.positionCS.xy, hiDepth);
            }
            ENDHLSL
        }
    }
}