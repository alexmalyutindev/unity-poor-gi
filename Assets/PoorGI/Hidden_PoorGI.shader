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

        #if 0
        static const half3 basisX = half3( sqrt(1.0h / 2.0h), -sqrt(1.0h / 6.0h), sqrt(1.0h / 3.0h));
        static const half3 basisY = half3(              0.0h,  sqrt(2.0h / 3.0h), sqrt(1.0h / 3.0h));
        static const half3 basisZ = half3(-sqrt(1.0h / 2.0h), -sqrt(1.0h / 6.0h), sqrt(1.0h / 3.0h));
        #elif 0
        static const half3 basisX = half3( sqrt(1.0h / 2.0h), sqrt(1.0h / 3.0h),  sqrt(1.0h / 6.0h));
        static const half3 basisY = half3(              0.0h, sqrt(1.0h / 3.0h), -sqrt(2.0h / 3.0h));
        static const half3 basisZ = half3(-sqrt(1.0h / 2.0h), sqrt(1.0h / 3.0h),  sqrt(1.0h / 6.0h));
        #else
        static const half3 basisX = half3(1, 0, 0);
        static const half3 basisY = half3(0, 1, 0);
        static const half3 basisZ = half3(0, 0, 1);
        #endif

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

        static half _BlurSize = 5.0h;
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
                return LinearEyeDepth(
                    SAMPLE_DEPTH_TEXTURE_LOD(_MainTex, sampler_LinearClamp, input.uv, 0), _ZBufferParams);

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
                half3 color = SAMPLE_TEXTURE2D_LOD(_CameraOpaqueTexture, sampler_LinearClamp, uv, 0).rgb;
                return color;
                half luminance = Luminance(color);
                return color * step(0.9h, luminance);
                return color * max(0.0h, luminance - 0.9h);
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
                const half rayStepsRCP = rcp(raySteps);
                const half rayLength = 0.5f;
                const half rayCount = 16.0h;
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
                    for (half stepIndex = 0.75h; stepIndex < raySteps; stepIndex++)
                    {
                        half ji = (jitter + stepIndex) * rayStepsRCP;
                        half noff = ji * ji;

                        half2 rayUV = traceUV + rayDirection * noff * rayLength;

                        if (any(rayUV < 0.0h || rayUV > 1.0h))
                        {
                            break;
                        }

                        half linearDepth = SampleTraceLinearDepth(rayUV);
                        half3 lingting = SampleTraceLighting(rayUV);
                        half3 surfNormalWS = SamplerTraceNormals(rayUV);
                        half3 surfNormalVS = TransformWorldToCameraNormal(surfNormalWS);

                        half3 rayVS = TransformScreenUVToViewLinear(rayUV, linearDepth);
                        half3 rayDirVS = rayVS - probeVS;
                        half3 rayDirectionVS = normalize(rayDirVS);
                        half VdotR = dot(viewDirectionVS, rayDirectionVS);
                        half traceDistance = length(rayDirVS);

                        half OcclusionFactor = VdotR;
                        half occlusion = smoothstep(prevOcclusionFactor - 0.01h, prevOcclusionFactor, OcclusionFactor);
                        prevOcclusionFactor = max(prevOcclusionFactor, OcclusionFactor);

                        half3 current = lingting * occlusion * rayStepsRCP * exp2(-traceDistance * 0.1);
                        half lum = Luminance(current);

                        finalColor += current;

                        finalSH.w += kSHBasis0 * lum;
                        finalSH.x += kSHBasis1 * dot(rayDirectionVS, basisX) * lum;
                        finalSH.y += kSHBasis1 * dot(rayDirectionVS, basisY) * lum;
                        finalSH.z += kSHBasis1 * dot(rayDirectionVS, basisZ) * lum;
                    }
                }

                finalColor /= rayCount;

                // TODO: Compute SH: https://deadvoxels.blogspot.com/2009/08/has-someone-tried-this-before.html
                // - Use 3 targets (rgb x3 + aaa for storing 4 coefs)
                // - Resolve with normals on final blit stage
                // - Try to do specular with dominant from SH
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
                    half weight = exp(-i * i) / exp(10.0h * abs(centerDepth - depth) * abs(centerLum - lum));
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
                    half weight = exp(-i * i) / exp(10.0h * abs(centerDepth - depth) * abs(centerLum - lum));
                    result += color * weight;
                    totalWeight += weight;
                }

                return result / totalWeight;
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

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SphericalHarmonics.hlsl"

            int _UpscaleType;
            half4 _TraceSize;
            half4 _TraceDepth_TexelSize;
            Texture2D<half> _TraceDepth;
            Texture2D<half4> _SHBuffer;

            half4 LinearEyeDepth(half4 depth)
            {
                return 1.0h / (_ZBufferParams.z * depth + _ZBufferParams.w);
            }

            inline half4 LoadGI(int2 coord)
            {
                // return SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, coord * _MainTex_TexelSize.xy, 0);
                return LOAD_TEXTURE2D_LOD(_MainTex, coord, 0);
            }

            inline half LoadTraceDepth(int2 coord)
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

            half4 GetGI_WiderDepth(int2 coord, half4 bilinearWeights, half hiLinearDepth)
            {
                // c d
                // a b
                half4 offset = half4(-_MainTex_TexelSize.xy, _MainTex_TexelSize.xy) * 0.66h;
                half2 center = (coord + 0.5h) * _MainTex_TexelSize.xy;

                half4 a = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, center + offset.xy, 0);
                half4 b = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, center + offset.zy, 0);
                half4 c = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, center + offset.xw, 0);
                half4 d = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, center + offset.zw, 0);

                half4 lowDepthABCD = half4(a.a, b.a, c.a, d.a);

                half4 weights = bilinearWeights / exp(10.0h * abs(lowDepthABCD - hiLinearDepth));
                weights /= dot(1.0h, weights) + 0.000001h;
                return mul(weights, half4x4(a, b, c, d));
                return mul(weights, half4x4(a.aaaa, b.aaaa, c.aaaa, d.aaaa)) * 0.1;
            }

            half4 GetGI_PlusPattern(half2 positionCS, half hiLinearDepth)
            {
                half2 coord = positionCS / 4 + 0.5;
                half2 texel = _MainTex_TexelSize.xy;

                half2 center = coord * texel;
                half3 offsets = half3(texel.xy, 0.0h);

                half3 V = TransformScreenUVToViewLinear(center, hiLinearDepth);
                V = -normalize(V);

                half4 lowDepthABCD;
                lowDepthABCD.x = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, center + offsets.xz, 0);
                lowDepthABCD.y = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, center - offsets.xz, 0);
                lowDepthABCD.z = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, center + offsets.zy, 0);
                lowDepthABCD.w = SAMPLE_TEXTURE2D_LOD(_TraceDepth, sampler_LinearClamp, center - offsets.zy, 0);

                half4 a = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, center + offsets.xz, 0);
                half4 b = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, center - offsets.xz, 0);
                half4 c = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, center + offsets.zy, 0);
                half4 d = SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_LinearClamp, center - offsets.zy, 0);

                half4 shA = SAMPLE_TEXTURE2D_LOD(_SHBuffer, sampler_LinearClamp, center + offsets.xz, 0);
                half4 shB = SAMPLE_TEXTURE2D_LOD(_SHBuffer, sampler_LinearClamp, center - offsets.xz, 0);
                half4 shC = SAMPLE_TEXTURE2D_LOD(_SHBuffer, sampler_LinearClamp, center + offsets.zy, 0);
                half4 shD = SAMPLE_TEXTURE2D_LOD(_SHBuffer, sampler_LinearClamp, center - offsets.zy, 0);

                half4 weights = 1.0 / (exp(10.0h * abs(hiLinearDepth - lowDepthABCD)) + 0.01h);
                weights = saturate(weights / dot(1.0h, weights));

                half4 irradianceColor = mul(weights, half4x4(a, b, c, d));
                half4 sh = mul(weights, half4x4(shA, shB, shC, shD));

                half3 normalWS = LoadSceneNormals(positionCS);
                half3 N = TransformWorldToCameraNormal(normalWS);

                half irradiance = sh.w +
                    sh.x * dot(N, basisX) +
                    sh.y * dot(N, basisY) +
                    sh.z * dot(N, basisZ);

                half3 R = reflect(-V, N);
                half reflection =
                    sh.x * dot(R, basisX) +
                    sh.y * dot(R, basisY) +
                    sh.z * dot(R, basisZ);

                return irradiance * irradianceColor + pow(saturate(reflection), 5) * irradianceColor;
            }

            half4 Fragmet(Varyings input) : SV_Target
            {
                int2 traceCoord = floor(input.positionCS.xy) / 4;
                // TODO: Bilinear weight???
                half2 ratio = frac(floor(input.positionCS.xy) * 0.25h);
                half4 bilinearWeights = GetBilinearWeights(ratio);

                half hiDepth = LoadSceneDepth(floor(input.positionCS.xy));

                half4 giDepthA = LoadGI(traceCoord);
                half4 giDepthB = LoadGI(traceCoord + int2(1, 0));
                half4 giDepthC = LoadGI(traceCoord + int2(0, 1));
                half4 giDepthD = LoadGI(traceCoord + int2(1, 1));

                hiDepth = LinearEyeDepth(hiDepth, _ZBufferParams);
                half4 lowDepthABCD = half4(giDepthA.a, giDepthB.a, giDepthC.a, giDepthD.a);

                if (_UpscaleType == 0)
                {
                    return GetGI_WiderDepth(traceCoord, bilinearWeights, hiDepth);
                }
                else if (_UpscaleType == 1)
                {
                    half4 weights = bilinearWeights * saturate(exp(-100.0h * abs(hiDepth - lowDepthABCD)));
                    half totalWeight = dot(1.0h, weights);
                    weights = saturate(weights / totalWeight);
                    half4 result =
                        giDepthA * weights.x +
                        giDepthB * weights.y +
                        giDepthC * weights.z +
                        giDepthD * weights.w;

                    return result;
                }
                else if (_UpscaleType == 2)
                {
                    half _UpsampleTolerance = 1.0h;
                    half _NoiseFilterStrength = 0.9h;
                    half4 initialWeight = half4(9, 3, 3, 1); // ???
                    half4 weights = initialWeight * bilinearWeights / (100.0h * abs(hiDepth.xxxx - lowDepthABCD) + 1.0h);
                    half totalWeight = dot(weights, 1.0h);
                    weights /= totalWeight;

                    // weights *= bilinearWeights;

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
                else if (_UpscaleType == 3)
                {
                    // https://github.com/Polish-Miko/GravityEngine/blob/6fad1bd3140ccf5f656197374fe32c7defa3987c/GEngine/GDxRenderer/Shaders/GtaoUpsamplePS.hlsl#L22
                    half4 w = saturate(1.0h - abs(hiDepth.xxxx - lowDepthABCD) / 2.5h);
                    half3 colorAB = lerp(giDepthA * w.x, giDepthB * w.y, ratio.x);
                    half3 colorCD = lerp(giDepthC * w.z, giDepthD * w.w, ratio.x);
                    return half4(lerp(colorAB, colorCD, ratio.y), 1.0h);
                }
                else if (_UpscaleType == 4)
                {
                    return GetGI_PlusPattern(input.positionCS.xy, hiDepth);
                }

                return 0;
            }

            half4 Fragmet2(Varyings input) : SV_Target
            {
                uint2 traceCoord = floor(input.positionCS.xy) / 4;
                half hiDepth = LinearEyeDepth(LoadSceneDepth(floor(input.positionCS.xy)), _ZBufferParams);

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
                    giDepthB * weights.w;
            }
            ENDHLSL
        }
    }
}