namespace AlexMalyutin.PoorGI
{
    public class DomainReloadHook
    {
#if UNITY_EDITOR
        [UnityEditor.InitializeOnLoadMethod]
        private static void InitializeOnLoad()
        {
            UnityEditor.AssemblyReloadEvents.beforeAssemblyReload += PoorGIPass.CleanUp;
        }
#endif
    }
}