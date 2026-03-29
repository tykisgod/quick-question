// Commands/ComponentCommands.cs
using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEditor;

namespace Tykit
{
    [InitializeOnLoad]
    public static class ComponentCommands
    {
        static ComponentCommands()
        {
            RegisterCommands();
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "add-component",
                    "Add a component to a GameObject.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("component", CommandSchema.String("Component type name.")))),
                AddComponent);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "remove-component",
                    "Remove a component from a GameObject.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("component", CommandSchema.String("Component type name.")))),
                RemoveComponent);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "get-properties",
                    "Read serialized properties from one or all components on a GameObject.",
                    "scene.query",
                    false,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("component", CommandSchema.String("Optional component type name.")))),
                GetProperties);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "set-property",
                    "Set a serialized property on a component.",
                    "scene.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("component", CommandSchema.String("Component type name.")),
                        ("property", CommandSchema.String("Serialized property path.")),
                        ("value", new JObject { ["description"] = "Value converted to string before assignment." }))),
                SetProperty);
        }

        // args: {"id":12345,"component":"BoxCollider"} or {"name":"Ship","component":"BoxCollider"}
        private static JObject AddComponent(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var typeName = args["component"]?.Value<string>();
            if (string.IsNullOrEmpty(typeName))
                return CommandRegistry.Error("Missing 'component' type name");

            var type = TypeHelper.FindType(typeName);
            if (type == null)
                return CommandRegistry.Error($"Type not found: {typeName}");

            if (!typeof(Component).IsAssignableFrom(type) || type.IsAbstract)
                return CommandRegistry.Error($"'{typeName}' is not a concrete Component type");

            go.AddComponent(type);
            EditorUtility.SetDirty(go);
            return CommandRegistry.Ok($"Added {typeName} to {go.name}");
        }

        // args: {"id":12345,"component":"BoxCollider"} or {"name":"Ship","component":"BoxCollider"}
        private static JObject RemoveComponent(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var typeName = args["component"]?.Value<string>();
            if (string.IsNullOrEmpty(typeName))
                return CommandRegistry.Error("Missing 'component' type name");

            var type = TypeHelper.FindType(typeName);
            if (type == null)
                return CommandRegistry.Error($"Type not found: {typeName}");

            var comp = go.GetComponent(type);
            if (comp == null)
                return CommandRegistry.Error($"{typeName} not found on {go.name}");

            Undo.DestroyObjectImmediate(comp);
            return CommandRegistry.Ok($"Removed {typeName} from {go.name}");
        }

        // args: {"id":12345,"component":"Transform"} — omit component to list all
        private static JObject GetProperties(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var typeName = args["component"]?.Value<string>();
            var result = new JObject();

            if (!string.IsNullOrEmpty(typeName))
            {
                var type = TypeHelper.FindType(typeName);
                if (type == null)
                    return CommandRegistry.Error($"Type not found: {typeName}");

                var comp = go.GetComponent(type);
                if (comp == null)
                    return CommandRegistry.Error($"Component not found: {typeName}");

                result[typeName] = SerializeProperties(comp);
            }
            else
            {
                foreach (var comp in go.GetComponents<Component>())
                {
                    if (comp == null) continue;
                    result[comp.GetType().Name] = SerializeProperties(comp);
                }
            }

            return CommandRegistry.Ok(result);
        }

        // args: {"id":12345,"component":"Transform","property":"m_LocalPosition.x","value":"5"}
        private static JObject SetProperty(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var typeName = args["component"]?.Value<string>();
            var propName = args["property"]?.Value<string>();
            var value = args["value"]?.Value<string>();

            if (string.IsNullOrEmpty(typeName) || string.IsNullOrEmpty(propName))
                return CommandRegistry.Error("Required: 'component', 'property', 'value'");

            var type = TypeHelper.FindType(typeName);
            if (type == null) return CommandRegistry.Error($"Type not found: {typeName}");

            var comp = go.GetComponent(type);
            if (comp == null) return CommandRegistry.Error($"Component not found: {typeName}");

            var so = new SerializedObject(comp);
            var prop = so.FindProperty(propName);
            if (prop == null) return CommandRegistry.Error($"Property not found: {propName}");

            if (!SetPropertyValue(prop, value))
                return CommandRegistry.Error($"Cannot set {prop.propertyType} from string");

            so.ApplyModifiedProperties();
            return CommandRegistry.Ok($"Set {propName} = {value} on {go.name}.{typeName}");
        }

        private static JObject SerializeProperties(Component comp)
        {
            var props = new JObject();
            var so = new SerializedObject(comp);
            var iter = so.GetIterator();
            if (iter.NextVisible(true))
            {
                do
                {
                    props[iter.name] = $"{GetPropertyValue(iter)} ({iter.propertyType})";
                } while (iter.NextVisible(false));
            }
            return props;
        }

        private static string GetPropertyValue(SerializedProperty prop)
        {
            switch (prop.propertyType)
            {
                case SerializedPropertyType.Integer: return prop.intValue.ToString();
                case SerializedPropertyType.Float: return prop.floatValue.ToString("F4");
                case SerializedPropertyType.Boolean: return prop.boolValue.ToString();
                case SerializedPropertyType.String: return prop.stringValue;
                case SerializedPropertyType.Vector2: return prop.vector2Value.ToString();
                case SerializedPropertyType.Vector3: return prop.vector3Value.ToString();
                case SerializedPropertyType.Enum: return prop.enumNames[prop.enumValueIndex];
                case SerializedPropertyType.ObjectReference:
                    return prop.objectReferenceValue != null ? prop.objectReferenceValue.name : "null";
                default: return $"({prop.propertyType})";
            }
        }

        private static bool SetPropertyValue(SerializedProperty prop, string value)
        {
            switch (prop.propertyType)
            {
                case SerializedPropertyType.Integer:
                    if (int.TryParse(value, out var i)) { prop.intValue = i; return true; } break;
                case SerializedPropertyType.Float:
                    if (float.TryParse(value, out var f)) { prop.floatValue = f; return true; } break;
                case SerializedPropertyType.Boolean:
                    if (bool.TryParse(value, out var b)) { prop.boolValue = b; return true; } break;
                case SerializedPropertyType.String:
                    prop.stringValue = value; return true;
                case SerializedPropertyType.Enum:
                    var idx = Array.IndexOf(prop.enumNames, value);
                    if (idx >= 0) { prop.enumValueIndex = idx; return true; } break;
                case SerializedPropertyType.ObjectReference:
                    if (int.TryParse(value, out var instanceId))
                    {
                        var obj = EditorUtility.InstanceIDToObject(instanceId);
                        if (obj == null) return false;
                        prop.objectReferenceValue = obj;
                        return true;
                    }
                    break;
            }
            return false;
        }
    }
}
