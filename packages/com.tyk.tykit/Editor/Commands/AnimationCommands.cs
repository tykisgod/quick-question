using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEditor;

namespace Tykit
{
    [InitializeOnLoad]
    public static class AnimationCommands
    {
        static AnimationCommands()
        {
            RegisterCommands();
        }

        public static void RegisterCommands()
        {
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "create-animation",
                    "Create an animation clip and assign an AnimatorController to a GameObject.",
                    "animation.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("clip", CommandSchema.String("Animation clip name.")),
                        ("path", CommandSchema.String("Optional clip asset path.")),
                        ("loop", CommandSchema.Boolean("Whether the clip should loop.")),
                        ("keyframes", CommandSchema.Array(CommandSchema.Object(), "Keyframe objects containing time, property, and value.")))),
                CreateAnimation);
            CommandRegistry.Register(
                CommandRegistry.Describe(
                    "set-animator",
                    "Assign an AnimatorController or set an Animator parameter.",
                    "animation.mutate",
                    true,
                    CommandSchema.Object(
                        ("id", CommandSchema.Integer("GameObject instanceId.")),
                        ("path", CommandSchema.String("Hierarchy path.")),
                        ("name", CommandSchema.String("GameObject name.")),
                        ("controller", CommandSchema.String("Optional RuntimeAnimatorController asset path.")),
                        ("parameter", CommandSchema.String("Animator parameter name.")),
                        ("float", CommandSchema.Number("Optional float parameter value.")),
                        ("int", CommandSchema.Integer("Optional integer parameter value.")),
                        ("bool", CommandSchema.Boolean("Optional boolean parameter value.")),
                        ("trigger", CommandSchema.Boolean("Set trigger when true.")))),
                SetAnimator);
        }

        // args: {
        //   "id": ID,                          // target GameObject
        //   "clip": "BounceClip",              // clip name (also used as asset name)
        //   "path": "Assets/.../Bounce.anim",  // optional: save as asset
        //   "loop": true,                      // default true
        //   "keyframes": [
        //     {"time":0,   "property":"localPosition.y", "value":0},
        //     {"time":0.5, "property":"localPosition.y", "value":2},
        //     {"time":1,   "property":"localPosition.y", "value":0}
        //   ]
        // }
        // Supported properties: localPosition.x/y/z, localEulerAngles.x/y/z, localScale.x/y/z,
        //   or any animatable float property path (e.g. "m_SpriteRenderer.m_Color.r")
        private static JObject CreateAnimation(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var clipName = args["clip"]?.Value<string>() ?? "NewClip";
            var loop = args["loop"]?.Value<bool>() ?? true;
            var keyframes = args["keyframes"] as JArray;

            if (keyframes == null || keyframes.Count == 0)
                return CommandRegistry.Error("Missing 'keyframes' array");

            // Group keyframes by property
            var curves = new Dictionary<string, List<Keyframe>>();
            foreach (var kf in keyframes)
            {
                var time = kf["time"]?.Value<float>() ?? 0f;
                var prop = kf["property"]?.Value<string>();
                var value = kf["value"]?.Value<float>() ?? 0f;

                if (string.IsNullOrEmpty(prop))
                    return CommandRegistry.Error("Each keyframe needs 'time', 'property', 'value'");

                if (!curves.ContainsKey(prop))
                    curves[prop] = new List<Keyframe>();

                curves[prop].Add(new Keyframe(time, value));
            }

            // Create AnimationClip
            var clip = new AnimationClip();
            clip.name = clipName;

            foreach (var kvp in curves)
            {
                var propertyPath = kvp.Key;
                var keys = kvp.Value.ToArray();
                var curve = new AnimationCurve(keys);

                // Resolve the binding: split "component.property" or use Transform
                var (type, resolvedPath) = ResolvePropertyBinding(propertyPath);
                clip.SetCurve("", type, resolvedPath, curve);
            }

            if (loop)
            {
                var settings = AnimationUtility.GetAnimationClipSettings(clip);
                settings.loopTime = true;
                AnimationUtility.SetAnimationClipSettings(clip, settings);
            }

            // Save as asset if path provided
            var assetPath = args["path"]?.Value<string>();
            if (!string.IsNullOrEmpty(assetPath))
            {
                var dir = System.IO.Path.GetDirectoryName(assetPath);
                if (!string.IsNullOrEmpty(dir) && !System.IO.Directory.Exists(dir))
                    System.IO.Directory.CreateDirectory(dir);
                AssetDatabase.CreateAsset(clip, assetPath);
                AssetDatabase.SaveAssets();
            }

            // Ensure Animator exists and assign the clip
            var animator = go.GetComponent<Animator>();
            if (animator == null)
                animator = go.AddComponent<Animator>();

            // Create a simple AnimatorController with one state
            var controller = UnityEditor.Animations.AnimatorController.CreateAnimatorControllerAtPathWithClip(
                $"Assets/{clipName}_Controller.controller", clip);
            animator.runtimeAnimatorController = controller;

            EditorUtility.SetDirty(go);

            return CommandRegistry.Ok(new JObject
            {
                ["name"] = go.name,
                ["instanceId"] = go.GetInstanceID(),
                ["clip"] = clipName,
                ["properties"] = new JArray(curves.Keys),
                ["controller"] = $"Assets/{clipName}_Controller.controller"
            });
        }

        // args: {"id":ID, "controller":"Assets/.../Controller.controller", "parameter":"Speed", "float":1.5}
        // Sets an animator parameter
        private static JObject SetAnimator(JObject args)
        {
            var (go, err) = CommandRegistry.ResolveGameObject(args);
            if (go == null) return CommandRegistry.Error(err);

            var animator = go.GetComponent<Animator>();
            if (animator == null)
                return CommandRegistry.Error($"No Animator on {go.name}");

            // Optionally assign a controller
            var controllerPath = args["controller"]?.Value<string>();
            if (!string.IsNullOrEmpty(controllerPath))
            {
                var controller = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(controllerPath);
                if (controller == null)
                    return CommandRegistry.Error($"Controller not found: {controllerPath}");
                animator.runtimeAnimatorController = controller;
            }

            // Set parameter
            var paramName = args["parameter"]?.Value<string>();
            if (!string.IsNullOrEmpty(paramName))
            {
                if (args["float"] != null)
                    animator.SetFloat(paramName, args["float"].Value<float>());
                else if (args["int"] != null)
                    animator.SetInteger(paramName, args["int"].Value<int>());
                else if (args["bool"] != null)
                    animator.SetBool(paramName, args["bool"].Value<bool>());
                else if (args["trigger"] != null && args["trigger"].Value<bool>())
                    animator.SetTrigger(paramName);

                return CommandRegistry.Ok($"Set {paramName} on {go.name}");
            }

            return CommandRegistry.Ok($"Animator configured on {go.name}");
        }

        private static (System.Type type, string path) ResolvePropertyBinding(string propertyPath)
        {
            // Common shortcuts for Transform properties
            if (propertyPath.StartsWith("localPosition."))
                return (typeof(Transform), propertyPath);
            if (propertyPath.StartsWith("localEulerAngles.") || propertyPath.StartsWith("localRotation."))
                return (typeof(Transform), propertyPath);
            if (propertyPath.StartsWith("localScale."))
                return (typeof(Transform), propertyPath);

            // Default: treat as Transform property
            return (typeof(Transform), propertyPath);
        }
    }
}
