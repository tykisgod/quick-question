// Commands/HierarchyCommands.cs
using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEditor;

namespace Tykit
{
    [InitializeOnLoad]
    public static class HierarchyCommands
    {
        static HierarchyCommands()
        {
            RegisterCommands();
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "hierarchy",
                    "Read the active scene hierarchy as a flattened tree.",
                    "scene.query",
                    false,
                    CommandSchema.Object(
                        ("depth", CommandSchema.Integer("Maximum traversal depth. Default is 3.")))),
                GetHierarchy);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "find",
                    "Find GameObjects by name, tag, or component type.",
                    "scene.query",
                    false,
                    CommandSchema.Object(
                        ("name", CommandSchema.String("Exact GameObject name.")),
                        ("tag", CommandSchema.String("Unity tag.")),
                        ("type", CommandSchema.String("Component or GameObject type name.")))),
                FindGameObjects);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "inspect",
                    "Inspect a GameObject and return basic transform and component information.",
                    "scene.query",
                    false,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")))),
                InspectGameObject);
        }

        // args: {"depth":3}
        private static JObject GetHierarchy(JObject args)
        {
            int maxDepth = args["depth"]?.Value<int>() ?? 3;
            var scene = SceneManager.GetActiveScene();
            var roots = scene.GetRootGameObjects();
            var arr = new JArray();

            foreach (var root in roots)
                BuildHierarchy(root.transform, 0, maxDepth, arr);

            return CommandRegistry.Ok(arr);
        }

        private static void BuildHierarchy(Transform t, int depth, int maxDepth, JArray arr)
        {
            if (depth >= maxDepth) return;

            var node = new JObject
            {
                ["name"] = t.name,
                ["instanceId"] = t.gameObject.GetInstanceID(),
                ["active"] = t.gameObject.activeSelf,
                ["depth"] = depth
            };
            arr.Add(node);

            for (int i = 0; i < t.childCount; i++)
                BuildHierarchy(t.GetChild(i), depth + 1, maxDepth, arr);
        }

        // args: {"name":"Ship"} or {"tag":"Player"} or {"type":"Camera"}
        private static JObject FindGameObjects(JObject args)
        {
            var results = new JArray();

            var name = args["name"]?.Value<string>();
            var tag = args["tag"]?.Value<string>();
            var typeName = args["type"]?.Value<string>();

            if (!string.IsNullOrEmpty(name))
            {
                var go = GameObject.Find(name);
                if (go != null) results.Add(FormatGameObject(go));
            }
            else if (!string.IsNullOrEmpty(tag))
            {
                try
                {
                    foreach (var go in GameObject.FindGameObjectsWithTag(tag))
                        results.Add(FormatGameObject(go));
                }
                catch (UnityException e)
                {
                    return CommandRegistry.Error($"Invalid tag: {e.Message}");
                }
            }
            else if (!string.IsNullOrEmpty(typeName))
            {
                var type = TypeHelper.FindType(typeName);
                if (type == null)
                    return CommandRegistry.Error($"Type not found: {typeName}");

                foreach (var obj in UnityEngine.Object.FindObjectsByType(type, FindObjectsSortMode.None))
                {
                    if (obj is Component c)
                        results.Add(FormatGameObject(c.gameObject));
                    else if (obj is GameObject go)
                        results.Add(FormatGameObject(go));
                }
            }
            else
            {
                return CommandRegistry.Error("Provide 'name', 'tag', or 'type'");
            }

            return CommandRegistry.Ok(results);
        }

        // args: {"id":12345} or {"name":"Ship"}
        private static JObject InspectGameObject(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var components = new JArray();
            foreach (var comp in go.GetComponents<Component>())
            {
                if (comp == null) continue;
                components.Add(comp.GetType().Name);
            }

            var data = new JObject
            {
                ["name"] = go.name,
                ["instanceId"] = go.GetInstanceID(),
                ["active"] = go.activeSelf,
                ["layer"] = LayerMask.LayerToName(go.layer),
                ["tag"] = go.tag,
                ["position"] = Vec3ToJson(go.transform.position),
                ["rotation"] = Vec3ToJson(go.transform.eulerAngles),
                ["scale"] = Vec3ToJson(go.transform.localScale),
                ["childCount"] = go.transform.childCount,
                ["components"] = components
            };

            return CommandRegistry.Ok(data);
        }

        private static JObject FormatGameObject(GameObject go)
        {
            var components = new JArray();
            foreach (var c in go.GetComponents<Component>())
            {
                if (c != null && c.GetType() != typeof(Transform))
                    components.Add(c.GetType().Name);
            }

            return new JObject
            {
                ["name"] = go.name,
                ["instanceId"] = go.GetInstanceID(),
                ["path"] = GetPath(go.transform),
                ["components"] = components
            };
        }

        private static string GetPath(Transform t)
        {
            var path = t.name;
            while (t.parent != null)
            {
                t = t.parent;
                path = t.name + "/" + path;
            }
            return path;
        }

        private static JArray Vec3ToJson(Vector3 v)
        {
            return new JArray(v.x, v.y, v.z);
        }
    }
}
