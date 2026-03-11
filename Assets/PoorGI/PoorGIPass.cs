using System;
using System.Buffers;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Rendering.Universal;
using Object = UnityEngine.Object;

namespace AlexMalyutin.PoorGI
{
    public class PoorGIPass : ScriptableRenderPass
    {
        private readonly Material _ssgiMaterial;
        private int _upscaleType;

        private static Mesh _triangleMesh;

        public PoorGIPass(Material ssgiMaterial)
        {
            _ssgiMaterial = ssgiMaterial;
            CreateFullScreenTriangle();
        }

        public void Setup(int upscaleType)
        {
            _upscaleType = upscaleType;
        }

        private class PassData
        {
            public TextureHandle CameraDepth;

            public int TraceWidth;
            public int TraceHeight;
            public TextureHandle TraceDepth;
            public TextureHandle VarianceDepth;

            public TextureHandle TempTraceBufferMips;
            public TextureHandle TempTraceBuffer_Half;

            public TextureHandle Irradiance;
            public TextureHandle SH;
            public TextureHandle Irradiance_Half;
            public TextureHandle SH_Half;

            public TextureHandle CameraColorTarget;
            public TextureHandle GBuffer0;

            public Material SSGIMaterial;
            public int UpsaleType;
        }

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            var resourceData = frameData.Get<UniversalResourceData>();
            var cameraData = frameData.Get<UniversalCameraData>();

            using var builder = renderGraph.AddUnsafePass<PassData>(nameof(PoorGIPass), out var passData);
            builder.AllowPassCulling(false);

            passData.UpsaleType = _upscaleType;
            passData.SSGIMaterial = _ssgiMaterial;

            passData.CameraDepth = resourceData.cameraDepthTexture;
            builder.UseTexture(passData.CameraDepth);

            passData.CameraColorTarget = resourceData.activeColorTexture;
            builder.UseTexture(passData.CameraColorTarget);

            var screenWidth = cameraData.scaledWidth;
            var screenHeight = cameraData.scaledHeight;

            var traceScale = 4.0f;
            // Use CeilToInt for both dimensions to ensure proper coverage
            var traceWidth = Mathf.CeilToInt(screenWidth / traceScale);
            var traceHeight = Mathf.CeilToInt(screenHeight / traceScale);
            var traceBufferWidth = traceWidth;
            var traceBufferHeight = traceHeight;

            passData.TraceWidth = traceWidth;
            passData.TraceHeight = traceHeight;

            var traceDepthDesc = new TextureDesc(traceBufferWidth, traceBufferHeight)
            {
                name = "_TraceDepth",
                format = GraphicsFormatUtility.GetGraphicsFormat(RenderTextureFormat.RGHalf, false),
                useMipMap = true,
                autoGenerateMips = false,
            };
            passData.TraceDepth = builder.CreateTransientTexture(traceDepthDesc);

            // NOTE: Disable variance depth for now.
            var varianceDepthDesc = new TextureDesc(traceBufferWidth, traceBufferHeight)
            {
                name = "_VarianceDepth",
                format = GraphicsFormatUtility.GetGraphicsFormat(RenderTextureFormat.RGHalf, false),
            };
            passData.VarianceDepth = builder.CreateTransientTexture(varianceDepthDesc);

            var giBufferDesc = new TextureDesc(traceBufferWidth, traceBufferHeight)
            {
                name = "_IrradianceBuffer",
                filterMode = FilterMode.Bilinear,
                format = GraphicsFormatUtility.GetGraphicsFormat(RenderTextureFormat.ARGBFloat, isSRGB: false),
                clearBuffer = false,
            };
            passData.Irradiance = renderGraph.CreateTexture(giBufferDesc);
            builder.UseTexture(passData.Irradiance);

            giBufferDesc.name = "_SHBuffer";
            passData.SH = builder.CreateTransientTexture(giBufferDesc);
            
