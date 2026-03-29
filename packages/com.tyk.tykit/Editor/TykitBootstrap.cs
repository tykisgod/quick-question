namespace Tykit
{
    public static class TykitBootstrap
    {
        public static void EnsureCommandsRegistered()
        {
            EditorCommands.RegisterCommands();
            HierarchyCommands.RegisterCommands();
            GameObjectCommands.RegisterCommands();
            ComponentCommands.RegisterCommands();
            AssetCommands.RegisterCommands();
            InputCommands.RegisterCommands();
            VisualCommands.RegisterCommands();
            UICommands.RegisterCommands();
            AnimationCommands.RegisterCommands();
            ScreenshotCommands.RegisterCommands();
            TestCommands.RegisterCommands();
        }
    }
}
