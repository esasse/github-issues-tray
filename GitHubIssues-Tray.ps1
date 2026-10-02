#Requires -Version 5.1
<#
    GitHub Issues Tray
    ------------------
    Shows how many GitHub issues and pull requests are assigned to you, plus the
    pull requests waiting on your review, in the Windows tray.
    Left click opens the list; clicking an item opens it in the browser.

    Authentication is delegated to the GitHub CLI (gh). No token is stored by this app.

    IMPORTANT: this file must be saved as UTF-8 WITH BOM (it contains non-ASCII text).
#>
param(
    [switch]$AllowMultipleInstances,
    [switch]$ShowOnStart
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('TrayNative' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class TrayNative
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr context);

    [DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(int value);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr hmon, int type, out uint x, out uint y);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    // Must run before the first window exists. Without it Windows stretches the
    // window as a bitmap on displays scaled above 100% and the font comes out blurry.
    public static string EnableDpiAwareness()
    {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return "per-monitor-v2"; } catch { }
        try { if (SetProcessDpiAwareness(2) == 0) return "per-monitor"; } catch { }
        try { if (SetProcessDPIAware()) return "system"; } catch { }
        return "nenhuma";
    }

    // Scale factor of the monitor containing the point (0 = unknown).
    public static double ScaleForPoint(int x, int y)
    {
        try
        {
            POINT p; p.X = x; p.Y = y;
            IntPtr mon = MonitorFromPoint(p, 2 /* MONITOR_DEFAULTTONEAREST */);
            uint dx, dy;
            if (GetDpiForMonitor(mon, 0 /* MDT_EFFECTIVE_DPI */, out dx, out dy) == 0 && dx > 0)
                return dx / 96.0;
        }
        catch { }
        return 0;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public class HotkeyWindow : NativeWindow, IDisposable
    {
        private const int WM_HOTKEY = 0x0312;
        private const int HOTKEY_ID = 0xB17;
        private bool registered;

        public event EventHandler Pressed;

        public HotkeyWindow()
        {
            CreateHandle(new CreateParams());
        }

        public bool Register(uint modifiers, uint virtualKey)
        {
            registered = RegisterHotKey(this.Handle, HOTKEY_ID, modifiers, virtualKey);
            return registered;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HOTKEY_ID)
            {
                EventHandler handler = Pressed;
                if (handler != null) handler(this, EventArgs.Empty);
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (registered) UnregisterHotKey(this.Handle, HOTKEY_ID);
            DestroyHandle();
        }
    }
}
'@
}


$script:DpiMode = [TrayNative]::EnableDpiAwareness()

[System.Windows.Forms.Application]::EnableVisualStyles()
# Labels draw with GDI+ unless told otherwise before the first window exists - the
# call every Visual Studio template makes and a script has to make by hand. Left
# on GDI+, the header, footer and empty-state text came out thin and unevenly
# spaced next to the rows, which draw with GDI (see Write-RowText).
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) }
catch { $script:CompatTextError = $_.Exception.Message }

# ------------------------------------------------------------------ paths ---

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot 'config.json'
$StateDir   = Join-Path $env:LOCALAPPDATA 'github-issues-tray'
$CachePath  = Join-Path $StateDir 'cache.json'
$LogPath    = Join-Path $StateDir 'tray.log'

if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 256KB)) {
            Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
        }
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $LogPath -Value "$stamp  $Message" -Encoding UTF8
    } catch { }
}

# -------------------------------------------------------- single instance ---

$script:Mutex = $null
if (-not $AllowMultipleInstances) {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Global\GitHubIssuesTray', [ref]$created)
    if (-not $created) {
        # There is already an instance in the tray. Exit quietly: a modal dialog from
        # an app with no window only gets in the way (autostart + double click is common).
        Write-Log 'an instance was already running; this one exited without doing anything'
        return
    }
}

# ---------------------------------------------------------------- interop ---


# ---------------------------------------------------------- configuration ---

$DefaultConfig = [ordered]@{
    refreshMinutes        = 5
    maxItems              = 50
    includeReviewRequests = $true
    showLabels            = $true
    hotkey                = 'Ctrl+Win+I'
    accentColor           = '#00A8FF'
    popupWidth            = 520
    popupMaxHeight        = 620
}

function Read-Config {
    $cfg = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $cfg[$k] = $DefaultConfig[$k] }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) {
                if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
            }
        } catch {
            Write-Log "invalid config.json, falling back to defaults: $($_.Exception.Message)"
        }
    } else {
        try {
            ($DefaultConfig | ConvertTo-Json) |
                Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        } catch { }
    }
    if ([int]$cfg.refreshMinutes -lt 1)  { $cfg.refreshMinutes = 1 }
    if ([int]$cfg.maxItems -lt 1)        { $cfg.maxItems = 1 }
    if ([int]$cfg.maxItems -gt 100)      { $cfg.maxItems = 100 }
    return $cfg
}

$script:Config = Read-Config
# Pull requests assigned to you are always shown - they are work assigned to you as
# much as an issue is. Review requests are too, unless the config turns them off:
# the key exists for whoever wants the tray back to what is assigned to them.
$script:IncludeReviews = [bool]$script:Config.includeReviewRequests

function Get-ConfigColor {
    param([string]$Hex, [string]$Fallback = '#00A8FF')
    try { return [System.Drawing.ColorTranslator]::FromHtml($Hex) }
    catch { return [System.Drawing.ColorTranslator]::FromHtml($Fallback) }
}

# ---------------------------------------------------------------- palette ---

$Theme = @{
    Back      = [System.Drawing.ColorTranslator]::FromHtml('#1B1D22')
    BackAlt   = [System.Drawing.ColorTranslator]::FromHtml('#22252B')
    Sel       = [System.Drawing.ColorTranslator]::FromHtml('#2C3742')
    Fore      = [System.Drawing.ColorTranslator]::FromHtml('#E8EAED')
    Muted     = [System.Drawing.ColorTranslator]::FromHtml('#8A9199')
    Border    = [System.Drawing.ColorTranslator]::FromHtml('#3A3F47')
    Accent    = Get-ConfigColor $script:Config.accentColor
    Warn      = [System.Drawing.ColorTranslator]::FromHtml('#E5534B')
    Zero      = [System.Drawing.ColorTranslator]::FromHtml('#6E7681')
    Purple    = [System.Drawing.ColorTranslator]::FromHtml('#A371F7')
    Review    = [System.Drawing.ColorTranslator]::FromHtml('#D29922')
}

$RepoPalette = @(
    '#4C9AFF','#57D9A3','#FFAB00','#FF7452','#B57BFF',
    '#00C7E6','#F2789F','#96C22D','#FF8B00','#79A3FF'
) | ForEach-Object { [System.Drawing.ColorTranslator]::FromHtml($_) }

function Get-RepoColor {
    param([string]$Repo)
    if ([string]::IsNullOrEmpty($Repo)) { return $Theme.Muted }
    $h = 0
    foreach ($c in $Repo.ToCharArray()) { $h = (($h * 31) + [int]$c) % 100000 }
    return $RepoPalette[$h % $RepoPalette.Count]
}

$FontTitle = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Regular)
$FontMeta  = New-Object System.Drawing.Font('Segoe UI', 8.25, [System.Drawing.FontStyle]::Regular)
$FontRepo  = New-Object System.Drawing.Font('Segoe UI Semibold', 8.25, [System.Drawing.FontStyle]::Regular)
$FontChip  = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Regular)

# ------------------------------------------------------------------ scale ---
# Fonts are declared in points and GDI and GDI+ already convert them by the device DPI.
# The layout's pixel measurements are not: they go through S().

$script:Scale = 1.0
$s0 = [TrayNative]::ScaleForPoint(0, 0)
if ($s0 -gt 0) { $script:Scale = $s0 }

function S {
    param([double]$Px)
    return [int][math]::Round($Px * $script:Scale)
}


# ---------------------------------------------------------------- helpers ---

function Format-Age {
    param([datetime]$When)
    $span = (Get-Date) - $When.ToLocalTime()
    # Floor, not [int]: the PowerShell cast rounds to nearest, so 90 seconds read
    # as "2m ago" and 39 hours as "2d ago". An age should never claim more time
    # has passed than actually has.
    $mins = [int][math]::Floor($span.TotalMinutes)
    if ($mins -lt 1)   { return 'now' }
    if ($mins -lt 60)  { return "$mins" + 'm ago' }
    $hours = [int][math]::Floor($span.TotalHours)
    if ($hours -lt 24) { return "$hours" + 'h ago' }
    $days = [int][math]::Floor($span.TotalDays)
    if ($days -lt 14)  { return "$days" + 'd ago' }
    # Thresholds are all in days on purpose. Written against each unit's own
    # counter they stop lining up once the counters truncate: "23mo ago" would be
    # followed a day later by "1y ago", and a months limit of 12 against a years
    # divisor of 365 yields "0y ago" for five weeks of the year.
    if ($days -lt 63)  { return "$([int][math]::Floor($span.TotalDays / 7))" + 'w ago' }
    if ($days -lt 365) { return "$([int][math]::Floor($span.TotalDays / 30))" + 'mo ago' }
    return "$([int][math]::Floor($span.TotalDays / 365))y ago"
}

