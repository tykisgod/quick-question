using NUnit.Framework;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Tykit.Tests
{
    public class ComponentCommandsTests : CommandBackedTestsBase
    {
        private GameObject _go;

        [SetUp]
        public void Setup()
        {
            _go = new GameObject("TestComp");
            _go.AddComponent<BoxCollider>();
        }

        [TearDown]
        public void TearDown()
        {
            if (_go != null) Object.DestroyImmediate(_go);
        }

        [Test]
        public void RemoveComponent_RemovesIt()
        {
            Assert.IsNotNull(_go.GetComponent<BoxCollider>());
            var result = Exec("remove-component", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["component"] = "BoxCollider"
            });
            AssertOk(result);
            Assert.IsNull(_go.GetComponent<BoxCollider>());
        }

        [Test]
        public void RemoveComponent_NotFound_ReturnsError()
        {
            var result = Exec("remove-component", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["component"] = "Rigidbody"
            });
            AssertError(result, "not found on");
        }

        [Test]
        public void RemoveComponent_MissingTypeName_ReturnsError()
        {
            var result = Exec("remove-component", new JObject
            {
                ["id"] = _go.GetInstanceID()
            });
            AssertError(result, "Missing 'component'");
        }

        [Test]
        public void RemoveComponent_InvalidType_ReturnsError()
        {
            var result = Exec("remove-component", new JObject
            {
                ["id"] = _go.GetInstanceID(),
                ["component"] = "TotallyFakeComponent"
            });
            AssertError(result, "Type not found");
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
