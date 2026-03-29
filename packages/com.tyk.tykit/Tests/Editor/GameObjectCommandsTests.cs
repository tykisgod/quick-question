using NUnit.Framework;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEditor;

namespace Tykit.Tests
{
    public class GameObjectCommandsTests : CommandBackedTestsBase
    {
        private GameObject _go;

        [SetUp]
        public void Setup()
        {
            _go = new GameObject("TestObj");
        }

        [TearDown]
        public void TearDown()
        {
            if (_go != null) Object.DestroyImmediate(_go);
            // clean up any stray test objects
            var leftover = GameObject.Find("TestObj_Clone");
            if (leftover != null) Object.DestroyImmediate(leftover);
            leftover = GameObject.Find("TestObj");
            if (leftover != null) Object.DestroyImmediate(leftover);
            leftover = GameObject.Find("TestParent");
            if (leftover != null) Object.DestroyImmediate(leftover);
        }

        // --- set-parent ---

        [Test]
        public void SetParent_ByName()
        {
            var parent = new GameObject("TestParent");
            try
            {
                var result = Exec("set-parent", new JObject
                {
                    ["id"] = _go.GetInstanceID(),
                    ["parent"] = "TestParent"
                });
                AssertOk(result);
                Assert.AreEqual(parent.transform, _go.transform.parent);
            }
            finally
            {
                Object.DestroyImmediate(parent);
            }
        }

        [Test]
        public void SetParent_ById()
        {
            var parent = new GameObject("TestParent");
            try
            {
                var result = Exec("set-parent", new JObject
                {
                    ["id"] = _go.GetInstanceID(),
                    ["parentId"] = parent.GetInstanceID()
                });
                AssertOk(result);
                Assert.AreEqual(parent.transform, _go.transform.parent);
            }
            finally
            {
                Object.DestroyImmediate(parent);
            }
        }

        [Test]
        public void SetParent_Null_Unparents()
        {
            var parent = new GameObject("TestParent");
            _go.transform.SetParent(parent.transform);
            try
            {
                var result = Exec("set-parent", new JObject
                {
                    ["id"] = _go.GetInstanceID(),
                    ["parent"] = JValue.CreateNull()
                });
                AssertOk(result);
                Assert.IsNull(_go.transform.parent);
            }
            finally
            {
                Object.DestroyImmediate(parent);
            }
        }

        [Test]
        public void SetParent_NotFound_ReturnsError()
        {
            var result = Exec("set-parent", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["parent"] = "NonExistentParent"
            });
            AssertError(result, "not found");
        }

        // --- duplicate ---

        [Test]
        public void Duplicate_CreatesClone()
        {
            var result = Exec("duplicate", new JObject { ["id"] = _go.GetInstanceID() });
            AssertOk(result);
            var cloneId = result["data"]["instanceId"].Value<int>();
            var clone = EditorUtility.InstanceIDToObject(cloneId) as GameObject;
            Assert.IsNotNull(clone);
            Assert.AreEqual("TestObj", clone.name);
            Object.DestroyImmediate(clone);
        }

        // --- set-active ---

        [Test]
        public void SetActive_Deactivates()
        {
            var result = Exec("set-active", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["active"] = false
            });
            AssertOk(result);
            Assert.IsFalse(_go.activeSelf);
        }

        [Test]
        public void SetActive_Activates()
        {
            _go.SetActive(false);
            var result = Exec("set-active", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["active"] = true
            });
            AssertOk(result);
            Assert.IsTrue(_go.activeSelf);
        }

        [Test]
        public void SetActive_MissingField_ReturnsError()
        {
            var result = Exec("set-active", new JObject { ["id"] = _go.GetInstanceID() });
            AssertError(result, "Missing 'active'");
        }

        // --- set-layer ---

        [Test]
        public void SetLayer_ByName()
        {
            var result = Exec("set-layer", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["layer"] = "Ignore Raycast"
            });
            AssertOk(result);
            Assert.AreEqual(LayerMask.NameToLayer("Ignore Raycast"), _go.layer);
        }

        [Test]
        public void SetLayer_ByIndex()
        {
            var result = Exec("set-layer", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["layer"] = 5
            });
            AssertOk(result);
            Assert.AreEqual(5, _go.layer);
        }

        [Test]
        public void SetLayer_InvalidName_ReturnsError()
        {
            var result = Exec("set-layer", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["layer"] = "NonExistentLayer"
            });
            AssertError(result, "not found");
        }

        // --- set-tag ---

        [Test]
        public void SetTag_Valid()
        {
            var result = Exec("set-tag", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["tag"] = "MainCamera"
            });
            AssertOk(result);
            Assert.AreEqual("MainCamera", _go.tag);
        }

        [Test]
        public void SetTag_MissingField_ReturnsError()
        {
            var result = Exec("set-tag", new JObject { ["id"] = _go.GetInstanceID() });
            AssertError(result, "Missing 'tag'");
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
