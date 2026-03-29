using System;
using System.Collections.Generic;
using System.Globalization;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEditor.TestTools.TestRunner.Api;
using UnityEngine;

namespace Tykit
{
    [InitializeOnLoad]
    public static class TestCommands
    {
        private static TestRunnerApi _api;
        private static ResultCollector _collector;

        static TestCommands()
        {
            // After domain reload, find surviving ScriptableObject collector and re-register callbacks
            var existing = Resources.FindObjectsOfTypeAll<ResultCollector>();
            if (existing.Length > 0)
            {
                _collector = existing[0];
                _api = ScriptableObject.CreateInstance<TestRunnerApi>();
                _api.RegisterCallbacks(_collector);
            }

            RegisterCommands();
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "run-tests",
                    "Start EditMode or PlayMode tests and return a runId for polling.",
                    "tests.run",
                    true,
                    CommandSchema.Object(
                        ("mode", CommandSchema.String("Test mode.", "editmode", "playmode", "play", "all")),
                        ("filter", CommandSchema.String("Semicolon-separated test names.")),
                        ("assemblyNames", CommandSchema.String("Semicolon-separated assembly names.")))),
                RunTests);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "get-test-result",
                    "Poll structured test results for the current or requested run.",
                    "tests.query",
                    false,
                    CommandSchema.Object(
                        ("runId", CommandSchema.String("Optional test run identifier.")))),
                GetTestResult);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "get-compile-result",
                    "Read structured compile results from CompileWatcher.",
                    "editor.state",
                    false,
                    CommandSchema.Object(
                        ("afterTimestamp", CommandSchema.String("Optional ISO 8601 freshness threshold.")))),
                GetCompileResult);
            CommandRegistry.Register(
                CommandRegistry.Describe("trigger-refresh", "Call AssetDatabase.Refresh() and return immediately.", "assets.mutate", true),
                _ => TriggerRefresh());
            CommandRegistry.Register(
                CommandRegistry.Describe("request-script-reload", "Force a Unity script reload.", "editor.control", true),
                _ => RequestScriptReload());
        }

        /// <summary>
        /// Read the structured compilation result from CompileWatcher.
        /// Returns state, timestamp, duration, and error list.
        ///
        /// Optional args:
        ///   afterTimestamp (string, ISO 8601) — if the current result is not newer than
        ///     this timestamp, returns {"state":"waiting"} so the caller knows to poll again.
        /// </summary>
        private static JObject GetCompileResult(JObject args)
        {
            var afterTimestamp = args?["afterTimestamp"]?.Value<string>();

            var status = CompileWatcher.ReadStatus();
            if (status == null)
                return CommandRegistry.Ok(new JObject
                {
                    ["state"] = "unknown",
                    ["message"] = "No compile_status.json found (first compile not yet completed)"
                });

            // If caller wants a result newer than a specific timestamp, check freshness
            if (!string.IsNullOrEmpty(afterTimestamp)
                && DateTime.TryParse(afterTimestamp, null,
                    DateTimeStyles.RoundtripKind, out var threshold)
                && DateTime.TryParse(status.timestamp, null,
                    DateTimeStyles.RoundtripKind, out var current)
                && current <= threshold)
            {
                return CommandRegistry.Ok(new JObject
                {
                    ["state"] = "waiting",
                    ["isCompiling"] = EditorApplication.isCompiling,
                    ["lastTimestamp"] = status.timestamp
                });
            }

            var result = new JObject
            {
                ["state"] = status.state,
                ["timestamp"] = status.timestamp,
                ["duration"] = status.duration,
                ["isCompiling"] = EditorApplication.isCompiling
            };

            if (status.errors != null && status.errors.Length > 0)
            {
                var arr = new JArray();
                foreach (var e in status.errors) arr.Add(e);
                result["errors"] = arr;
            }
            else
            {
                result["errors"] = new JArray();
            }

            return CommandRegistry.Ok(result);
        }

        /// <summary>
        /// Force a domain reload regardless of whether Unity's file watcher detected changes.
        /// Use when trigger-refresh reports "no code changes" but files were modified externally.
        /// </summary>
        private static JObject RequestScriptReload()
        {
            EditorUtility.RequestScriptReload();
            return CommandRegistry.Ok("Script reload requested. Poll get-compile-result for status.");
        }

        /// <summary>
        /// Trigger AssetDatabase.Refresh() and return immediately.
        /// Poll get-compile-result or compile-status to track progress.
        /// </summary>
        private static JObject TriggerRefresh()
        {
            AssetDatabase.Refresh();
            return CommandRegistry.Ok("AssetDatabase.Refresh() triggered. Poll get-compile-result for status.");
        }

        /// <summary>
        /// Run tests via Unity Test Runner API.
        /// args: {"mode":"editmode|playmode|all", "filter":"TestName1;TestName2", "assemblyNames":"Asm1;Asm2"}
        /// Returns a runId for polling via get-test-result.
        /// </summary>
        private static JObject RunTests(JObject args)
        {
            // Auto-save dirty scenes to prevent the modal "Save Scene" dialog
            // which blocks the main thread and freezes tykit
            if (EditorSceneManager.GetActiveScene().isDirty)
                EditorSceneManager.SaveOpenScenes();

            // Always create fresh api + collector (following TestWatcher pattern)
            // Reusing stale instances leaves dirty state across EditMode→PlayMode transitions, causing PlayMode startup failures
            var oldCollectors = Resources.FindObjectsOfTypeAll<ResultCollector>();
            foreach (var old in oldCollectors)
                ScriptableObject.DestroyImmediate(old);

            _api = ScriptableObject.CreateInstance<TestRunnerApi>();
            _collector = ScriptableObject.CreateInstance<ResultCollector>();
            _collector.hideFlags = HideFlags.HideAndDontSave;
            _api.RegisterCallbacks(_collector);

            var runId = Guid.NewGuid().ToString("N").Substring(0, 8);
            var currentScenePath = EditorSceneManager.GetActiveScene().path;
            _collector.Reset(runId, currentScenePath);

            var modeStr = args?["mode"]?.Value<string>()?.ToLower() ?? "editmode";
            TestMode mode;
            switch (modeStr)
            {
                case "playmode":
                case "play":
                    mode = TestMode.PlayMode;
                    break;
                case "all":
                    mode = TestMode.EditMode | TestMode.PlayMode;
                    break;
                default:
                    mode = TestMode.EditMode;
                    break;
            }

            var filter = new Filter { testMode = mode };

            // Support semicolon-separated filter names (compatible with TestWatcher)
            var testFilter = args?["filter"]?.Value<string>();
            if (!string.IsNullOrEmpty(testFilter))
                filter.testNames = testFilter.Split(';');

            // Support semicolon-separated assembly names
            var assemblyNames = args?["assemblyNames"]?.Value<string>();
            if (!string.IsNullOrEmpty(assemblyNames))
                filter.assemblyNames = assemblyNames.Split(';');

            _api.Execute(new ExecutionSettings(filter));

            return CommandRegistry.Ok(new JObject
            {
                ["message"] = $"Tests started ({modeStr})",
                ["mode"] = modeStr,
                ["runId"] = runId
            });
        }

        /// <summary>
        /// Get structured test result. Poll this after run-tests.
        /// Optional args: {"runId":"abc12345"} — if provided and doesn't match current run, returns "waiting".
        /// Terminal states: "passed", "failed". Non-terminal: "idle", "running", "waiting".
        /// </summary>
        private static JObject GetTestResult(JObject args)
        {
            if (_collector == null)
                return CommandRegistry.Ok(new JObject { ["state"] = "idle" });

            var requestedRunId = args?["runId"]?.Value<string>();
            if (!string.IsNullOrEmpty(requestedRunId) && _collector.RunId != requestedRunId)
                return CommandRegistry.Ok(new JObject
                {
                    ["state"] = "waiting",
                    ["message"] = "Requested runId does not match current run"
                });

            var result = new JObject
            {
                ["state"] = _collector.State,
                ["runId"] = _collector.RunId,
                ["mode"] = _collector.Mode,
                ["total"] = _collector.Total,
                ["passed"] = _collector.Passed,
                ["failed"] = _collector.Failed,
                ["skipped"] = _collector.Skipped,
                ["duration"] = _collector.Duration
            };

            var failures = _collector.Failures;
            if (failures.Count > 0)
            {
                var arr = new JArray();
                foreach (var f in failures) arr.Add(f);
                result["failures"] = arr;
            }

            return CommandRegistry.Ok(result);
        }

        /// <summary>
        /// ScriptableObject-based result collector that survives domain reload.
        /// Implements ICallbacks for test lifecycle and IErrorCallbacks for build/compile errors.
        /// </summary>
        private class ResultCollector : ScriptableObject, ICallbacks, IErrorCallbacks
        {
            [SerializeField] private int _passed;
            [SerializeField] private int _failed;
            [SerializeField] private int _skipped;
            [SerializeField] private int _total;
            [SerializeField] private string _state = "idle";
            [SerializeField] private string _mode = "";
            [SerializeField] private string _runId = "";
            [SerializeField] private string _sceneToRestore = "";
            [SerializeField] private float _startTime;
            [SerializeField] private float _duration;
            [SerializeField] private List<string> _failures = new();

            public string State => _state;
            public string RunId => _runId;
            public string Mode => _mode;
            public int Total => _total;
            public int Passed => _passed;
            public int Failed => _failed;
            public int Skipped => _skipped;
            public float Duration => _duration;
            public List<string> Failures => _failures;

            public void Reset(string runId, string sceneToRestore = "")
            {
                _passed = _failed = _skipped = _total = 0;
                _duration = 0f;
                _state = "running";
                _runId = runId;
                _sceneToRestore = sceneToRestore;
                _failures.Clear();
            }

            public void RunStarted(ITestAdaptor testsToRun)
            {
                _mode = testsToRun.TestMode.ToString();
                _startTime = Time.realtimeSinceStartup;
                Debug.Log($"[Tykit] {_mode} tests starting... (runId: {_runId})");
            }

            public void RunFinished(ITestResultAdaptor result)
            {
                _duration = Time.realtimeSinceStartup - _startTime;
                _state = _failed > 0 ? "failed" : "passed";

                var color = _failed > 0 ? "red" : "green";
                Debug.Log($"<color={color}>[Tykit:TestRunner] {_mode} {_state.ToUpper()}: " +
                          $"total={_total} passed={_passed} failed={_failed} skipped={_skipped} " +
                          $"duration={_duration:F1}s</color>");

                foreach (var f in _failures)
                    Debug.LogError($"[Tykit:TestRunner] {f}");

                // Restore original scene after PlayMode tests
                RestoreScene();
            }

            public void TestStarted(ITestAdaptor test) { }

            public void TestFinished(ITestResultAdaptor result)
            {
                if (result.HasChildren) return;
                _total++;
                switch (result.TestStatus)
                {
                    case TestStatus.Passed:
                        _passed++;
                        break;
                    case TestStatus.Failed:
                        _failed++;
                        _failures.Add($"FAIL: {result.Test.Name} — {result.Message}");
                        break;
                    case TestStatus.Skipped:
                        _skipped++;
                        break;
                }
            }

            /// <summary>
            /// Called when test build/compile fails before tests can run.
            /// Maps to "failed" terminal state so polling doesn't hang.
            /// </summary>
            public void OnError(string message)
            {
                _duration = Time.realtimeSinceStartup - _startTime;
                _state = "failed";
                _failed++;
                _failures.Add($"ERROR: {message}");
                Debug.LogError($"[Tykit:TestRunner] Build/compile error: {message}");

                RestoreScene();
            }

            private void RestoreScene()
            {
                if (string.IsNullOrEmpty(_sceneToRestore)) return;

                if (EditorApplication.isPlaying)
                {
                    // Cannot call EditorSceneManager.OpenScene while in Play Mode; restore after exiting
                    void OnPlayModeChanged(PlayModeStateChange state)
                    {
                        if (state != PlayModeStateChange.EnteredEditMode) return;
                        EditorApplication.playModeStateChanged -= OnPlayModeChanged;
                        DoRestoreScene();
                    }
                    EditorApplication.playModeStateChanged += OnPlayModeChanged;
                }
                else
                {
                    EditorApplication.delayCall += DoRestoreScene;
                }
            }

            private void DoRestoreScene()
            {
                if (string.IsNullOrEmpty(_sceneToRestore)) return;

                var currentScene = EditorSceneManager.GetActiveScene();
                if (currentScene.path == _sceneToRestore) return;

                EditorSceneManager.OpenScene(_sceneToRestore);
                Debug.Log($"[Tykit:TestRunner] Restored scene: {_sceneToRestore}");
            }
        }
    }
}
