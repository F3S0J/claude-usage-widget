# Claude Code subscription usage - floating always-on-top widget.
# Reads the OAuth token Claude Code keeps in ~/.claude/.credentials.json (read-only,
# never refreshes it) and polls the same endpoint /usage uses.
# Drag to move, double-click to refresh, right-click for menu.
# Global hotkeys: F9 = show / hide the Claude terminal (opens one if none),
#                 Shift+F9 = new Claude tab.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CredPath  = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$StatePath = Join-Path $PSScriptRoot 'position.json'
$HwndPath  = Join-Path $PSScriptRoot 'claude-window.txt'
$CachePath = Join-Path $PSScriptRoot 'last-usage.json'
$PollSec   = 120
$ClaudeDir = $env:USERPROFILE          # folder new Claude sessions start in
$HotKeyVk  = 0x78                      # F9  (see learn.microsoft.com virtual-key codes)

# If this widget was started from inside a Claude session, don't pass that session's
# markers on to the terminals it opens (they'd run as "child" sessions with no transcript).
Get-ChildItem Env: | Where-Object { $_.Name -match '^(CLAUDE_CODE|CLAUDECODE)' } |
    ForEach-Object { Remove-Item "Env:$($_.Name)" }

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class ClaudeHotKeys : NativeWindow {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);

    public Action<int> OnHotKey;
    public ClaudeHotKeys() { CreateHandle(new CreateParams()); }
    public bool Register(int id, uint mods, uint vk) { return RegisterHotKey(Handle, id, mods | 0x4000, vk); } // 0x4000 = no auto-repeat
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && OnHotKey != null) OnHotKey(m.WParam.ToInt32());
        base.WndProc(ref m);
    }

    public static bool IsTerminal(IntPtr h) {
        if (h == IntPtr.Zero || !IsWindow(h)) return false;
        var sb = new StringBuilder(64); GetClassName(h, sb, 64);
        return sb.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS";
    }
    public static IntPtr[] Terminals() {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => { if (IsWindowVisible(h) && IsTerminal(h)) list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    public static bool IsForeground(IntPtr h) { return GetForegroundWindow() == h; }
    public static IntPtr Foreground() { return GetForegroundWindow(); }
    public static void Show(IntPtr h) { if (IsIconic(h)) ShowWindow(h, 9); SetForegroundWindow(h); }
    public static void Minimize(IntPtr h) { ShowWindow(h, 6); }
}
'@

function Get-Usage {
    $cred = (Get-Content $CredPath -Raw | ConvertFrom-Json).claudeAiOauth
    $exp  = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$cred.expiresAt)
    if ($exp -lt [DateTimeOffset]::UtcNow) { throw 'Token expired - open Claude Code once to renew it' }
    Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 15 -Headers @{
        Authorization    = "Bearer $($cred.accessToken)"
        'anthropic-beta' = 'oauth-2025-04-20'
    }
}

function Format-Reset($iso) {
    if (-not $iso) { return '' }
    $t   = [DateTimeOffset]::Parse($iso).LocalDateTime.AddSeconds(30)
    $t   = $t.AddSeconds(-$t.Second).AddMilliseconds(-$t.Millisecond)
    $d   = $t - (Get-Date)
    $in  = if ($d.TotalMinutes -lt 1) { 'now' }
           elseif ($d.TotalHours -lt 1) { '{0}m' -f [int][math]::Floor($d.TotalMinutes) }
           elseif ($d.TotalDays -lt 1)  { '{0}h {1}m' -f [int][math]::Floor($d.TotalHours), $d.Minutes }
           else { '{0}d {1}h' -f [int][math]::Floor($d.TotalDays), $d.Hours }
    $at  = if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') } else { $t.ToString('ddd d MMM HH:mm', [Globalization.CultureInfo]'en-GB') }
    "resets $at  ($in)"
}

function Get-Label($l) {
    switch ($l.kind) {
        'session'    { 'Session (5h)' }
        'weekly_all' { 'Week - all models' }
        default {
            $n = $l.scope.model.display_name
            if ($n) { "Week - $n" } else { $l.kind }
        }
    }
}

