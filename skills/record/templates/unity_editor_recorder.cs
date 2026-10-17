// qq:record — Unity Editor recorder, run with the official CLI while the Editor is in Play mode:
//   unity command --project-path "$PWD" --json --no-banner eval_file -- --file "<absolute path to a copy of this file>" --timeout 60000
// Copy this file next to your recording output (not into Assets/), fill in the EDIT blocks, run it once.
// It only installs an EditorApplication.update callback and returns at once (eval runs on the main thread: never wait in it).
// Each game frame the callback poses the camera, renders Camera.main into a 1920x1080 RenderTexture (no Screen Space Overlay UI)
// and saves <OUT>/<clip>/f_00000.jpg ...; a still shot saves only its last frame, as <OUT>/stills/<name>.jpg.
// At the end it writes <OUT>/clips.json + <OUT>/done.txt (error.txt on an exception). Then: qq-frames-to-mp4.py --batch <OUT>.
// Time.captureFramerate locks game time to 1/FPS per frame, so slow rendering never drops or speeds up frames.
// eval_file code is a method body: no `using` lines, no class declarations, fully qualified type names, and it must end with `return ...;`.
// Edit OUT with a verbatim string (@"C:\rec\x") and, when a script rewrites this file, use raw strings there too: sed on a
// Windows path turns "\r" into a carriage return and silently records into the wrong folder.

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
bool HoldsAnything(string dir) => System.IO.Directory.Exists(dir) && System.Linq.Enumerable.Any(System.IO.Directory.EnumerateFileSystemEntries(dir));
// Refuse to wipe a folder that is not an earlier recording: a wrong OUT would delete other work.
if (HoldsAnything(OUT)
    && !System.IO.File.Exists(System.IO.Path.Combine(OUT, "clips.json")) && !System.IO.File.Exists(System.IO.Path.Combine(OUT, "done.txt"))
    && !System.IO.File.Exists(System.IO.Path.Combine(OUT, "error.txt")))
    throw new System.Exception(OUT + " is not empty and is not an earlier recording; pick an empty folder");
// A retake must not wipe the takes it fixes: with ONLY set, OUT is wiped only when it is a retake folder (or empty).
// Even a partly recorded, not yet encoded take holds the good shots. A second retake round wipes the first one's
// rec-retake: record it into a new folder (rec2-retake) when the page still points at the first.
if (ONLY.Length > 0 && HoldsAnything(OUT) && !OUT.TrimEnd('\\', '/').EndsWith("-retake"))
    throw new System.Exception(OUT + " holds a recording and ONLY is set: record the retake into <topic>/rec-retake, or empty ONLY to re-record everything");
var rt = new UnityEngine.RenderTexture(W, H, 24);
var tex = new UnityEngine.Texture2D(W, H, UnityEngine.TextureFormat.RGB24, false);

// ---- Camera helpers ----
// Up(p): which way is up at p. World up for flat scenes; replace it on a round world (planet up at p) or a tilted platform.
UnityEngine.Vector3 Up(UnityEngine.Vector3 p) => UnityEngine.Vector3.up;
void Look(UnityEngine.Vector3 pos, UnityEngine.Vector3 target, float fov)
{
    cam.fieldOfView = fov;
    cam.transform.SetPositionAndRotation(pos, UnityEngine.Quaternion.LookRotation(target - pos, Up(pos)));
}
// Orbit works in world axes and ignores Up: on a round world or a tilted platform build the orbit from Up(focus) instead.
UnityEngine.Vector3 Orbit(UnityEngine.Vector3 focus, float yaw, float pitch, float distance)
    => focus + UnityEngine.Quaternion.Euler(pitch, yaw, 0f) * new UnityEngine.Vector3(0f, 0f, -distance);
