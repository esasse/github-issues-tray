using IssuesTray.Issues;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace IssuesTray;

/// <summary>
/// Owns the list and everything that keeps it current: the periodic fetch, a clock
/// for the ages, the retries, and the actions. The tray icon and the popup only draw
/// what is here.
/// </summary>
internal sealed class IssuesController : IDisposable
{
    public const string AssignedPageUrl = "https://github.com/issues/assigned";
    private static readonly TimeSpan FetchTimeout = TimeSpan.FromSeconds(60);
    private static readonly int[] RetryDelaysSec = [20, 60, 120, 300];

    private readonly TrayHost _tray;
    private readonly PopupWindow _popup;
    private readonly DispatcherQueueTimer _refreshTimer;
    private readonly DispatcherQueueTimer _clockTimer;
    private readonly DispatcherQueueTimer _retryTimer;
    private readonly bool _offline;
    private string? _gh;
    private int _retryCount;
    private DateTimeOffset _lastTick = DateTimeOffset.Now;
    private string _iconSignature = "";

    public IssuesController(DispatcherQueue dispatcher, bool offline)
    {
        _offline = offline;
        AppPaths.Ensure();
        Settings = Settings.Load();
        Native.AllowDarkMenus();

        _tray = new TrayHost();
        _tray.Click += () => _popup!.Toggle();
        _tray.HotkeyPressed += () => _popup!.Toggle();
        _tray.ShowRequested += () => { if (!_popup!.IsOpen) _popup.ShowPopup(); };
        _tray.MiddleClick += () => Shell.Open(Visible().FirstOrDefault()?.Url);
        _tray.ContextMenuRequested += ShowMenu;
        _tray.AppearanceChanged += () =>
        {
            _iconSignature = "";
            UpdateTray();
        };

        _popup = new PopupWindow(this);

        _refreshTimer = dispatcher.CreateTimer();
        _refreshTimer.Interval = TimeSpan.FromMinutes(Settings.RefreshMinutes);
        _refreshTimer.Tick += (_, _) => Refresh();

        // Keeps the "3m ago" current without touching the network, and notices a
        // resume from sleep.
        _clockTimer = dispatcher.CreateTimer();
        _clockTimer.Interval = TimeSpan.FromSeconds(60);
        _clockTimer.Tick += (_, _) => OnClock();

        _retryTimer = dispatcher.CreateTimer();
        _retryTimer.IsRepeating = false;
        _retryTimer.Tick += (_, _) => Refresh();
    }

    public Settings Settings { get; private set; }
    public IReadOnlyList<GhItem> Items { get; private set; } = [];
    public DateTimeOffset? LastUpdate { get; private set; }
    public string? LastError { get; private set; }
    public bool Fetching { get; private set; }
    public DateTimeOffset Now { get; private set; } = DateTimeOffset.Now;
    public bool IncludeReviews => Settings.IncludeReviewRequests;

    /// <summary>O flips the list between newest and oldest first. Unlike the filters it
    /// hides nothing, so it is a preference that outlives the popup and the app.</summary>
    public bool OldestFirst { get; private set; }

    /// <summary>“Nothing yet” is not “zero”: until the first query comes back the count
    /// is unknown. During a later refresh the number on screen stays truer than a
    /// spinner, so this is the only moment the loading state is the honest answer.</summary>
    public bool Loading => LastUpdate == null && LastError == null && Items.Count == 0;

    /// <summary>
    /// What the tray counts and the popup lists before its own filters: issues and
    /// assigned PRs always, plus the PRs asking for your review (only fetched with
    /// review requests on), newest first, capped at maxItems.
    /// </summary>
    public IReadOnlyList<GhItem> Visible() =>
        Items.Where(i => i.IsAssigned || i.IsReview)
             .OrderByDescending(i => i.Updated)
             .Take(Settings.MaxItems)
             .ToList();

