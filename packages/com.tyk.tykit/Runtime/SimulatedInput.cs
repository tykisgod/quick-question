using System.Collections.Generic;
using UnityEngine;

namespace Tykit
{
    /// <summary>
    /// Drop-in replacement for UnityEngine.Input with remote simulation support.
    /// When no simulation is active, all calls pass through to real Input.
    /// Replace Input.GetAxis/GetKey/GetKeyDown with SimulatedInput equivalents.
    /// </summary>
    public static class SimulatedInput
    {
        private static readonly Dictionary<string, float> _axes = new();
        private static readonly HashSet<KeyCode> _keysHeld = new();
        private static readonly HashSet<KeyCode> _keysDown = new();
        private static readonly HashSet<KeyCode> _keysUp = new();
        private static bool _active;

        public static bool IsSimulating => _active;

        // --- Control API (called by tykit commands) ---

        public static void SetAxis(string axis, float value)
        {
            _active = true;
            _axes[axis] = value;
        }

        public static void KeyDown(KeyCode key)
        {
            _keysHeld.Add(key);
            _keysDown.Add(key);
            RefreshActiveState();
        }

        public static void KeyUp(KeyCode key)
        {
            _keysHeld.Remove(key);
            _keysUp.Add(key);
            RefreshActiveState();
        }

        public static void EndFrame()
        {
            _keysDown.Clear();
            _keysUp.Clear();
            RefreshActiveState();
        }

        public static void ReleaseAll()
        {
            _axes.Clear();
            _keysHeld.Clear();
            _keysDown.Clear();
            _keysUp.Clear();
            _active = false;
        }

        private static void RefreshActiveState()
        {
            _active = _axes.Count > 0 || _keysHeld.Count > 0 || _keysDown.Count > 0 || _keysUp.Count > 0;
        }

        // --- Input replacements ---

        public static float GetAxis(string axis)
        {
            if (_active && _axes.TryGetValue(axis, out var val)) return val;
            return Input.GetAxis(axis);
        }

        public static float GetAxisRaw(string axis)
        {
            if (_active && _axes.TryGetValue(axis, out var val))
                return val > 0 ? 1f : val < 0 ? -1f : 0f;
            return Input.GetAxisRaw(axis);
        }

        public static bool GetKey(KeyCode key)
        {
            if (_active && _keysHeld.Contains(key)) return true;
            return Input.GetKey(key);
        }

        public static bool GetKeyDown(KeyCode key)
        {
            if (_active && _keysDown.Contains(key)) return true;
            return Input.GetKeyDown(key);
        }

        public static bool GetKeyUp(KeyCode key)
        {
            if (_active && _keysUp.Contains(key)) return true;
            return Input.GetKeyUp(key);
        }
    }

    /// <summary>
    /// Auto-created MonoBehaviour that clears per-frame input state after LateUpdate.
    /// </summary>
    public class SimulatedInputCleaner : MonoBehaviour
    {
        private static SimulatedInputCleaner _instance;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Init()
        {
            if (_instance != null) return;
            var go = new GameObject("[SimulatedInputCleaner]");
            go.hideFlags = HideFlags.HideAndDontSave;
            DontDestroyOnLoad(go);
            _instance = go.AddComponent<SimulatedInputCleaner>();
        }

        void LateUpdate()
        {
            SimulatedInput.EndFrame();
        }
    }
}
