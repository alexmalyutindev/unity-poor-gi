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
            public TextureHandle TempTraceBufferMips2;
            public TextureHandle TempTraceBufferLowRes;

            public TextureHandle Irradiance;
            public TextureHandle Irradiance2;
            public TextureHandle SH;
            public TextureHandle IrradianceLowRes;
            public TextureHandle SHLowRes;

            public TextureHandle CameraColorTarget;
            public TextureHandle GBuffer0;

            public Material SSGIMaterial;
            public int UpsaleType;
            public float TraceScale;
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

            // TODO: Add depth downsample support for other scale factors! 
            var traceScale = 4.0f;
            var traceWidth = Mathf.CeilToInt(screenWidth / traceScale);
            var traceHeight = Mathf.CeilToInt(screenHeight / traceScale);
            var traceBufferWidth = traceWidth;
            var traceBufferHeight = traceHeight;

            passData.TraceScale = traceScale;
            passData.TraceWidth = traceWidth;
            passData.TraceHeight = traceHeight;

            var traceDepthDesc = new TextureDesc(traceBufferWidth, traceBufferHeight)
            {
                name = "_TraceDepth",
                format = GraphicsFormatUtility.GetGraphicsFormat(RenderTextureFormat.ARGBHalf, false),
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
            giBufferDesc.name = "_IrradianceBuffer2";
            passData.Irradiance2 = renderGraph.CreateTexture(giBufferDesc);
            builder.UseTexture(passData.Irradiance2);

            giBufferDesc.name = "_SHBuffer";
            passData.SH = builder.CreateTransientTexture(giBufferDesc);

            // HalfRes buffers
            {
                var desc = giBufferDesc;
                desc.name = "_IrradianceBuffer_Half";
                desc.width = traceBufferWidth / 2;
                desc.height = traceBufferHeight / 2;
                passData.IrradianceLowRes = builder.CreateTransientTexture(desc);
                desc.name = "_SHBuffer_Half";
                passData.SHLowRes = builder.CreateTransientTexture(desc);

                desc.name = "_Temp_Half";
                passData.TempTraceBufferLowRes = builder.CreateTransientTexture(desc);
            }

            giBufferDesc.name = "_Temp_Mips";
            giBufferDesc.useMipMap = true;
            giBufferDesc.autoGenerateMips = false;
            giBufferDesc.filterMode = FilterMode.Bilinear;
            passData.TempTraceBufferMips = builder.CreateTransientTexture(giBufferDesc);
            passData.TempTraceBufferMips2 = builder.CreateTransientTexture(giBufferDesc);

            passData.GBuffer0 = resourceData.gBuffer[0];
            builder.UseTexture(passData.GBuffer0);

            builder.SetRenderFunc<PassData>(static (data, context) =>
            {
                var cmd = CommandBufferHelpers.GetNativeCommandBuffer(context.cmd);

                // Downsample Depth
                cmd.BeginSample("Prepare Fame Buffers");
                {
                    cmd.Blit(data.CameraDepth, data.TraceDepth, data.SSGIMaterial, (int)Pass.DownSampleDepthPass);
                    cmd.GenerateMips(data.TraceDepth);

                    // Variance Depth
                    cmd.Blit(data.CameraDepth, data.TempTraceBufferMips, data.SSGIMaterial, (int)Pass.VarianceDepthPass);
                    cmd.Blit(data.TempTraceBufferMips, data.VarianceDepth, data.SSGIMaterial, (int)Pass.VarianceDepthGaussianBlur);

                    // Downsample Color
                    cmd.Blit(data.CameraColorTarget, data.TempTraceBufferMips, data.SSGIMaterial, (int)Pass.BlitBlur);
                    cmd.GenerateMips(data.TempTraceBufferMips);
                    // TODO: Make blur frame color mip chain
                    // cmd.DrawMesh();
                }
                cmd.EndSample("Prepare Fame Buffers");

                // Tracing
                cmd.BeginSample("Tracing");
                {
                    var bindings = CreateMRTBinding(data.Irradiance, data.Irradiance2, data.SH);
                    cmd.SetRenderTarget(bindings);

                    // TODO: Pass With MaterialPropBlock.
                    cmd.SetGlobalTexture("_TraceColor", data.TempTraceBufferMips);
                    cmd.SetGlobalTexture("_TraceDepth", data.TraceDepth);
                    cmd.SetGlobalTexture("_VarianceDepth", data.VarianceDepth);
                    data.SSGIMaterial.EnableKeyword("USE_SH01");
                    DrawFullScreenTriangle(cmd, data, (int)Pass.TraceGI);
                }
                cmd.EndSample("Tracing");

                cmd.BeginSample("Filtering");
                {
                    if (true)
                    {
                        cmd.BeginSample("BoxFilter.Irradiance");
                        BoxFilter(cmd, data, data.Irradiance, data.TempTraceBufferMips);
                        cmd.EndSample("BoxFilter.Irradiance");
    
                        cmd.BeginSample("BoxFilter.Irradiance2");
                        BoxFilter(cmd, data, data.Irradiance2, data.TempTraceBufferMips);
                        cmd.EndSample("BoxFilter.Irradiance2");

                        cmd.BeginSample("BoxFilter.SH");
                        BoxFilter(cmd, data, data.SH, data.TempTraceBufferMips);
                        cmd.EndSample("BoxFilter.SH");
                    }

                    // Blur GI
                    if (true)
                    {
                        cmd.BeginSample("BilateralBlur");
                        BilateralBlur(cmd, data, data.Irradiance, data.TempTraceBufferMips);
                        BilateralBlur(cmd, data, data.Irradiance2, data.TempTraceBufferMips);
                        BilateralBlur(cmd, data, data.SH, data.TempTraceBufferMips);
                        cmd.EndSample("BilateralBlur");
                    }
                }
                cmd.EndSample("Filtering");

                cmd.BeginSample("Final Bilateral Upscaling");
                {
                    cmd.SetRenderTarget(data.CameraColorTarget);

                    cmd.SetGlobalInteger("_UpscaleType", data.UpsaleType);
                    cmd.SetGlobalVector("_TraceSize", new Vector4(data.TraceWidth, data.TraceHeight));

                    cmd.SetGlobalTexture("_TraceDepth", data.TraceDepth);
                    cmd.SetGlobalTexture("_Irradiance", data.Irradiance);
                    cmd.SetGlobalTexture("_Irradiance2", data.Irradiance2);
                    cmd.SetGlobalTexture("_SH", data.SH);

                    cmd.SetGlobalTexture("_GBuffer0", data.GBuffer0);

                    cmd.SetGlobalFloat("_UpscaleFactor", 1.0f / data.TraceScale);
                    DrawFullScreenTriangle(cmd, data, (int)Pass.ResolveGI);
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

        private static RenderTargetBinding CreateMRTBinding(TextureHandle colorA, TextureHandle colorB, TextureHandle colorC)
        {
            var targetsCount = 3;

            var targets = ArrayPool<RenderTargetIdentifier>.Shared.Rent(targetsCount);
            var load = ArrayPool<RenderBufferLoadAction>.Shared.Rent(targetsCount);
            var store = ArrayPool<RenderBufferStoreAction>.Shared.Rent(targetsCount);

            try
            {
                targets[0] = colorA;
                load[0] = RenderBufferLoadAction.DontCare;
                store[0] = RenderBufferStoreAction.Store;

                targets[1] = colorB;
                load[1] = RenderBufferLoadAction.DontCare;
                store[1] = RenderBufferStoreAction.Store;

                targets[2] = colorC;
                load[2] = RenderBufferLoadAction.DontCare;
                store[2] = RenderBufferStoreAction.Store;

                var bindings = new RenderTargetBinding()
                {
                    colorRenderTargets = targets[..targetsCount],
                    colorLoadActions = load[..targetsCount],
                    colorStoreActions = store[..targetsCount],
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

        private static void DrawFullScreenTriangle(CommandBuffer cmd, PassData data, int pass)
        {
            cmd.DrawMesh(_triangleMesh, Matrix4x4.identity, data.SSGIMaterial, 0, pass);
        }
        
        private static void BilateralBlur(CommandBuffer cmd, PassData data, TextureHandle src, TextureHandle tmp)
        {
            cmd.SetGlobalTexture("_RefrenceDepthLod", 0);
            cmd.SetGlobalTexture("_RefrenceDepth", data.TraceDepth);

            cmd.SetGlobalVector("_Direction", new Vector4(1, 0));
            cmd.Blit(src, tmp, data.SSGIMaterial, (int)Pass.BilateralBlur);
            cmd.SetGlobalVector("_Direction", new Vector4(0, 1));
            cmd.Blit(tmp, src, data.SSGIMaterial, (int)Pass.BilateralBlur);
        }     
        
        private static void BoxFilter(CommandBuffer cmd, PassData data, TextureHandle src, TextureHandle tmp)
        {
            cmd.SetGlobalVector("_Direction", new Vector4(1, 0));
            cmd.Blit(src, tmp, data.SSGIMaterial, (int)Pass.BoxFilter);
            cmd.SetGlobalVector("_Direction", new Vector4(0, 1));
            cmd.Blit(tmp, src, data.SSGIMaterial, (int)Pass.BoxFilter);
        }

        enum Pass : int
        {
            DownSampleDepthPass,
            TraceGI,
            BilateralBlur,
            ResolveGI,
            VarianceDepthPass,
            BlitBlur,
            VarianceDepthGaussianBlur,
            BoxFilter,
        }
    }
}
