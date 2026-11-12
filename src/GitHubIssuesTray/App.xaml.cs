using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace IssuesTray;

public partial class App : Application
{
    private Mutex? _instance;
    private IssuesController? _controller;

    public App()
    {
        InitializeComponent();

        // A tray app lives for days. No bug in a callback should ever reach the user
        // as a crash dialog: log it and stay up.
        UnhandledException += (_, e) =>
        {
            Log.Write($"unhandled UI exception: {e.Exception}");
            e.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Write($"unobserved task exception: {e.Exception}");
            e.SetObserved();
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"fatal: {e.ExceptionObject}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _instance = new Mutex(true, @"Local\" + AppPaths.InstanceName, out var createdNew);
        if (!createdNew)
        {
            // Already in the tray: a second launch (Start menu, autostart plus a
            // double click) opens the running one's list instead of a twin.
            TrayHost.SignalRunningInstance();
            Log.Write("another instance is running; asked it to open its list and exited");
            Exit();
            return;
        }

        // The app has no window most of the time; it ends on Quit, not when the
        // popup goes away.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;

        var argv = Environment.GetCommandLineArgs().Skip(1).ToList();
        bool Has(string flag) => argv.Any(a => a.Equals(flag, StringComparison.OrdinalIgnoreCase));

        _controller = new IssuesController(DispatcherQueue.GetForCurrentThread(), offline: Has("--offline"));
        _controller.Start(showPopup: Has("--show"));
    }
}