            // HalfRes buffers
            {
                var desc = giBufferDesc;
                desc.name = "_IrradianceBuffer_Half";
                desc.width = traceBufferWidth / 2;
                desc.height = traceBufferHeight / 2;
                passData.Irradiance_Half = builder.CreateTransientTexture(desc);
                desc.name = "_SHBuffer_Half";
                passData.SH_Half = builder.CreateTransientTexture(desc);
                
                desc.name = "_Temp_Half";
                passData.TempTraceBuffer_Half = builder.CreateTransientTexture(desc);
            }
            
            giBufferDesc.name = "_Temp_Mips";
            giBufferDesc.useMipMap = true;
            giBufferDesc.autoGenerateMips = false;
            giBufferDesc.filterMode = FilterMode.Point;
            passData.TempTraceBufferMips = builder.CreateTransientTexture(giBufferDesc);

            passData.GBuffer0 = resourceData.gBuffer[0];
            builder.UseTexture(passData.GBuffer0);

            builder.SetRenderFunc<PassData>(static (data, context) =>
            {
                const int DownSampleDepthPass = 0;
                const int TracePass = 1;
                const int BlurHorizontalPass = 2;
                const int BlurVerticalPass = 3;
                const int BilateralUpsamplePass = 4;
                const int VarianceDepthPass = 5;
                const int BlitBlur = 6;
                const int GaussianBlur_Variance = 7;
                const int BoxFilter = 8;

                var cmd = CommandBufferHelpers.GetNativeCommandBuffer(context.cmd);

                // Downsample Depth
                cmd.BeginSample("Prepare Fame Buffers");
                {
                    cmd.Blit(data.CameraDepth, data.TraceDepth, data.SSGIMaterial, DownSampleDepthPass);
                    cmd.GenerateMips(data.TraceDepth);

                    // Variance Depth
                    cmd.Blit(data.CameraDepth, data.TempTraceBufferMips, data.SSGIMaterial, VarianceDepthPass);
                    cmd.Blit(data.TempTraceBufferMips, data.VarianceDepth, data.SSGIMaterial, GaussianBlur_Variance);

                    // Downsample Color
                    // cmd.Blit(data.CameraColorTarget, data.TempTraceBuffer, data.SSGIMaterial, BlitBlur);
                    cmd.Blit(data.CameraColorTarget, data.TempTraceBufferMips, data.SSGIMaterial, BlitBlur);
                    cmd.GenerateMips(data.TempTraceBufferMips);
                }
                cmd.EndSample("Prepare Fame Buffers");

                // Tracing
                cmd.BeginSample("Tracing");
                {
                    var bindings = CreateMRTBinding(data.Irradiance, data.SH);
                    cmd.SetRenderTarget(bindings);

                    // TODO: Pass With MaterialPropBlock.
                    cmd.SetGlobalTexture("_TraceColor", data.TempTraceBufferMips);
                    cmd.SetGlobalTexture("_TraceDepth", data.TraceDepth);
                    cmd.SetGlobalTexture("_VarianceDepth", data.VarianceDepth);
                    cmd.DrawMesh(_triangleMesh, Matrix4x4.identity, data.SSGIMaterial, 0, TracePass);
                }
                cmd.EndSample("Tracing");

                cmd.BeginSample("Box Filter");
                {
                    cmd.SetRenderTarget(data.Irradiance_Half);
                    cmd.SetGlobalTexture("_BlitTexture", data.Irradiance);
                    cmd.DrawMesh(_triangleMesh, Matrix4x4.identity, data.SSGIMaterial, 0, BoxFilter);

                    cmd.SetRenderTarget(data.SH_Half);
                    cmd.SetGlobalTexture("_BlitTexture", data.SH);
                    cmd.DrawMesh(_triangleMesh, Matrix4x4.identity, data.SSGIMaterial, 0, BoxFilter);
                }
                cmd.EndSample("Box Filter");

                // Blur GI
                cmd.BeginSample("Bilateral Blur");
                {
                    cmd.SetGlobalTexture("_RefrenceDepth", data.TraceDepth);
                    cmd.Blit(data.Irradiance_Half, data.TempTraceBuffer_Half, data.SSGIMaterial, BlurHorizontalPass);
                    cmd.Blit(data.TempTraceBuffer_Half, data.Irradiance_Half, data.SSGIMaterial, BlurVerticalPass);

                    cmd.Blit(data.SH_Half, data.TempTraceBuffer_Half, data.SSGIMaterial, BlurHorizontalPass);
                    cmd.Blit(data.TempTraceBuffer_Half, data.SH_Half, data.SSGIMaterial, BlurVerticalPass);
                }
                cmd.EndSample("Bilateral Blur");

                cmd.BeginSample("Final Bilateral Upscaling");
                {
                    cmd.SetGlobalInteger("_UpscaleType", data.UpsaleType);
                    cmd.SetGlobalVector("_TraceSize", new Vector4(data.TraceWidth, data.TraceHeight));
                    cmd.SetGlobalTexture("_TraceDepth", data.TraceDepth);
                    cmd.SetGlobalTexture("_SHBuffer", data.SH);
                    cmd.SetGlobalTexture("_GBuffer0", data.GBuffer0);

                    cmd.SetGlobalFloat("_UpscaleFactor", 1.0f / 4.0f);
                    cmd.Blit(data.Irradiance, data.CameraColorTarget, data.SSGIMaterial, BilateralUpsamplePass);
                }
                cmd.EndSample("Final Bilateral Upscaling");

            });
        }