function New-Brush($hex) { [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
function Get-BarColor($p) { if ($p -ge 85) { '#E5484D' } elseif ($p -ge 60) { '#F5A524' } else { '#D97757' } }

# ---------- window ----------
$win = New-Object Windows.Window -Property @{
    WindowStyle = 'None'; AllowsTransparency = $true; Background = 'Transparent'
    Topmost = $true; ShowInTaskbar = $false; ResizeMode = 'NoResize'
    SizeToContent = 'Height'; Width = 250; Title = 'Claude usage'
}
$border = New-Object Windows.Controls.Border -Property @{
    CornerRadius = 10; Padding = '12,9,12,10'; Background = (New-Brush '#E61F1E1D')
    BorderBrush = (New-Brush '#44FFFFFF'); BorderThickness = 1
}
$root = New-Object Windows.Controls.StackPanel
$border.Child = $root
$win.Content = $border

$header = New-Object Windows.Controls.DockPanel -Property @{ Margin = '0,0,0,4' }
$title  = New-Object Windows.Controls.TextBlock -Property @{ Text = 'Claude usage'; Foreground = (New-Brush '#D97757'); FontWeight = 'SemiBold'; FontSize = 12 }
$stamp  = New-Object Windows.Controls.TextBlock -Property @{ Foreground = (New-Brush '#88FFFFFF'); FontSize = 10; HorizontalAlignment = 'Right'; VerticalAlignment = 'Center' }
[Windows.Controls.DockPanel]::SetDock($title, 'Left')
[void]$header.Children.Add($title); [void]$header.Children.Add($stamp)
[void]$root.Children.Add($header)
$rows = New-Object Windows.Controls.StackPanel
[void]$root.Children.Add($rows)

function Add-Row($label, $pct, $sub) {
    $p = [math]::Max(0, [math]::Min(100, [double]$pct))
    $top = New-Object Windows.Controls.DockPanel -Property @{ Margin = '0,6,0,2' }
    $pt  = New-Object Windows.Controls.TextBlock -Property @{ Text = ('{0:0}%' -f $p); Foreground = (New-Brush '#FFFFFF'); FontWeight = 'SemiBold'; FontSize = 12 }
    [Windows.Controls.DockPanel]::SetDock($pt, 'Right')
    [void]$top.Children.Add($pt)
    [void]$top.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $label; Foreground = (New-Brush '#DDFFFFFF'); FontSize = 12 }))
    $bar = New-Object Windows.Controls.ProgressBar -Property @{
        Value = $p; Maximum = 100; Height = 6; BorderThickness = 0
        Background = (New-Brush '#33FFFFFF'); Foreground = (New-Brush (Get-BarColor $p))
    }
    [void]$rows.Children.Add($top)
    [void]$rows.Children.Add($bar)
    if ($sub) {
        [void]$rows.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $sub; Foreground = (New-Brush '#88FFFFFF'); FontSize = 10; Margin = '0,2,0,0' }))
    }
}

function Show-Usage($u) {
    $rows.Children.Clear()
    $limits = @($u.limits)
    if ($limits.Count -eq 0) {
        # fallback to the older field layout
        $limits = @(
            [pscustomobject]@{ kind = 'session';    percent = $u.five_hour.utilization; resets_at = $u.five_hour.resets_at }
            [pscustomobject]@{ kind = 'weekly_all'; percent = $u.seven_day.utilization; resets_at = $u.seven_day.resets_at }
        )
    }
    foreach ($l in $limits) { Add-Row (Get-Label $l) $l.percent (Format-Reset $l.resets_at) }
    if ($u.extra_usage.is_enabled -and $u.spend.used) {
        $amt = $u.spend.used.amount_minor / [math]::Pow(10, $u.spend.used.exponent)
        Add-Row 'Usage credits' $u.spend.percent ('{0:0.00} {1} used' -f $amt, $u.spend.used.currency)
    }
}

# Last good answer, saved so a restart or a rate-limit still shows numbers (with their age).
function Show-Cached {
    if (-not (Test-Path $CachePath)) { return $null }
    try {
        $c = Get-Content $CachePath -Raw | ConvertFrom-Json
        Show-Usage $c.data
        return ([datetime]$c.fetched).ToString('HH:mm')
    } catch { return $null }
}

function Update-View {
    try {
        $u = Get-Usage
        Show-Usage $u
        try { @{ fetched = (Get-Date).ToString('o'); data = $u } | ConvertTo-Json -Depth 10 | Set-Content $CachePath } catch {}
        $stamp.Text = (Get-Date).ToString('HH:mm')
        $stamp.Foreground = New-Brush '#88FFFFFF'
        $stamp.ToolTip = $null
        $timer.Interval = [TimeSpan]::FromSeconds($PollSec)            # back to normal after a back-off
    } catch {
        $msg = $_.Exception.Message
        $resp = $_.Exception.Response
        $asOf = Show-Cached
        $age = if ($asOf) { " (numbers from $asOf)" } else { '' }
        if ($resp -and [int]$resp.StatusCode -eq 429) {
            # Rate-limited: show the saved numbers, wait longer (Retry-After if given, else double, max 15 min)
            $wait = 0; try { $wait = [int]$resp.Headers['Retry-After'] } catch {}
            if ($wait -le 0) { $wait = [math]::Min(900, [int]$timer.Interval.TotalSeconds * 2) }
            $timer.Interval = [TimeSpan]::FromSeconds([math]::Max($PollSec, $wait))
            $stamp.Text = if ($asOf) { "$asOf · limited" } else { 'rate-limited' }
            $stamp.Foreground = New-Brush '#F5A524'
            $stamp.ToolTip = "Usage server says too many requests$age - next try at $((Get-Date).Add($timer.Interval).ToString('HH:mm'))"
            return
        }
        $stamp.Text = if ($asOf) { "$asOf · offline" } else { 'offline' }
        $stamp.Foreground = New-Brush '#E5484D'
        $stamp.ToolTip = "$msg$age"
        if ($rows.Children.Count -eq 0) {
            [void]$rows.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $msg; Foreground = (New-Brush '#E5484D'); FontSize = 11; TextWrapping = 'Wrap' }))
        }
    }
}
# ---------- interaction ----------
$win.Add_MouseLeftButtonDown({
    if ($_.ClickCount -eq 2) { Update-View } else {
        try { $win.DragMove() } catch {}
        @{ Left = $win.Left; Top = $win.Top } | ConvertTo-Json | Set-Content $StatePath
    }
})

