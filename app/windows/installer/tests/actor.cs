// Harmless executable and real SCM service used only by the isolated fixture.
using System;
using System.ServiceProcess;
using System.Threading;

sealed class FixtureService : ServiceBase {
    readonly int delay;
    public FixtureService(string name, int stopDelay) {
        if (!name.StartsWith("AuroraLifecycleTest_", StringComparison.Ordinal))
            throw new ArgumentException("fixture service name required");
        ServiceName = name;
        CanStop = true;
        delay = stopDelay;
    }
    protected override void OnStart(string[] args) { }
    protected override void OnStop() {
        RequestAdditionalTime(delay + 5000);
        Thread.Sleep(delay);
    }
    static void Main(string[] args) {
        if (args.Length == 2) {
            ServiceBase.Run(new FixtureService(args[0], Int32.Parse(args[1])));
        } else {
            Thread.Sleep(600000);
        }
    }
}
