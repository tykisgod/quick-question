// qq:record — Unity Editor recorder, run with the official CLI while the Editor is in Play mode:
//   unity command --project-path "$PWD" --json --no-banner eval_file -- --file "<absolute path to a copy of this file>" --timeout 60000
// Copy this file next to your recording output (not into Assets/), fill in the EDIT blocks, run it once.
// It only installs an EditorApplication.update callback and returns at once (eval runs on the main thread: never wait in it).
// Each game frame the callback poses the camera, renders Camera.main into a 1920x1080 RenderTexture (no Screen Space Overlay UI)
// and saves <OUT>/<clip>/f_00000.jpg ...; a still shot saves only its last frame, as <OUT>/stills/<name>.jpg.
// At the end it writes <OUT>/clips.json + <OUT>/done.txt (error.txt on an exception). Then: qq-frames-to-mp4.py --batch <OUT>.
// Time.captureFramerate locks game time to 1/FPS per frame, so slow rendering never drops or speeds up frames.
// eval_file code is a method body: no `using` lines, no class declarations, fully qualified type names, and it must end with `return ...;`.

// ===================== EDIT 1: output and size =====================
// Layout: keep this script in <topic>/ and record into <topic>/rec; a retake goes into <topic>/rec-retake.
// OUT is wiped at the start, so never put the script or anything else inside it. Absolute path, outside Assets/ and Temp/.
var OUT = @"C:\recordings\topic\rec";
// FPS = frames saved per second of game time. 30 for most clips; 60 or 120 for fast events (blasts, splashes): --batch
// then puts a real-time clip on the page and adds a slow-motion copy as a link. Frame counts and trigger frames below are
// in saved frames, so at FPS 120 ten seconds is 1200 frames.
const int W = 1920, H = 1080, FPS = 30;
var ONLY = new string[] { };                 // retake: the shots to record, e.g. new[] { "03_event" }; empty = all
// true: put the camera back after every capture (the game's camera controller keeps running and sees its own pose).
// false: leave the camera at the shot pose; use it with the camera controller switched off (see `driver` below), so
// camera-following systems (ocean / terrain LOD, streaming, TAA history) see the pose that is rendered.
const bool RESTORE_CAMERA = true;
// ===================================================================

if (!UnityEditor.EditorApplication.isPlaying) throw new System.Exception("enter Play mode first (editor_play, then poll editor_status until playing)");
if (System.AppDomain.CurrentDomain.GetData("qq.record.active") is bool running && running)
    throw new System.Exception("a recording is already running in this Editor (wait for its done.txt, or leave Play mode to stop it)");
var cam = UnityEngine.Camera.main;
if (cam == null) throw new System.Exception("no Camera.main");
// Refuse to wipe a folder that is not an earlier recording: a wrong OUT would delete other work.
if (System.IO.Directory.Exists(OUT) && System.IO.Directory.EnumerateFileSystemEntries(OUT).GetEnumerator().MoveNext()
    && !System.IO.File.Exists(System.IO.Path.Combine(OUT, "clips.json")) && !System.IO.File.Exists(System.IO.Path.Combine(OUT, "done.txt"))
    && !System.IO.File.Exists(System.IO.Path.Combine(OUT, "error.txt")))
    throw new System.Exception(OUT + " is not empty and is not an earlier recording; pick an empty folder");
// A retake must not wipe the full recording it fixes (frames, mp4/, sheets/): with ONLY set, an already encoded OUT
// is only reused when it is a retake folder.
if (ONLY.Length > 0 && System.IO.Directory.Exists(System.IO.Path.Combine(OUT, "mp4")) && !OUT.TrimEnd('\\', '/').EndsWith("-retake"))
    throw new System.Exception(OUT + " holds an encoded recording and ONLY is set: record the retake into <topic>/rec-retake, or empty ONLY to re-record everything");
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
// Methods and private fields of a showcase or debug component (developer tooling only; uncomment and set the type name):
// var show = System.Linq.Enumerable.First(UnityEngine.Object.FindObjectsByType<UnityEngine.MonoBehaviour>(UnityEngine.FindObjectsSortMode.None), m => m.GetType().Name == "MyShowcase");
// var NP = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public;
// void Call(string n, params object[] a) => show.GetType().GetMethod(n, NP).Invoke(show, a);
// void SetF(string n, object v) => show.GetType().GetField(n, NP).SetValue(show, v);   // match the field type: 2f for a float, not 2
// object GetF(string n) => show.GetType().GetField(n, NP).GetValue(show);

