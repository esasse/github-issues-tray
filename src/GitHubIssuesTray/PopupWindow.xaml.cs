using System.Collections.ObjectModel;
using IssuesTray.Issues;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using VirtualKey = Windows.System.VirtualKey;
using CoreVirtualKeyStates = Windows.UI.Core.CoreVirtualKeyStates;

namespace IssuesTray;

/// <summary>
/// The list, in a flyout anchored to the corner of the screen where the taskbar is.
/// Created once and shown/hidden, never closed: it hides itself the moment it loses
/// the focus, like the Windows 11 flyouts.
///
/// The filters live here and nowhere else. They narrow the list and never the tray
/// count, which answers “how much is assigned to me” - a filter must not be able to
/// make that number look better than it is. And they belong to one visit to the
/// list: the popup forgets them when it hides, since reopening it to a silent subset
/// would be worse than typing two letters again.
/// </summary>
public sealed partial class PopupWindow : Window
{
    private const double MinHeightDip = 200;
    private static readonly IReadOnlyDictionary<TypeFilter, (string Key, string Label, string One, string Many, string Other)> Types =
        new Dictionary<TypeFilter, (string, string, string, string, string)>
        {
            [TypeFilter.PR] = ("P", "PRs only", "pull request", "pull requests", "issues"),
            [TypeFilter.Issue] = ("I", "Issues only", "issue", "issues", "pull requests"),
        };

    private readonly IssuesController _app;
    private readonly ObservableCollection<IssueItem> _items = [];
    private readonly IntPtr _hwnd;
    private readonly DispatcherQueueTimer _flashTimer;
    private long _lastHideTicks;
    private bool _allowClose;
    private Native.POINT _anchor;
    private Brush _accent = new SolidColorBrush();

    private KindFilter _kind;
    private TypeFilter _type;
    private bool _searchOpen;
    private string _filter = "";
    private string? _flash;
    /// <summary>The count parts the header shows, kept for the empty-state text.</summary>
    private IReadOnlyList<CountPart> _parts = [];

    internal PopupWindow(IssuesController app)
    {
        _app = app;
        InitializeComponent();
        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);

        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico"));
        AppWindow.Closing += (_, e) =>
        {
            // Alt+F4 hides it; only Quit really closes it.
            if (_allowClose) return;
            e.Cancel = true;
            HidePopup();
        };