        private static RenderTargetBinding CreateMRTBinding(TextureHandle colorA, TextureHandle colorB)
        {
            var targets = ArrayPool<RenderTargetIdentifier>.Shared.Rent(2);
            var load = ArrayPool<RenderBufferLoadAction>.Shared.Rent(2);
            var store = ArrayPool<RenderBufferStoreAction>.Shared.Rent(2);

            try
            {
                targets[0] = colorA;
                load[0] = RenderBufferLoadAction.DontCare;
                store[0] = RenderBufferStoreAction.Store;

                targets[1] = colorB;
                load[1] = RenderBufferLoadAction.DontCare;
                store[1] = RenderBufferStoreAction.Store;

                var bindings = new RenderTargetBinding()
                {
                    colorRenderTargets = targets[..2],
                    colorLoadActions = load[..2],
                    colorStoreActions = store[..2],
                    depthRenderTarget = colorA,
                    flags = RenderTargetFlags.None,
                };
                return bindings;
            }
            finally
            {
                ArrayPool<RenderTargetIdentifier>.Shared.Return(targets);
                ArrayPool<RenderBufferLoadAction>.Shared.Return(load);
                ArrayPool<RenderBufferStoreAction>.Shared.Return(store);
            }
        }

        private static void CreateFullScreenTriangle()
        {
            /*UNITY_NEAR_CLIP_VALUE*/
            float nearClipZ = SystemInfo.usesReversedZBuffer ? 1 : -1;
            if (!_triangleMesh)
            {
                _triangleMesh = new Mesh();
                _triangleMesh.hideFlags = HideFlags.DontSave;
                _triangleMesh.vertices = GetFullScreenTriangleVertexPosition(nearClipZ);
                _triangleMesh.uv = GetFullScreenTriangleTexCoord();
                _triangleMesh.triangles = new int[3] { 0, 1, 2 };
            }
        }

        // Should match Common.hlsl
        public static Vector3[] GetFullScreenTriangleVertexPosition(float z /*= UNITY_NEAR_CLIP_VALUE*/)
        {
            var r = new Vector3[3];
            for (int i = 0; i < 3; i++)
            {
                Vector2 uv = new Vector2((i << 1) & 2, i & 2);
                r[i] = new Vector3(uv.x * 2.0f - 1.0f, uv.y * 2.0f - 1.0f, z);
            }

            return r;
        }

        // Should match Common.hlsl
        public static Vector2[] GetFullScreenTriangleTexCoord()
        {
            var r = new Vector2[3];
            for (int i = 0; i < 3; i++)
            {
                if (SystemInfo.graphicsUVStartsAtTop)
                    r[i] = new Vector2((i << 1) & 2, 1.0f - (i & 2));
                else
                    r[i] = new Vector2((i << 1) & 2, i & 2);
            }

            return r;
        }

        public static void CleanUp()
        {
            if (_triangleMesh) Object.DestroyImmediate(_triangleMesh);
        }
    }
}
