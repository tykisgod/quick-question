// qq:record — Unity Editor recorder, run with the official CLI while the Editor is in Play mode:
//   unity command --project-path "$PWD" --json --no-banner eval_file -- --file "<absolute path to a copy of this file>" --timeout 60000
// Copy this file next to your recording output (not into Assets/), fill in the two EDIT blocks, run it once.
// It only installs an EditorApplication.update callback and returns at once (eval runs on the main thread: never wait in it).
// Each game frame the callback poses the camera, renders Camera.main into a 1920x1080 RenderTexture (no Screen Space Overlay UI),
// saves <OUT>/<clip>/f_00000.jpg ..., and writes <OUT>/clips.json + <OUT>/done.txt at the end (error.txt on an exception).
// Time.captureFramerate locks game time to 1/FPS per frame, so slow rendering never drops or speeds up frames.
// eval_file code is a method body: no `using` lines, no class declarations, fully qualified type names, and it must end with `return ...;`.

// ===================== EDIT 1: output and size =====================
var OUT = @"C:\path\to\recording";          // absolute; outside Assets/ and Temp/ (Temp/ can be wiped by Unity)
const int W = 1920, H = 1080, FPS = 30;      // FPS = frames saved per second of game time; 120 + encode at 30 = 4x slow motion
// ===================================================================

if (!UnityEditor.EditorApplication.isPlaying) throw new System.Exception("enter Play mode first (editor_play, then poll editor_status until playing)");
var cam = UnityEngine.Camera.main;
if (cam == null) throw new System.Exception("no Camera.main");
var rt = new UnityEngine.RenderTexture(W, H, 24);
var tex = new UnityEngine.Texture2D(W, H, UnityEngine.TextureFormat.RGB24, false);

// Camera helpers. Look(pos, target) puts the camera at pos looking at target; Orbit gives a point on a sphere around a focus.
void Look(UnityEngine.Vector3 pos, UnityEngine.Vector3 target, float fov)
{
    cam.fieldOfView = fov;
    cam.transform.SetPositionAndRotation(pos, UnityEngine.Quaternion.LookRotation(target - pos));
}
UnityEngine.Vector3 Orbit(UnityEngine.Vector3 focus, float yaw, float pitch, float distance)
    => focus + UnityEngine.Quaternion.Euler(pitch, yaw, 0f) * new UnityEngine.Vector3(0f, 0f, -distance);
float Ease(float a, float b, float t) => UnityEngine.Mathf.Lerp(a, b, UnityEngine.Mathf.SmoothStep(0f, 1f, UnityEngine.Mathf.Clamp01(t)));
// Private fields / methods of a showcase or debug component (developer tooling only):
// var show = System.Linq.Enumerable.First(UnityEngine.Object.FindObjectsByType<UnityEngine.MonoBehaviour>(UnityEngine.FindObjectsSortMode.None), m => m.GetType().Name == "MyShowcase");
// var NP = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public;
// void Call(string n, params object[] a) => show.GetType().GetMethod(n, NP).Invoke(show, a);

// Shots: (folder name, caption for the video, frame count, step). step(f) runs every frame before the capture:
// trigger things at chosen frames (f == 0, f == 90 ...) and pose the camera every frame.
var shots = new System.Collections.Generic.List<(string Name, string Title, int Frames, System.Action<int> Step)>();
var state = new System.Collections.Generic.Dictionary<string, string>();   // optional readbacks written into clips.json

// ===================== EDIT 2: the shot list =====================
shots.Add(("01_overview", "What this clip shows, in the reader's language", 300, f =>
{
    var focus = new UnityEngine.Vector3(0f, 0.5f, 0f);
    Look(Orbit(focus, Ease(-30f, 30f, f / 299f), 25f, 8f), focus, 40f);
}));
shots.Add(("02_event", "Trigger at second 3, keep filming for the aftermath", 450, f =>
{
    if (f == 90) { /* call the real game code path here, e.g. a debug-panel method */ }
    if (f == 449) state["02_event"] = "read back what changed here (counts, HP, depth...)";
    var focus = new UnityEngine.Vector3(0f, 0.3f, 0f);
    Look(Orbit(focus, 0f, 40f, 5f), focus, 40f);
}));
// =================================================================

// If the game drives the camera every frame (a camera controller script), disable it here and re-enable it in Finish:
// var driver = cam.GetComponent("MyCameraController") as UnityEngine.Behaviour; if (driver != null) driver.enabled = false;

int si = 0, sf = 0, last = -1;
var meta = new System.Collections.Generic.List<string>();
UnityEditor.EditorApplication.CallbackFunction tick = null;
string Esc(string s) => (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n");
void Finish(string why)
{
    UnityEditor.EditorApplication.update -= tick;
    UnityEngine.Time.captureFramerate = 0;
    System.IO.File.WriteAllText(System.IO.Path.Combine(OUT, "clips.json"), "[" + string.Join(",\n", meta) + "]", new System.Text.UTF8Encoding(false));
    System.IO.File.WriteAllText(System.IO.Path.Combine(OUT, "done.txt"), why);
}
tick = () =>
{
    try
    {
        if (!UnityEditor.EditorApplication.isPlaying) { Finish("stopped at shot " + si); return; }
        if (UnityEngine.Time.frameCount == last) return;      // one capture per game frame
        last = UnityEngine.Time.frameCount;
        var s = shots[si];
        var dir = System.IO.Path.Combine(OUT, s.Name);
        if (sf == 0) System.IO.Directory.CreateDirectory(dir);
        var pos = cam.transform.position; var rot = cam.transform.rotation; float fov = cam.fieldOfView; var rect = cam.rect;
        s.Step(sf);
        cam.rect = new UnityEngine.Rect(0f, 0f, 1f, 1f);   // a viewport rect would render into part of the texture only
        var previous = cam.targetTexture;
        cam.targetTexture = rt; cam.ResetAspect(); cam.Render(); cam.targetTexture = previous;
        var active = UnityEngine.RenderTexture.active;
        UnityEngine.RenderTexture.active = rt;
        tex.ReadPixels(new UnityEngine.Rect(0, 0, W, H), 0, 0); tex.Apply(false);
        UnityEngine.RenderTexture.active = active;
        System.IO.File.WriteAllBytes(System.IO.Path.Combine(dir, $"f_{sf:00000}.jpg"), tex.EncodeToJPG(90));
        cam.transform.SetPositionAndRotation(pos, rot); cam.fieldOfView = fov; cam.rect = rect; cam.ResetAspect();
        sf++;
        if (sf >= s.Frames)
        {
            state.TryGetValue(s.Name, out var readback);
            meta.Add("{\"name\":\"" + Esc(s.Name) + "\",\"title\":\"" + Esc(s.Title) + "\",\"frames\":" + sf + ",\"fps\":" + FPS + ",\"state\":\"" + Esc(readback) + "\"}");
            si++; sf = 0;
            if (si >= shots.Count) Finish("ok");
        }
    }
    catch (System.Exception e)
    {
        System.IO.File.WriteAllText(System.IO.Path.Combine(OUT, "error.txt"), e.ToString());
        Finish("error at shot " + si);
    }
};
if (System.IO.Directory.Exists(OUT)) System.IO.Directory.Delete(OUT, true);
System.IO.Directory.CreateDirectory(OUT);
UnityEngine.Time.captureFramerate = FPS;
UnityEditor.EditorApplication.update += tick;
return "recording " + shots.Count + " shots into " + OUT;
