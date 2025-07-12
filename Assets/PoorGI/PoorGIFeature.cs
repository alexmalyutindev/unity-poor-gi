using UnityEngine;
using UnityEngine.Rendering.Universal;

namespace AlexMalyutin.PoorGI
{
    public class PoorGIFeature : ScriptableRendererFeature
    {
        [Range(0, 4)]
        public int UpscaleType;

        public Material SSGIMaterial;
        private PoorGIPass _pass;

        public override void Create()
        {
            _pass = new PoorGIPass(SSGIMaterial)
            {
                renderPassEvent = RenderPassEvent.BeforeRenderingSkybox
            };
            _pass.ConfigureInput(
                ScriptableRenderPassInput.Depth |
                ScriptableRenderPassInput.Normal
            );
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (renderingData.cameraData.isPreviewCamera) return;
            _pass.Setup(UpscaleType);
            renderer.EnqueuePass(_pass);
        }
    }
}