# gh writes multi-line errors ("error connecting to api.github.com\ncheck your
# internet connection..."). Left raw, one of those turns a log entry into three
# lines and makes a mess of the tray tooltip.
function Format-ErrorText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return (($Text -replace '\s+', ' ').Trim())
}

# NotifyIcon.Text throws ArgumentOutOfRangeException at 64 characters or more -
# the limit is 63, not the 127 you might expect. An over-long tooltip used to
# escape as an unhandled exception and put a .NET crash dialog on screen, and the
# caught message then went back into the error text, making the next tooltip even
# longer. Keep the tooltip short, clamp it here, and never let it throw.
$TrayTextMax = 63

function Set-TrayTooltip {
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $TrayTextMax) {
        $Text = $Text.Substring(0, $TrayTextMax - 1) + '…'
    }
    try { $script:Notify.Text = $Text }
    catch { Write-Log "could not set the tray tooltip: $(Format-ErrorText $_.Exception.Message)" }
}

function Plural {
    param([int]$N, [string]$One, [string]$Many)
    if ($N -eq 1) { return $One }
    return $Many
}

function Get-ContrastColor {
    param([System.Drawing.Color]$Background)
    $l = (0.299 * $Background.R + 0.587 * $Background.G + 0.114 * $Background.B) / 255.0
    if ($l -gt 0.6) { return [System.Drawing.Color]::FromArgb(20, 20, 20) }
    return [System.Drawing.Color]::White
}

function Open-Url {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    try { Start-Process $Url } catch { Write-Log "failed to open $Url : $($_.Exception.Message)" }
}

# ------------------------------------------------------------------- icon ---

$script:CurrentIconHandle = [IntPtr]::Zero

function Set-TrayIcon {
    param(
        [int]$Count,
        [ValidateSet('normal', 'zero', 'stale', 'error', 'loading')]
        [string]$Mode = 'normal'
    )

    # Draw at exactly the size the notification area asks for: a larger icon would
    # arrive resampled by the shell and come out soft.
    $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    if ($size -lt 16) { $size = 16 }
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    switch ($Mode) {
        'error'   { $fill = $Theme.Warn;   $text = '!' }
        'zero'    { $fill = $Theme.Zero;   $text = '0' }
        'loading' { $fill = $Theme.Muted;  $text = '' }   # dots are drawn by hand below
        'stale'   {
            # Refresh failed but the cached list is still worth showing: keep the
            # count and grey it out, instead of throwing the number away.
            $fill = $Theme.Zero
            $text = if ($Count -gt 99) { '99+' } else { [string]$Count }
        }
        default   {
            $fill = $Theme.Accent
            $text = if ($Count -gt 99) { '99+' } else { [string]$Count }
        }
    }

    $brush = New-Object System.Drawing.SolidBrush($fill)
    $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)
    $brush.Dispose()

    $textBrush = New-Object System.Drawing.SolidBrush((Get-ContrastColor $fill))

    if ($Mode -eq 'loading') {
        # Three dots drawn by hand rather than the "…" glyph. That glyph is aligned
        # on the baseline: its box is a full line tall but the ink sits in the
        # bottom few pixels, so centring the box drops the dots to the floor of the
        # circle. At a 20px icon that reads as dirt, not as a state.
        $r = [double]$size * 0.075
        if ($r -lt 1.0) { $r = 1.0 }
        $gap = $r * 3.2
        $c = [double]$size / 2.0
        foreach ($off in @(-$gap, 0.0, $gap)) {
            $g.FillEllipse($textBrush, [float]($c + $off - $r), [float]($c - $r), [float]($r * 2), [float]($r * 2))
        }
    } else {
        $ratio = switch ($text.Length) { 1 { 0.60 } 2 { 0.50 } default { 0.38 } }
        $fontSize = [float]($size * $ratio)
        $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)

        # A circle is only as wide as $size across its middle, and narrower over the
        # band the glyphs actually occupy. "99+" came out touching the edge, so shrink
        # until the drawn box clears it. Never fires for one or two characters.
        $budget = [float]($size * 0.80)
        while ($fontSize -gt 5.0 -and $g.MeasureString($text, $font).Width -gt $budget) {
            $font.Dispose()
            $fontSize = $fontSize - 0.5
            $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        }

        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
        $g.DrawString($text, $font, $textBrush, $rect, $fmt)
        $fmt.Dispose(); $font.Dispose()
    }

    $textBrush.Dispose(); $g.Dispose()

    $handle = $bmp.GetHicon()
    $newIcon = [System.Drawing.Icon]::FromHandle($handle)

    $oldIcon = $script:Notify.Icon
    $oldHandle = $script:CurrentIconHandle

    $script:Notify.Icon = $newIcon
    $script:CurrentIconHandle = $handle

    if ($oldIcon) { $oldIcon.Dispose() }
    if ($oldHandle -ne [IntPtr]::Zero) { [TrayNative]::DestroyIcon($oldHandle) | Out-Null }
    $bmp.Dispose()
}

# ------------------------------------------------------------------ state ---

$script:AllItems    = @()          # issues + PRs, as they came from gh
$script:LastUpdate  = $null
$script:LastError   = $null
$script:Fetching    = $false
$script:GhPath      = $null
$script:RetryCount  = 0

# The search filter narrows the popup list and nothing else. It is deliberately
# kept out of Get-VisibleItems: the icon and the tooltip answer “how much is
# assigned to me”, and a filter must never be able to make that number look
# better than it is.
$script:Filter        = ''
$script:SearchOpen    = $false
$script:MatchCount    = 0
$script:SuspendSearch = $false   # set while the box is cleared in code
$script:HeaderBase    = ''       # header without the “N matching” suffix
# Clicking “N assigned” or “N to review” in the header narrows the list to that
# group; same scope as the search filter - the list only, never the counts.
$script:KindFilter     = ''      # '' | 'own' | 'review'
$script:HeaderSegments = @()     # clickable parts of HeaderBase: @{ Kind; Start; Text }

# "Nothing yet" is not the same as "zero". Until the first query comes back the
# count is unknown, and showing 0 claims an inbox is clear when it may not be.
# This is the only moment the loading icon is the honest answer: during a later
# refresh the number already on screen stays truer than a spinner.
function Test-Loading {
    return ((-not $script:LastUpdate) -and (-not $script:LastError) -and ($script:AllItems.Count -eq 0))
}

function Get-VisibleItems {
    # Issues and assigned PRs always, plus the PRs that ask for your review. Those only
    # exist with review requests on: they are not fetched otherwise, and Restore-Cache
    # clears isReview on cached ones.
    $items = @($script:AllItems | Where-Object {
        $_.isAssigned -or $_.isReview
    })
    $items = @($items | Sort-Object -Property @{ Expression = { $_.updated } } -Descending)
    if ($items.Count -gt [int]$script:Config.maxItems) {
        $items = @($items[0..([int]$script:Config.maxItems - 1)])
    }
    # Callers must wrap this in @(). PowerShell unrolls the array on the way out, so a
    # single result arrives as a bare object, and .Count on one of those is $null on
    # 5.1 - which is how exactly one assigned issue rendered as " issues" with no number
    # in front of it, and left middle-click-opens-the-newest doing nothing. Returning
    # ",$items" instead would not help: @() around such a return nests it one deeper.
    return $items
}

# Terms are ANDed and matched anywhere, so “mon api” finds an issue in monde/api
# as readily as one titled “API” in monde/web, and the order you type them in does
# not matter. The haystack carries the number with its “#” so both “#412” and
# “412” hit.
function Test-ItemMatch {
    param($Item, [string[]]$Terms)
    $hay = "$($Item.repo) #$($Item.number) $($Item.title)"
    if ($Item.isPR) {
        $hay += ' pr'
        if ($Item.isDraft) { $hay += ' draft' }
        if ($Item.isReview) { $hay += ' review' }
    }
    if ($Item.labels) {
        foreach ($lb in $Item.labels) { $hay += ' ' + $lb.name }
    }
    $hay = $hay.ToLowerInvariant()
    foreach ($t in $Terms) {
        # Ordinal, not the default culture-sensitive IndexOf: word sort gives hyphens
        # and apostrophes almost no weight, so “email” would hit a title reading
        # “e-mail” and vice versa, and a term made only of ignorable characters would
        # match every row. Both sides are already lowercased, so there is nothing for
        # a culture to add here - and it is the comparison being run per keystroke.
        if ($hay.IndexOf($t, [System.StringComparison]::Ordinal) -lt 0) { return $false }
    }
    return $true
}

