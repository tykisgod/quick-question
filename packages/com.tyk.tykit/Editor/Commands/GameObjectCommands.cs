// Commands/GameObjectCommands.cs
using System;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEditor;

namespace Tykit
{
    [InitializeOnLoad]
    public static class GameObjectCommands
    {
        static GameObjectCommands()
        {
            RegisterCommands();
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "create",
                    "Create a new GameObject or primitive.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("name", CommandSchema.String("GameObject name.")),
                        ("parent", CommandSchema.String("Optional parent GameObject name.")),
                        ("primitiveType", CommandSchema.String("Optional Unity PrimitiveType.")),
                        ("position", CommandSchema.Array(CommandSchema.Number(), "Optional [x,y,z] world position.")))),
                CreateGameObject);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "instantiate",
                    "Instantiate a prefab into the active scene.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("prefab", CommandSchema.String("Prefab asset path.")),
                        ("name", CommandSchema.String("Optional instance name override.")),
                        ("parent", CommandSchema.String("Optional parent GameObject name.")),
                        ("position", CommandSchema.Array(CommandSchema.Number(), "Optional [x,y,z] world position.")))),
                InstantiatePrefab);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "destroy",
                    "Destroy a GameObject immediately.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")))),
                DestroyGameObject);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "set-transform",
                    "Update a GameObject transform.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("position", CommandSchema.Array(CommandSchema.Number(), "Optional [x,y,z] position.")),
                        ("rotation", CommandSchema.Array(CommandSchema.Number(), "Optional [x,y,z] Euler rotation.")),
                        ("scale", CommandSchema.Array(CommandSchema.Number(), "Optional [x,y,z] local scale.")))),
                SetTransform);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "set-parent",
                    "Change a GameObject parent or unparent it.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("parent", CommandSchema.String("Parent GameObject name, or null to unparent.")),
                        ("parentId", CommandSchema.Integer("Parent GameObject instanceId.")),
                        ("worldPositionStays", CommandSchema.Boolean("Keep world transform while reparenting.")))),
                SetParent);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "duplicate",
                    "Duplicate a GameObject.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")))),
                Duplicate);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "set-active",
                    "Enable or disable a GameObject.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("active", CommandSchema.Boolean("Desired active state.")))),
                SetActive);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "set-layer",
                    "Assign a GameObject layer by name or index.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("layer", new JObject { ["description"] = "Layer name or integer index." }))),
                SetLayer);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "set-tag",
                    "Assign a Unity tag to a GameObject.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("tag", CommandSchema.String("Unity tag.")))),
                SetTag);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "add-force",
                    "Apply force to a Rigidbody on the target GameObject.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("force", CommandSchema.Array(CommandSchema.Number(), "Force vector [x,y,z].")),
                        ("mode", CommandSchema.String("Unity ForceMode enum value.")))),
                AddForce);
        }

        // args: {"name":"Barrel","parent":"Ship","primitiveType":"Cube","position":[0,1,0]}
        private static JObject CreateGameObject(JObject args)
        {
            var name = args["name"]?.Value<string>() ?? "New GameObject";

            GameObject go;
            var primitiveType = args["primitiveType"]?.Value<string>();
            if (!string.IsNullOrEmpty(primitiveType) &&
                Enum.TryParse<PrimitiveType>(primitiveType, true, out var pt))
            {
                go = GameObject.CreatePrimitive(pt);
                go.name = name;
            }
            else
            {
                go = new GameObject(name);
            }

            // Parent — error if specified but not found
            var parentName = args["parent"]?.Value<string>();
            if (!string.IsNullOrEmpty(parentName))
            {
                var parent = GameObject.Find(parentName);
                if (parent == null)
                {
                    UnityEngine.Object.DestroyImmediate(go);
                    return CommandRegistry.Error($"Parent not found: {parentName}");
                }
                go.transform.SetParent(parent.transform, false);
            }

            ApplyPosition(go, args);
            // Undo.RegisterCreatedObjectUndo(go, $"Create {name}");

            return CommandRegistry.Ok(new JObject
            {
                ["name"] = go.name,
                ["instanceId"] = go.GetInstanceID()
            });
        }

        // args: {"prefab":"Assets/Res/Prefabs/Ship.prefab","name":"MyShip","parent":"World","position":[0,0,0]}
        private static JObject InstantiatePrefab(JObject args)
        {
            var prefabPath = args["prefab"]?.Value<string>();
            if (string.IsNullOrEmpty(prefabPath))
                return CommandRegistry.Error("Missing 'prefab' path");

            var prefabAsset = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            if (prefabAsset == null)
                return CommandRegistry.Error($"Prefab not found: {prefabPath}");

            var go = (GameObject)PrefabUtility.InstantiatePrefab(prefabAsset);
            var customName = args["name"]?.Value<string>();
            if (!string.IsNullOrEmpty(customName)) go.name = customName;

            var parentName = args["parent"]?.Value<string>();
            if (!string.IsNullOrEmpty(parentName))
            {
                var parent = GameObject.Find(parentName);
                if (parent == null)
                {
                    UnityEngine.Object.DestroyImmediate(go);
                    return CommandRegistry.Error($"Parent not found: {parentName}");
                }
                go.transform.SetParent(parent.transform, false);
            }

            ApplyPosition(go, args);
            // Undo.RegisterCreatedObjectUndo(go, $"Instantiate {prefabPath}");

            return CommandRegistry.Ok(new JObject
            {
                ["name"] = go.name,
                ["instanceId"] = go.GetInstanceID()
            });
        }

        // args: {"id":12345} or {"name":"Barrel"}
        private static JObject DestroyGameObject(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var name = go.name;
            UnityEngine.Object.DestroyImmediate(go);
            return CommandRegistry.Ok($"Destroyed: {name}");
        }

        // args: {"id":12345,"position":[1,2,3],"rotation":[0,90,0],"scale":[2,2,2]}
        private static JObject SetTransform(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            // Direct transform modification without Undo

            var pos = args["position"] as JArray;
            if (pos != null && pos.Count == 3)
                go.transform.position = new Vector3(pos[0].Value<float>(), pos[1].Value<float>(), pos[2].Value<float>());

            var rot = args["rotation"] as JArray;
            if (rot != null && rot.Count == 3)
                go.transform.eulerAngles = new Vector3(rot[0].Value<float>(), rot[1].Value<float>(), rot[2].Value<float>());

            var scale = args["scale"] as JArray;
            if (scale != null && scale.Count == 3)
                go.transform.localScale = new Vector3(scale[0].Value<float>(), scale[1].Value<float>(), scale[2].Value<float>());

            return CommandRegistry.Ok($"Updated transform: {go.name}");
        }

        // args: {"id":12345,"force":[0,12,0],"mode":"Impulse"}
        private static JObject AddForce(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var rb = go.GetComponent<Rigidbody>();
            if (rb == null) return CommandRegistry.Error($"No Rigidbody on {go.name}");

            var force = args["force"] as JArray;
            if (force == null || force.Count != 3)
                return CommandRegistry.Error("Provide 'force' as [x,y,z]");

            var f = new Vector3(force[0].Value<float>(), force[1].Value<float>(), force[2].Value<float>());
            var modeStr = args["mode"]?.Value<string>() ?? "Impulse";
            if (!System.Enum.TryParse<ForceMode>(modeStr, true, out var mode))
                mode = ForceMode.Impulse;

            rb.AddForce(f, mode);
            return CommandRegistry.Ok($"Applied force {f} ({mode}) to {go.name}");
        }

        // args: {"id":12345,"parent":"ParentName"} or {"id":12345,"parentId":67890} or {"id":12345,"parent":null} (unparent)
        private static JObject SetParent(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var worldPositionStays = args["worldPositionStays"]?.Value<bool>() ?? true;

            // Unparent
            if (args["parent"] != null && args["parent"].Type == JTokenType.Null)
            {
                Undo.SetTransformParent(go.transform, null, "Set Parent");
                return CommandRegistry.Ok($"Unparented: {go.name}");
            }

            // By instanceId
            var parentId = args["parentId"]?.Value<int>();
            if (parentId.HasValue)
            {
                var parentObj = EditorUtility.InstanceIDToObject(parentId.Value) as GameObject;
                if (parentObj == null) return CommandRegistry.Error($"Parent not found: id {parentId}");
                Undo.SetTransformParent(go.transform, parentObj.transform, "Set Parent");
                go.transform.SetParent(parentObj.transform, worldPositionStays);
                return CommandRegistry.Ok($"Set parent of {go.name} to {parentObj.name}");
            }

            // By name
            var parentName = args["parent"]?.Value<string>();
            if (string.IsNullOrEmpty(parentName))
                return CommandRegistry.Error("Provide 'parent' (name/null) or 'parentId'");

            var parent = GameObject.Find(parentName);
            if (parent == null) return CommandRegistry.Error($"Parent not found: {parentName}");
            Undo.SetTransformParent(go.transform, parent.transform, "Set Parent");
            go.transform.SetParent(parent.transform, worldPositionStays);
            return CommandRegistry.Ok($"Set parent of {go.name} to {parent.name}");
        }

        // args: {"id":12345} or {"name":"Barrel"}
        private static JObject Duplicate(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var clone = UnityEngine.Object.Instantiate(go, go.transform.parent);
            clone.name = go.name; // remove "(Clone)" suffix
            Undo.RegisterCreatedObjectUndo(clone, $"Duplicate {go.name}");
            return CommandRegistry.Ok(new JObject
            {
                ["name"] = clone.name,
                ["instanceId"] = clone.GetInstanceID()
            });
        }

        // args: {"id":12345,"active":false}
        private static JObject SetActive(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var active = args["active"]?.Value<bool>();
            if (!active.HasValue)
                return CommandRegistry.Error("Missing 'active' (true/false)");

            Undo.RecordObject(go, "Set Active");
            go.SetActive(active.Value);
            return CommandRegistry.Ok($"{go.name} active={active.Value}");
        }

        // args: {"id":12345,"layer":"Water"} or {"id":12345,"layer":4}
        private static JObject SetLayer(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var layerToken = args["layer"];
            if (layerToken == null) return CommandRegistry.Error("Missing 'layer'");

            int layer;
            if (layerToken.Type == JTokenType.Integer)
            {
                layer = layerToken.Value<int>();
            }
            else
            {
                layer = LayerMask.NameToLayer(layerToken.Value<string>());
                if (layer < 0) return CommandRegistry.Error($"Layer not found: {layerToken}");
            }

            Undo.RecordObject(go, "Set Layer");
            go.layer = layer;
            return CommandRegistry.Ok($"{go.name} layer={LayerMask.LayerToName(layer)} ({layer})");
        }

        // args: {"id":12345,"tag":"Player"}
        private static JObject SetTag(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var tag = args["tag"]?.Value<string>();
            if (string.IsNullOrEmpty(tag)) return CommandRegistry.Error("Missing 'tag'");

            Undo.RecordObject(go, "Set Tag");
            go.tag = tag;
            return CommandRegistry.Ok($"{go.name} tag={tag}");
        }

        private static void ApplyPosition(GameObject go, JObject args)
        {
            var pos = args["position"] as JArray;
            if (pos != null && pos.Count == 3)
                go.transform.position = new Vector3(pos[0].Value<float>(), pos[1].Value<float>(), pos[2].Value<float>());
        }
    }
}
