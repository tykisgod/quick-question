using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UI;
using UnityEditor;
using TMPro;

namespace Tykit
{
    [InitializeOnLoad]
    public static class UICommands
    {
        static UICommands()
        {
            RegisterCommands();
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "create-canvas",
                    "Create a Canvas with standard UI support components.",
                    "ui.mutate",
                    true,
                    CommandSchema.Object(
                        ("name", CommandSchema.String("Canvas GameObject name.")),
                        ("renderMode", CommandSchema.String("Canvas render mode.", "overlay", "camera", "world")))),
                CreateCanvas);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "create-ui",
                    "Create a basic UI element under a Canvas.",
                    "ui.mutate",
                    true,
                    CommandSchema.Object(
                        ("type", CommandSchema.String("UI element type.", "text", "image", "button", "slider", "panel")),
                        ("name", CommandSchema.String("Optional element name.")),
                        ("text", CommandSchema.String("Optional text content.")),
                        ("parent", CommandSchema.String("Optional parent Canvas or transform name.")),
                        ("position", CommandSchema.Array(CommandSchema.Number(), "Optional anchored position [x,y].")),
                        ("size", CommandSchema.Array(CommandSchema.Number(), "Optional size [width,height].")),
                        ("fontSize", CommandSchema.Number("Optional text font size.")),
                        ("color", new JObject { ["description"] = "Optional color value." }))),
                CreateUI);
        }

        // args: {"name":"GameUI", "renderMode":"overlay"} — overlay(default), camera, world
        private static JObject CreateCanvas(JObject args)
        {
            var name = args["name"]?.Value<string>() ?? "Canvas";
            var modeStr = args["renderMode"]?.Value<string>()?.ToLower() ?? "overlay";

            var go = new GameObject(name);
            var canvas = go.AddComponent<Canvas>();
            go.AddComponent<CanvasScaler>();
            go.AddComponent<GraphicRaycaster>();

            switch (modeStr)
            {
                case "camera":
                    canvas.renderMode = RenderMode.ScreenSpaceCamera;
                    canvas.worldCamera = Camera.main;
                    break;
                case "world":
                    canvas.renderMode = RenderMode.WorldSpace;
                    var rt = go.GetComponent<RectTransform>();
                    rt.sizeDelta = new Vector2(400, 300);
                    break;
                default:
                    canvas.renderMode = RenderMode.ScreenSpaceOverlay;
                    break;
            }

            // Auto-create EventSystem if not present
            if (Object.FindObjectOfType<UnityEngine.EventSystems.EventSystem>() == null)
            {
                var es = new GameObject("EventSystem");
                es.AddComponent<UnityEngine.EventSystems.EventSystem>();
                es.AddComponent<UnityEngine.EventSystems.StandaloneInputModule>();
                Undo.RegisterCreatedObjectUndo(es, "Create EventSystem");
            }

            Undo.RegisterCreatedObjectUndo(go, $"Create Canvas {name}");
            return CommandRegistry.Ok(new JObject
            {
                ["name"] = go.name,
                ["instanceId"] = go.GetInstanceID(),
                ["renderMode"] = modeStr
            });
        }

        // args: {"type":"text","text":"Hello","parent":"Canvas","position":[x,y],"size":[w,h],"fontSize":24,"color":[r,g,b,a]}
        // Supported types: text, image, button, slider, panel
        private static JObject CreateUI(JObject args)
        {
            var typeName = args["type"]?.Value<string>()?.ToLower();
            if (string.IsNullOrEmpty(typeName))
                return CommandRegistry.Error("Missing 'type' (text, image, button, slider, panel)");

            // Find parent Canvas
            Transform parent = null;
            var parentName = args["parent"]?.Value<string>();
            if (!string.IsNullOrEmpty(parentName))
            {
                var parentGo = GameObject.Find(parentName);
                if (parentGo != null) parent = parentGo.transform;
            }

            // Auto-find a Canvas if no parent specified
            if (parent == null)
            {
                var canvas = Object.FindObjectOfType<Canvas>();
                if (canvas != null) parent = canvas.transform;
            }

            if (parent == null)
                return CommandRegistry.Error("No Canvas found. Create one first with 'create-canvas'");

            var elementName = args["name"]?.Value<string>() ?? typeName;

            GameObject go;
            switch (typeName)
            {
                case "text":
                    go = CreateText(elementName, args);
                    break;
                case "image":
                    go = CreateImage(elementName, args);
                    break;
                case "button":
                    go = CreateButton(elementName, args);
                    break;
                case "slider":
                    go = CreateSlider(elementName);
                    break;
                case "panel":
                    go = CreatePanel(elementName, args);
                    break;
                default:
                    return CommandRegistry.Error($"Unknown UI type: {typeName}. Use: text, image, button, slider, panel");
            }

            go.transform.SetParent(parent, false);

            // Position (anchored position)
            var pos = args["position"] as JArray;
            if (pos != null && pos.Count >= 2)
            {
                var rt = go.GetComponent<RectTransform>();
                rt.anchoredPosition = new Vector2(pos[0].Value<float>(), pos[1].Value<float>());
            }

            // Size
            var size = args["size"] as JArray;
            if (size != null && size.Count >= 2)
            {
                var rt = go.GetComponent<RectTransform>();
                rt.sizeDelta = new Vector2(size[0].Value<float>(), size[1].Value<float>());
            }

            Undo.RegisterCreatedObjectUndo(go, $"Create UI {typeName}");
            return CommandRegistry.Ok(new JObject
            {
                ["name"] = go.name,
                ["instanceId"] = go.GetInstanceID(),
                ["type"] = typeName
            });
        }

        private static GameObject CreateText(string name, JObject args)
        {
            var go = new GameObject(name);
            var tmp = go.AddComponent<TextMeshProUGUI>();
            tmp.text = args["text"]?.Value<string>() ?? "Text";
            tmp.fontSize = args["fontSize"]?.Value<float>() ?? 24f;
            tmp.alignment = TextAlignmentOptions.Center;

            var color = ParseColor(args["color"]);
            if (color.HasValue) tmp.color = color.Value;

            var rt = go.GetComponent<RectTransform>();
            rt.sizeDelta = new Vector2(200, 50);
            return go;
        }

        private static GameObject CreateImage(string name, JObject args)
        {
            var go = new GameObject(name);
            var img = go.AddComponent<Image>();

            var color = ParseColor(args["color"]);
            img.color = color ?? Color.white;

            var rt = go.GetComponent<RectTransform>();
            rt.sizeDelta = new Vector2(100, 100);
            return go;
        }

        private static GameObject CreateButton(string name, JObject args)
        {
            var go = new GameObject(name);
            var img = go.AddComponent<Image>();
            go.AddComponent<Button>();

            var color = ParseColor(args["color"]);
            img.color = color ?? new Color(0.2f, 0.6f, 1f, 1f);

            var rt = go.GetComponent<RectTransform>();
            rt.sizeDelta = new Vector2(160, 40);

            // Button label
            var label = new GameObject("Label");
            label.transform.SetParent(go.transform, false);
            var tmp = label.AddComponent<TextMeshProUGUI>();
            tmp.text = args["text"]?.Value<string>() ?? "Button";
            tmp.fontSize = 18f;
            tmp.alignment = TextAlignmentOptions.Center;
            tmp.color = Color.white;
            var labelRt = label.GetComponent<RectTransform>();
            labelRt.anchorMin = Vector2.zero;
            labelRt.anchorMax = Vector2.one;
            labelRt.sizeDelta = Vector2.zero;

            return go;
        }

        private static GameObject CreateSlider(string name)
        {
            // Use a simplified slider structure
            var go = new GameObject(name);
            var slider = go.AddComponent<Slider>();
            var rt = go.GetComponent<RectTransform>();
            rt.sizeDelta = new Vector2(160, 20);

            // Background
            var bg = new GameObject("Background");
            bg.transform.SetParent(go.transform, false);
            var bgImg = bg.AddComponent<Image>();
            bgImg.color = new Color(0.3f, 0.3f, 0.3f, 1f);
            var bgRt = bg.GetComponent<RectTransform>();
            bgRt.anchorMin = Vector2.zero;
            bgRt.anchorMax = Vector2.one;
            bgRt.sizeDelta = Vector2.zero;

            // Fill area
            var fillArea = new GameObject("Fill Area");
            fillArea.transform.SetParent(go.transform, false);
            var fillAreaRt = fillArea.AddComponent<RectTransform>();
            fillAreaRt.anchorMin = Vector2.zero;
            fillAreaRt.anchorMax = Vector2.one;
            fillAreaRt.sizeDelta = Vector2.zero;

            var fill = new GameObject("Fill");
            fill.transform.SetParent(fillArea.transform, false);
            var fillImg = fill.AddComponent<Image>();
            fillImg.color = new Color(0.2f, 0.6f, 1f, 1f);
            var fillRt = fill.GetComponent<RectTransform>();
            fillRt.anchorMin = Vector2.zero;
            fillRt.anchorMax = new Vector2(0.5f, 1f);
            fillRt.sizeDelta = Vector2.zero;

            // Handle
            var handleArea = new GameObject("Handle Slide Area");
            handleArea.transform.SetParent(go.transform, false);
            var handleAreaRt = handleArea.AddComponent<RectTransform>();
            handleAreaRt.anchorMin = Vector2.zero;
            handleAreaRt.anchorMax = Vector2.one;
            handleAreaRt.sizeDelta = Vector2.zero;

            var handle = new GameObject("Handle");
            handle.transform.SetParent(handleArea.transform, false);
            var handleImg = handle.AddComponent<Image>();
            handleImg.color = Color.white;
            var handleRt = handle.GetComponent<RectTransform>();
            handleRt.sizeDelta = new Vector2(20, 0);

            slider.fillRect = fillRt;
            slider.handleRect = handleRt;
            slider.targetGraphic = handleImg;

            return go;
        }

        private static GameObject CreatePanel(string name, JObject args)
        {
            var go = new GameObject(name);
            var img = go.AddComponent<Image>();
            var color = ParseColor(args["color"]);
            img.color = color ?? new Color(0, 0, 0, 0.5f);

            var rt = go.GetComponent<RectTransform>();
            rt.sizeDelta = new Vector2(300, 200);
            return go;
        }

        private static Color? ParseColor(JToken token)
        {
            if (token == null) return null;
            if (token is JArray arr && arr.Count >= 3)
            {
                return new Color(
                    arr[0].Value<float>(), arr[1].Value<float>(), arr[2].Value<float>(),
                    arr.Count >= 4 ? arr[3].Value<float>() : 1f);
            }
            if (token.Type == JTokenType.String && ColorUtility.TryParseHtmlString(token.Value<string>(), out var c))
                return c;
            return null;
        }
    }
}