        SystemBackdrop = new DesktopAcrylicBackdrop();
        Activated += OnActivated;
        Root.PreviewKeyDown += OnPreviewKeyDown;
        // handledEventsToo: with the focus on the list, the ListView takes the character
        // for itself and "/" never reached a plain handler. Left there, the letters typed
        // next ran as shortcuts - "l" of a search for "lgpd" started a gh login.
        Root.AddHandler(UIElement.CharacterReceivedEvent,
            new Windows.Foundation.TypedEventHandler<UIElement, CharacterReceivedRoutedEventArgs>(OnCharacterReceived), true);
        SearchBox.TextChanged += OnSearchChanged;
        // handledEventsToo: the list item swallows the pointer events it does not use.
        IssuesList.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(OnListPointerReleased), true);
        IssuesList.ItemsSource = _items;
        // The list's extent is only known once its panel has laid the rows out, which
        // is after Render's own RefineHeight ran: a search narrowing to four rows left
        // the popup at full height, with the space for the other rows empty.
        IssuesList.Loaded += (_, _) =>
        {
            if (IssuesList.ItemsPanelRoot is { } panel)
                panel.SizeChanged += (_, _) => { if (IsOpen) RefineHeight(); };
        };

        _flashTimer = DispatcherQueue.CreateTimer();
        _flashTimer.IsRepeating = false;
        _flashTimer.Interval = TimeSpan.FromSeconds(2.5);
        _flashTimer.Tick += (_, _) =>
        {
            _flash = null;
            if (IsOpen) Render();
        };

        ApplySettings();
    }

    public bool IsOpen => AppWindow.IsVisible;

    internal void ApplySettings()
    {
        _accent = new SolidColorBrush(ToColor(TrayIconRenderer.ParseAccent(_app.Settings.AccentColor)));
        HeaderRing.Stroke = _accent;
        HeaderDot.Fill = _accent;
        // The rows bake in showLabels, and a reload clears IsReview on the same objects:
        // SyncItems would find nothing changed and keep the old labels and Review chips.
        _items.Clear();
    }

    private static Windows.UI.Color ToColor(System.Drawing.Color c) => Microsoft.UI.ColorHelper.FromArgb(255, c.R, c.G, c.B);

    // ------------------------------------------------------------ show / hide

    public void Toggle()
    {
        if (IsOpen)
        {
            HidePopup();
            return;
        }
        // A click on the tray icon while the popup is open first deactivates it (which
        // hides it) and then arrives here as a click: without this it would reopen.
        if (Environment.TickCount64 - _lastHideTicks < 300) return;
        ShowPopup();
    }

    public void ShowPopup()
    {
        try
        {
            Native.GetCursorPos(out _anchor);
            Render();
            if (IssuesList.SelectedIndex < 0 && _items.Count > 0) IssuesList.SelectedIndex = 0;
            Place(EstimateHeightDip());
            AppWindow.Show(true);
            Activate();
            Native.SetForegroundWindow(_hwnd);
            // Placed again now that it is on the target monitor: a window moved onto
            // a display with another scale gets resized by the DPI change.
            Place(EstimateHeightDip());
            DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
            {
                RefineHeight();
                FocusList();
            });
        }
        catch (Exception ex)
        {
            Log.Write($"error opening the popup: {ex}");
        }
    }

    public void HidePopup()
    {
        if (!IsOpen) return;
        _lastHideTicks = Environment.TickCount64;
        AppWindow.Hide();
        _kind = KindFilter.None;
        _type = TypeFilter.None;
        _flash = null;
        CloseSearch();
        Render();
    }

    internal void CloseForGood()
    {
        _allowClose = true;
        Close();
    }

    private void OnActivated(object sender, Microsoft.UI.Xaml.WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated) HidePopup();
    }

    // ----------------------------------------------------------------- layout

    private void Place(double heightDip)
    {
        var area = DisplayArea.GetFromPoint(new PointInt32(_anchor.X, _anchor.Y), DisplayAreaFallback.Nearest);
        var scale = Native.ScaleAt(_anchor.X, _anchor.Y);
        int Px(double dip) => (int)Math.Round(dip * scale);

        var wa = area.WorkArea;
        var ob = area.OuterBounds;
        var margin = Px(12);
        var w = Math.Min(Px(_app.Settings.PopupWidth), wa.Width - 2 * margin);
        // popupMaxHeight is in DIPs and grows with the scale, so on a high-scale display
        // it could exceed the work area and push the footer behind the taskbar.
        var h = Math.Min(Px(heightDip), wa.Height - 2 * margin);

        // The corner nearest the taskbar, wherever the taskbar is.
        var x = wa.X + wa.Width - w - margin;
        var y = wa.Y + wa.Height - h - margin;
        if (wa.X > ob.X) x = wa.X + margin;
        if (wa.Y > ob.Y) y = wa.Y + margin;
        AppWindow.MoveAndResize(new RectInt32(x, y, w, h));
    }

    /// <summary>A guess from typical row heights, good enough to open at about the
    /// right size; RefineHeight corrects it from the real layout right after.</summary>
    private double EstimateHeightDip()
    {
        double h = 12 + 10 + 52 + 8 + 16;
        if (StatusText.Visibility == Visibility.Visible) h += 16 + 8;
        if (SearchBox.Visibility == Visibility.Visible) h += 32 + 8;
        if (_items.Count > 0 && IssuesList.Visibility == Visibility.Visible)
            h += _items.Sum(i => i.Labels.Count > 0 ? 82 : 60) + 8 + 8;
        else h += 120 + 8;
        return Math.Clamp(h, MinHeightDip, _app.Settings.PopupMaxHeight);
    }

    private void RefineHeight()
    {
        if (!IsOpen || Root.ActualHeight <= 0) return;
        var chrome = Root.ActualHeight - Body.ActualHeight;
        var body = IssuesList.Visibility == Visibility.Visible && FindScrollViewer(IssuesList) is { } sv && sv.ExtentHeight > 0
            ? sv.ExtentHeight + 4
            : 120;
        var target = Math.Clamp(chrome + body, MinHeightDip, _app.Settings.PopupMaxHeight);
        if (Math.Abs(target - Root.ActualHeight) > 2) Place(target);
    }

    /// <summary>
    /// Focuses the highlighted row, not the list. A ListView given the focus hands it
    /// to its first row, and the selection follows the focus: Esc out of a search that
    /// had the cursor on the fourth issue put it back on the first.
    /// </summary>
    private void FocusList()
    {
        if (IssuesList.Visibility != Visibility.Visible)
        {
            Root.Focus(FocusState.Programmatic);
            return;
        }
        if (IssuesList.SelectedItem is not { } item)
        {
            IssuesList.Focus(FocusState.Programmatic);
            return;
        }
        IssuesList.ScrollIntoView(item);
        IssuesList.UpdateLayout();
        if (IssuesList.ContainerFromItem(item) is Control row) row.Focus(FocusState.Programmatic);
        else IssuesList.Focus(FocusState.Programmatic);
    }

    private static ScrollViewer? FindScrollViewer(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is ScrollViewer sv) return sv;
            if (FindScrollViewer(child) is { } found) return found;
        }
        return null;
    }

    // ----------------------------------------------------------------- render

    internal void Render()
    {
        var now = _app.Now;
        var visible = _app.Visible();
        var loading = _app.Loading;
        var stale = _app.LastError != null;

        // Same split as the tray tooltip: a PR both assigned and asking for review is “to review”.
        var reviews = visible.Count(i => i.IsReview);
        _parts = Fmt.CountParts(visible.Count - reviews, reviews);
        // With one group there is nothing to narrow: a click would hide nothing and cost an Esc.
        var clickable = !loading && _parts.Count > 1;
        // A refresh can leave the group being filtered on empty, or alone.
        if (_kind != KindFilter.None && !(clickable && _parts.Any(p => p.Kind == _kind))) _kind = KindFilter.None;

        RenderMeta(visible, loading, clickable, now);

        Spinner.IsActive = _app.Fetching;
        Spinner.Visibility = _app.Fetching ? Visibility.Visible : Visibility.Collapsed;
        RefreshButton.Visibility = _app.Fetching ? Visibility.Collapsed : Visibility.Visible;

        // With rows to show, the reason for a failure goes up here; with none, the
        // empty state says it, in more room.
        if (stale && visible.Count > 0)
        {
            StatusText.Text = $"Could not refresh: {_app.LastError}";
            StatusText.Visibility = Visibility.Visible;
        }
        else
        {
            StatusText.Visibility = Visibility.Collapsed;
        }
        ToolTipService.SetToolTip(StatusText, StatusText.Visibility == Visibility.Visible ? StatusText.Text : null);

        SearchBox.Visibility = _searchOpen ? Visibility.Visible : Visibility.Collapsed;

        var shown = Filtered(visible);
        SyncItems(shown, now);
        var any = _items.Count > 0;
        IssuesList.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        if (!any) EmptyText.Text = EmptyMessage(loading, visible.Count > 0);

        ViewText.Text = _flash ?? ViewLine(shown.Count);

        // While typing, the letter shortcuts are all text, so listing them would be an
        // invitation to a surprise.
        FooterText.Text = _searchOpen
            ? "↑↓ move · Enter open · Esc clear search"
            : "Enter open · / search · P PRs · I issues · O order · C copy · R refresh · G github · Esc close";

        if (IsOpen) DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, RefineHeight);
    }

    /// <summary>“5 assigned, 2 to review · 4 repos · 3m ago”, with the counts as links
    /// when there are two groups to choose between. The active one is underlined.</summary>
    private void RenderMeta(IReadOnlyList<GhItem> visible, bool loading, bool clickable, DateTimeOffset now)
    {
        MetaText.Inlines.Clear();
        if (loading)
        {
            MetaText.Inlines.Add(new Run { Text = "loading…" });
            return;
        }
        for (var i = 0; i < _parts.Count; i++)
        {
            var part = _parts[i];
            if (i > 0) MetaText.Inlines.Add(new Run { Text = ", " });
            if (!clickable)
            {
                MetaText.Inlines.Add(new Run { Text = part.Text });
                continue;
            }
            var active = part.Kind == _kind;
            var link = new Hyperlink
            {
                UnderlineStyle = active ? UnderlineStyle.Single : UnderlineStyle.None,
                Foreground = active ? _accent : IssueItem.Theme("TextFillColorPrimaryBrush"),
                IsTabStop = false,
            };
            link.Inlines.Add(new Run { Text = part.Text });
            link.Click += (_, _) => ToggleKind(part.Kind);
            MetaText.Inlines.Add(link);
        }
        var tail = "";
        var repos = visible.Select(i => i.Repo).Distinct().Count();
        if (repos > 0) tail += $"  ·  {repos} {Fmt.Plural(repos, "repo", "repos")}";
        if (_app.LastUpdate is { } at) tail += "  ·  " + Fmt.Age(at, now);
        if (tail.Length > 0) MetaText.Inlines.Add(new Run { Text = tail });
    }

    /// <summary>How the list is narrowed and ordered, next to the title: while typing it
    /// is the one line that says how much of the list you are still looking at.</summary>
    private string ViewLine(int matching)
    {
        var parts = new List<string>();
        if (_type != TypeFilter.None) parts.Add(Types[_type].Label);
        if (_app.OldestFirst) parts.Add("oldest first");
        if (_filter.Length > 0) parts.Add($"{matching} matching");
        return string.Join("  ·  ", parts);
    }

    private List<GhItem> Filtered(IReadOnlyList<GhItem> visible)
    {
        IEnumerable<GhItem> items = visible;
        if (_kind == KindFilter.Review) items = items.Where(i => i.IsReview);
        else if (_kind == KindFilter.Own) items = items.Where(i => !i.IsReview);
        if (_type == TypeFilter.PR) items = items.Where(i => i.IsPR);
        else if (_type == TypeFilter.Issue) items = items.Where(i => !i.IsPR);
        var terms = Fmt.Terms(_filter);
        if (terms.Count > 0) items = items.Where(i => Fmt.Matches(i, terms));
        var list = items.ToList();
        // Reversed here, not sorted the other way in Visible(): by then maxItems has kept
        // the most recently updated ones, and the order must not change which those are
        // - nor the item the tray's middle click opens.
        if (_app.OldestFirst) list.Reverse();
        return list;
    }

    private void SyncItems(List<GhItem> shown, DateTimeOffset now)
    {
        if (shown.Count == _items.Count && shown.Select((g, i) => SameRow(g, _items[i].Item)).All(same => same))
        {
            foreach (var item in _items) item.Tick(now);
            return;
        }

        // Keep the highlight on the issue, not on the row number. Every rebuild can move
        // rows under it - a filter, Esc clearing one, a click on a header count, a
        // refresh that re-sorts - and an index kept across that leaves the highlight on
        // a different issue, which is the one Enter then opens.
        var selectedUrl = (IssuesList.SelectedItem as IssueItem)?.Url;
        _items.Clear();
        foreach (var g in shown) _items.Add(new IssueItem(g, now, _app.Settings.ShowLabels));
        if (_items.Count == 0) return;
        var index = selectedUrl == null ? -1 : IndexOf(selectedUrl);
        IssuesList.SelectedIndex = Math.Max(0, index);
    }

    /// <summary>Every fetch brings new objects for the same issues. Compared by reference,
    /// each refresh rebuilt the list and threw the scroll back to the top under whoever
    /// was reading it. A change to a title, label or draft state moves updatedAt.</summary>
    private static bool SameRow(GhItem a, GhItem b) => ReferenceEquals(a, b) ||
        (a.Url == b.Url && a.Updated == b.Updated && a.IsReview == b.IsReview && a.IsAssigned == b.IsAssigned);

    private int IndexOf(string url)
    {
        for (var i = 0; i < _items.Count; i++)
            if (_items[i].Url == url) return i;
        return -1;
    }

    private string EmptyMessage(bool loading, bool anyVisible)
    {
        if (loading) return "Loading…";
        // With rows behind a filter the failure is already in StatusText; here it would
        // hide which filter emptied the list.
        if (!anyVisible && _app.LastError is { } error)
        {
            var why = Log.OneLine(error);
            if (why.Length > 240) why = why[..239] + "…";
            return $"Couldn't reach GitHub.\n{why}\nPress R to try again, or L to sign in.";
        }
        if (_filter.Length > 0 || _type != TypeFilter.None)
        {
            // Ahead of the one below on purpose: with a filter on, “nothing assigned to
            // you” would be a lie about the list. Every narrowing that is on gets named -
            // blaming the search alone sends Esc after the wrong one and leaves the
            // matches still out of sight.
            var group = _kind == KindFilter.None ? null : _parts.FirstOrDefault(p => p.Kind == _kind)?.Text;
            var type = _type == TypeFilter.None ? ((string Key, string Label, string One, string Many, string Other)?)null : Types[_type];
            var noun = type is { } t1 ? $"No {t1.One}" : "Nothing";
            var where = group != null ? $" in '{group}'" : "";
            if (_filter.Length > 0)
            {
                var more = type is { } t2 ? $"press {t2.Key} to search the {t2.Other} too, " : "";
                var hint = group != null
                    ? $"Click it again to search {(type is { } t3 ? "all " + t3.Many : "everything")}, {more}or press Esc to clear the search."
                    : type is { } t4 ? $"Press {t4.Key} to search the {t4.Other} too, or Esc to clear the search."
                    : "Press Esc to clear the search.";
                return $"{noun}{where} matches '{_filter}'.\n{hint}";
            }
            var t = type!.Value;
            return group != null
                ? $"No {t.Many} in '{group}'.\nPress {t.Key} to show its {t.Other} too."
                : $"No {t.Many} here.\nPress {t.Key} to show everything.";
        }
        return "Nothing assigned to you" + (_app.IncludeReviews ? ", nothing to review" : "") + ". 🎉";
    }

    // ---------------------------------------------------------------- filters

    private void ToggleKind(KindFilter kind)
    {
        _kind = _kind == kind ? KindFilter.None : kind;
        Render();
        // Back to wherever the typing was. Left on the list, the rest of a search typed
        // after the click would run as shortcuts: R refreshes, G opens github.com.
        if (_searchOpen) SearchBox.Focus(FocusState.Programmatic);
        else FocusList();
    }

    private void ToggleType(TypeFilter type)
    {
        // Pressing the other key while one is on switches straight over rather than
        // stopping at “everything”.
        _type = _type == type ? TypeFilter.None : type;
        Render();
    }

    private void ShowSearch()
    {
        if (!_searchOpen)
        {
            _searchOpen = true;
            _filter = "";
            SearchBox.Text = "";
            Render();
        }
        // Reached again from Ctrl+F: select what is there, so the next keystroke starts
        // a new search. “/” typed INTO the box is a literal slash - repository names
        // carry one, and “monde/api” is a search that has to work.
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            SearchBox.Focus(FocusState.Programmatic);
            SearchBox.SelectAll();
        });
    }

    private void CloseSearch()
    {
        if (!_searchOpen) return;
        _searchOpen = false;
        _filter = "";
        SearchBox.Text = "";
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        // TextChanged arrives asynchronously, after the code that cleared the box has
        // returned, so a flag set around that assignment is already off by then. The
        // filter decides instead: clearing the box in code clears the filter first, and
        // the late event finds nothing to do - where it used to rebuild the list and
        // throw the highlight back to the first row.
        var text = SearchBox.Text.Trim();
        if (!_searchOpen || text == _filter) return;
        _filter = text;
        Render();
        // Narrowing the list invalidates wherever the cursor was: put it on the first
        // match rather than on whatever row the old index now points at.
        if (_items.Count > 0)
        {
            IssuesList.SelectedIndex = 0;
            IssuesList.ScrollIntoView(_items[0]);
        }
    }

    private void ToggleOrder()
    {
        _app.ToggleOrder();
        // After a flip the top is what you want to see, not the far end of the list
        // where the highlighted issue now sits.
        IssuesList.SelectedIndex = -1;
        Render();
        // Set here, not left to the rebuild: a single row reverses to itself, nothing is
        // rebuilt, and the cleared selection would stay cleared (Enter and C dead).
        if (_items.Count > 0)
        {
            IssuesList.SelectedIndex = 0;
            IssuesList.ScrollIntoView(_items[0]);
        }
    }

    // ---------------------------------------------------------------- actions

    private void OpenSelected()
    {
        if (IssuesList.SelectedItem is not IssueItem item) return;
        HidePopup();
        Shell.Open(item.Url);
    }

    private void CopySelected()
    {
        if (IssuesList.SelectedItem is not IssueItem item) return;
        try
        {
            var data = new DataPackage();
            data.SetText(item.Url);
            Clipboard.SetContent(data);
            Clipboard.Flush();
            _flash = $"link copied: #{item.Item.Number}";
            _flashTimer.Stop();
            _flashTimer.Start();
            Render();
        }
        catch (Exception ex)
        {
            Log.Write($"failed to copy: {ex.Message}");
        }
    }

    private void MoveSelection(int delta)
    {
        if (_items.Count == 0) return;
        var index = Math.Clamp(IssuesList.SelectedIndex + delta, 0, _items.Count - 1);
        IssuesList.SelectedIndex = index;
        IssuesList.ScrollIntoView(_items[index]);
    }

    private void IssuesList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not IssueItem item) return;
        HidePopup();
        Shell.Open(item.Url);
    }

    private void OnListPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (e.GetCurrentPoint(null).Properties.PointerUpdateKind != Microsoft.UI.Input.PointerUpdateKind.MiddleButtonReleased) return;
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not IssueItem item) return;
        IssuesList.SelectedItem = item;
        CopySelected();
        e.Handled = true;
    }

    private void Refresh_Click(object sender, RoutedEventArgs e) => _app.RefreshNow();

    // --------------------------------------------------------------- keyboard

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = IsDown(VirtualKey.Control);
        var alt = IsDown(VirtualKey.Menu);

        if (ctrl && e.Key == VirtualKey.F)
        {
            ShowSearch();
            e.Handled = true;
            return;
        }

        // With the box focused every other key is text being typed, so only navigation
        // is taken here: otherwise searching for “pr” would toggle pull requests and
        // then refresh.
        if (_searchOpen && SearchBox.FocusState != FocusState.Unfocused)
        {
            switch (e.Key)
            {
                case VirtualKey.Escape: CloseSearch(); Render(); FocusList(); break;
                case VirtualKey.Enter: OpenSelected(); break;
                case VirtualKey.Up: MoveSelection(-1); break;
                case VirtualKey.Down: MoveSelection(1); break;
                case VirtualKey.PageUp: MoveSelection(-5); break;
                case VirtualKey.PageDown: MoveSelection(5); break;
                default: return;
            }
            e.Handled = true;
            return;
        }

        // Letters only without Ctrl or Alt: Ctrl+C is not "copy the link" by accident,
        // and Alt+P is not a menu mnemonic that happens to filter.
        var plain = !ctrl && !alt;
        switch (e.Key)
        {
            case VirtualKey.Escape:
                // Esc backs out one step at a time: the search, the group, P/I, the popup.
                if (_searchOpen) { CloseSearch(); Render(); }
                else if (_kind != KindFilter.None) { _kind = KindFilter.None; Render(); }
                else if (_type != TypeFilter.None) { _type = TypeFilter.None; Render(); }
                else HidePopup();
                break;
            case VirtualKey.Enter: OpenSelected(); break;
            case VirtualKey.Up or VirtualKey.Down or VirtualKey.PageUp or VirtualKey.PageDown or VirtualKey.Home or VirtualKey.End:
                if (IssuesList.FocusState == FocusState.Unfocused) IssuesList.Focus(FocusState.Keyboard);
                return;
            case VirtualKey.P when plain: ToggleType(TypeFilter.PR); break;
            case VirtualKey.I when plain: ToggleType(TypeFilter.Issue); break;
            case VirtualKey.O when plain: ToggleOrder(); break;
            case VirtualKey.C when plain: CopySelected(); break;
            case VirtualKey.R when plain: _app.RefreshNow(); break;
            case VirtualKey.G when plain: HidePopup(); _app.OpenAssignedPage(); break;
            case VirtualKey.L when plain: HidePopup(); _app.GhLogin(); break;
            default: return;
        }
        e.Handled = true;
    }

    /// <summary>
    /// “/” is read as a character, not a key: the virtual key behind it moves with the
    /// layout - VK_OEM_2 on a US keyboard, VK_ABNT_C1 on the Brazilian ABNT2 - and
    /// matching on the code would open the search on one keyboard and not the other.
    /// </summary>
    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        if (_searchOpen && SearchBox.FocusState != FocusState.Unfocused) return;
        if (e.Character != '/') return;
        ShowSearch();
        e.Handled = true;
    }
}