# Same contract as Get-VisibleItems: wrap the result in @().
function Get-FilteredItems {
    $items = @(Get-VisibleItems)
    # Same split as the header counts: a PR both assigned and asking for review is “to review”.
    if ($script:KindFilter -eq 'review') { $items = @($items | Where-Object { $_.isReview }) }
    elseif ($script:KindFilter -eq 'own') { $items = @($items | Where-Object { -not $_.isReview }) }
    if ([string]::IsNullOrWhiteSpace($script:Filter)) { return $items }
    $terms = @($script:Filter.ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    if ($terms.Count -eq 0) { return $items }
    return @($items | Where-Object { Test-ItemMatch -Item $_ -Terms $terms })
}

function Save-Cache {
    try {
        $payload = [ordered]@{
            savedAt = (Get-Date).ToString('o')
            items   = @($script:AllItems | ForEach-Object {
                [ordered]@{
                    number = $_.number; title = $_.title; url = $_.url; repo = $_.repo
                    isPR = $_.isPR; isDraft = $_.isDraft
                    isAssigned = $_.isAssigned; isReview = $_.isReview
                    updated = $_.updated.ToString('o'); created = $_.created.ToString('o')
                    labels = @($_.labels | ForEach-Object { [ordered]@{ name = $_.name; color = $_.color } })
                }
            })
        }
        ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $CachePath -Encoding UTF8
    } catch { Write-Log "failed to write cache: $($_.Exception.Message)" }
}

function Restore-Cache {
    if (-not (Test-Path -LiteralPath $CachePath)) { return }
    try {
        $raw = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:AllItems = @($raw.items | ForEach-Object {
            # A cache written before review requests existed has no isAssigned, and
            # every item in it came from an assignee query.
            $assigned = if ($_.PSObject.Properties['isAssigned']) { [bool]$_.isAssigned } else { $true }
            # A cache written while review requests were on still says isReview after
            # includeReviewRequests is turned off; left as is, an assigned PR would show
            # the Review chip and count as "to review" until the first fetch lands.
            $review = $script:IncludeReviews -and [bool]$_.isReview
            [pscustomobject]@{
                number = [int]$_.number; title = [string]$_.title; url = [string]$_.url
                repo = [string]$_.repo; isPR = [bool]$_.isPR; isDraft = [bool]$_.isDraft
                isAssigned = $assigned; isReview = $review
                updated = [datetime]$_.updated; created = [datetime]$_.created
                labels = @($_.labels)
            }
        })
        if ($raw.savedAt) { $script:LastUpdate = [datetime]$raw.savedAt }
        Write-Log "cache restored: $($script:AllItems.Count) items"
    } catch { Write-Log "failed to read cache: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ fetch ---

$script:Jobs = @()

function New-GhJob {
    param([string]$Kind, [string]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:GhPath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    return [pscustomobject]@{
        Kind    = $Kind
        Proc    = $proc
        OutTask = $proc.StandardOutput.ReadToEndAsync()
        ErrTask = $proc.StandardError.ReadToEndAsync()
        Started = Get-Date
        Args    = $Arguments
    }
}

function Start-Fetch {
    if ($script:Fetching) { return }
    if (-not $script:GhPath) {
        $script:LastError = 'GitHub CLI (gh) not found on PATH.'
        Update-Ui
        return
    }

    $limit = [int]$script:Config.maxItems
    $fields = 'number,title,url,repository,labels,createdAt,updatedAt'

    try {
        # Record each child as it starts. Built as one array expression, a failure to
        # launch the second gh throws before anything is assigned, and the first child
        # is orphaned with its pipes undrained - Stop-Fetch can only reap what it sees.
        $script:Jobs = @()
        $script:Jobs += New-GhJob 'issue' "search issues --assignee @me --state open --sort updated --order desc --limit $limit --json $fields"
        $script:Jobs += New-GhJob 'pr' "search prs --assignee @me --state open --sort updated --order desc --limit $limit --json $fields,isDraft"
        # review-requested also matches requests made to a team you are on, like
        # github.com/pulls/review-requested does, and a PR drops out on its own once
        # you submit your review.
        if ($script:IncludeReviews) {
            $script:Jobs += New-GhJob 'review' "search prs --review-requested @me --state open --sort updated --order desc --limit $limit --json $fields,isDraft"
        }
        $script:Fetching = $true
    } catch {
        # Only a failure to LAUNCH gh belongs in here - nothing else runs inside the
        # try. Keeping Update-Ui (or the icon call below) in it turned any UI error
        # into a bogus "failed to run gh", and that text then fed straight back into
        # the next tooltip, making it longer every round. Stop-Fetch reaps the child
        # that did start when the second one did not.
        Stop-Fetch
        $script:LastError = "failed to run gh: $(Format-ErrorText $_.Exception.Message)"
        Write-Log $script:LastError
        $script:RetryCount++
        Start-Retry
    }

    if ($script:Fetching) { $script:PollTimer.Start() }
    # The icon is Update-Ui's business alone. Setting it here as well is what kept
    # the loading icon invisible: it was drawn and then immediately overwritten.
    Update-Ui
}

function Convert-GhItem {
    param($Raw, [string]$Kind)
    $repo = if ($Raw.repository -and $Raw.repository.nameWithOwner) { $Raw.repository.nameWithOwner } else { '' }
    return [pscustomobject]@{
        number  = [int]$Raw.number
        title   = [string]$Raw.title
        url     = [string]$Raw.url
        repo    = [string]$repo
        isPR    = ($Kind -ne 'issue')
        isDraft = [bool]($Raw.PSObject.Properties['isDraft'] -and $Raw.isDraft)
        isAssigned = ($Kind -ne 'review')
        isReview   = ($Kind -eq 'review')
        created = [datetime]$Raw.createdAt
        updated = [datetime]$Raw.updatedAt
        labels  = @($Raw.labels | ForEach-Object { [pscustomobject]@{ name = $_.name; color = $_.color } })
    }
}

function Complete-Fetch {
    $errors = @()
    $collected = @()

    foreach ($job in $script:Jobs) {
        $out = $job.OutTask.Result
        $err = $job.ErrTask.Result
        $code = $job.Proc.ExitCode
        $job.Proc.Dispose()

        if ($code -ne 0) {
            $msg = if ([string]::IsNullOrWhiteSpace($err)) { "gh exited with code $code" } else { Format-ErrorText $err }
            $errors += $msg
            continue
        }
        if ([string]::IsNullOrWhiteSpace($out)) { continue }
        try {
            $parsed = $out | ConvertFrom-Json
            foreach ($raw in @($parsed)) { $collected += (Convert-GhItem -Raw $raw -Kind $job.Kind) }
        } catch {
            $errors += "invalid response from gh: $(Format-ErrorText $_.Exception.Message)"
        }
    }

    $script:Jobs = @()
    $script:Fetching = $false

    if ($errors.Count -gt 0) {
        # every job fails with the same message when the network is down; saying it
        # more than once helps nobody
        $script:LastError = (@($errors | Select-Object -Unique) -join ' | ')
        $script:RetryCount++
        Write-Log "fetch error (attempt $($script:RetryCount)): $($script:LastError)"
        Start-Retry
    } else {
        $script:LastError = $null
        $script:RetryCount = 0
        $script:RetryTimer.Stop()
        # A PR assigned to you that also asks for your review comes back from both
        # queries. Listed twice it would count twice in the tray; kept once, it
        # carries both reasons.
        $byUrl = [ordered]@{}
        foreach ($it in $collected) {
            $seen = $byUrl[$it.url]
            if ($seen) {
                $seen.isAssigned = ($seen.isAssigned -or $it.isAssigned)
                $seen.isReview   = ($seen.isReview -or $it.isReview)
            } else {
                $byUrl[$it.url] = $it
            }
        }
        $script:AllItems = @($byUrl.Values)
        $script:LastUpdate = Get-Date
        Save-Cache
        Write-Log "fetch ok: $($script:AllItems.Count) items"
    }
    Update-Ui
}

function Stop-Fetch {
    foreach ($job in $script:Jobs) {
        try { if (-not $job.Proc.HasExited) { $job.Proc.Kill() } } catch { }
        try { $job.Proc.Dispose() } catch { }
    }
    $script:Jobs = @()
    $script:Fetching = $false
}

# -------------------------------------------------------------- interface ---

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Visible = $true

# ---- popup

$Popup = New-Object System.Windows.Forms.Form
$Popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$Popup.ShowInTaskbar = $false
$Popup.TopMost = $true
$Popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$Popup.BackColor = $Theme.Back
$Popup.KeyPreview = $true
$Popup.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$Popup.Width = S $script:Config.popupWidth
$Popup.MinimumSize = New-Object System.Drawing.Size((S $script:Config.popupWidth), (S 120))
$Popup.Padding = New-Object System.Windows.Forms.Padding(1)

$Header = New-Object System.Windows.Forms.Panel
$Header.Dock = [System.Windows.Forms.DockStyle]::Top
$Header.Height = S 44
$Header.BackColor = $Theme.BackAlt

# A Panel, not a Label: the counts in it are click targets, and a Label pads and
# wraps its text by rules of its own that the hit test would have to guess at. The
# text is drawn in the header's Paint handler, with the flags it is measured with.
$HeaderTitle = New-Object System.Windows.Forms.Panel
$HeaderTitle.Dock = [System.Windows.Forms.DockStyle]::Fill
$HeaderTitle.ForeColor = $Theme.Fore
$HeaderTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$HeaderTitle.Padding = New-Object System.Windows.Forms.Padding((S 14), 0, (S 14), 0)
$Header.Controls.Add($HeaderTitle)

$Footer = New-Object System.Windows.Forms.Panel
$Footer.Dock = [System.Windows.Forms.DockStyle]::Bottom
$Footer.Height = S 30
$Footer.BackColor = $Theme.BackAlt

$FooterLabel = New-Object System.Windows.Forms.Label
$FooterLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$FooterLabel.ForeColor = $Theme.Muted
$FooterLabel.Font = $FontMeta
$FooterLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$FooterLabel.Padding = New-Object System.Windows.Forms.Padding((S 14), 0, (S 14), 0)
$Footer.Controls.Add($FooterLabel)

$List = New-Object System.Windows.Forms.ListBox
$List.Dock = [System.Windows.Forms.DockStyle]::Fill
$List.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawVariable
$List.BackColor = $Theme.Back
$List.ForeColor = $Theme.Fore
$List.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$List.IntegralHeight = $false

$Empty = New-Object System.Windows.Forms.Label
$Empty.Dock = [System.Windows.Forms.DockStyle]::Fill
$Empty.ForeColor = $Theme.Muted
$Empty.Font = $FontTitle
$Empty.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$Empty.Visible = $false

# ---- search bar

# Hidden until “/” or Ctrl+F. It docks between the header and the list, so opening
# it pushes the rows down instead of covering them, and Resize-Popup pays for the
# extra height.
$SearchPanel = New-Object System.Windows.Forms.Panel
$SearchPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$SearchPanel.Height = S 36
$SearchPanel.BackColor = $Theme.BackAlt
$SearchPanel.Visible = $false
$SearchPanel.Padding = New-Object System.Windows.Forms.Padding((S 14), (S 8), (S 14), (S 8))

$SearchIcon = New-Object System.Windows.Forms.Label
$SearchIcon.Dock = [System.Windows.Forms.DockStyle]::Left
$SearchIcon.AutoSize = $false
$SearchIcon.Width = S 18
$SearchIcon.Text = '/'
$SearchIcon.Font = $FontRepo
$SearchIcon.ForeColor = $Theme.Accent
$SearchIcon.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

$SearchBox = New-Object System.Windows.Forms.TextBox
$SearchBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$SearchBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$SearchBox.BackColor = $Theme.BackAlt
$SearchBox.ForeColor = $Theme.Fore
$SearchBox.Font = $FontTitle
# Multiline is the only way a TextBox keeps the height the panel gives it: a
# single-line one snaps back to the font's own height and sits against the top of
# the bar. Enter never reaches the box (the popup suppresses it), so nothing wraps.
$SearchBox.Multiline = $true
$SearchBox.AcceptsReturn = $false

# An empty bar with a caret in it does not say what it filters. There is no cue
# banner to lean on - EM_SETCUEBANNER ignores a multiline edit - so the hint is its
# own label, parked on the right and dropped as soon as there is text to read.
$SearchHint = New-Object System.Windows.Forms.Label
$SearchHint.Dock = [System.Windows.Forms.DockStyle]::Right
$SearchHint.AutoSize = $false
$SearchHint.Width = S 150
$SearchHint.Text = 'title, repo, #number, label'
$SearchHint.Font = $FontMeta
$SearchHint.ForeColor = $Theme.Zero
$SearchHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight

$SearchPanel.Controls.Add($SearchBox)
$SearchPanel.Controls.Add($SearchIcon)
$SearchPanel.Controls.Add($SearchHint)

# a hairline under the bar, so the filter reads as part of the header
$SearchPanel.Add_Paint({
    param($sender, $e)
    $pen = New-Object System.Drawing.Pen($Theme.Border)
    $y = $SearchPanel.Height - 1
    $e.Graphics.DrawLine($pen, 0, $y, $SearchPanel.Width, $y)
    $pen.Dispose()
})

$SearchBox.Add_TextChanged({
    if ($script:SuspendSearch) { return }
    $script:Filter = $SearchBox.Text.Trim()
    $SearchHint.Visible = ($SearchBox.Text.Length -eq 0)
    Update-List
    # Narrowing the list invalidates wherever the cursor was. Put it on the first
    # match - the most recently updated one - rather than on whatever row the old
    # index now happens to point at.
    if ($List.Items.Count -gt 0) { $List.SelectedIndex = 0 }
})

# Docking runs from the highest index down, so the search bar has to sit below the
# header and above the list in this collection for it to land there on screen.
$Popup.Controls.Add($List)
$Popup.Controls.Add($Empty)
$Popup.Controls.Add($SearchPanel)
$Popup.Controls.Add($Header)
$Popup.Controls.Add($Footer)

# ---- list drawing

# Line heights come from the font measured at the current DPI, not from constants:
# the font is declared in points and grows on its own, so the layout pixels have to
# keep up or the text overlaps on a scaled display.
$script:PadY = 7; $script:PadX = 20
$script:LineRepo = 17; $script:LineTitle = 21; $script:ChipH = 16

function Update-Metrics {
    # Measure at the target DPI, not from a Graphics of the popup: when the popup is
    # about to open on another monitor it is still parked on the old one, so the line
    # height would mix the font from there with the padding from here (rows too short,
    # label chips clipped). GetHeight(dpi) does not depend on where the window is.
    $dpi = [float](96.0 * $script:Scale)
    $script:LineRepo  = [int][math]::Ceiling($FontRepo.GetHeight($dpi))  + (S 4)
    $script:LineTitle = [int][math]::Ceiling($FontTitle.GetHeight($dpi)) + (S 5)
    $script:ChipH     = [int][math]::Ceiling($FontChip.GetHeight($dpi))  + (S 4)
    $script:PadY      = S 7
    $script:PadX      = S 20
}

function Get-ItemHeight {
    param($Item)
    $h = ($script:PadY * 2) + $script:LineRepo + $script:LineTitle
    if ($script:Config.showLabels -and $Item.labels -and $Item.labels.Count -gt 0) {
        $h += $script:ChipH + (S 5)
    }
    return $h
}

# Redo everything that depends on the scale. Called when the popup is about to open
# on a monitor with a different DPI than the previous one.
function Apply-Scale {
    Update-Metrics
    $Popup.Width = S $script:Config.popupWidth
    $Popup.MinimumSize = New-Object System.Drawing.Size((S $script:Config.popupWidth), (S 120))
    $Header.Height = S 44
    $Footer.Height = S 30
    $SearchPanel.Height = S 36
    $SearchPanel.Padding = New-Object System.Windows.Forms.Padding((S 14), (S 8), (S 14), (S 8))
    $SearchIcon.Width = S 18
    $SearchHint.Width = S 150
    $HeaderTitle.Padding = New-Object System.Windows.Forms.Padding((S 14), 0, (S 14), 0)
    $HeaderTitle.Invalidate()
    $FooterLabel.Padding = New-Object System.Windows.Forms.Padding((S 14), 0, (S 14), 0)
}

$List.Add_MeasureItem({
    param($sender, $e)
    $e.ItemHeight = Get-ItemHeight $List.Items[$e.Index]
})

# Row text goes through GDI (TextRenderer), not GDI+ (Graphics.DrawString), the
# same as the labels once SetCompatibleTextRenderingDefault is off: GDI+ ClearType
# came out jagged, with thin, uneven stems, colour fringes and irregular letter
# spacing, worst of all light text on a dark background. NoPrefix keeps an
# "&" in a title from turning into an underline; NoPadding makes measuring and
# drawing agree to the pixel. NoClipping because a rectangle exactly as wide as
# the measured text still cuts the last pixel of ink off some glyphs (the "4" in
# "#1234"). The tray icon stays on GDI+: it is drawn onto a transparent bitmap, and
# GDI does not blend alpha.
$RowTextFlags = [System.Windows.Forms.TextFormatFlags]'NoPadding, NoPrefix, SingleLine, NoClipping'
$RowTextCentred = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter'

function Measure-RowText {
    param($G, [string]$Text, $Font)
    return [System.Windows.Forms.TextRenderer]::MeasureText($G, $Text, $Font, [System.Drawing.Size]::Empty, $RowTextFlags).Width
}

function Write-RowText {
    param($G, [string]$Text, $Font, [System.Drawing.Color]$Color, [System.Drawing.Rectangle]$Rect,
          [System.Windows.Forms.TextFormatFlags]$Extra = [System.Windows.Forms.TextFormatFlags]::Default)
    [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $Font, $Rect, $Color, ($RowTextFlags -bor $Extra))
}

$List.Add_DrawItem({
    param($sender, $e)
    if ($e.Index -lt 0 -or $e.Index -ge $List.Items.Count) { return }
    $item = $List.Items[$e.Index]
    $g = $e.Graphics
    # Everything drawn here is an axis-aligned rectangle. Anti-aliased, the 1px
    # outline of the PR chip straddled two pixels and came out as a blurred 2px line.
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None

    $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $bg = if ($selected) { $Theme.Sel } else { $Theme.Back }
    $bgBrush = New-Object System.Drawing.SolidBrush($bg)
    $g.FillRectangle($bgBrush, $e.Bounds)
    $bgBrush.Dispose()

    $repoColor = Get-RepoColor $item.repo
    $barBrush = New-Object System.Drawing.SolidBrush($repoColor)
    $g.FillRectangle($barBrush, ($e.Bounds.Left + (S 8)), ($e.Bounds.Top + (S 9)), (S 3), ($e.Bounds.Height - (S 18)))
    $barBrush.Dispose()

    $x = $e.Bounds.Left + $script:PadX
    $right = $e.Bounds.Right - (S 12)
    $y = $e.Bounds.Top + $script:PadY

    # line 1: age on the right
    $age = Format-Age $item.updated
    Write-RowText $g $age $FontMeta $Theme.Muted (New-Object System.Drawing.Rectangle($x, $y, ($right - $x), $script:LineRepo)) ([System.Windows.Forms.TextFormatFlags]::Right)

    # line 1: repo #number (+ PR marker)
    $repoText = "$($item.repo) #$($item.number)"
    $repoWidth = Measure-RowText $g $repoText $FontRepo
    Write-RowText $g $repoText $FontRepo $repoColor (New-Object System.Drawing.Rectangle($x, $y, $repoWidth, $script:LineRepo))

    if ($item.isPR) {
        # A review request trumps the plain PR marker: it is the reason the row is here
        # (or, for a PR assigned to you as well, the more urgent of the two).
        $prColor = if ($item.isDraft) { $Theme.Muted } elseif ($item.isReview) { $Theme.Review } else { $Theme.Purple }
        $prText = if ($item.isReview) {
            if ($item.isDraft) { 'Draft review' } else { 'Review' }
        } else {
            if ($item.isDraft) { 'Draft PR' } else { 'PR' }
        }
        $prW = (Measure-RowText $g $prText $FontChip) + (S 10)
        $prRect = New-Object System.Drawing.Rectangle(($x + $repoWidth + (S 6)), $y, $prW, $script:ChipH)
        $pen = New-Object System.Drawing.Pen($prColor)
        # DrawRectangle covers Width+1 by Height+1 pixels; shrink by one so the
        # outline lands on the same box the text is centred in.
        $g.DrawRectangle($pen, $prRect.X, $prRect.Y, ($prRect.Width - 1), ($prRect.Height - 1))
        $pen.Dispose()
        Write-RowText $g $prText $FontChip $prColor $prRect $RowTextCentred
    }

    # line 2: title
    $y += $script:LineRepo
    $titleRect = New-Object System.Drawing.Rectangle($x, $y, ($right - $x), $script:LineTitle)
    Write-RowText $g $item.title $FontTitle $Theme.Fore $titleRect ([System.Windows.Forms.TextFormatFlags]::EndEllipsis)

    # line 3: labels
    if ($script:Config.showLabels -and $item.labels -and $item.labels.Count -gt 0) {
        $y += $script:LineTitle
        $chipX = $x
        foreach ($lb in $item.labels) {
            if ($chipX -gt ($right - (S 40))) { break }
            try { $c = [System.Drawing.ColorTranslator]::FromHtml('#' + $lb.color) }
            catch { $c = $Theme.Muted }
            $text = [string]$lb.name
            $w = (Measure-RowText $g $text $FontChip) + (S 12)
            if (($chipX + $w) -gt $right) { break }
            $chipRect = New-Object System.Drawing.Rectangle($chipX, $y, $w, $script:ChipH)
            $chipBrush = New-Object System.Drawing.SolidBrush($c)
            $g.FillRectangle($chipBrush, $chipRect)
            $chipBrush.Dispose()
            Write-RowText $g $text $FontChip (Get-ContrastColor $c) $chipRect $RowTextCentred
            $chipX += $w + (S 5)
        }
    }
})

# ---- list assembly

function Update-List {
    $items = @(Get-FilteredItems)
    $script:MatchCount = $items.Count
    # Keep the highlight on the issue, not on the row number. Every rebuild can move
    # rows under it - a filter, Esc clearing one, a click on a header count, a refresh
    # that re-sorts by updated - and an index kept across that leaves the highlight on
    # a different issue, which is the one Enter then opens.
    $previousUrl = if ($List.SelectedIndex -ge 0) { $List.Items[$List.SelectedIndex].url } else { $null }
    $List.BeginUpdate()
    $List.Items.Clear()
    foreach ($i in $items) { $List.Items.Add($i) | Out-Null }
    $List.EndUpdate()

    if ($List.Items.Count -gt 0) {
        $idx = 0
        if ($previousUrl) {
            for ($i = 0; $i -lt $List.Items.Count; $i++) {
                if ($List.Items[$i].url -eq $previousUrl) { $idx = $i; break }
            }
        }
        $List.SelectedIndex = $idx
        $List.Visible = $true
        $Empty.Visible = $false
    } else {
        $List.Visible = $false
        $Empty.Visible = $true
        $Empty.Text = if (Test-Loading) {
            'Loading…'
        } elseif ($script:LastError) {
            # This is the only place with room for the reason; the tooltip cannot hold it.
            $why = Format-ErrorText $script:LastError
            if ($why.Length -gt 160) { $why = $why.Substring(0, 159) + [char]0x2026 }
            "Couldn't reach GitHub.`r`n$why`r`nPress R to try again, or L to sign in."
        } elseif ($script:Filter) {
            # Ahead of the two below on purpose: with a filter on, “nothing assigned to
            # you” would be a lie about the list, not just about the search.
            if ($script:KindFilter) {
                # The group hides results too; blaming the search alone sends Esc
                # after the wrong one and leaves the matches still out of sight.
                $group = ($script:HeaderSegments | Where-Object { $_.Kind -eq $script:KindFilter } | Select-Object -First 1).Text
                "Nothing in '$group' matches '$($script:Filter)'.`r`nClick it again to search everything, or press Esc to clear the search."
            } else {
                "Nothing matches '$($script:Filter)'.`r`nPress Esc to clear the search."
            }
        } else {
            $clear = 'Nothing assigned to you'
            if ($script:IncludeReviews) { $clear += ', nothing to review' }
            $clear + '. 🎉'
        }
    }
    $Popup.Controls.SetChildIndex($List, 0)
    $Popup.Controls.SetChildIndex($Empty, 0)
    Set-HeaderText
    Resize-Popup
}

function Resize-Popup {
    $rows = 0
    for ($i = 0; $i -lt $List.Items.Count; $i++) {
        $rows += Get-ItemHeight $List.Items[$i]
    }
    if ($List.Items.Count -eq 0) { $rows = S 90 }
    $target = $Header.Height + $Footer.Height + $rows + (S 8)
    if ($SearchPanel.Visible) { $target += $SearchPanel.Height }
    # One screen answers both questions below - how tall this may be, and where it
    # then goes. Read from two different screens they disagree: clamp the height to a
    # tall monitor the cursor happens to be on, re-anchor to the shorter one the popup
    # is actually on, and the footer lands behind the taskbar. They could only differ
    # once the search bar started resizing a popup that is already on screen. While it
    # is hidden the cursor's screen is the right guess: Show-Popup is about to open it
    # there, and positions it against that same work area.
    $screen = if ($Popup.Visible) {
        [System.Windows.Forms.Screen]::FromControl($Popup)
    } else {
        [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    }

    $max = S $script:Config.popupMaxHeight
    # popupMaxHeight scales too, so on a high-scale display it can exceed the work
    # area and push the footer (the shortcuts) behind the taskbar.
    $fit = $screen.WorkingArea.Height - (S 24)
    if ($fit -gt 0 -and $max -gt $fit) { $max = $fit }
    if ($target -gt $max) { $target = $max }
    if ($target -lt (S 160)) { $target = S 160 }
    if ($Popup.Height -eq $target) { return }
    $Popup.Height = $target
    # The popup is placed by its top-left corner but belongs to the bottom-right one,
    # so a height change while it is on screen has to put it back. Opening the search
    # bar adds 36px and would otherwise push the footer - the line that says how to
    # get out of the search - behind the taskbar; Esc on a filter narrowed to one row
    # grows it back by hundreds of pixels and would push most of the list off the
    # bottom of the screen. While it is hidden there is nothing to move: Show-Popup
    # positions it against whatever height it ends up with.
    if ($Popup.Visible) { Set-PopupPosition $screen }
}

# The filter goes in the header, not the footer: while you type it is the one line
# that can say how much of the list you are still looking at. $script:HeaderBase is
# what Update-Ui computed; the suffix is re-applied on every keystroke, from
# Update-List, without recomputing the rest.
function Set-HeaderText {
    $text = $script:HeaderBase
    if ($script:Filter) { $text += '  ·  ' + $script:MatchCount + ' matching' }
    $HeaderTitle.Text = $text
    $HeaderTitle.Invalidate()
}

# Where each clickable count landed in the last paint: @{ Kind; X0; X1 }. Measured
# there, with the Graphics the text was drawn on, so the mouse handlers only read it.
$script:HeaderSpans = @()

$HeaderTitle.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $font = $HeaderTitle.Font
    $text = $HeaderTitle.Text
    $pad = $HeaderTitle.Padding
    $rect = New-Object System.Drawing.Rectangle($pad.Left, 0, [Math]::Max(0, $HeaderTitle.ClientSize.Width - $pad.Horizontal), $HeaderTitle.ClientSize.Height)
    $spans = @()
    $size = [System.Windows.Forms.TextRenderer]::MeasureText($g, $text, $font, [System.Drawing.Size]::Empty, $RowTextFlags)
    if ($size.Width -le $rect.Width) {
        Write-RowText $g $text $font $HeaderTitle.ForeColor $rect ([System.Windows.Forms.TextFormatFlags]::VerticalCenter)
        # “link copied: #12” replaces the header for a moment; nothing to hit then.
        # Ordinal, like Test-ItemMatch: “·” and “…” are in this text.
        if ($script:HeaderBase -and $text.StartsWith($script:HeaderBase, [System.StringComparison]::Ordinal)) {
            foreach ($seg in $script:HeaderSegments) {
                # The end is measured with everything before it, so kerning and the
                # spaces in between cannot drift it.
                $end = Measure-RowText $g ($text.Substring(0, $seg.Start + $seg.Text.Length)) $font
                $len = Measure-RowText $g $seg.Text $font
                $spans += @{ Kind = $seg.Kind; X0 = $rect.X + $end - $len; X1 = $rect.X + $end }
            }
        }
    } else {
        # Too long for one line: a stale header with every part on, in a narrow popup.
        # Wrapped, the counts are no longer where a one-line measure puts them, so they
        # stop being click targets rather than be hit in the wrong place.
        $wrap = [System.Windows.Forms.TextFormatFlags]'NoPadding, NoPrefix, WordBreak'
        $h = [System.Windows.Forms.TextRenderer]::MeasureText($g, $text, $font, (New-Object System.Drawing.Size($rect.Width, 0)), $wrap).Height
        $top = [Math]::Max(0, [int](($rect.Height - $h) / 2))
        $box = New-Object System.Drawing.Rectangle($rect.X, $top, $rect.Width, ($rect.Height - $top))
        [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $font, $box, $HeaderTitle.ForeColor, $wrap)
    }
    $script:HeaderSpans = $spans

    # The active group is underlined in the accent colour, just under the text.
    $active = $spans | Where-Object { $_.Kind -eq $script:KindFilter } | Select-Object -First 1
    if ($active) {
        $y = [int](($rect.Height + $size.Height) / 2) + 1
        $pen = New-Object System.Drawing.Pen($Theme.Accent, [float](S 2))
        $g.DrawLine($pen, $active.X0, $y, $active.X1, $y)
        $pen.Dispose()
    }
})

# A Panel does not repaint on its own for either of these, as a Label does.
$HeaderTitle.Add_TextChanged({ $HeaderTitle.Invalidate() })
$HeaderTitle.Add_Resize({ $HeaderTitle.Invalidate() })

function Get-HeaderSegmentAt {
    param([int]$X)
    foreach ($span in $script:HeaderSpans) {
        if ($X -ge $span.X0 -and $X -le $span.X1) { return $span }
    }
    return $null
}

$HeaderTitle.Add_MouseMove({
    param($sender, $e)
    $HeaderTitle.Cursor = if (Get-HeaderSegmentAt $e.X) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
})

$HeaderTitle.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $seg = Get-HeaderSegmentAt $e.X
    if (-not $seg) { return }
    $script:KindFilter = if ($script:KindFilter -eq $seg.Kind) { '' } else { $seg.Kind }
    Update-List
    # Back to wherever the typing was. Left on the list, the rest of a search typed
    # after the click would run as shortcuts: R refreshes, G opens github.com.
    if ($script:SearchOpen) { $SearchBox.Focus() | Out-Null } else { $List.Focus() | Out-Null }
})

function Set-FooterText {
    if ($script:SearchOpen) {
        # The letter shortcuts are all typing while the box has focus, so listing them
        # here would be an invitation to a surprise.
        $FooterLabel.Text = '↑↓ navigate  Enter open  Esc clear search'
    } else {
        $FooterLabel.Text = '↑↓ navigate  Enter open  / search  C copy  R refresh  G github  Esc close'
    }
}

# “3 assigned”, “3 assigned, 2 to review”, or just “2 to review” when that is all
# there is. The first group mixes issues and assigned PRs, so it is counted as
# “assigned” rather than given a noun that would be wrong for half of it.
# Returned in parts, @{ Kind; Text }, joined by the caller, so the header can tell
# where each count sits in the text without repeating how it was built.
function Get-CountParts {
    param([int]$Own, [int]$Reviews)
    $parts = @()
    if ($Own -gt 0 -or $Reviews -eq 0) { $parts += @{ Kind = 'own'; Text = "$Own assigned" } }
    if ($Reviews -gt 0) { $parts += @{ Kind = 'review'; Text = "$Reviews to review" } }
    return $parts
}

function Update-Ui {
    try {
    $items = @(Get-VisibleItems)
    $count = $items.Count

    # A failed refresh does not invalidate what we already have: only fall back to
    # the error icon when there is genuinely nothing to show. Otherwise keep the
    # count and mark it stale, so a dropped network does not erase the number.
    $stale = [bool]$script:LastError
    $loading = Test-Loading
    if ($loading) {
        Set-TrayIcon -Count 0 -Mode 'loading'
    } elseif ($script:LastError -and $count -eq 0) {
        Set-TrayIcon -Count 0 -Mode 'error'
    } elseif ($count -eq 0) {
        Set-TrayIcon -Count 0 -Mode 'zero'
    } elseif ($stale) {
        Set-TrayIcon -Count $count -Mode 'stale'
    } else {
        Set-TrayIcon -Count $count -Mode 'normal'
    }

    # 63 characters total, so the reason for a failure does not fit here: it always
    # goes to the log, and to the popup when there is nothing left to list.
    $repos = @($items | Select-Object -ExpandProperty repo -Unique).Count
    $reviews = @($items | Where-Object { $_.isReview }).Count
    $parts = @(Get-CountParts -Own ($count - $reviews) -Reviews $reviews)
    $sep = ', '
    $what = ($parts | ForEach-Object { $_.Text }) -join $sep
    if ($loading) {
        $tip = 'GitHub Issues Tray - loading…'
    } elseif ($script:LastError -and $count -eq 0) {
        $tip = 'GitHub Issues Tray - refresh failed'
    } else {
        $inRepos = if ($repos -gt 0) { " in $repos " + (Plural $repos 'repo' 'repos') } else { '' }
        if ($stale) {
            # Has to fit in $TrayTextMax together with the count line above it, or the
            # clamp in Set-TrayTooltip eats exactly the age this line exists to show.
            $when = if ($script:LastUpdate) {
                "`r`nStale - data from " + (Format-Age $script:LastUpdate)
            } else {
                "`r`nRefresh failed"
            }
        } elseif ($script:LastUpdate) {
            $when = "`r`nUpdated " + (Format-Age $script:LastUpdate)
        } else {
            $when = ''
        }
        $tip = "GitHub: $what$inRepos$when"
        # "12 assigned, 3 to review in 4 repos" with a stale age under it runs past 63.
        # The repo count is the part the header repeats, so it gives way first.
        if ($tip.Length -gt $TrayTextMax) { $tip = "GitHub: $what$when" }
    }
    Set-TrayTooltip $tip

    # The counts open the header, in the order $what joined them. With one group
    # there is nothing to narrow: a click would hide nothing and cost an extra Esc.
    $segs = @()
    if (-not $loading -and $parts.Count -gt 1) {
        $start = 0
        foreach ($p in $parts) {
            $segs += @{ Kind = $p.Kind; Start = $start; Text = $p.Text }
            $start += $p.Text.Length + $sep.Length
        }
    }

    if ($loading) {
        $headerText = 'loading…'
    } else {
        $headerText = $what
        if ($repos -gt 0) { $headerText += "  ·  $repos " + (Plural $repos 'repo' 'repos') }
        if ($script:Fetching) {
            $headerText += '  ·  refreshing…'
        } elseif ($script:LastUpdate) {
            $headerText += '  ·  ' + (Format-Age $script:LastUpdate)
        }
        if ($stale) { $headerText += '  ·  could not refresh' }
    }
    # Side by side, with nothing that can throw between them: the segments are
    # offsets into this text, and one without the other would point past its end.
    $script:HeaderBase = $headerText
    $script:HeaderSegments = $segs
    # A refresh can leave the group being filtered on empty, or alone; filtering on it
    # would then show an empty list or hide nothing.
    if ($script:KindFilter -and -not ($segs | Where-Object { $_.Kind -eq $script:KindFilter })) { $script:KindFilter = '' }
    Set-HeaderText
    $HeaderTitle.ForeColor = if ($script:LastError) { $Theme.Warn } else { $Theme.Fore }

    Set-FooterText

    if ($Popup.Visible) { Update-List }
    } catch {
        # Update-Ui runs from timers; an exception escaping here reaches WinForms
        # as an unhandled one. Log it and keep the tray alive.
        Write-Log "error in Update-Ui: $(Format-ErrorText $_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"
    }
}

# ---- position and visibility

$script:LastHideTicks = 0

# Bottom-right of the work area, inset by the same gap on both sides. Shared with
# Resize-Popup, which has to redo this every time the height moves.
function Set-PopupPosition {
    param($Screen)
    $wa = $Screen.WorkingArea
    $x = $wa.Right - $Popup.Width - (S 12)
    $y = $wa.Bottom - $Popup.Height - (S 12)
    if ($x -lt $wa.Left) { $x = $wa.Left }
    if ($y -lt $wa.Top) { $y = $wa.Top }
    $Popup.Location = New-Object System.Drawing.Point($x, $y)
}

function Show-Popup {
    try {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($cursor)

    # the popup may open on a monitor with a different scale than the previous one
    $sc = [TrayNative]::ScaleForPoint($cursor.X, $cursor.Y)
    if ($sc -gt 0 -and [math]::Abs($sc - $script:Scale) -gt 0.01) {
        Write-Log "scale changed from $($script:Scale) to $sc"
        $script:Scale = $sc
        Apply-Scale
    }

    # Update-Ui, not just Update-List: the header carries the age of the data
    # ("3m ago"), and only the one-minute clock recomputed it. Opening the popup
    # between two ticks showed an age up to a minute out of date - the row ages are
    # fine either way, since those are formatted while each row is painted.
    # Update-List runs unconditionally after it. Update-Ui swallows its own errors,
    # so skipping this when the popup happens to be visible would leave the list
    # and the height unrebuilt on exactly the path where Update-Ui failed early.
    # When the popup is closed - which is every real case, since it hides on losing
    # focus - Update-Ui does not touch the list, so this stays a single rebuild.
    Update-Ui
    Update-List

    Set-PopupPosition $screen
    $Popup.Show()
    $Popup.Activate()
    [TrayNative]::SetForegroundWindow($Popup.Handle) | Out-Null
    $List.Focus() | Out-Null
    } catch { Write-Log "error in Show-Popup: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
}

function Hide-Popup {
    if ($Popup.Visible) {
        $script:LastHideTicks = [Environment]::TickCount
        $Popup.Hide()
        $script:KindFilter = ''
        # A filter belongs to this visit to the list, not the next one: left set, the
        # popup would reopen showing a subset with no visible reason why. Hidden first,
        # so the rebuild Hide-Search triggers does not flash a resize on the way out.
        Hide-Search
    }
}

function Toggle-Popup {
    if ($Popup.Visible) {
        Hide-Popup
    } else {
        if (([Environment]::TickCount - $script:LastHideTicks) -lt 300) { return }
        Show-Popup
    }
}

$Popup.Add_Deactivate({ Hide-Popup })

$Popup.Add_Paint({
    param($sender, $e)
    $pen = New-Object System.Drawing.Pen($Theme.Border)
    $e.Graphics.DrawRectangle($pen, 0, 0, $Popup.Width - 1, $Popup.Height - 1)
    $pen.Dispose()
})

# ---- actions

function Open-Selected {
    if ($List.SelectedIndex -lt 0) { return }
    $item = $List.Items[$List.SelectedIndex]
    Hide-Popup
    Open-Url $item.url
}

function Copy-Selected {
    if ($List.SelectedIndex -lt 0) { return }
    $item = $List.Items[$List.SelectedIndex]
    try {
        [System.Windows.Forms.Clipboard]::SetText($item.url)
        $HeaderTitle.Text = "link copied: #$($item.number)"
    } catch { Write-Log "failed to copy: $($_.Exception.Message)" }
}

function Move-Selection {
    param([int]$Delta)
    if ($List.Items.Count -eq 0) { return }
    $idx = $List.SelectedIndex + $Delta
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $List.Items.Count) { $idx = $List.Items.Count - 1 }
    $List.SelectedIndex = $idx
}

function Show-Search {
    if (-not $Popup.Visible) { return }
    if ($script:SearchOpen) {
        # Reached from Ctrl+F, or from “/” with the focus somewhere other than the box:
        # put the cursor back and select what is there, so the next keystroke starts a
        # new filter. “/” typed INTO the box is a literal slash on purpose - repository
        # names carry one, and “monde/api” is a search the README promises works. Ctrl+F
        # is the way to start over without leaving the keyboard.
        $SearchBox.Focus() | Out-Null
        $SearchBox.SelectAll()
        return
    }
    $script:SearchOpen = $true
    $script:Filter = ''
    $script:SuspendSearch = $true
    $SearchBox.Text = ''
    $script:SuspendSearch = $false
    $SearchHint.Visible = $true
    $SearchPanel.Visible = $true
    Update-List
    Set-FooterText
    $SearchBox.Focus() | Out-Null
}

function Hide-Search {
    if (-not $script:SearchOpen) { return }
    $script:SearchOpen = $false
    $script:Filter = ''
    $script:SuspendSearch = $true
    $SearchBox.Text = ''
    $script:SuspendSearch = $false
    $SearchPanel.Visible = $false
    Update-List
    Set-FooterText
    if ($Popup.Visible) { $List.Focus() | Out-Null }
}

function Open-AssignedPage { Hide-Popup; Open-Url 'https://github.com/issues/assigned' }

function Invoke-GhLogin {
    Hide-Popup
    if (-not $script:GhPath) { return }
    try { Start-Process -FilePath $script:GhPath -ArgumentList 'auth', 'login' }
    catch { Write-Log "failed to run gh auth login: $($_.Exception.Message)" }
}

# ---- keyboard

$Popup.Add_KeyDown({
    param($sender, $e)

    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::F) {
        Show-Search
        $e.Handled = $true; $e.SuppressKeyPress = $true
        return
    }

    # With the box focused every other key is text being typed, so only navigation is
    # taken here: left to the switch below, filtering for “pr” would toggle pull
    # requests and then refresh.
    if ($script:SearchOpen -and $SearchBox.Focused) {
        switch ($e.KeyCode) {
            ([System.Windows.Forms.Keys]::Escape)   { Hide-Search;              $e.Handled = $true; $e.SuppressKeyPress = $true }
            ([System.Windows.Forms.Keys]::Enter)    { Open-Selected;            $e.Handled = $true; $e.SuppressKeyPress = $true }
            ([System.Windows.Forms.Keys]::Up)       { Move-Selection -Delta -1; $e.Handled = $true; $e.SuppressKeyPress = $true }
            ([System.Windows.Forms.Keys]::Down)     { Move-Selection -Delta 1;  $e.Handled = $true; $e.SuppressKeyPress = $true }
            ([System.Windows.Forms.Keys]::PageUp)   { Move-Selection -Delta -5; $e.Handled = $true; $e.SuppressKeyPress = $true }
            ([System.Windows.Forms.Keys]::PageDown) { Move-Selection -Delta 5;  $e.Handled = $true; $e.SuppressKeyPress = $true }
        }
        return
    }

    switch ($e.KeyCode) {
        ([System.Windows.Forms.Keys]::Escape) {
            # Esc backs out one step at a time: the filter first, the popup after.
            if ($script:SearchOpen) { Hide-Search }
            elseif ($script:KindFilter) { $script:KindFilter = ''; Update-List }
            else { Hide-Popup }
            $e.Handled = $true
        }
        ([System.Windows.Forms.Keys]::Enter)  { Open-Selected; $e.Handled = $true; $e.SuppressKeyPress = $true }
        ([System.Windows.Forms.Keys]::C)      { Copy-Selected; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::R)      { $script:RetryCount = 0; Start-Fetch; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::G)      { Open-AssignedPage; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::L)      { Invoke-GhLogin; $e.Handled = $true }
    }
})

