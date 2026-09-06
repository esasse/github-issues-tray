#Requires -Version 5.1
<#
    GitHub Issues Tray
    ------------------
    Shows how many GitHub issues are assigned to you, in the Windows tray.
    Left click opens the list; clicking an item opens the issue in the browser.

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
    refreshMinutes      = 5
    maxItems            = 50
    includePullRequests = $false
    showLabels          = $true
    hotkey              = 'Ctrl+Win+I'
    accentColor         = '#00A8FF'
    popupWidth          = 520
    popupMaxHeight      = 620
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
$script:IncludePRs = [bool]$script:Config.includePullRequests

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
# Fonts are declared in points and GDI+ already converts them by the device DPI.
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
    $mins = [int]$span.TotalMinutes
    if ($mins -lt 1)    { return 'now' }
    if ($mins -lt 60)   { return "$mins" + 'm ago' }
    $hours = [int]$span.TotalHours
    if ($hours -lt 24)  { return "$hours" + 'h ago' }
    $days = [int]$span.TotalDays
    if ($days -lt 14)   { return "$days" + 'd ago' }
    $weeks = [int]($days / 7)
    if ($weeks -lt 9)   { return "$weeks" + 'w ago' }
    $months = [int]($days / 30)
    if ($months -lt 24) { return "$months" + 'mo ago' }
    return "$([int]($days / 365))y ago"
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
        'loading' { $fill = $Theme.Muted;  $text = '…' }
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

    $ratio = switch ($text.Length) { 1 { 0.60 } 2 { 0.50 } default { 0.38 } }
    $fontSize = [float]($size * $ratio)
    $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $textBrush = New-Object System.Drawing.SolidBrush((Get-ContrastColor $fill))
    $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
    $g.DrawString($text, $font, $textBrush, $rect, $fmt)

    $textBrush.Dispose(); $fmt.Dispose(); $font.Dispose(); $g.Dispose()

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

function Get-VisibleItems {
    $items = @($script:AllItems)
    if (-not $script:IncludePRs) {
        $items = @($items | Where-Object { -not $_.isPR })
    }
    $items = @($items | Sort-Object -Property @{ Expression = { $_.updated } } -Descending)
    if ($items.Count -gt [int]$script:Config.maxItems) {
        $items = @($items[0..([int]$script:Config.maxItems - 1)])
    }
    return $items
}