$menu = New-Object Windows.Controls.ContextMenu
foreach ($item in @(
    @{ H = 'Refresh now'; A = { Update-View } },
    @{ H = 'Exit';        A = { $win.Close() } }
)) {
    $mi = New-Object Windows.Controls.MenuItem -Property @{ Header = $item.H }
    $mi.Add_Click($item.A)
    [void]$menu.Items.Add($mi)
}
$win.ContextMenu = $menu

# position: restore last spot, else top-right of the work area
$wa = [Windows.SystemParameters]::WorkArea
$win.Left = $wa.Right - 270; $win.Top = $wa.Top + 20
if (Test-Path $StatePath) {
    try {
        $pos = Get-Content $StatePath -Raw | ConvertFrom-Json
        if ($pos.Left -ge [Windows.SystemParameters]::VirtualScreenLeft -and $pos.Left -lt ([Windows.SystemParameters]::VirtualScreenLeft + [Windows.SystemParameters]::VirtualScreenWidth - 50)) {
            $win.Left = $pos.Left; $win.Top = $pos.Top
        }
    } catch {}
}
$win.Add_Closing({ @{ Left = $win.Left; Top = $win.Top } | ConvertTo-Json | Set-Content $StatePath })

$timer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds($PollSec) }
$timer.Add_Tick({ Update-View })
$timer.Start()

# ---------- Claude terminal hotkeys ----------
$script:ClaudeHwnd = [IntPtr]::Zero
if (Test-Path $HwndPath) {
    try {
        $h = [IntPtr][int64](Get-Content $HwndPath -Raw)
        if ([ClaudeHotKeys]::IsTerminal($h)) { $script:ClaudeHwnd = $h }
    } catch {}
}

function Open-ClaudeTab {
    # "-w claude" = one named Terminal window; reused if it is still open.
    $script:Before = [ClaudeHotKeys]::Terminals()
    Start-Process wt.exe -ArgumentList @('-w', 'claude', 'new-tab', '-d', "`"$ClaudeDir`"", 'claude')
    # find the Terminal window that got the tab (new window, or the one brought to front)
    $script:FindTries = 0
    $find = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(250) }
    $find.Add_Tick({
        $script:FindTries++
        $new = [ClaudeHotKeys]::Terminals() | Where-Object { $script:Before -notcontains $_ } | Select-Object -First 1
        if (-not $new -and $script:FindTries -ge 4) {
            $fg = [ClaudeHotKeys]::Foreground()
            if ([ClaudeHotKeys]::IsTerminal($fg)) { $new = $fg }
        }
        if ($new) {
            $script:ClaudeHwnd = $new
            Set-Content $HwndPath ([int64]$new)
        }
        if ($new -or $script:FindTries -ge 24) { $this.Stop() }
    })
    $find.Start()
}

$hotkeys = New-Object ClaudeHotKeys
$hotkeys.OnHotKey = [Action[int]]{
    param($id)
    if ($id -eq 2) { Open-ClaudeTab; return }                       # Shift+F9
    $h = $script:ClaudeHwnd
    if (-not [ClaudeHotKeys]::IsTerminal($h)) { Open-ClaudeTab; return }
    if ([ClaudeHotKeys]::IsForeground($h)) { [ClaudeHotKeys]::Minimize($h) }
    else { [ClaudeHotKeys]::Show($h) }
}
$hkOk = $hotkeys.Register(1, 0, $HotKeyVk) -and $hotkeys.Register(2, 0x4, $HotKeyVk)
if (-not $hkOk) { $title.ToolTip = 'F9 hotkey is taken by another app' }

Update-View
[void]$win.ShowDialog()