# “/” is read as a character, not as a key code: the virtual key behind it moves with
# the layout - VK_OEM_2 on a US keyboard, VK_ABNT_C1 on the Brazilian ABNT2 - and
# matching on the code would open the search on one keyboard and do nothing on the
# other. Handled here, it is also kept from reaching the ListBox, whose own
# type-ahead would otherwise try to match it against the rows.
$Popup.Add_KeyPress({
    param($sender, $e)
    # Not a missing case: with the box focused, “/” is text. Intercepting it here would
    # make “monde/api” untypable, and Ctrl+F already restarts the search from inside.
    if ($script:SearchOpen -and $SearchBox.Focused) { return }
    if ([string]$e.KeyChar -eq '/') {
        Show-Search
        $e.Handled = $true
    }
})

# ---- mouse on the list

$List.Add_MouseUp({
    param($sender, $e)
    $idx = $List.IndexFromPoint($e.Location)
    if ($idx -lt 0 -or $idx -ge $List.Items.Count) { return }
    $List.SelectedIndex = $idx
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-Selected }
    elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Middle) { Copy-Selected }
})

# ---- tray context menu

$Menu = New-Object System.Windows.Forms.ContextMenuStrip

$miOpen = $Menu.Items.Add('Open list')
$miOpen.Add_Click({ Show-Popup })
$miOpen.Font = New-Object System.Drawing.Font($Menu.Font, [System.Drawing.FontStyle]::Bold)

