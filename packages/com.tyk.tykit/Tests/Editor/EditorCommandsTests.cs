using NUnit.Framework;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEditor;
using UnityEditor.SceneManagement;

namespace Tykit.Tests
{
    public class EditorCommandsTests : CommandBackedTestsBase
    {
        [Test]
        public void CompileStatus_ReturnsFields()
        {
            var result = Exec("compile-status");
            AssertOk(result);
            var data = result["data"] as JObject;
            Assert.IsNotNull(data["isCompiling"]);
            Assert.IsNotNull(data["isUpdating"]);
        }

        [Test]
        public void GetSelection_EmptyByDefault()
        {
            Selection.activeGameObject = null;
            var result = Exec("get-selection");
            AssertOk(result);
            Assert.AreEqual(0, (result["data"] as JArray).Count);
        }

        [Test]
        public void GetSelection_ReturnsSelectedObject()
        {
            var go = new GameObject("TestSelect");
            try
            {
                Selection.activeGameObject = go;
                var result = Exec("get-selection");
                AssertOk(result);
                var arr = result["data"] as JArray;
                Assert.AreEqual(1, arr.Count);
                Assert.AreEqual("TestSelect", arr[0]["name"].Value<string>());
                Assert.AreEqual(go.GetInstanceID(), arr[0]["instanceId"].Value<int>());
            }
            finally
            {
                Selection.activeGameObject = null;
                Object.DestroyImmediate(go);
            }
        }

        [Test]
        public void OpenScene_MissingPath_ReturnsError()
        {
            var result = Exec("open-scene");
            AssertError(result, "Missing 'path'");
        }

        [Test]
        public void OpenScene_InvalidPath_ReturnsError()
        {
            var result = Exec("open-scene", new JObject { ["path"] = "Assets/NonExistent.unity" });
            AssertError(result, "not found");
        }

        [Test]
        public void ListScenes_ReturnsArray()
        {
            var result = Exec("list-scenes");
            AssertOk(result);
            Assert.IsInstanceOf<JArray>(result["data"]);
        }

        // --- helpers ---

        private static JObject Exec(string command, JObject args = null)
        {
            var req = new JObject { ["command"] = command };
            if (args != null) req["args"] = args;
            return CommandRegistry.Execute(req.ToString());
        }

        private static void AssertOk(JObject result)
        {
            Assert.IsTrue(result["success"].Value<bool>(), result["error"]?.Value<string>());
        }

        private static void AssertError(JObject result, string contains)
        {
            Assert.IsFalse(result["success"].Value<bool>());
            StringAssert.Contains(contains, result["error"].Value<string>());
        }
    }
}
