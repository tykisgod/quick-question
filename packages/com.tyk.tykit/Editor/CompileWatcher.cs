using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.Compilation;
using UnityEngine;

namespace Tykit
{
    /// <summary>
    /// Monitors compilation events, writes status to Temp/compile_status.json,
    /// and watches for Temp/refresh_trigger to invoke AssetDatabase.Refresh().
    /// </summary>
    [InitializeOnLoad]
    public static class CompileWatcher
    {
        private static readonly string StatusFile = Path.Combine(
            Application.dataPath, "..", "Temp", "compile_status.json");

        private static readonly string TriggerFile = Path.Combine(
            Application.dataPath, "..", "Temp", "refresh_trigger");

        private static DateTime _compileStartTime;
        private static bool _hasErrors;
        private static double _lastTriggerCheck;

        static CompileWatcher()
        {
            CompilationPipeline.compilationStarted += OnCompilationStarted;
            CompilationPipeline.compilationFinished += OnCompilationFinished;
            CompilationPipeline.assemblyCompilationFinished += OnAssemblyCompilationFinished;
            EditorApplication.update += CheckRefreshTrigger;
        }

        /// <summary>Read the current compile status from disk.</summary>
        public static CompileStatus ReadStatus()
        {
            if (!File.Exists(StatusFile)) return null;
            try
            {
                var json = File.ReadAllText(StatusFile);
                return JsonUtility.FromJson<CompileStatus>(json);
            }
            catch { return null; }
        }

        private static void CheckRefreshTrigger()
        {
            if (EditorApplication.timeSinceStartup - _lastTriggerCheck < 0.5)
                return;
            _lastTriggerCheck = EditorApplication.timeSinceStartup;

            if (!File.Exists(TriggerFile)) return;
            try
            {
                File.Delete(TriggerFile);
                AssetDatabase.Refresh();
            }
            catch (Exception e)
            {
                Debug.LogWarning($"[CompileWatcher] Failed to process trigger: {e.Message}");
            }
        }

        private static void OnCompilationStarted(object context)
        {
            _compileStartTime = DateTime.Now;
            _hasErrors = false;
            WriteStatus(new CompileStatus
            {
                state = "compiling",
                timestamp = DateTime.Now.ToString("o"),
                errors = new string[0]
            });
        }

        private static void OnAssemblyCompilationFinished(string assemblyPath, CompilerMessage[] messages)
        {
            foreach (var msg in messages)
            {
                if (msg.type == CompilerMessageType.Error)
                    _hasErrors = true;
            }
        }

        private static void OnCompilationFinished(object context)
        {
            var duration = (DateTime.Now - _compileStartTime).TotalSeconds;
            WriteStatus(new CompileStatus
            {
                state = EditorUtility.scriptCompilationFailed ? "failed" : "success",
                timestamp = DateTime.Now.ToString("o"),
                duration = duration,
                errors = GetRecentErrors()
            });
        }

        private static string[] GetRecentErrors()
        {
            var errors = new List<string>();
            var logPath = UnityEngine.Application.consoleLogPath;

            if (!File.Exists(logPath)) return errors.ToArray();
            try
            {
                using (var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    var startPos = Math.Max(0, fs.Length - 100 * 1024);
                    fs.Seek(startPos, SeekOrigin.Begin);
                    using (var reader = new StreamReader(fs))
                    {
                        string line;
                        while ((line = reader.ReadLine()) != null)
                        {
                            if (line.Contains("): error CS"))
                                errors.Add(line.Trim());
                        }
                    }
                }
            }
            catch { }
            return errors.ToArray();
        }

        private static void WriteStatus(CompileStatus status)
        {
            try
            {
                var dir = Path.GetDirectoryName(StatusFile);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.WriteAllText(StatusFile, JsonUtility.ToJson(status, true));
            }
            catch { }
        }

        [Serializable]
        public class CompileStatus
        {
            public string state;      // "compiling", "success", "failed"
            public string timestamp;  // ISO 8601
            public double duration;   // seconds
            public string[] errors;
        }
    }
}
