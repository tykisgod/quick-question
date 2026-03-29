using System;
using System.Collections.Generic;
using System.Linq;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Tykit
{
    // Metadata descriptors back both describe-commands and MCP schema enrichment.
    public sealed class CommandDescriptor
    {
        public string Name { get; }
        public string Summary { get; }
        public string Category { get; }
        public bool IsWrite { get; }
        public JObject InputSchema { get; }
        public JArray Examples { get; }

        public CommandDescriptor(
            string name,
            string summary,
            string category,
            bool isWrite,
            JObject inputSchema = null,
            JArray examples = null)
        {
            Name = name;
            Summary = summary;
            Category = category;
            IsWrite = isWrite;
            InputSchema = inputSchema ?? CommandSchema.Object();
            Examples = examples ?? new JArray();
        }

        public JObject ToJson()
        {
            return new JObject
            {
                ["name"] = Name,
                ["summary"] = Summary,
                ["category"] = Category,
                ["isWrite"] = IsWrite,
                ["inputSchema"] = InputSchema.DeepClone(),
                ["examples"] = Examples.DeepClone()
            };
        }
    }

    public static class CommandSchema
    {
        public static JObject Object(params (string Name, JToken Schema)[] properties)
        {
            var props = new JObject();
            foreach (var (name, schema) in properties)
                props[name] = schema;

            return new JObject
            {
                ["type"] = "object",
                ["properties"] = props
            };
        }

        public static JObject String(string description = null, params string[] enumValues)
        {
            var schema = new JObject { ["type"] = "string" };
            if (!string.IsNullOrEmpty(description))
                schema["description"] = description;
            if (enumValues != null && enumValues.Length > 0)
                schema["enum"] = new JArray(enumValues);
            return schema;
        }

        public static JObject Integer(string description = null)
        {
            var schema = new JObject { ["type"] = "integer" };
            if (!string.IsNullOrEmpty(description))
                schema["description"] = description;
            return schema;
        }

        public static JObject Number(string description = null)
        {
            var schema = new JObject { ["type"] = "number" };
            if (!string.IsNullOrEmpty(description))
                schema["description"] = description;
            return schema;
        }

        public static JObject Boolean(string description = null)
        {
            var schema = new JObject { ["type"] = "boolean" };
            if (!string.IsNullOrEmpty(description))
                schema["description"] = description;
            return schema;
        }

        public static JObject Array(JToken items, string description = null)
        {
            var schema = new JObject
            {
                ["type"] = "array",
                ["items"] = items
            };
            if (!string.IsNullOrEmpty(description))
                schema["description"] = description;
            return schema;
        }

        public static JArray Examples(params JObject[] examples)
        {
            return new JArray(examples ?? System.Array.Empty<JObject>());
        }
    }

    public static class CommandRegistry
    {
        private static readonly Dictionary<string, Func<JObject, JObject>> _commands = new();
        private static readonly Dictionary<string, CommandDescriptor> _descriptors = new();

        public static void Register(string name, Func<JObject, JObject> handler)
        {
            _commands[name] = handler;
            if (!_descriptors.ContainsKey(name))
                _descriptors[name] = new CommandDescriptor(name, "", "uncategorized", false);
        }

        public static void Register(CommandDescriptor descriptor, Func<JObject, JObject> handler)
        {
            _commands[descriptor.Name] = handler;
            _descriptors[descriptor.Name] = descriptor;
        }

        public static bool HasCommand(string name) => _commands.ContainsKey(name);

        public static IEnumerable<string> GetCommandNames() => _commands.Keys;

        public static IEnumerable<CommandDescriptor> GetDescriptors() => _descriptors.Values;

        public static void ClearAll()
        {
            _commands.Clear();
            _descriptors.Clear();
        }

        public static void RestoreDefaults()
        {
            ClearAll();
            TykitBootstrap.EnsureCommandsRegistered();
        }

        public static CommandDescriptor Describe(
            string name,
            string summary,
            string category,
            bool isWrite,
            JObject inputSchema = null,
            JArray examples = null)
        {
            return new CommandDescriptor(name, summary, category, isWrite, inputSchema, examples);
        }

        public static JObject Execute(string requestBody)
        {
            JObject request;
            try
            {
                request = JObject.Parse(requestBody);
            }
            catch (Exception e)
            {
                return Error($"Invalid JSON: {e.Message}");
            }

            var command = request["command"]?.Value<string>();
            if (string.IsNullOrEmpty(command))
                return Error("Missing 'command' field");

            if (command == "batch")
                return ExecuteBatch(request);

            if (!_commands.TryGetValue(command, out var handler))
                return Error($"Unknown command: {command}. Available: {string.Join(", ", _commands.Keys)}");

            var args = request["args"] as JObject ?? new JObject();

            try
            {
                return handler(args);
            }
            catch (Exception e)
            {
                return Error(e.ToString());
            }
        }

        private static JObject ExecuteBatch(JObject request)
        {
            var commands = request["args"]?["commands"] as JArray;
            if (commands == null || commands.Count == 0)
                return Error("batch requires non-empty args.commands array");

            var results = new JArray();
            var instanceIds = new List<int>();

            foreach (var cmd in commands)
            {
                var cmdObj = cmd as JObject;
                if (cmdObj == null)
                {
                    results.Add(Error("Invalid command entry"));
                    instanceIds.Add(0);
                    continue;
                }

                var name = cmdObj["command"]?.Value<string>();
                if (string.IsNullOrEmpty(name) || !_commands.TryGetValue(name, out var handler))
                {
                    results.Add(Error($"Unknown command: {name}"));
                    instanceIds.Add(0);
                    continue;
                }

                var args = cmdObj["args"] as JObject ?? new JObject();
                SubstituteRefs(args, instanceIds);

                JObject result;
                try
                {
                    result = handler(args);
                }
                catch (Exception e)
                {
                    result = Error(e.ToString());
                }

                results.Add(result);
                var data = result["data"] as JObject;
                instanceIds.Add(data?["instanceId"]?.Value<int>() ?? 0);
            }

            return Ok(results);
        }

        private static void SubstituteRefs(JObject args, List<int> instanceIds)
        {
            var keys = args.Properties().Select(p => p.Name).ToList();
            foreach (var key in keys)
            {
                if (args[key] is JValue jv && jv.Type == JTokenType.String)
                {
                    var str = jv.Value<string>();
                    if (str.StartsWith("$") && int.TryParse(str.Substring(1), out var refIdx)
                        && refIdx >= 0 && refIdx < instanceIds.Count)
                    {
                        args[key] = instanceIds[refIdx];
                    }
                }
            }
        }

        // --- Public helpers for command implementations ---

        public static JObject Ok(JToken data = null)
        {
            return new JObject { ["success"] = true, ["data"] = data, ["error"] = null };
        }

        public static JObject Error(string message)
        {
            return new JObject { ["success"] = false, ["data"] = null, ["error"] = message };
        }

        public static JObject DescribeCommands()
        {
            return Ok(new JArray(
                GetDescriptors()
                    .OrderBy(d => d.Name)
                    .Select(d => d.ToJson())));
        }

        /// <summary>
        /// Find a GameObject by instanceId, path, or name.
        /// </summary>
        public static (GameObject go, string error) ResolveGameObject(JObject args)
        {
            if (args["id"] != null)
            {
                var id = args["id"].Value<int>();
                var obj = UnityEditor.EditorUtility.InstanceIDToObject(id) as GameObject;
                if (obj == null)
                    return (null, $"No GameObject with instanceId {id}");
                return (obj, null);
            }

            var path = args["path"]?.Value<string>();
            var name = args["name"]?.Value<string>();
            var query = !string.IsNullOrEmpty(path) ? path : name;

            if (string.IsNullOrEmpty(query))
                return (null, "Provide 'id', 'path', or 'name' to identify the GameObject");

            var go = GameObject.Find(query);
            if (go == null)
                return (null, $"GameObject not found: {query}");

            return (go, null);
        }
    }

    /// <summary>
    /// Find Type by short name across loaded assemblies.
    /// </summary>
    public static class TypeHelper
    {
        public static Type FindType(string typeName)
        {
            var type = Type.GetType(typeName);
            if (type != null) return type;

            foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
            {
                try
                {
                    foreach (var t in assembly.GetTypes())
                    {
                        if (t.Name == typeName)
                            return t;
                    }
                }
                catch (System.Reflection.ReflectionTypeLoadException) { }
            }
            return null;
        }
    }
}