function Save-Cache {
    try {
        $payload = [ordered]@{
            savedAt = (Get-Date).ToString('o')
            items   = @($script:AllItems | ForEach-Object {
                [ordered]@{
                    number = $_.number; title = $_.title; url = $_.url; repo = $_.repo
                    isPR = $_.isPR; isDraft = $_.isDraft
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
            [pscustomobject]@{
                number = [int]$_.number; title = [string]$_.title; url = [string]$_.url
                repo = [string]$_.repo; isPR = [bool]$_.isPR; isDraft = [bool]$_.isDraft
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
    param([string]$Arguments)
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
        $script:Jobs += New-GhJob "search issues --assignee @me --state open --sort updated --order desc --limit $limit --json $fields"
        $script:Jobs += New-GhJob "search prs --assignee @me --state open --sort updated --order desc --limit $limit --json $fields,isDraft"
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

    if ($script:Fetching) {
        $script:PollTimer.Start()
        if ($script:AllItems.Count -eq 0 -and -not $script:LastUpdate) {
            try { Set-TrayIcon -Count 0 -Mode 'loading' }
            catch { Write-Log "could not draw the loading icon: $(Format-ErrorText $_.Exception.Message)" }
        }
    }
    Update-Ui
}

function Convert-GhItem {
    param($Raw, [bool]$IsPR)
    $repo = if ($Raw.repository -and $Raw.repository.nameWithOwner) { $Raw.repository.nameWithOwner } else { '' }
    return [pscustomobject]@{
        number  = [int]$Raw.number
        title   = [string]$Raw.title
        url     = [string]$Raw.url
        repo    = [string]$repo
        isPR    = $IsPR
        isDraft = [bool]($Raw.PSObject.Properties['isDraft'] -and $Raw.isDraft)
        created = [datetime]$Raw.createdAt
        updated = [datetime]$Raw.updatedAt
        labels  = @($Raw.labels | ForEach-Object { [pscustomobject]@{ name = $_.name; color = $_.color } })
    }
}

function Complete-Fetch {
    $errors = @()
    $collected = @()

    for ($i = 0; $i -lt $script:Jobs.Count; $i++) {
        $job = $script:Jobs[$i]
        $isPR = ($i -eq 1)
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
            foreach ($raw in @($parsed)) { $collected += (Convert-GhItem -Raw $raw -IsPR $isPR) }
        } catch {
            $errors += "invalid response from gh: $(Format-ErrorText $_.Exception.Message)"
        }
    }

    $script:Jobs = @()
    $script:Fetching = $false

    if ($errors.Count -gt 0) {
        # both jobs fail with the same message when the network is down; saying it
        # twice helps nobody
        $script:LastError = (@($errors | Select-Object -Unique) -join ' | ')
        $script:RetryCount++
        Write-Log "fetch error (attempt $($script:RetryCount)): $($script:LastError)"
        Start-Retry
    } else {
        $script:LastError = $null
        $script:RetryCount = 0
        $script:RetryTimer.Stop()
        $script:AllItems = @($collected)
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

$HeaderTitle = New-Object System.Windows.Forms.Label
$HeaderTitle.AutoSize = $false
$HeaderTitle.Dock = [System.Windows.Forms.DockStyle]::Fill
$HeaderTitle.ForeColor = $Theme.Fore
$HeaderTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$HeaderTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
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

$Popup.Controls.Add($List)
$Popup.Controls.Add($Empty)
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
    $HeaderTitle.Padding = New-Object System.Windows.Forms.Padding((S 14), 0, (S 14), 0)
    $FooterLabel.Padding = New-Object System.Windows.Forms.Padding((S 14), 0, (S 14), 0)
}

$List.Add_MeasureItem({
    param($sender, $e)
    $e.ItemHeight = Get-ItemHeight $List.Items[$e.Index]
})

$List.Add_DrawItem({
    param($sender, $e)
    if ($e.Index -lt 0 -or $e.Index -ge $List.Items.Count) { return }
    $item = $List.Items[$e.Index]
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

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
    $ageSize = $g.MeasureString($age, $FontMeta)
    $mutedBrush = New-Object System.Drawing.SolidBrush($Theme.Muted)
    $g.DrawString($age, $FontMeta, $mutedBrush, [float]($right - $ageSize.Width), [float]$y)

    # line 1: repo #number (+ PR marker)
    $repoBrush = New-Object System.Drawing.SolidBrush($repoColor)
    $repoText = "$($item.repo) #$($item.number)"
    $g.DrawString($repoText, $FontRepo, $repoBrush, [float]$x, [float]$y)
    $repoWidth = $g.MeasureString($repoText, $FontRepo).Width
    $repoBrush.Dispose()

    if ($item.isPR) {
        $prColor = if ($item.isDraft) { $Theme.Muted } else { $Theme.Purple }
        $prText = if ($item.isDraft) { 'Draft PR' } else { 'PR' }
        $prW = [int]$g.MeasureString($prText, $FontChip).Width + (S 10)
        $prRect = New-Object System.Drawing.Rectangle([int]($x + $repoWidth + (S 6)), [int]$y, $prW, $script:ChipH)
        $pen = New-Object System.Drawing.Pen($prColor)
        $g.DrawRectangle($pen, $prRect)
        $pen.Dispose()
        $prBrush = New-Object System.Drawing.SolidBrush($prColor)
        $g.DrawString($prText, $FontChip, $prBrush, [float]($prRect.X + (S 4)), [float]($prRect.Y + (S 2)))
        $prBrush.Dispose()
    }

    # line 2: title
    $y += $script:LineRepo
    $titleBrush = New-Object System.Drawing.SolidBrush($Theme.Fore)
    $titleRect = New-Object System.Drawing.RectangleF([float]$x, [float]$y, [float]($right - $x), [float]$script:LineTitle)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $g.DrawString($item.title, $FontTitle, $titleBrush, $titleRect, $fmt)
    $titleBrush.Dispose()

    # line 3: labels
    if ($script:Config.showLabels -and $item.labels -and $item.labels.Count -gt 0) {
        $y += $script:LineTitle
        $chipX = $x
        foreach ($lb in $item.labels) {
            if ($chipX -gt ($right - (S 40))) { break }
            try { $c = [System.Drawing.ColorTranslator]::FromHtml('#' + $lb.color) }
            catch { $c = $Theme.Muted }
            $text = [string]$lb.name
            $w = [int]$g.MeasureString($text, $FontChip).Width + (S 12)
            if (($chipX + $w) -gt $right) { break }
            $chipRect = New-Object System.Drawing.Rectangle([int]$chipX, [int]$y, $w, $script:ChipH)
            $chipBrush = New-Object System.Drawing.SolidBrush($c)
            $g.FillRectangle($chipBrush, $chipRect)
            $chipBrush.Dispose()
            $fgBrush = New-Object System.Drawing.SolidBrush((Get-ContrastColor $c))
            $g.DrawString($text, $FontChip, $fgBrush, [float]($chipRect.X + (S 6)), [float]($chipRect.Y + (S 2)))
            $fgBrush.Dispose()
            $chipX += $w + (S 5)
        }
    }

    $mutedBrush.Dispose()
    $fmt.Dispose()
})

# ---- list assembly

function Update-List {
    $items = Get-VisibleItems
    $previous = $List.SelectedIndex
    $List.BeginUpdate()
    $List.Items.Clear()
    foreach ($i in $items) { $List.Items.Add($i) | Out-Null }
    $List.EndUpdate()

    if ($List.Items.Count -gt 0) {
        $idx = if ($previous -ge 0 -and $previous -lt $List.Items.Count) { $previous } else { 0 }
        $List.SelectedIndex = $idx
        $List.Visible = $true
        $Empty.Visible = $false
    } else {
        $List.Visible = $false
        $Empty.Visible = $true
        $Empty.Text = if ($script:LastError) {
            # This is the only place with room for the reason; the tooltip cannot hold it.
            $why = Format-ErrorText $script:LastError
            if ($why.Length -gt 160) { $why = $why.Substring(0, 159) + [char]0x2026 }
            "Couldn't reach GitHub.`r`n$why`r`nPress R to try again, or L to sign in."
        } elseif ($script:IncludePRs) {
            'Nothing assigned to you. 🎉'
        } else {
            "No issues assigned to you. 🎉`r`nPress P to include pull requests."
        }
    }
    $Popup.Controls.SetChildIndex($List, 0)
    $Popup.Controls.SetChildIndex($Empty, 0)
    Resize-Popup
}

function Resize-Popup {
    $rows = 0
    for ($i = 0; $i -lt $List.Items.Count; $i++) {
        $rows += Get-ItemHeight $List.Items[$i]
    }
    if ($List.Items.Count -eq 0) { $rows = S 90 }
    $target = $Header.Height + $Footer.Height + $rows + (S 8)
    $max = S $script:Config.popupMaxHeight
    # popupMaxHeight scales too, so on a high-scale display it can exceed the work
    # area and push the footer (the shortcuts) behind the taskbar.
    $fit = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea.Height - (S 24)
    if ($fit -gt 0 -and $max -gt $fit) { $max = $fit }
    if ($target -gt $max) { $target = $max }
    if ($target -lt (S 160)) { $target = S 160 }
    $Popup.Height = $target
}

function Update-Ui {
    try {
    $items = Get-VisibleItems
    $count = $items.Count

    # A failed refresh does not invalidate what we already have: only fall back to
    # the error icon when there is genuinely nothing to show. Otherwise keep the
    # count and mark it stale, so a dropped network does not erase the number.
    $stale = [bool]$script:LastError
    if ($script:LastError -and $count -eq 0) {
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
    $word = if ($script:IncludePRs) { 'open' } else { Plural $count 'issue' 'issues' }
    if ($script:LastError -and $count -eq 0) {
        $tip = 'GitHub Issues Tray - refresh failed'
    } else {
        $tip = "GitHub: $count $word"
        if ($repos -gt 0) { $tip += " in $repos " + (Plural $repos 'repo' 'repos') }
        if ($stale) {
            # Has to fit in $TrayTextMax together with the count line above it, or the
            # clamp in Set-TrayTooltip eats exactly the age this line exists to show.
            $tip += if ($script:LastUpdate) {
                "`r`nStale - data from " + (Format-Age $script:LastUpdate)
            } else {
                "`r`nRefresh failed"
            }
        } elseif ($script:LastUpdate) {
            $tip += "`r`nUpdated " + (Format-Age $script:LastUpdate)
        }
    }
    Set-TrayTooltip $tip

    $label = if ($script:IncludePRs) { 'open' } else { Plural $count 'issue' 'issues' }
    $headerText = "$count $label"
    if ($repos -gt 0) { $headerText += "  ·  $repos " + (Plural $repos 'repo' 'repos') }
    if ($script:Fetching) {
        $headerText += '  ·  refreshing…'
    } elseif ($script:LastUpdate) {
        $headerText += '  ·  ' + (Format-Age $script:LastUpdate)
    }
    if ($stale) { $headerText += '  ·  could not refresh' }
    $HeaderTitle.Text = $headerText
    $HeaderTitle.ForeColor = if ($script:LastError) { $Theme.Warn } else { $Theme.Fore }

    $prState = if ($script:IncludePRs) { 'with PRs' } else { 'no PRs' }
    $FooterLabel.Text = "↑↓ navigate   Enter open   C copy   P $prState   R refresh   G github   Esc close"

    $script:MenuIncludePRs.Checked = $script:IncludePRs

    if ($Popup.Visible) { Update-List }
    } catch {
        # Update-Ui runs from timers; an exception escaping here reaches WinForms
        # as an unhandled one. Log it and keep the tray alive.
        Write-Log "error in Update-Ui: $(Format-ErrorText $_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"
    }
}

# ---- position and visibility

$script:LastHideTicks = 0

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

    Update-List
    $wa = $screen.WorkingArea
    $x = $wa.Right - $Popup.Width - (S 12)
    $y = $wa.Bottom - $Popup.Height - (S 12)
    if ($x -lt $wa.Left) { $x = $wa.Left }
    if ($y -lt $wa.Top) { $y = $wa.Top }
    $Popup.Location = New-Object System.Drawing.Point($x, $y)
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

function Toggle-PullRequests {
    $script:IncludePRs = -not $script:IncludePRs
    $List.SelectedIndex = -1
    Update-Ui
    if ($Popup.Visible) { Update-List }
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
    switch ($e.KeyCode) {
        ([System.Windows.Forms.Keys]::Escape) { Hide-Popup; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::Enter)  { Open-Selected; $e.Handled = $true; $e.SuppressKeyPress = $true }
        ([System.Windows.Forms.Keys]::C)      { Copy-Selected; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::P)      { Toggle-PullRequests; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::R)      { $script:RetryCount = 0; Start-Fetch; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::G)      { Open-AssignedPage; $e.Handled = $true }
        ([System.Windows.Forms.Keys]::L)      { Invoke-GhLogin; $e.Handled = $true }
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

$script:MenuIncludePRs = New-Object System.Windows.Forms.ToolStripMenuItem('Include pull requests')
$script:MenuIncludePRs.CheckOnClick = $false
$script:MenuIncludePRs.Add_Click({ Toggle-PullRequests })
$Menu.Items.Add($script:MenuIncludePRs) | Out-Null

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
        $items = Get-VisibleItems
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
