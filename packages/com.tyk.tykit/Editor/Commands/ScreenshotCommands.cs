// Commands/ScreenshotCommands.cs
using System;
using System.IO;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEditor;

namespace Tykit
{
    [InitializeOnLoad]
    public static class ScreenshotCommands
    {
        private static readonly string ScreenshotDir = Path.Combine(
            Application.dataPath, "..", "Temp", "Screenshots");

        static ScreenshotCommands()
        {
            RegisterCommands();
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "screenshot",
                    "Capture the Scene or Game view to a PNG file under Temp/Screenshots.",
                    "visual.query",
                    false,
                    CommandSchema.Object(
                        ("view", CommandSchema.String("Target view.", "scene", "game")),
                        ("width", CommandSchema.Integer("Optional output width.")),
                        ("height", CommandSchema.Integer("Optional output height.")))),
                TakeScreenshot);
        }

        // args: {"view":"scene"} or {"view":"game"} or {"width":1920,"height":1080}
        private static JObject TakeScreenshot(JObject args)
        {
            var view = args["view"]?.Value<string>() ?? "scene";
            int width = args["width"]?.Value<int>() ?? 0;
            int height = args["height"]?.Value<int>() ?? 0;

            if (!Directory.Exists(ScreenshotDir))
                Directory.CreateDirectory(ScreenshotDir);

            var filename = $"screenshot_{DateTime.Now:yyyyMMdd_HHmmss}.png";
            var filePath = Path.Combine(ScreenshotDir, filename);

            try
            {
                switch (view.ToLower())
                {
                    case "scene":
                        CaptureSceneView(filePath, width, height);
                        break;
                    case "game":
                        CaptureGameView(filePath, width, height);
                        break;
                    default:
                        return CommandRegistry.Error($"Unknown view: {view}. Use 'scene' or 'game'");
                }
            }
            catch (Exception e)
            {
                return CommandRegistry.Error($"Screenshot failed: {e.Message}");
            }

            return CommandRegistry.Ok(new JObject
            {
                ["path"] = filePath,
                ["view"] = view,
                ["size"] = new FileInfo(filePath).Length
            });
        }

        private static void CaptureSceneView(string path, int width, int height)
        {
            var sceneView = SceneView.lastActiveSceneView;
            if (sceneView == null)
                throw new Exception("No active Scene View");

            var cam = sceneView.camera;
            if (cam == null)
                throw new Exception("Scene View camera not available");

            if (width <= 0) width = (int)sceneView.position.width;
            if (height <= 0) height = (int)sceneView.position.height;

            RenderCameraToFile(cam, path, width, height);
        }

        private static void CaptureGameView(string path, int width, int height)
        {
            var cam = Camera.main;
            if (cam == null)
            {
                // Try to find any camera
                cam = UnityEngine.Object.FindFirstObjectByType<Camera>();
            }
            if (cam == null)
                throw new Exception("No camera found in scene");

            if (width <= 0) width = 1920;
            if (height <= 0) height = 1080;

            RenderCameraToFile(cam, path, width, height);
        }

        private static void RenderCameraToFile(Camera cam, string path, int width, int height)
        {
            var rt = new RenderTexture(width, height, 24);
            var origRT = cam.targetTexture;

            cam.targetTexture = rt;
            cam.Render();

            RenderTexture.active = rt;
            var tex = new Texture2D(width, height, TextureFormat.RGB24, false);
            tex.ReadPixels(new Rect(0, 0, width, height), 0, 0);
            tex.Apply();

            cam.targetTexture = origRT;
            RenderTexture.active = null;

            var png = tex.EncodeToPNG();
            File.WriteAllBytes(path, png);

            UnityEngine.Object.DestroyImmediate(tex);
            UnityEngine.Object.DestroyImmediate(rt);
        }
    }
}
