using NUnit.Framework;
using Newtonsoft.Json.Linq;

namespace Tykit.Tests
{
    public class AssetCommandsTests : CommandBackedTestsBase
    {
        [Test]
        public void ListAssets_ReturnsArray()
        {
            var result = Exec("list-assets", new JObject { ["filter"] = "t:Scene" });
            AssertOk(result);
            Assert.IsInstanceOf<JArray>(result["data"]);
        }

        [Test]
        public void ListAssets_DefaultFilter_ReturnsResults()
        {
            var result = Exec("list-assets");
            AssertOk(result);
            var arr = result["data"] as JArray;
            Assert.Greater(arr.Count, 0);
        }

        [Test]
        public void ListAssets_WithPath_FiltersDirectory()
        {
            var all = Exec("list-assets");
            var filtered = Exec("list-assets", new JObject { ["path"] = "Assets/Scripts" });
            AssertOk(all);
            AssertOk(filtered);
            // filtered should have fewer or equal results
            Assert.LessOrEqual((filtered["data"] as JArray).Count, (all["data"] as JArray).Count);
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
    }
}