$miRefresh = $Menu.Items.Add('Refresh now')
$miRefresh.Add_Click({ $script:RetryCount = 0; Start-Fetch })

$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miAssigned = $Menu.Items.Add('Open github.com/issues/assigned')
$miAssigned.Add_Click({ Open-AssignedPage })

$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miLogin = $Menu.Items.Add('gh auth login')
$miLogin.Add_Click({ Invoke-GhLogin })

$miConfig = $Menu.Items.Add('Edit configuration')
$miConfig.Add_Click({
    Hide-Popup
    try { Start-Process notepad.exe -ArgumentList "`"$ConfigPath`"" } catch { }
})

$miLog = $Menu.Items.Add('Open log')
$miLog.Add_Click({
    Hide-Popup
    if (Test-Path -LiteralPath $LogPath) { try { Start-Process notepad.exe -ArgumentList "`"$LogPath`"" } catch { } }
})

$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miExit = $Menu.Items.Add('Quit')
$miExit.Add_Click({
    $script:Notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$script:Notify.ContextMenuStrip = $Menu

$script:Notify.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Toggle-Popup
    } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Middle) {
        $items = @(Get-VisibleItems)
        if ($items.Count -gt 0) { Open-Url $items[0].url }
    }
})

# ----------------------------------------------------------------- timers ---

