// Commands/InputCommands.cs
using System;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEditor;

namespace Tykit
{
    [InitializeOnLoad]
    public static class InputCommands
    {
        static InputCommands()
        {
            RegisterCommands();
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "input-key-down",
                    "Simulate a key-down event.",
                    "input.simulate",
                    true,
                    CommandSchema.Object(
                        ("key", CommandSchema.String("Unity KeyCode name or common alias.")))),
                KeyDown);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "input-key-up",
                    "Simulate a key-up event.",
                    "input.simulate",
                    true,
                    CommandSchema.Object(
                        ("key", CommandSchema.String("Unity KeyCode name or common alias.")))),
                KeyUp);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "input-axis",
                    "Set a simulated input axis value.",
                    "input.simulate",
                    true,
                    CommandSchema.Object(
                        ("axis", CommandSchema.String("Axis name.")),
                        ("value", CommandSchema.Number("Axis value.")))),
                SetAxis);
            CommandRegistry.Register(
                CommandRegistry.Describe("input-release-all", "Release all simulated input state.", "input.simulate", true),
                _ => ReleaseAll());
            // EndFrame is now called by SimulatedInputCleaner MonoBehaviour in LateUpdate
        }

        // args: {"key":"Space"} or {"key":"RightArrow"}
        private static JObject KeyDown(JObject args)
        {
            var keyName = args["key"]?.Value<string>();
            if (string.IsNullOrEmpty(keyName))
                return CommandRegistry.Error("Missing 'key'");

            if (!TryParseKey(keyName, out var keyCode))
                return CommandRegistry.Error($"Unknown key: {keyName}");

            SimulatedInput.KeyDown(keyCode);
            return CommandRegistry.Ok($"Key down: {keyCode}");
        }

        // args: {"key":"Space"}
        private static JObject KeyUp(JObject args)
        {
            var keyName = args["key"]?.Value<string>();
            if (string.IsNullOrEmpty(keyName))
                return CommandRegistry.Error("Missing 'key'");

            if (!TryParseKey(keyName, out var keyCode))
                return CommandRegistry.Error($"Unknown key: {keyName}");

            SimulatedInput.KeyUp(keyCode);
            return CommandRegistry.Ok($"Key up: {keyCode}");
        }

        // args: {"axis":"Horizontal","value":1.0}
        private static JObject SetAxis(JObject args)
        {
            var axis = args["axis"]?.Value<string>();
            if (string.IsNullOrEmpty(axis))
                return CommandRegistry.Error("Missing 'axis'");

            var value = args["value"]?.Value<float>() ?? 0f;
            SimulatedInput.SetAxis(axis, value);
            return CommandRegistry.Ok($"Axis {axis} = {value}");
        }

        private static JObject ReleaseAll()
        {
            SimulatedInput.ReleaseAll();
            return CommandRegistry.Ok("All input released");
        }

        // EndFrame handled by SimulatedInputCleaner at end of frame

        private static bool TryParseKey(string name, out KeyCode key)
        {
            // Try direct enum parse
            if (Enum.TryParse<KeyCode>(name, true, out key))
                return true;

            // Common aliases
            switch (name.ToLower())
            {
                case "left": key = KeyCode.LeftArrow; return true;
                case "right": key = KeyCode.RightArrow; return true;
                case "up": key = KeyCode.UpArrow; return true;
                case "down": key = KeyCode.DownArrow; return true;
                case "space": key = KeyCode.Space; return true;
                case "enter": key = KeyCode.Return; return true;
                case "esc": key = KeyCode.Escape; return true;
                case "shift": key = KeyCode.LeftShift; return true;
                case "ctrl": key = KeyCode.LeftControl; return true;
                case "alt": key = KeyCode.LeftAlt; return true;
            }

            key = KeyCode.None;
            return false;
        }
    }
}
