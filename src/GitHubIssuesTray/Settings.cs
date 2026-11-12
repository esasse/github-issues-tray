using System.Text.Json;
using System.Text.Json.Serialization;

namespace IssuesTray;

/// <summary>
/// config.json, with the same keys the PowerShell version read, so the old file
/// works as it is. Keys it no longer knows (includePullRequests) are ignored.
/// </summary>
internal sealed class Settings
{
    public int RefreshMinutes { get; set; } = 5;
    public int MaxItems { get; set; } = 50;
    public bool IncludeReviewRequests { get; set; } = true;
    public bool ShowLabels { get; set; } = true;
    public string Hotkey { get; set; } = "Ctrl+Win+I";
    public string AccentColor { get; set; } = "#00A8FF";
    public int PopupWidth { get; set; } = 520;
    public int PopupMaxHeight { get; set; } = 620;

    internal static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public static Settings Load()
    {
        var settings = new Settings();
        try
        {
            if (!File.Exists(AppPaths.ConfigFile)) Create();
            settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(AppPaths.ConfigFile), Json) ?? new Settings();
        }
        catch (Exception ex)
        {
            Log.Write($"invalid config.json, using the defaults: {ex.Message}");
            settings = new Settings();
        }

        settings.Hotkey ??= "";
        settings.AccentColor ??= "#00A8FF";
        settings.RefreshMinutes = Math.Clamp(settings.RefreshMinutes, 1, 1440);
        settings.MaxItems = Math.Clamp(settings.MaxItems, 1, 100);
        settings.PopupWidth = Math.Clamp(settings.PopupWidth, 360, 1600);
        settings.PopupMaxHeight = Math.Clamp(settings.PopupMaxHeight, 240, 2400);
        return settings;
    }

    /// <summary>The PowerShell version kept config.json next to the script, at the
    /// repository root. A build wipes dist\, so it could not stay next to the .exe:
    /// the first run copies the old file over, and creates the defaults otherwise.</summary>
    private static void Create()
    {
        var legacy = AppPaths.LegacyConfigFile;
        if (File.Exists(legacy))
        {
            File.Copy(legacy, AppPaths.ConfigFile);
            Log.Write($"config.json copied from {legacy}");
            return;
        }
        File.WriteAllText(AppPaths.ConfigFile, JsonSerializer.Serialize(new Settings(), Json));
    }
}