// Shots: (folder name, caption, frame count, still, step). step(f) runs every frame before the capture: trigger things at
// chosen frames (f == 0, f == 90 ...) and pose the camera every frame. still = true: the shot runs its frames (let streaming,
// shaders and animation settle) and saves only the last one as a screenshot.
var shots = new System.Collections.Generic.List<(string Name, string Title, int Frames, bool Still, System.Action<int> Step)>();
var state = new System.Collections.Generic.Dictionary<string, string>();   // readbacks for clips.json, in the reader's language ("eggs 0 -> 6"), not field names
// Keep each caption to one line (about 30 CJK characters or 60 Latin): longer titles wrap and cover more of the frame.
string Esc(string s) => (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r").Replace("\t", "\\t");
// Per-frame captions: Cap("03_event", f, "now: the gate opens") from a step; each caption shows until the next one. Written
// to <OUT>/<clip>/timeline.jsonl when the clip ends; qq-frames-to-mp4.py --batch burns it in as a bar at the bottom.
var captions = new System.Collections.Generic.Dictionary<string, System.Text.StringBuilder>();
void Cap(string clip, int frame, string text)
{
    if (!captions.TryGetValue(clip, out var sb)) captions[clip] = sb = new System.Text.StringBuilder();
    sb.Append("{\"f\":").Append(frame).Append(",\"caption\":\"").Append(Esc(text)).Append("\"}\n");
}
// If a camera controller script drives the camera every frame, posed shots switch it off at their f == 0, the
// default-camera shot switches it back on, and Finish re-enables it:
// var driver = cam.GetComponent("MyCameraController") as UnityEngine.Behaviour;

// ===================== EDIT 2: the shot list =====================
// Put whatever a shot needs (taking over the camera, setting the time of day) at f == 0 of that shot itself:
// with ONLY set, the other shots never run.
shots.Add(("01_default_camera", "Screenshot from the player's default camera", 20, true, f =>
{
    // if (f == 0) driver.enabled = true;
    // Don't pose anything: with the game's camera controller running this captures exactly what the player sees.
    // A hand-made "default" pose is always a little off (target, FOV, orbit basis).
}));
shots.Add(("02_overview", "What this clip shows, in the reader's language", 300, false, f =>
{
    // if (f == 0) driver.enabled = false;
    var focus = new UnityEngine.Vector3(0f, 0.5f, 0f);
    Look(Orbit(focus, Ease(-30f, 30f, f / 299f), 25f, 8f), focus, 40f);
}));
shots.Add(("03_event", "Trigger at second 3, keep filming for the aftermath", 450, false, f =>
{
    // if (f == 0) driver.enabled = false;
    if (f == 90) { /* call the real game code path here, e.g. a debug-panel method */ }
    if (f == 449) state["03_event"] = "read back what changed here (counts, HP, depth...)";
    var focus = new UnityEngine.Vector3(0f, 0.3f, 0f);
    Look(Orbit(focus, 0f, 40f, 5f), focus, 40f);
}));
// =================================================================
foreach (var name in ONLY)
    if (!shots.Exists(s => s.Name == name)) throw new System.Exception("ONLY names a shot that is not in the list: " + name);
if (ONLY.Length > 0) shots.RemoveAll(s => System.Array.IndexOf(ONLY, s.Name) < 0);
if (shots.Count == 0) throw new System.Exception("no shots to record");

int si = 0, sf = 0, last = -1;
var meta = new System.Collections.Generic.List<string>();
UnityEditor.EditorApplication.CallbackFunction tick = null;
void Finish(string why)
{
    UnityEditor.EditorApplication.update -= tick;
    UnityEngine.Time.captureFramerate = 0;
    System.AppDomain.CurrentDomain.SetData("qq.record.active", false);
    // driver.enabled = true;   // if posed shots switch the camera controller off
    rt.Release(); UnityEngine.Object.Destroy(rt); UnityEngine.Object.Destroy(tex);
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
        var dir = System.IO.Path.Combine(OUT, s.Still ? "stills" : s.Name);
        if (sf == 0) System.IO.Directory.CreateDirectory(dir);
        var pos = cam.transform.position; var rot = cam.transform.rotation; float fov = cam.fieldOfView; var rect = cam.rect;
        s.Step(sf);
        if (!s.Still || sf == s.Frames - 1)
        {
            cam.rect = new UnityEngine.Rect(0f, 0f, 1f, 1f);   // a viewport rect would render into part of the texture only
            var previous = cam.targetTexture;
            cam.targetTexture = rt; cam.ResetAspect(); cam.Render(); cam.targetTexture = previous;
            var active = UnityEngine.RenderTexture.active;
            UnityEngine.RenderTexture.active = rt;
            tex.ReadPixels(new UnityEngine.Rect(0, 0, W, H), 0, 0); tex.Apply(false);
            UnityEngine.RenderTexture.active = active;
            var file = s.Still ? s.Name + ".jpg" : $"f_{sf:00000}.jpg";
            System.IO.File.WriteAllBytes(System.IO.Path.Combine(dir, file), tex.EncodeToJPG(90));
            cam.rect = rect; cam.ResetAspect();
        }
        if (RESTORE_CAMERA) { cam.transform.SetPositionAndRotation(pos, rot); cam.fieldOfView = fov; }
        sf++;
        if (sf >= s.Frames)
        {
            if (!s.Still && captions.TryGetValue(s.Name, out var lines))
                System.IO.File.WriteAllText(System.IO.Path.Combine(dir, "timeline.jsonl"), lines.ToString(), new System.Text.UTF8Encoding(false));
            state.TryGetValue(s.Name, out var readback);
            meta.Add("{\"name\":\"" + Esc(s.Name) + "\",\"title\":\"" + Esc(s.Title) + "\",\"frames\":" + sf + ",\"fps\":" + FPS
                     + (s.Still ? ",\"still\":true,\"image\":\"stills/" + Esc(s.Name) + ".jpg\"" : "")
                     + ",\"state\":\"" + Esc(readback) + "\"}");
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
System.AppDomain.CurrentDomain.SetData("qq.record.active", true);
UnityEngine.Time.captureFramerate = FPS;
UnityEditor.EditorApplication.update += tick;
return "recording " + shots.Count + " shots into " + OUT;