    public void Start(bool showPopup)
    {
        GhClient.TelemetryOff();
        _gh = GhClient.Find();
        if (_gh == null && !_offline)
        {
            LastError = "GitHub CLI (gh) not found. Install it with: winget install GitHub.cli";
            Log.Write(LastError);
        }

        // The cache first, so the list is populated the moment the app comes up,
        // before the first query finishes.
        var (cached, savedAt) = Store.LoadCache(IncludeReviews);
        Items = cached;
        LastUpdate = savedAt;
        OldestFirst = Store.LoadOldestFirst();

        RegisterHotkey();
        Changed();
        _refreshTimer.Start();
        _clockTimer.Start();
        Refresh();
        if (showPopup) _popup.ShowPopup();
        Log.Write($"started (refresh {Settings.RefreshMinutes}min, hotkey {(Settings.Hotkey.Length > 0 ? Settings.Hotkey : "none")}{(_offline ? ", offline" : "")})");
    }

    // ---------------------------------------------------------------- refresh

    public async void Refresh()
    {
        if (Fetching || _offline) return;
        if (_gh == null)
        {
            // Installed while the app was running: look again before giving up.
            _gh = GhClient.Find();
            if (_gh == null)
            {
                Changed();
                return;
            }
        }
        Fetching = true;
        Changed();

        var gh = _gh;
        var limit = Settings.MaxItems;
        var reviews = IncludeReviews;
        var outdated = false;
        using var cts = new CancellationTokenSource(FetchTimeout);
        try
        {
            var result = await Task.Run(() => GhClient.FetchAsync(gh, limit, reviews, cts.Token));
            if (result.Errors.Count > 0)
            {
                Fail(string.Join(" | ", result.Errors));
            }
            else
            {
                Items = result.Items;
                LastUpdate = DateTimeOffset.Now;
                LastError = null;
                _retryCount = 0;
                _retryTimer.Stop();
                Store.SaveCache(Items, LastUpdate.Value);
                Log.Write($"fetch ok: {Items.Count} items");
                // A reload that landed while this was out asked for a refresh that the
                // Fetching guard dropped: these results follow the old settings (review
                // requests back after being turned off, the old maxItems).
                outdated = reviews != IncludeReviews || limit != Settings.MaxItems;
            }
        }
        catch (Exception ex)
        {
            // gh uninstalled or moved: look for it again next time, as when it was missing at start.
            if (ex is System.ComponentModel.Win32Exception) _gh = null;
            // A hang is a failure like any other: a gh left hanging by a half-open
            // connection (exactly the resume-from-sleep case) goes through the same
            // backoff instead of sitting stale for a whole refresh interval.
            Fail(cts.IsCancellationRequested ? "the GitHub query took too long (timeout)" : $"failed to run gh: {Log.OneLine(ex.Message)}");
        }
        finally
        {
            Fetching = false;
            Changed();
        }
        if (outdated)
        {
            Log.Write("configuration changed during the fetch; fetching again");
            Refresh();
        }
    }

    /// <summary>A failed refresh does not invalidate what is already here: the list
    /// and the count stay, marked stale.</summary>
    private void Fail(string error)
    {
        LastError = error;
        _retryCount++;
        Log.Write($"fetch error (attempt {_retryCount}): {error}");
        ScheduleRetry();
    }

    /// <summary>Back off 20s, 60s, 120s, 300s, then wait for the regular interval. The
    /// usual cause is a resume from sleep with the network a few seconds behind.</summary>
    private void ScheduleRetry()
    {
        if (_retryCount < 1 || _retryCount > RetryDelaysSec.Length) return;
        var delay = RetryDelaysSec[_retryCount - 1];
        _retryTimer.Stop();
        _retryTimer.Interval = TimeSpan.FromSeconds(delay);
        _retryTimer.Start();
        Log.Write($"retrying in {delay}s");
    }

