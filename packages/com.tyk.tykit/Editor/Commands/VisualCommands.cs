using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEditor;

namespace Tykit
{
    [InitializeOnLoad]
    public static class VisualCommands
    {
        static VisualCommands()
        {
            RegisterCommands();
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "set-color",
                    "Set renderer or sprite color on a GameObject.",
                    "visual.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("color", new JObject { ["description"] = "Color as [r,g,b,a] or #RRGGBB." }))),
                SetColor);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "set-material-property",
                    "Set a material property on a renderer.",
                    "visual.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("property", CommandSchema.String("Material property name.")),
                        ("color", new JObject { ["description"] = "Optional color value." }),
                        ("float", CommandSchema.Number("Optional float value.")),
                        ("int", CommandSchema.Integer("Optional integer value.")),
                        ("vector", CommandSchema.Array(CommandSchema.Number(), "Optional [x,y,z,w] vector value.")))),
                SetMaterialProperty);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "create-sprite",
                    "Create a procedural colored sprite GameObject.",
                    "visual.mutate",
                    true,
                    CommandSchema.Object(
                        ("name", CommandSchema.String("Sprite GameObject name.")),
                        ("color", new JObject { ["description"] = "Optional color value." }),
                        ("size", CommandSchema.Array(CommandSchema.Number(), "Sprite size [width,height].")),
                        ("position", CommandSchema.Array(CommandSchema.Number(), "Optional [x,y,z] world position.")),
                        ("parent", CommandSchema.String("Optional parent GameObject name.")),
                        ("sortingOrder", CommandSchema.Integer("Optional SpriteRenderer sorting order.")))),
                CreateSprite);
        }

        // args: {"id":ID, "color":[r,g,b,a]} or {"id":ID, "color":"#FF0000"}
        // Sets the main color (_BaseColor or _Color) on the renderer's material
        private static JObject SetColor(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var renderer = go.GetComponent<Renderer>();
            var spriteRenderer = go.GetComponent<SpriteRenderer>();

            if (renderer == null && spriteRenderer == null)
                return CommandRegistry.Error($"No Renderer or SpriteRenderer on {go.name}");

            var color = ParseColor(args["color"]);
            if (!color.HasValue)
                return CommandRegistry.Error("Invalid 'color'. Use [r,g,b,a] (0-1) or \"#RRGGBB\"");

            if (spriteRenderer != null)
            {
                Undo.RecordObject(spriteRenderer, "Set Color");
                spriteRenderer.color = color.Value;
            }
            else
            {
                // Clone material to avoid modifying shared assets
                Undo.RecordObject(renderer, "Set Color");
                var mat = new Material(renderer.sharedMaterial);
                mat.color = color.Value;
                renderer.material = mat;
            }

            EditorUtility.SetDirty(go);
            return CommandRegistry.Ok($"Set color on {go.name} to {color.Value}");
        }

        // args: {"id":ID, "property":"_EmissionColor", "color":[r,g,b,a]}
        //    or {"id":ID, "property":"_Metallic", "float":0.8}
        //    or {"id":ID, "property":"_BaseMap_ST", "vector":[1,1,0,0]}
        private static JObject SetMaterialProperty(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var renderer = go.GetComponent<Renderer>();
            if (renderer == null)
                return CommandRegistry.Error($"No Renderer on {go.name}");

            var propName = args["property"]?.Value<string>();
            if (string.IsNullOrEmpty(propName))
                return CommandRegistry.Error("Missing 'property' name (e.g. _BaseColor, _Metallic)");

            Undo.RecordObject(renderer, "Set Material Property");
            var mat = new Material(renderer.sharedMaterial);

            if (args["color"] != null)
            {
                var c = ParseColor(args["color"]);
                if (!c.HasValue) return CommandRegistry.Error("Invalid 'color'");
                mat.SetColor(propName, c.Value);
            }
            else if (args["float"] != null)
            {
                mat.SetFloat(propName, args["float"].Value<float>());
            }
            else if (args["int"] != null)
            {
                mat.SetInt(propName, args["int"].Value<int>());
            }
            else if (args["vector"] != null)
            {
                var v = args["vector"] as JArray;
                if (v == null || v.Count != 4) return CommandRegistry.Error("'vector' must be [x,y,z,w]");
                mat.SetVector(propName, new Vector4(v[0].Value<float>(), v[1].Value<float>(),
                    v[2].Value<float>(), v[3].Value<float>()));
            }
            else
            {
                return CommandRegistry.Error("Provide 'color', 'float', 'int', or 'vector' value");
            }

            renderer.material = mat;
            EditorUtility.SetDirty(go);
            return CommandRegistry.Ok($"Set {propName} on {go.name}");
        }

        // args: {"name":"X", "color":[r,g,b,a], "size":[w,h], "position":[x,y,z], "parent":"P", "sortingOrder":1}
        // Creates a GameObject with SpriteRenderer using a procedural colored sprite
        private static JObject CreateSprite(JObject args)
        {
            var name = args["name"]?.Value<string>() ?? "Sprite";

            // Size
            float w = 1f, h = 1f;
            var size = args["size"] as JArray;
            if (size != null && size.Count >= 2)
            {
                w = size[0].Value<float>();
                h = size[1].Value<float>();
            }

            // Color
            var color = ParseColor(args["color"]) ?? Color.white;

            // Create texture
            int texW = Mathf.Max(1, Mathf.RoundToInt(w * 32));
            int texH = Mathf.Max(1, Mathf.RoundToInt(h * 32));
            var tex = new Texture2D(texW, texH);
            var pixels = new Color[texW * texH];
            for (int i = 0; i < pixels.Length; i++) pixels[i] = color;
            tex.SetPixels(pixels);
            tex.Apply();
            tex.filterMode = FilterMode.Point;

            // Create sprite (100 pixels per unit)
            var sprite = Sprite.Create(tex, new Rect(0, 0, texW, texH), new Vector2(0.5f, 0.5f), 32f);

            // Create GameObject
            var go = new GameObject(name);
            var sr = go.AddComponent<SpriteRenderer>();
            sr.sprite = sprite;
            sr.color = Color.white; // color is baked into texture

            // Sorting order
            var sortingOrder = args["sortingOrder"]?.Value<int>();
            if (sortingOrder.HasValue) sr.sortingOrder = sortingOrder.Value;

            // Parent
            var parentName = args["parent"]?.Value<string>();
            if (!string.IsNullOrEmpty(parentName))
            {
                var parent = GameObject.Find(parentName);
                if (parent != null) go.transform.SetParent(parent.transform, false);
            }

            // Position
            var pos = args["position"] as JArray;
            if (pos != null && pos.Count >= 2)
            {
                go.transform.position = new Vector3(
                    pos[0].Value<float>(),
                    pos[1].Value<float>(),
                    pos.Count >= 3 ? pos[2].Value<float>() : 0f);
            }

            Undo.RegisterCreatedObjectUndo(go, $"Create Sprite {name}");
            return CommandRegistry.Ok(new JObject
            {
                ["name"] = go.name,
                ["instanceId"] = go.GetInstanceID(),
                ["size"] = new JArray(w, h)
            });
        }

        // Parses [r,g,b,a] (0-1 floats) or "#RRGGBB" / "#RRGGBBAA"
        private static Color? ParseColor(JToken token)
        {
            if (token == null) return null;

            if (token is JArray arr)
            {
                if (arr.Count < 3) return null;
                float r = arr[0].Value<float>();
                float g = arr[1].Value<float>();
                float b = arr[2].Value<float>();
                float a = arr.Count >= 4 ? arr[3].Value<float>() : 1f;
                return new Color(r, g, b, a);
            }

            if (token.Type == JTokenType.String)
            {
                if (ColorUtility.TryParseHtmlString(token.Value<string>(), out var c))
                    return c;
            }

            return null;
        }
    }
}