$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = 250
$script:PollTimer.Add_Tick({
    if (-not $script:Fetching) { $script:PollTimer.Stop(); return }

    $stale = $script:Jobs | Where-Object { ((Get-Date) - $_.Started).TotalSeconds -gt 60 }
    if ($stale) {
        Stop-Fetch
        $script:LastError = 'the GitHub query took too long (timeout)'
        $script:PollTimer.Stop()
        # A hang is a failure like any other. Without this the timeout is the one
        # path that skips the backoff, and a gh left hanging by a half-open
        # connection (exactly the resume-from-sleep case) sits stale for a whole
        # refresh interval. Stop-Fetch first: Start-Fetch bails while Fetching.
        $script:RetryCount++
        Write-Log "fetch exceeded 60s, cancelling (attempt $($script:RetryCount))"
        Start-Retry
        Update-Ui
        return
    }

    $done = $true
    foreach ($job in $script:Jobs) {
        if (-not $job.Proc.HasExited -or -not $job.OutTask.IsCompleted -or -not $job.ErrTask.IsCompleted) {
            $done = $false; break
        }
    }
    if ($done) {
        $script:PollTimer.Stop()
        Complete-Fetch
    }
})

$script:RefreshTimer = New-Object System.Windows.Forms.Timer
$script:RefreshTimer.Interval = [int]$script:Config.refreshMinutes * 60000
$script:RefreshTimer.Add_Tick({ Start-Fetch })