    /// <summary>A refresh asked for by the user starts the backoff over.</summary>
    public void RefreshNow()
    {
        _retryCount = 0;
        Refresh();
    }

    private void OnClock()
    {
        // Timers do not fire while the machine sleeps, so a jump in the wall clock
        // means a resume and the data may be hours old. A large clock correction trips
        // this too; the cost of that is one extra query.
        var now = DateTimeOffset.Now;
        if ((now - _lastTick).TotalSeconds > 180)
        {
            Log.Write($"clock jumped {(int)(now - _lastTick).TotalMinutes}min (resume from sleep); refreshing");
            RefreshNow();
        }
        _lastTick = now;
        Changed();
    }

    /// <summary>Redraws whatever depends on the state or the clock.</summary>
    private void Changed()
    {
        Now = DateTimeOffset.Now;
        try
        {
            UpdateTray();
            if (_popup.IsOpen) _popup.Render();
        }
        catch (Exception ex)
        {
            Log.Write($"error updating the UI: {ex}");
        }
    }

    // ------------------------------------------------------------------- tray

    private void UpdateTray()
    {
        var items = Visible();
        var count = items.Count;
        var stale = LastError != null;

        TrayMode mode;
        if (Loading) mode = TrayMode.Loading;
        else if (stale && count == 0) mode = TrayMode.Error;
        else if (count == 0) mode = TrayMode.Zero;
        else mode = stale ? TrayMode.Stale : TrayMode.Normal;

        var tooltip = Tooltip(items, stale);
        var size = TrayIconRenderer.IconSize();
        var signature = $"{mode}|{count}|{size}|{Settings.AccentColor}";
        if (signature == _iconSignature)
        {
            _tray.SetTooltip(tooltip);
            return;
        }
        _iconSignature = signature;
        _tray.Update(TrayIconRenderer.Render(mode, count, size, TrayIconRenderer.ParseAccent(Settings.AccentColor)), tooltip);
    }

    /// <summary>A summary, not a report: the reason for a failure goes to the log and
    /// to the popup, which have room for it.</summary>
    private string Tooltip(IReadOnlyList<GhItem> items, bool stale)
    {
        if (Loading) return "GitHub Issues Tray - loading…";
        if (stale && items.Count == 0) return "GitHub Issues Tray - refresh failed";

        var reviews = items.Count(i => i.IsReview);
        var what = string.Join(", ", Fmt.CountParts(items.Count - reviews, reviews).Select(p => p.Text));
        var repos = items.Select(i => i.Repo).Distinct().Count();
        var inRepos = repos > 0 ? $" in {repos} {Fmt.Plural(repos, "repo", "repos")}" : "";
        var when = stale
            ? LastUpdate is { } at ? "\nStale - data from " + Fmt.Age(at, Now) : "\nRefresh failed"
            : LastUpdate is { } upd ? "\nUpdated " + Fmt.Age(upd, Now) : "";
        return $"GitHub: {what}{inRepos}{when}";
    }

    private enum Cmd { Open = 1, Refresh, Assigned, Login, Config, ReloadConfig, LogFile, Quit }

    private void ShowMenu()
    {
        _popup.HidePopup();
        var entries = new List<MenuEntry>
        {
            new("Open list", (int)Cmd.Open, IsDefault: true),
            new("Refresh now", (int)Cmd.Refresh, Enabled: !_offline),
            MenuEntry.Separator,
            new("Open github.com/issues/assigned", (int)Cmd.Assigned),
            MenuEntry.Separator,
            new("gh auth login", (int)Cmd.Login, Enabled: _gh != null),
            new("Edit configuration", (int)Cmd.Config),
            new("Reload configuration", (int)Cmd.ReloadConfig),
            new("Open log", (int)Cmd.LogFile),
            MenuEntry.Separator,
            new("Quit", (int)Cmd.Quit),
        };

        switch ((Cmd)_tray.ShowMenu(entries))
        {
            case Cmd.Open: _popup.ShowPopup(); break;
            case Cmd.Refresh: RefreshNow(); break;
            case Cmd.Assigned: OpenAssignedPage(); break;
            case Cmd.Login: GhLogin(); break;
            case Cmd.Config: Shell.Edit(AppPaths.ConfigFile); break;
            case Cmd.ReloadConfig: ReloadSettings(); break;
            case Cmd.LogFile: Shell.Edit(AppPaths.LogFile); break;
            case Cmd.Quit: Quit(); break;
        }
    }

