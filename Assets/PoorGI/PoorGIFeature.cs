using UnityEngine;
using UnityEngine.Rendering.Universal;

namespace AlexMalyutin.PoorGI
{
    public class PoorGIFeature : ScriptableRendererFeature
    {
        public Material SSGIMaterial;

        [Header("Settings")]
        public bool UseBoxFilter = true;
        public bool UseBilateralFilter = true;

        private PoorGIPass _pass;

        public override void Create()
        {
            _pass = new PoorGIPass(SSGIMaterial)
            {
                renderPassEvent = RenderPassEvent.AfterRenderingDeferredLights
            };
            _pass.ConfigureInput(
                ScriptableRenderPassInput.Depth |
                ScriptableRenderPassInput.Normal
            );
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (renderingData.cameraData.isPreviewCamera) return;
            _pass.Setup(UseBoxFilter, UseBilateralFilter);
            renderer.EnqueuePass(_pass);
        }
    }
}