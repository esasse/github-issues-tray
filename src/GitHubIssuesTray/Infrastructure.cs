using System.Diagnostics;
using System.Text.RegularExpressions;

namespace IssuesTray;

/// <summary>Where the app keeps its state: %LOCALAPPDATA%\github-issues-tray, the same
/// folder the PowerShell version used, so its cache and order carry over.</summary>
internal static class AppPaths
{
    private static readonly string? Home = Environment.GetEnvironmentVariable("GITHUB_ISSUES_TRAY_HOME") is { Length: > 0 } h
        ? Path.GetFullPath(h)
        : null;

    /// <summary>GITHUB_ISSUES_TRAY_HOME points the app at another folder: a throwaway
    /// one for trying things, so test data never lands next to the real cache. Made
    /// absolute, so a relative value does not follow the folder the app started in.</summary>
    public static readonly string Root = Home ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "github-issues-tray");

    /// <summary>Names the single-instance mutex and the tray window class. A copy
    /// running on another home is a separate app: with the same names, launching it
    /// next to the real one would only open the real one's list.</summary>
    public static readonly string InstanceName = Home == null
        ? "GitHubIssuesTray"
        : "GitHubIssuesTray-" + Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Root.ToLowerInvariant())))[..12];

    public static string ConfigFile => Path.Combine(Root, "config.json");
    public static string CacheFile => Path.Combine(Root, "cache.json");
    public static string PrefsFile => Path.Combine(Root, "prefs.json");
    public static string LogFile => Path.Combine(Root, "tray.log");

    /// <summary>Where the PowerShell version kept its config.json: the repository root,
    /// which is the parent of dist\.</summary>
    public static string LegacyConfigFile => Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "config.json"));

    public static void Ensure() => Directory.CreateDirectory(Root);
}

internal static partial class Log
{
    private static readonly object Gate = new();

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(AppPaths.Root);
                var file = new FileInfo(AppPaths.LogFile);
                if (file.Exists && file.Length > 256 * 1024) file.Delete();
                File.AppendAllText(AppPaths.LogFile,
                    $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {OneLine(message)}\r\n");
            }
        }
        catch
        {
            // a log that throws would take down whatever was trying to report a problem
        }
    }

    /// <summary>Collapses whitespace: gh writes multi-line errors ("error connecting to
    /// api.github.com\ncheck your internet connection..."), and one of those would turn
    /// a log entry into three lines and the popup's status line into a mess.</summary>
    public static string OneLine(string? text) => Whitespace().Replace(text ?? "", " ").Trim();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();
}

internal static class Shell
{
    public static void Open(string? target)
    {
        if (string.IsNullOrWhiteSpace(target)) return;
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Write($"could not open {target}: {ex.Message}");
        }
    }

    public static void Edit(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo("notepad.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Write($"could not open {path} in Notepad: {ex.Message}");
        }
    }
}
