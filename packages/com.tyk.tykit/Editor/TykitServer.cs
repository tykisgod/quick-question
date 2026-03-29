// TykitServer.cs
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEngine;

namespace Tykit
{
    [InitializeOnLoad]
    public static class TykitServer
    {
        private const int PortRangeBase = 8090;
        private const int PortRangeSize = 64; // 8090-8153

        private static HttpListener _listener;
        private static Thread _listenerThread;
        private static int _activePort;
        private static readonly ConcurrentQueue<RequestContext> _requestQueue = new();

        private static readonly string ServerInfoFile = Path.Combine(
            Application.dataPath, "..", "Temp", "tykit.json");

        static TykitServer()
        {
            TykitBootstrap.EnsureCommandsRegistered();
            Start();
            EditorApplication.update += ProcessQueue;
            AssemblyReloadEvents.beforeAssemblyReload += OnBeforeReload;
            EditorApplication.quitting += OnQuitting;
        }

        private static void Start()
        {
            // Primary port: deterministic hash of project path
            // Fallback: try nearby ports if primary is occupied
            int preferredPort = GetPreferredPort();
            int maxPort = PortRangeBase + PortRangeSize - 1;

            // Try preferred port first, then scan from there
            int[] portsToTry = new int[PortRangeSize];
            portsToTry[0] = preferredPort;
            int idx = 1;
            for (int p = PortRangeBase; p <= maxPort && idx < PortRangeSize; p++)
            {
                if (p != preferredPort)
                    portsToTry[idx++] = p;
            }

            for (int i = 0; i < portsToTry.Length; i++)
            {
                int port = portsToTry[i];
                try
                {
                    _listener = new HttpListener();
                    _listener.Prefixes.Add($"http://localhost:{port}/");
                    _listener.Start();
                    _activePort = port;

                    _listenerThread = new Thread(ListenLoop) { IsBackground = true };
                    _listenerThread.Start();

                    WriteServerInfo();
                    string hint = port == preferredPort ? "preferred" : $"fallback, preferred was {preferredPort}";
                    Debug.Log($"[tykit] Listening on http://localhost:{port}/ ({hint})");
                    return;
                }
                catch (Exception)
                {
                    _listener?.Close();
                }
            }
            Debug.LogError($"[tykit] Failed to start: all ports {PortRangeBase}-{maxPort} in use");
        }

        /// <summary>
        /// Deterministic port from project path hash.
        /// Same algorithm in tykit_mcp.py — keep in sync.
        /// </summary>
        private static int GetPreferredPort()
        {
            string projectPath = Path.GetFullPath(Path.Combine(Application.dataPath, ".."));
            uint hash = StableHash(projectPath);
            return PortRangeBase + (int)(hash % (uint)PortRangeSize);
        }

        /// <summary>
        /// FNV-1a 32-bit hash — simple, deterministic, no crypto dependency.
        /// </summary>
        private static uint StableHash(string s)
        {
            uint h = 2166136261u;
            foreach (char c in s)
            {
                h ^= c;
                h *= 16777619u;
            }
            return h;
        }

        private static void OnBeforeReload()
        {
            // Drain queue — respond with error to in-flight requests
            while (_requestQueue.TryDequeue(out var rc))
            {
                Respond(rc.HttpContext, 503,
                    new JObject { ["success"] = false, ["error"] = "Domain reload in progress" }.ToString());
            }
            StopListener();
        }

        private static void OnQuitting()
        {
            StopListener();
            try { File.Delete(ServerInfoFile); } catch { }
        }

        private static void StopListener()
        {
            try
            {
                _listener?.Stop();
                _listener?.Close();
            }
            catch { }
            _listener = null;
        }

        private static void ListenLoop()
        {
            while (_listener != null && _listener.IsListening)
            {
                try
                {
                    var ctx = _listener.GetContext();
                    string body;
                    using (var reader = new StreamReader(ctx.Request.InputStream))
                        body = reader.ReadToEnd();

                    // /ping responds immediately (no Unity API needed)
                    if (ctx.Request.Url.AbsolutePath == "/ping")
                    {
                        var ping = new JObject
                        {
                            ["status"] = "ok",
                            ["port"] = _activePort,
                            ["pid"] = System.Diagnostics.Process.GetCurrentProcess().Id,
                            ["project"] = Path.GetFullPath(Path.Combine(Application.dataPath, ".."))
                        };
                        Respond(ctx, 200, ping.ToString());
                        continue;
                    }

                    _requestQueue.Enqueue(new RequestContext
                    {
                        HttpContext = ctx,
                        Body = body,
                        EnqueueTime = DateTime.UtcNow
                    });
                }
                catch (HttpListenerException) { break; }
                catch (ObjectDisposedException) { break; }
                catch (Exception e)
                {
                    Debug.LogWarning($"[tykit] Listener error: {e.Message}");
                }
            }
        }

        private static void ProcessQueue()
        {
            while (_requestQueue.TryDequeue(out var rc))
            {
                // Timeout stale requests
                if ((DateTime.UtcNow - rc.EnqueueTime).TotalSeconds > 30)
                {
                    Respond(rc.HttpContext, 504,
                        new JObject { ["success"] = false, ["error"] = "Request timed out in queue" }.ToString());
                    continue;
                }

                try
                {
                    var result = CommandRegistry.Execute(rc.Body);
                    Respond(rc.HttpContext, result["success"]?.Value<bool>() == true ? 200 : 400, result.ToString());
                }
                catch (Exception e)
                {
                    var err = new JObject { ["success"] = false, ["error"] = e.ToString() };
                    Respond(rc.HttpContext, 500, err.ToString());
                }
            }
        }

        private static void Respond(HttpListenerContext ctx, int statusCode, string json)
        {
            try
            {
                var response = ctx.Response;
                response.StatusCode = statusCode;
                response.ContentType = "application/json";
                var buffer = Encoding.UTF8.GetBytes(json);
                response.ContentLength64 = buffer.Length;
                response.OutputStream.Write(buffer, 0, buffer.Length);
                response.Close();
            }
            catch (Exception e)
            {
                Debug.LogWarning($"[tykit] Response error: {e.Message}");
            }
        }

        private static void WriteServerInfo()
        {
            try
            {
                var info = new JObject
                {
                    ["port"] = _activePort,
                    ["pid"] = System.Diagnostics.Process.GetCurrentProcess().Id,
                    ["project"] = Path.GetFullPath(Path.Combine(Application.dataPath, "..")),
                    ["timestamp"] = DateTime.Now.ToString("o")
                };
                File.WriteAllText(ServerInfoFile, info.ToString());
            }
            catch { }
        }

        private class RequestContext
        {
            public HttpListenerContext HttpContext;
            public string Body;
            public DateTime EnqueueTime;
        }
    }
}