# Waiting the full refresh interval after a failure is what leaves a stale icon
# sitting there for minutes: the usual cause is a resume from sleep, where the
# network comes up seconds later. Retry sooner, backing off.
$script:RetryDelays = @(20, 60, 120, 300)

$script:RetryTimer = New-Object System.Windows.Forms.Timer
$script:RetryTimer.Add_Tick({
    $script:RetryTimer.Stop()
    Start-Fetch
})

function Start-Retry {
    if ($script:RetryCount -lt 1 -or $script:RetryCount -gt $script:RetryDelays.Count) { return }
    $delay = $script:RetryDelays[$script:RetryCount - 1]
    $script:RetryTimer.Stop()
    $script:RetryTimer.Interval = $delay * 1000
    $script:RetryTimer.Start()
    Write-Log "retrying in ${delay}s"
}

# one-minute clock: keeps the "Xm ago" in the tooltip/header current
$script:ClockTimer = New-Object System.Windows.Forms.Timer
$script:ClockTimer.Interval = 60000
$script:LastTick = Get-Date

$script:ClockTimer.Add_Tick({
    # A WinForms timer does not fire while the machine is suspended, so a jump in
    # the wall clock means we just came back from sleep. The scheduled refresh can
    # be minutes away and the data is already hours old, so ask for it now.
    # A large clock correction (NTP, or a dual-boot machine disagreeing with the
    # RTC) trips this too. That is fine: the cost of a false positive is one extra
    # query, and the cost of missing a real resume is a stale count for minutes.
    $now = Get-Date
    if (($now - $script:LastTick).TotalSeconds -gt 180) {
        Write-Log "clock jumped $([int](($now - $script:LastTick).TotalMinutes))min (resume from sleep); refreshing"
        $script:RetryCount = 0
        Start-Fetch
    }
    $script:LastTick = $now

    if ($script:LastUpdate) { Update-Ui }
})

