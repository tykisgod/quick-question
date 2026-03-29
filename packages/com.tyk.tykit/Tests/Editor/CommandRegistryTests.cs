using NUnit.Framework;
using Newtonsoft.Json.Linq;

namespace Tykit.Tests
{
    public class CommandRegistryTests
    {
        [SetUp]
        public void Setup()
        {
            CommandRegistry.ClearAll();
        }

        [TearDown]
        public void TearDown()
        {
            CommandRegistry.RestoreDefaults();
        }

        // --- Registration ---

        [Test]
        public void Register_AddsCommand()
        {
            CommandRegistry.Register("test", args => CommandRegistry.Ok("hello"));
            Assert.IsTrue(CommandRegistry.HasCommand("test"));
        }

        [Test]
        public void Register_OverwritesSameName()
        {
            CommandRegistry.Register("test", args => CommandRegistry.Ok("v1"));
            CommandRegistry.Register("test", args => CommandRegistry.Ok("v2"));

            var result = CommandRegistry.Execute("{\"command\":\"test\"}");
            Assert.AreEqual("v2", result["data"].Value<string>());
        }

        [Test]
        public void GetCommandNames_ReturnsRegistered()
        {
            CommandRegistry.Register("a", args => CommandRegistry.Ok());
            CommandRegistry.Register("b", args => CommandRegistry.Ok());
            CollectionAssert.AreEquivalent(new[] { "a", "b" }, CommandRegistry.GetCommandNames());
        }

        // --- Execute: JSON parsing ---

        [Test]
        public void Execute_InvalidJson_ReturnsError()
        {
            var result = CommandRegistry.Execute("not json");
            Assert.IsFalse(result["success"].Value<bool>());
            StringAssert.Contains("Invalid JSON", result["error"].Value<string>());
        }

        [Test]
        public void Execute_MissingCommand_ReturnsError()
        {
            var result = CommandRegistry.Execute("{}");
            Assert.IsFalse(result["success"].Value<bool>());
            StringAssert.Contains("Missing 'command'", result["error"].Value<string>());
        }

        [Test]
        public void Execute_UnknownCommand_ReturnsError()
        {
            var result = CommandRegistry.Execute("{\"command\":\"nope\"}");
            Assert.IsFalse(result["success"].Value<bool>());
            StringAssert.Contains("Unknown command", result["error"].Value<string>());
        }

        // --- Execute: dispatching ---

        [Test]
        public void Execute_DispatchesToHandler()
        {
            CommandRegistry.Register("greet", args =>
                CommandRegistry.Ok($"hello {args["name"]?.Value<string>()}"));

            var result = CommandRegistry.Execute("{\"command\":\"greet\",\"args\":{\"name\":\"Mario\"}}");
            Assert.IsTrue(result["success"].Value<bool>());
            Assert.AreEqual("hello Mario", result["data"].Value<string>());
        }

        [Test]
        public void Execute_EmptyArgs_PassesEmptyJObject()
        {
            JObject received = null;
            CommandRegistry.Register("check", args => { received = args; return CommandRegistry.Ok(); });

            CommandRegistry.Execute("{\"command\":\"check\"}");
            Assert.IsNotNull(received);
            Assert.AreEqual(0, received.Count);
        }

        [Test]
        public void Execute_HandlerException_ReturnsError()
        {
            CommandRegistry.Register("bomb", args => throw new System.Exception("boom"));

            var result = CommandRegistry.Execute("{\"command\":\"bomb\"}");
            Assert.IsFalse(result["success"].Value<bool>());
            StringAssert.Contains("boom", result["error"].Value<string>());
        }

        // --- Response format ---

        [Test]
        public void Ok_ResponseFormat()
        {
            var result = CommandRegistry.Ok("data");
            Assert.IsTrue(result["success"].Value<bool>());
            Assert.AreEqual("data", result["data"].Value<string>());
            Assert.AreEqual(JTokenType.Null, result["error"].Type);
        }

        [Test]
        public void Error_ResponseFormat()
        {
            var result = CommandRegistry.Error("something broke");
            Assert.IsFalse(result["success"].Value<bool>());
            Assert.AreEqual(JTokenType.Null, result["data"].Type);
            Assert.AreEqual("something broke", result["error"].Value<string>());
        }

        // --- Batch ---

        [Test]
        public void Batch_ExecutesMultipleCommands()
        {
            int count = 0;
            CommandRegistry.Register("inc", args => { count++; return CommandRegistry.Ok(count); });

            var result = CommandRegistry.Execute(
                "{\"command\":\"batch\",\"args\":{\"commands\":[" +
                "{\"command\":\"inc\"},{\"command\":\"inc\"},{\"command\":\"inc\"}" +
                "]}}");

            Assert.IsTrue(result["success"].Value<bool>());
            var data = result["data"] as JArray;
            Assert.AreEqual(3, data.Count);
            Assert.AreEqual(3, count);
        }

        [Test]
        public void Batch_RefSubstitution_PassesInstanceId()
        {
            CommandRegistry.Register("make", args =>
                CommandRegistry.Ok(new JObject { ["instanceId"] = 42 }));

            JObject receivedArgs = null;
            CommandRegistry.Register("use", args => { receivedArgs = args; return CommandRegistry.Ok(); });

            CommandRegistry.Execute(
                "{\"command\":\"batch\",\"args\":{\"commands\":[" +
                "{\"command\":\"make\"}," +
                "{\"command\":\"use\",\"args\":{\"id\":\"$0\"}}" +
                "]}}");

            Assert.AreEqual(42, receivedArgs["id"].Value<int>());
        }

        [Test]
        public void Batch_EmptyCommands_ReturnsError()
        {
            var result = CommandRegistry.Execute(
                "{\"command\":\"batch\",\"args\":{\"commands\":[]}}");
            Assert.IsFalse(result["success"].Value<bool>());
        }

        [Test]
        public void Batch_PartialFailure_ContinuesExecution()
        {
            CommandRegistry.Register("ok-cmd", args => CommandRegistry.Ok("fine"));

            var result = CommandRegistry.Execute(
                "{\"command\":\"batch\",\"args\":{\"commands\":[" +
                "{\"command\":\"ok-cmd\"}," +
                "{\"command\":\"nonexistent\"}," +
                "{\"command\":\"ok-cmd\"}" +
                "]}}");

            Assert.IsTrue(result["success"].Value<bool>());
            var data = result["data"] as JArray;
            Assert.AreEqual(3, data.Count);
            Assert.IsTrue(data[0]["success"].Value<bool>());
            Assert.IsFalse(data[1]["success"].Value<bool>());
            Assert.IsTrue(data[2]["success"].Value<bool>());
        }
    }
}
