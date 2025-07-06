using UnityEngine;
using UnityEngine.Rendering.Universal;

namespace AlexMalyutin.PoorGI
{
    public class PoorGIFeature : ScriptableRendererFeature
    {
        public Material SSGIMaterial;
        private PoorGIPass _pass;

        public override void Create()
        {
            _pass = new PoorGIPass(SSGIMaterial)
            {
                renderPassEvent = RenderPassEvent.BeforeRenderingTransparents
            };
            _pass.ConfigureInput(
                ScriptableRenderPassInput.Color |
                ScriptableRenderPassInput.Depth |
                ScriptableRenderPassInput.Normal
            );
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            renderer.EnqueuePass(_pass);
        }
    }
}