# ----------------------------------------------------------------- hotkey ---

$script:Hotkey = $null

function Register-Hotkey {
    param([string]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec)) { return }
    $mods = 0
    $key = $null
    foreach ($part in ($Spec -split '\+')) {
        switch ($part.Trim().ToLowerInvariant()) {
            'ctrl'    { $mods = $mods -bor 0x0002 }
            'control' { $mods = $mods -bor 0x0002 }
            'alt'     { $mods = $mods -bor 0x0001 }
            'shift'   { $mods = $mods -bor 0x0004 }
            'win'     { $mods = $mods -bor 0x0008 }
            'super'   { $mods = $mods -bor 0x0008 }
            default   { $key = $part.Trim() }
        }
    }
    if (-not $key) { return }
    try { $vk = [int][System.Windows.Forms.Keys]::Parse([System.Windows.Forms.Keys], $key, $true) }
    catch { Write-Log "unknown key in hotkey: $Spec"; return }

    $script:Hotkey = New-Object TrayNative+HotkeyWindow
    $script:Hotkey.Add_Pressed({
        try { Write-Log 'global hotkey pressed'; Toggle-Popup }
        catch { Write-Log "error opening from the hotkey: $($_.Exception.Message)" }
    })
    if ($script:Hotkey.Register([uint32]$mods, [uint32]$vk)) {
        Write-Log "global hotkey registered: $Spec"
    } else {
        Write-Log "global hotkey $Spec is already taken by another program; continuing without it"
        $script:Hotkey.Dispose()
        $script:Hotkey = $null
    }
}

# ------------------------------------------------------------------ start ---

$script:GhPath = (Get-Command gh -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source)
if (-not $script:GhPath) {
    $script:LastError = 'GitHub CLI (gh) not found. Install it with: winget install GitHub.cli'
    Write-Log $script:LastError
}

Apply-Scale
Write-Log "dpi: $($script:DpiMode), scale $($script:Scale)"
if ($script:CompatTextError) { Write-Log "labels stay on GDI+ text: $(Format-ErrorText $script:CompatTextError)" }

Restore-Cache
Update-Ui
Register-Hotkey $script:Config.hotkey

$script:RefreshTimer.Start()
$script:ClockTimer.Start()
Start-Fetch

Write-Log "started (refresh $($script:Config.refreshMinutes)min, hotkey $($script:Config.hotkey))"

if ($ShowOnStart) {
    $bootTimer = New-Object System.Windows.Forms.Timer
    $bootTimer.Interval = 1500
    $bootTimer.Add_Tick({ $bootTimer.Stop(); Show-Popup })
    $bootTimer.Start()
}

# Last line of defence: a tray app that lives for days must never answer a bug
# with a modal .NET crash dialog. Log it and stay up.
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    try { Write-Log "unhandled UI exception: $(Format-ErrorText $e.Exception.ToString())" } catch { }
})

$AppContext = New-Object System.Windows.Forms.ApplicationContext
try {
    [System.Windows.Forms.Application]::Run($AppContext)
} finally {
    Stop-Fetch
    $script:RefreshTimer.Stop()
    $script:ClockTimer.Stop()
    $script:PollTimer.Stop()
    $script:RetryTimer.Stop()
    if ($script:Hotkey) { $script:Hotkey.Dispose() }
    $script:Notify.Visible = $false
    $script:Notify.Dispose()
    if ($script:CurrentIconHandle -ne [IntPtr]::Zero) { [TrayNative]::DestroyIcon($script:CurrentIconHandle) | Out-Null }
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { } ; $script:Mutex.Dispose() }
    Write-Log 'stopped'
}
