using NUnit.Framework;

namespace Tykit.Tests
{
    public abstract class CommandBackedTestsBase
    {
        [SetUp]
        public void EnsureCommandRegistryDefaults()
        {
            CommandRegistry.RestoreDefaults();
        }
    }
}