float Ease(float a, float b, float t) => UnityEngine.Mathf.Lerp(a, b, UnityEngine.Mathf.SmoothStep(0f, 1f, UnityEngine.Mathf.Clamp01(t)));
// Occlusion: a fixed camera offset in a built-up scene ends up inside a wall or behind a house sooner or later. Fill
// `occluders` with the renderer bounds of whatever can stand in front of the subject (buildings, props; not the ground,
// colliders cover that), and let ClearEye / Follow / Fixed pick a viewpoint that sees the target.
// Pass the subject's own root as `self` when the subject has renderers or colliders of its own (a character, the prop or
// building being filmed): those never count as blocking. Everything else does, including the building the subject stands in.
var occluders = new System.Collections.Generic.List<(UnityEngine.Bounds Box, UnityEngine.Transform Owner)>();
void AddOccluders(UnityEngine.Transform root, System.Func<UnityEngine.Transform, bool> pick)
{
    foreach (UnityEngine.Transform child in root)
        if (pick(child))
            foreach (var r in child.GetComponentsInChildren<UnityEngine.Renderer>()) occluders.Add((r.bounds, r.transform));
}
// e.g. AddOccluders(UnityEngine.GameObject.Find("Town").transform, t => t.name.StartsWith("Bld_") || t.name.StartsWith("Prop_"));
bool Blocked(UnityEngine.Vector3 eye, UnityEngine.Vector3 target, UnityEngine.Transform self)
{
    var d = target - eye; float len = d.magnitude;
    var ray = new UnityEngine.Ray(eye, d / len);
    foreach (var o in occluders)
    {
        if (self != null && o.Owner.IsChildOf(self)) continue;
        if (o.Box.Contains(eye)) return true;
        if (o.Box.Contains(target)) continue;                   // the target sits in it (on a bench, in a doorway): the eye is outside
        if (o.Box.IntersectRay(ray, out float hit) && hit < len - 0.3f) return true;
    }
    // Terrain and anything else with a collider. A hit just short of the target reaches it; a hit within 1.2 m of the target
    // and not above it is the ground it stands on (a wall next to the target is hit above the target's height and still blocks).
    var up = Up(target);
    foreach (var h in UnityEngine.Physics.RaycastAll(eye, d / len, len, ~0, UnityEngine.QueryTriggerInteraction.Ignore))
    {
        if (h.distance > len - 0.3f || (self != null && h.transform.IsChildOf(self))) continue;
        var off = h.point - target;
        if (off.magnitude < 1.2f && UnityEngine.Vector3.Dot(off, up) < 0.1f) continue;
        return true;
    }
    return false;
}
// First viewpoint that sees `target`: directions turning away from `prefer` (0, ±30°, ±60° … 180°) × heights (1, 1.6, 2.4 × height).
UnityEngine.Vector3 ClearEye(UnityEngine.Vector3 target, UnityEngine.Vector3 prefer, float dist, float height, UnityEngine.Transform self = null)
{
    var up = Up(target);
    prefer = UnityEngine.Vector3.ProjectOnPlane(prefer, up).normalized;
    if (prefer.sqrMagnitude < 1e-4f) prefer = -UnityEngine.Vector3.ProjectOnPlane(cam.transform.forward, up).normalized;
    foreach (float lift in new[] { 1f, 1.6f, 2.4f })
    foreach (float yaw in new[] { 0f, 30f, -30f, 60f, -60f, 90f, -90f, 120f, -120f, 150f, -150f, 180f })
    {
        var eye = target + UnityEngine.Quaternion.AngleAxis(yaw, up) * prefer * dist + up * height * lift;
        if (!Blocked(eye, target, self)) return eye;
    }
    return target + prefer * dist + up * height * 2.4f;          // nothing clear: highest preferred view
}
// Fixed(f, target, ...): pick a clear viewpoint at f == 0 and hold it. Follow(f, subject, ...): keep the offset, re-check the
// line of sight three times a second (soon enough to leave a wall, rare enough not to flicker), move to a new clear offset when
// blocked, and smooth the position (about 0.3 s to settle) so the switch is a short pan, not a cut.
// Both work in world space. On a moving platform (a ship) pick the eye once with ClearEye, keep it in the platform's local
// space (InverseTransformPoint) and convert it back with TransformPoint every frame (§4 of reference/unity.md).
UnityEngine.Vector3 eyeNow = UnityEngine.Vector3.zero, offset = UnityEngine.Vector3.zero;
void Fixed(int f, UnityEngine.Vector3 target, UnityEngine.Vector3 prefer, float dist, float height, float fov, UnityEngine.Transform self = null)
{
    if (f == 0) eyeNow = ClearEye(target, prefer, dist, height, self);
    Look(eyeNow, target, fov);
}
void Follow(int f, UnityEngine.Vector3 subject, UnityEngine.Vector3 prefer, float dist, float height, float fov, UnityEngine.Transform self = null)
{
    var target = subject + Up(subject) * 0.8f;
    if (f == 0) { offset = ClearEye(target, prefer, dist, height, self) - target; eyeNow = target + offset; }
    else if (f % UnityEngine.Mathf.Max(1, FPS / 3) == 0 && Blocked(target + offset, target, self)) offset = ClearEye(target, offset, dist, height, self) - target;
    eyeNow = UnityEngine.Vector3.Lerp(eyeNow, target + offset, 1f - UnityEngine.Mathf.Pow(0.9f, 30f / FPS));
    Look(eyeNow, target, fov);
}
// Methods and private fields of a showcase or debug component (developer tooling only; uncomment and set the type name):
// var show = System.Linq.Enumerable.First(UnityEngine.Object.FindObjectsByType<UnityEngine.MonoBehaviour>(UnityEngine.FindObjectsSortMode.None), m => m.GetType().Name == "MyShowcase");
// var NP = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public;
// void Call(string n, params object[] a) => show.GetType().GetMethod(n, NP).Invoke(show, a);
// void SetF(string n, object v) => show.GetType().GetField(n, NP).SetValue(show, v);   // match the field type: 2f for a float, not 2
// object GetF(string n) => show.GetType().GetField(n, NP).GetValue(show);