    private void RegisterHotkey()
    {
        var spec = Settings.Hotkey;
        if (string.IsNullOrWhiteSpace(spec))
        {
            // An empty hotkey turns it off, also on a reload that had one before.
            _tray.UnregisterHotkey();
            return;
        }
        if (!Hotkeys.TryParse(spec, out var mods, out var vk))
        {
            _tray.UnregisterHotkey();
            Log.Write($"could not parse the hotkey \"{spec}\"");
            return;
        }
        if (_tray.RegisterHotkey(mods, vk)) Log.Write($"global hotkey registered: {spec}");
        else Log.Write($"global hotkey {spec} is taken by another program; continuing without it");
    }

    private void ReloadSettings()
    {
        var reviewsBefore = IncludeReviews;
        Settings = Settings.Load();
        _refreshTimer.Interval = TimeSpan.FromMinutes(Settings.RefreshMinutes);
        RegisterHotkey();
        _iconSignature = "";
        if (reviewsBefore && !IncludeReviews)
        {
            // Not fetched any more: drop them now instead of at the next fetch.
            Items = Items.Where(i => i.IsAssigned).ToList();
            foreach (var i in Items) i.IsReview = false;
        }
        _popup.ApplySettings();
        Log.Write("configuration reloaded");
        RefreshNow();
        Changed();
    }

    // ---------------------------------------------------------------- actions

    public void ToggleOrder()
    {
        OldestFirst = !OldestFirst;
        Store.SaveOldestFirst(OldestFirst);
    }

    public void OpenAssignedPage() => Shell.Open(AssignedPageUrl);

    public void GhLogin()
    {
        if (_gh == null) return;
        try
        {
            // A console of its own: the login is interactive.
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(_gh, "auth login") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Write($"failed to run gh auth login: {ex.Message}");
        }
    }

    public void Quit()
    {
        Log.Write("stopped");
        Dispose();
        Application.Current.Exit();
    }

    public void Dispose()
    {
        _refreshTimer.Stop();
        _clockTimer.Stop();
        _retryTimer.Stop();
        _tray.Dispose();
        _popup.CloseForGood();
    }
}

internal static class Hotkeys
{
    /// <summary>"Ctrl+Win+I" → modifiers and virtual key. Accepts Ctrl/Control, Alt,
    /// Shift, Win/Super, and a letter, digit or F1-F24.</summary>
    public static bool TryParse(string spec, out uint modifiers, out uint vk)
    {
        modifiers = 0;
        vk = 0;
        foreach (var raw in spec.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            switch (raw.ToLowerInvariant())
            {
                case "ctrl" or "control": modifiers |= Native.MOD_CONTROL; break;
                case "alt": modifiers |= Native.MOD_ALT; break;
                case "shift": modifiers |= Native.MOD_SHIFT; break;
                case "win" or "super": modifiers |= Native.MOD_WIN; break;
                default:
                    var key = raw.ToUpperInvariant();
                    if (key.Length == 1 && char.IsAsciiLetterOrDigit(key[0])) vk = key[0];
                    else if (key.Length >= 2 && key[0] == 'F' && int.TryParse(key[1..], out var f) && f is >= 1 and <= 24) vk = (uint)(0x70 + f - 1);
                    else return false;
                    break;
            }
        }
        return vk != 0 && modifiers != 0;
    }
}
