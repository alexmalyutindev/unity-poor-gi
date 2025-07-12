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
        static Vector3[] GetFullScreenTriangleVertexPosition(float z /*= UNITY_NEAR_CLIP_VALUE*/)
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
        static Vector2[] GetFullScreenTriangleTexCoord()
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

            public TextureHandle GIBuffer;
            public TextureHandle TempBlurBuffer;
            public TextureHandle SHBuffer;

            public TextureHandle CameraColorTarget;

            public Material SSGIMaterial;
            public int UpsaleType;
        }

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            var resourceData = frameData.Get<UniversalResourceData>();
            var universalCameraData = frameData.Get<UniversalCameraData>();

            using var builder = renderGraph.AddUnsafePass<PassData>(nameof(PoorGIPass), out var passData);
            builder.AllowPassCulling(false);

            passData.UpsaleType = _upscaleType;
            passData.SSGIMaterial = _ssgiMaterial;

            passData.CameraDepth = resourceData.cameraDepthTexture;
            builder.UseTexture(passData.CameraDepth);

            passData.CameraColorTarget = resourceData.activeColorTexture;
            builder.UseTexture(passData.CameraColorTarget);

            var screenWidth = universalCameraData.scaledWidth;
            var screenHeight = universalCameraData.scaledHeight;

            var traceScale = 4.0f;
            // BUG: If frame buffer is not divisible by 4, border appears on right or top side of MaxDepth.
            // TODO: Make bigger buffer for MaxDepth, but trace only valid pixels.
            var traceWidth = Mathf.FloorToInt(screenWidth / traceScale);
            var traceHeight = Mathf.FloorToInt(screenHeight / traceScale);
            var traceBufferWidth = Mathf.CeilToInt(screenWidth / traceScale);
            var traceBufferHeight = Mathf.CeilToInt(screenHeight / traceScale);

            passData.TraceWidth = traceWidth;
            passData.TraceHeight = traceHeight;

            var traceDepthDesc = new TextureDesc(traceBufferWidth, traceBufferHeight)
            {
                name = "_TraceDepth",
                format = GraphicsFormatUtility.GetGraphicsFormat(RenderTextureFormat.RFloat, false),
            };
            passData.TraceDepth = builder.CreateTransientTexture(traceDepthDesc);

            var giBufferDesc = new TextureDesc(traceWidth, traceHeight)
            {
                name = "_GIBuffer",
                filterMode = FilterMode.Bilinear,
                format = GraphicsFormatUtility.GetGraphicsFormat(RenderTextureFormat.ARGBFloat, isSRGB: false),
                clearBuffer = false,
            };
            passData.GIBuffer = renderGraph.CreateTexture(giBufferDesc);
            builder.UseTexture(passData.GIBuffer);
            giBufferDesc.name = "_GIBuffer_Temp";
            passData.TempBlurBuffer = builder.CreateTransientTexture(giBufferDesc);

            giBufferDesc.name = "_SHBuffer_Temp";
            passData.SHBuffer = builder.CreateTransientTexture(giBufferDesc);

            builder.SetRenderFunc<PassData>(static (data, context) =>
            {
                const int DownSampleDepthPass = 0;
                const int TracePass = 1;
                const int BlurHorizontalPass = 2;
                const int BlurVerticalPass = 3;
                const int BilateralUpsamplePass = 4;

                var cmd = CommandBufferHelpers.GetNativeCommandBuffer(context.cmd);

                // Downsample Depth
                cmd.Blit(data.CameraDepth, data.TraceDepth, data.SSGIMaterial, DownSampleDepthPass);

                // Tracing
                {
                    var targets = ArrayPool<RenderTargetIdentifier>.Shared.Rent(2);
                    var load = ArrayPool<RenderBufferLoadAction>.Shared.Rent(2);
                    var store = ArrayPool<RenderBufferStoreAction>.Shared.Rent(2);

                    targets[0] = data.GIBuffer;
                    load[0] = RenderBufferLoadAction.DontCare;
                    store[0] = RenderBufferStoreAction.Store;

                    targets[1] = data.SHBuffer;
                    load[1] = RenderBufferLoadAction.DontCare;
                    store[1] = RenderBufferStoreAction.Store;

                    var bindings = new RenderTargetBinding()
                    {
                        colorRenderTargets = targets[..2],
                        colorLoadActions = load[..2],
                        colorStoreActions = store[..2],
                        depthRenderTarget = data.GIBuffer,
                        flags = RenderTargetFlags.None,
                    };

                    ArrayPool<RenderTargetIdentifier>.Shared.Return(targets);
                    ArrayPool<RenderBufferLoadAction>.Shared.Return(load);
                    ArrayPool<RenderBufferStoreAction>.Shared.Return(store);

                    cmd.SetRenderTarget(bindings);
                    // TODO: Pass With MaterialPropBlock.
                    cmd.SetGlobalTexture("_TraceDepth", data.TraceDepth);
                    cmd.DrawMesh(_triangleMesh, Matrix4x4.identity, data.SSGIMaterial, 0, TracePass);
                    // cmd.Blit(data.TraceDepth, data.GIBuffer, data.SSGIMaterial, TracePass);
                }

                // Blur GI
                {
                    cmd.SetGlobalTexture("_RefrenceDepth", data.TraceDepth);
                    cmd.Blit(data.GIBuffer, data.TempBlurBuffer, data.SSGIMaterial, BlurHorizontalPass);
                    cmd.Blit(data.TempBlurBuffer, data.GIBuffer, data.SSGIMaterial, BlurVerticalPass);

                    cmd.Blit(data.SHBuffer, data.TempBlurBuffer, data.SSGIMaterial, BlurHorizontalPass);
                    cmd.Blit(data.TempBlurBuffer, data.SHBuffer, data.SSGIMaterial, BlurVerticalPass);
                }

                // Upscaling
                cmd.SetGlobalInteger("_UpscaleType", data.UpsaleType);
                cmd.SetGlobalVector("_TraceSize", new Vector4(data.TraceWidth, data.TraceHeight));
                cmd.SetGlobalTexture("_TraceDepth", data.TraceDepth);
                cmd.SetGlobalTexture("_SHBuffer", data.SHBuffer);
                cmd.Blit(data.GIBuffer, data.CameraColorTarget, data.SSGIMaterial, BilateralUpsamplePass);
            });
        }

        public static void CleanUp()
        {
            if (_triangleMesh) Object.DestroyImmediate(_triangleMesh);
        }
    }
}