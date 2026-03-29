using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEditor;
using UnityEditor.SceneManagement;

namespace Tykit
{
    [InitializeOnLoad]
    public static class EditorCommands
    {
        private static readonly ConcurrentQueue<LogEntry> _consoleLogs = new();
        private const int MaxLogs = 200;
        private static int _logCount;

        static EditorCommands()
        {
            RegisterCommands();
            Application.logMessageReceived += OnLogMessage;
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe("play", "Enter Play Mode.", "editor.control", true),
                _ => SetPlayMode(true));
            CommandRegistry.Register(
                CommandRegistry.Describe("stop", "Exit Play Mode.", "editor.control", true),
                _ => SetPlayMode(false));
            CommandRegistry.Register(
                CommandRegistry.Describe("pause", "Toggle Play Mode pause state.", "editor.control", true),
                _ => TogglePause());
            CommandRegistry.Register(
                CommandRegistry.Describe("save-scene", "Save all open scenes.", "scene.control", true),
                _ => SaveScene());
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "console",
                    "Read recent console entries from tykit's internal log buffer.",
                    "editor.console",
                    false,
                    CommandSchema.Object(
                        ("count", CommandSchema.Integer("Maximum number of entries to return.")),
                        ("filter", CommandSchema.String("Optional substring filter for log type or message.")))),
                GetConsole);
            CommandRegistry.Register(
                CommandRegistry.Describe("clear-console", "Clear the Unity Console and tykit log buffer.", "editor.console", true),
                _ => ClearConsole());
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "menu",
                    "Execute a Unity editor menu item.",
                    "editor.control",
                    true,
                    CommandSchema.Object(
                        ("item", CommandSchema.String("Menu path, for example Window/General/Console")))),
                ExecuteMenu);
            CommandRegistry.Register(
                CommandRegistry.Describe("commands", "List registered tykit command names.", "meta.query", false),
                _ => ListCommands());
            CommandRegistry.Register(
                CommandRegistry.Describe("describe-commands", "List tykit command metadata descriptors.", "meta.query", false),
                _ => CommandRegistry.DescribeCommands());
            CommandRegistry.Register(
                CommandRegistry.Describe("status", "Read current editor status, scene, and platform.", "editor.state", false),
                _ => GetStatus());
            CommandRegistry.Register(
                CommandRegistry.Describe("undo", "Perform one editor undo step.", "editor.control", true),
                _ => PerformUndo());
            CommandRegistry.Register(
                CommandRegistry.Describe("redo", "Perform one editor redo step.", "editor.control", true),
                _ => PerformRedo());
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "select",
                    "Select a GameObject by instanceId, path, or name.",
                    "selection",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path, for example World/Ship.")),
                        ("name", CommandSchema.String("GameObject name.")))),
                SelectGameObject);
            CommandRegistry.Register(
                CommandRegistry.Describe("get-selection", "Read the current editor selection.", "selection", false),
                _ => GetSelection());
            CommandRegistry.Register(
                CommandRegistry.Describe("compile-status", "Read current Unity compilation and asset update state.", "editor.state", false),
                _ => GetCompileStatus());
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "open-scene",
                    "Open a scene asset.",
                    "scene.control",
                    true,
                    CommandSchema.Object(
                        ("path", CommandSchema.String("Scene asset path, for example Assets/Scenes/Main.unity.")),
                        ("mode", CommandSchema.String("Open mode.", "single", "additive")))),
                OpenScene);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "new-scene",
                    "Create a new scene and save it to the given asset path.",
                    "scene.control",
                    true,
                    CommandSchema.Object(
                        ("path", CommandSchema.String("Target scene asset path.")))),
                NewScene);
            CommandRegistry.Register(
                CommandRegistry.Describe("list-scenes", "List all scene assets under Assets/.", "scene.query", false),
                _ => ListScenes());
        }

        private static JObject SetPlayMode(bool play)
        {
            EditorApplication.isPlaying = play;
            return CommandRegistry.Ok(play ? "Play mode starting" : "Play mode stopping");
        }

        private static JObject TogglePause()
        {
            EditorApplication.isPaused = !EditorApplication.isPaused;
            return CommandRegistry.Ok($"Paused: {EditorApplication.isPaused}");
        }

        private static JObject SaveScene()
        {
            var saved = EditorSceneManager.SaveOpenScenes();
            return saved
                ? CommandRegistry.Ok("Scenes saved")
                : CommandRegistry.Error("Failed to save scenes");
        }

        // args: {"count":50,"filter":"error"}
        private static JObject GetConsole(JObject args)
        {
            int count = args["count"]?.Value<int>() ?? 50;
            var filter = args["filter"]?.Value<string>();

            var snapshot = _consoleLogs.ToArray();
            var start = Math.Max(0, snapshot.Length - count);

            var lines = new JArray();
            for (int i = start; i < snapshot.Length; i++)
            {
                var entry = snapshot[i];
                if (filter != null &&
                    !entry.Type.Contains(filter, StringComparison.OrdinalIgnoreCase) &&
                    !entry.Message.Contains(filter, StringComparison.OrdinalIgnoreCase))
                    continue;

                lines.Add(new JObject { ["type"] = entry.Type, ["message"] = entry.Message });
            }

            return CommandRegistry.Ok(lines);
        }

        // args: {"item":"Window/General/Console"}
        private static JObject ExecuteMenu(JObject args)
        {
            var item = args["item"]?.Value<string>();
            if (string.IsNullOrEmpty(item))
                return CommandRegistry.Error("Missing 'item' field");

            var result = EditorApplication.ExecuteMenuItem(item);
            return result
                ? CommandRegistry.Ok($"Executed: {item}")
                : CommandRegistry.Error($"Menu item not found or failed: {item}");
        }

        private static JObject ListCommands()
        {
            return CommandRegistry.Ok(new JArray(CommandRegistry.GetCommandNames().OrderBy(n => n).ToArray()));
        }

        private static JObject GetStatus()
        {
            return CommandRegistry.Ok(new JObject
            {
                ["isPlaying"] = EditorApplication.isPlaying,
                ["isPaused"] = EditorApplication.isPaused,
                ["isCompiling"] = EditorApplication.isCompiling,
                ["activeScene"] = SceneManager.GetActiveScene().name,
                ["sceneCount"] = SceneManager.sceneCount,
                ["platform"] = EditorUserBuildSettings.activeBuildTarget.ToString()
            });
        }

        private static JObject PerformUndo()
        {
            Undo.PerformUndo();
            return CommandRegistry.Ok("Undo performed");
        }

        private static JObject PerformRedo()
        {
            Undo.PerformRedo();
            return CommandRegistry.Ok("Redo performed");
        }

        // args: {"id":12345} or {"name":"Ship"}
        private static JObject SelectGameObject(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            Selection.activeGameObject = go;
            EditorGUIUtility.PingObject(go);
            return CommandRegistry.Ok(new JObject
            {
                ["name"] = go.name,
                ["instanceId"] = go.GetInstanceID()
            });
        }

        // args: {"path":"Assets/Scenes/MyScene.unity","mode":"single"}
        // mode: "single" (default) or "additive"
        private static JObject OpenScene(JObject args)
        {
            var path = args["path"]?.Value<string>();
            if (string.IsNullOrEmpty(path))
                return CommandRegistry.Error("Missing 'path' field (e.g. Assets/Scenes/MyScene.unity)");

            if (!File.Exists(path))
                return CommandRegistry.Error($"Scene not found: {path}");

            var modeStr = args["mode"]?.Value<string>() ?? "single";
            var mode = modeStr == "additive"
                ? OpenSceneMode.Additive
                : OpenSceneMode.Single;

            if (EditorApplication.isPlaying)
                return CommandRegistry.Error("Cannot open scene while in Play mode");

            var scene = EditorSceneManager.OpenScene(path, mode);
            return CommandRegistry.Ok(new JObject
            {
                ["name"] = scene.name,
                ["path"] = scene.path,
                ["mode"] = modeStr
            });
        }

        // args: {"path":"Assets/Scenes/MyScene.unity"}
        // Creates a new empty scene and saves it to the given path.
        private static JObject NewScene(JObject args)
        {
            var path = args["path"]?.Value<string>();
            if (string.IsNullOrEmpty(path))
                return CommandRegistry.Error("Missing 'path' (e.g. Assets/Scenes/MyScene.unity)");

            if (EditorApplication.isPlaying)
                return CommandRegistry.Error("Cannot create scene while in Play mode");

            var dir = System.IO.Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir) && !System.IO.Directory.Exists(dir))
                System.IO.Directory.CreateDirectory(dir);

            var scene = EditorSceneManager.NewScene(NewSceneSetup.DefaultGameObjects, NewSceneMode.Single);
            EditorSceneManager.SaveScene(scene, path);

            return CommandRegistry.Ok(new JObject
            {
                ["name"] = scene.name,
                ["path"] = path
            });
        }

        private static JObject GetSelection()
        {
            var gos = Selection.gameObjects;
            if (gos.Length == 0)
                return CommandRegistry.Ok(new JArray());

            var arr = new JArray();
            foreach (var go in gos)
            {
                arr.Add(new JObject
                {
                    ["name"] = go.name,
                    ["instanceId"] = go.GetInstanceID()
                });
            }
            return CommandRegistry.Ok(arr);
        }

        private static JObject GetCompileStatus()
        {
            return CommandRegistry.Ok(new JObject
            {
                ["isCompiling"] = EditorApplication.isCompiling,
                ["isUpdating"] = EditorApplication.isUpdating
            });
        }

        private static JObject ListScenes()
        {
            var guids = AssetDatabase.FindAssets("t:Scene", new[] { "Assets" });
            var scenes = new JArray();
            foreach (var guid in guids)
            {
                var path = AssetDatabase.GUIDToAssetPath(guid);
                scenes.Add(path);
            }
            return CommandRegistry.Ok(scenes);
        }

        private static JObject ClearConsole()
        {
            // Clear tykit internal buffer
            while (_consoleLogs.TryDequeue(out _)) { }
            _logCount = 0;

            // Clear Unity Editor Console panel
            var logEntries = System.Type.GetType("UnityEditor.LogEntries, UnityEditor");
            logEntries?.GetMethod("Clear", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)
                ?.Invoke(null, null);

            return CommandRegistry.Ok("Console cleared");
        }

        private static void OnLogMessage(string condition, string stackTrace, LogType type)
        {
            _consoleLogs.Enqueue(new LogEntry { Type = type.ToString(), Message = condition });
            // Trim old entries (approximate — ConcurrentQueue doesn't have RemoveAt)
            if (++_logCount > MaxLogs * 2)
            {
                while (_consoleLogs.Count > MaxLogs)
                    _consoleLogs.TryDequeue(out _);
                _logCount = _consoleLogs.Count;
            }
        }

        private class LogEntry
        {
            public string Type;
            public string Message;
        }
    }
}
