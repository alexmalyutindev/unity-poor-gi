Shader "Hidden/PoorGI/Processing"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "./Common.hlsl"

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
            Name "0 BilateralBlur"

            Blend One Zero

            HLSLPROGRAM
            #pragma vertex FulscreenVertex
            #pragma fragment Fragmet

            float4 _MainTex_TexelSize;
            float2 _Direction;
            float _BlurSize;
            float _RefrenceDepthLod;
            float _EdgeSensitivity;
            
            Texture2D<half4> _MainTex;
            Texture2D<half> _RefrenceDepth;

            half4 Fragmet(Varyings input) : SV_Target
            {
                return BilateralBlur(
                    _MainTex, 
                    _RefrenceDepth, 
                    _RefrenceDepthLod,
                    _MainTex_TexelSize.xy,
                    input.uv,
                    _EdgeSensitivity,
                    _BlurSize, 
                    _Direction
                );
            }
            ENDHLSL
        }
    }
}