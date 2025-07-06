using UnityEngine;
using UnityEngine.Assertions.Must;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Rendering.Universal;

namespace AlexMalyutin.PoorGI
{
    public class PoorGIPass : ScriptableRenderPass
    {
        private readonly Material _ssgiMaterial;

        public PoorGIPass(Material ssgiMaterial)
        {
            _ssgiMaterial = ssgiMaterial;
        }

        private class PassData
        {
            public TextureHandle CameraDepth;

            public TextureHandle TraceDepth;
            public TextureHandle TraceDepthTemp;

            public TextureHandle GIBuffer;
            public TextureHandle GIBufferTemp;

            public TextureHandle CameraColorTarget;

            public Material SSGIMaterial;
        }

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            var resourceData = frameData.Get<UniversalResourceData>();
            var universalCameraData = frameData.Get<UniversalCameraData>();

            using var builder = renderGraph.AddUnsafePass<PassData>(nameof(PoorGIPass), out var passData);
            builder.AllowPassCulling(false);

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
            var traceWidth = Mathf.CeilToInt(screenWidth / traceScale);
            var traceHeight = Mathf.CeilToInt(screenHeight / traceScale);

            var traceDepthDesc = new TextureDesc(traceWidth, traceHeight)
            {
                name = "_MaxDepth",
                format = GraphicsFormatUtility.GetGraphicsFormat(RenderTextureFormat.RFloat,
                    RenderTextureReadWrite.Linear),
            };
            passData.TraceDepth = builder.CreateTransientTexture(traceDepthDesc);
            traceDepthDesc.name = "_MaxDepth_Temp";
            passData.TraceDepthTemp = builder.CreateTransientTexture(traceDepthDesc);

            var giBufferDesc = new TextureDesc(traceWidth, traceHeight)
            {
                name = "_GIBuffer",
                format = GraphicsFormatUtility.GetGraphicsFormat(RenderTextureFormat.RGB111110Float,
                    RenderTextureReadWrite.sRGB),
                clearBuffer = false,
            };
            passData.GIBuffer = renderGraph.CreateTexture(giBufferDesc);
            builder.UseTexture(passData.GIBuffer);
            giBufferDesc.name = "_GIBuffer_Temp";
            passData.GIBufferTemp = builder.CreateTransientTexture(giBufferDesc);

            builder.SetRenderFunc<PassData>(static (data, context) =>
            {
                const int DownSampleDepthPass = 0;
                const int TracePass = 1;
                const int BlurHorizontalPass = 2;
                const int BlurVerticalPass = 3;
                const int BilateralUpsamplePass = 4;

                var cmd = CommandBufferHelpers.GetNativeCommandBuffer(context.cmd);
                cmd.Blit(data.CameraDepth, data.TraceDepth, data.SSGIMaterial, DownSampleDepthPass);

                // Tracing
                cmd.Blit(data.TraceDepth, data.GIBuffer, data.SSGIMaterial, TracePass);

                // Blur GI
                // cmd.Blit(data.GIBuffer, data.GIBufferTemp, data.SSGIMaterial, BlurHorizontalPass);
                // cmd.Blit(data.GIBufferTemp, data.GIBuffer, data.SSGIMaterial, BlurVerticalPass);

                // Blur Depth
                // cmd.Blit(data.TraceDepth, data.TraceDepthTemp, data.SSGIMaterial, BlurHorizontalPass);
                // cmd.Blit(data.TraceDepthTemp, data.TraceDepth, data.SSGIMaterial, BlurVerticalPass);

                // Upscaling
                cmd.SetGlobalTexture("_TraceDepth", data.TraceDepth);
                cmd.Blit(data.GIBuffer, data.CameraColorTarget, data.SSGIMaterial, BilateralUpsamplePass);
            });
        }
    }
}