// Shots: (Name = folder name, Title = caption, Min frames, Max frames, Still, Step, Done).
// Step(f) runs every frame before the capture: trigger things at chosen frames and pose the camera every frame.
// Done(f): null for a fixed length (Min = Max). For an effect the simulation decides (a bird takes off, an NPC reaches the
// door), return true once the effect has happened and a few seconds have followed. The first true is kept: the shot ends
// there (not before Min) with "seen": true, even if Done would say false again later. At Max it ends anyway, and with no true
// so far clips.json gets "seen": false, so the page can't pass off a clip where nothing happened.
// still = true: the shot runs its frames (let streaming, shaders and animation settle) and saves only the last one.
var shots = new System.Collections.Generic.List<(string Name, string Title, int Min, int Max, bool Still, System.Action<int> Step, System.Func<int, bool> Done)>();
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
shots.Add(("01_default_camera", "Screenshot from the player's default camera", 20, 20, true, f =>
{
    // if (f == 0) driver.enabled = true;
    // Don't pose anything: with the game's camera controller running this captures exactly what the player sees.
    // A hand-made "default" pose is always a little off (target, FOV, orbit basis).
}, null));
shots.Add(("02_overview", "What this clip shows, in the reader's language", 300, 300, false, f =>
{
    // if (f == 0) driver.enabled = false;
    var focus = new UnityEngine.Vector3(0f, 0.5f, 0f);
    Look(Orbit(focus, Ease(-30f, 30f, f / 299f), 25f, 8f), focus, 40f);
}, null));
// An effect the simulation decides: trigger it, escalate if nothing happens by a deadline, end a few seconds after it
// happened (6 s here), give up at max. Caption the second it happened; readback says what triggered it.
int hitAt = -1;
shots.Add(("03_event", "Someone walks past the birds; they take off and land again", 150, 900, false, f =>
{
    // if (f == 0) { driver.enabled = false; hitAt = -1; /* first trigger: send a walker past, via the real game method */ }
    // if (f == 240 && hitAt < 0) { /* nothing yet after 8 s: a stronger trigger (send the dog) */ Cap("03_event", f, "no reaction: sending the dog"); }
    // if (hitAt < 0 && /* read back: the effect happened */ false) { hitAt = f; Cap("03_event", f, $"second {f / (float)FPS:F1}: they take off"); }
    var subject = new UnityEngine.Vector3(0f, 0.3f, 0f);
    Fixed(f, subject, new UnityEngine.Vector3(0f, 0f, -1f), 9f, 5f, 55f);
    state["03_event"] = hitAt < 0 ? "no take-off yet" : $"took off at second {hitAt / (float)FPS:F1}";
}, f => hitAt >= 0 && f - hitAt >= 6 * FPS));
// =================================================================
foreach (var name in ONLY)
    if (!shots.Exists(s => s.Name == name)) throw new System.Exception("ONLY names a shot that is not in the list: " + name);
if (ONLY.Length > 0) shots.RemoveAll(s => System.Array.IndexOf(ONLY, s.Name) < 0);
if (shots.Count == 0) throw new System.Exception("no shots to record");

int si = 0, sf = 0, last = -1;
bool reached = false;                                          // this shot's Done has been true

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
        if (sf == 0) { System.IO.Directory.CreateDirectory(dir); reached = false; }
        var pos = cam.transform.position; var rot = cam.transform.rotation; float fov = cam.fieldOfView; var rect = cam.rect;
        s.Step(sf);
        if (s.Done != null && !reached) reached = s.Done(sf);
        bool seen = s.Done == null || reached;
        bool end = sf + 1 >= s.Max || (sf + 1 >= s.Min && s.Done != null && reached);
        if (!s.Still || end)
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
        if (end)
        {
            if (!s.Still && captions.TryGetValue(s.Name, out var lines))
                System.IO.File.WriteAllText(System.IO.Path.Combine(dir, "timeline.jsonl"), lines.ToString(), new System.Text.UTF8Encoding(false));
            state.TryGetValue(s.Name, out var readback);
            meta.Add("{\"name\":\"" + Esc(s.Name) + "\",\"title\":\"" + Esc(s.Title) + "\",\"frames\":" + sf + ",\"fps\":" + FPS
                     + (s.Still ? ",\"still\":true,\"image\":\"stills/" + Esc(s.Name) + ".jpg\"" : "")
                     + ",\"seen\":" + (seen ? "true" : "false")
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
