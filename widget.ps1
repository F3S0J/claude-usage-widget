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
$DayPath   = Join-Path $PSScriptRoot 'day-start.json'
$SetPath   = Join-Path $PSScriptRoot 'settings.json'
$LogRoot   = Join-Path $env:USERPROFILE '.claude\projects'   # Claude Code transcripts (token counts)
$PollSec   = 120
$BaseWidth = 250

# Look: right-click menu (theme, transparency, size) or Ctrl + mouse wheel to resize.
$Themes = [ordered]@{
    'Dark'     = @{ Bg = '1F1E1D'; Border = '#44FFFFFF'; Accent = '#D97757'; Text = '#FFFFFF'; Label = '#DDFFFFFF'; Sub = '#88FFFFFF'; Track = '#33FFFFFF'; Tick = '#FFFFFF'; Good = '#7BD88F' }
    'Light'    = @{ Bg = 'FAF9F5'; Border = '#33000000'; Accent = '#C15F3C'; Text = '#1F1E1D'; Label = '#DD1F1E1D'; Sub = '#991F1E1D'; Track = '#22000000'; Tick = '#1F1E1D'; Good = '#2E8B57' }
    'Midnight' = @{ Bg = '0F172A'; Border = '#44A5B4FC'; Accent = '#7AA2F7'; Text = '#E6EDF7'; Label = '#DDE6EDF7'; Sub = '#88E6EDF7'; Track = '#33FFFFFF'; Tick = '#FFFFFF'; Good = '#7BD88F' }
    'Terminal' = @{ Bg = '000000'; Border = '#5533FF66'; Accent = '#33FF66'; Text = '#D7FFD9'; Label = '#DDD7FFD9'; Sub = '#8833FF66'; Track = '#3333FF66'; Tick = '#FFFFFF'; Good = '#33FF66' }
}
$script:S = @{ Theme = 'Dark'; Opacity = 90; Scale = 1.0 }
# what the widget shows (Preferences window) - everything on until switched off
$ShowKeys = 'Budget', 'Forecast', 'Tokens', 'Cost', 'Burn', 'PerPct', 'Models', 'Agents', 'Sessions', 'Week'
foreach ($k in $ShowKeys) { $script:S[$k] = $true }
$script:SessHist = @()
$script:WeekPct  = 0
if (Test-Path $SetPath) {
    try {
        $saved = Get-Content $SetPath -Raw | ConvertFrom-Json
        if ($Themes.Contains([string]$saved.Theme)) { $script:S.Theme = [string]$saved.Theme }
        if ($saved.Opacity) { $script:S.Opacity = [math]::Max(20, [math]::Min(100, [int]$saved.Opacity)) }
        if ($saved.Scale)   { $script:S.Scale   = [math]::Max(0.7, [math]::Min(2.5, [double]$saved.Scale)) }
        foreach ($k in $ShowKeys) { if ($null -ne $saved.$k) { $script:S[$k] = [bool]$saved.$k } }
    } catch {}
}
$script:T = $Themes[$script:S.Theme]
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

# Token statistics from the local Claude Code transcripts (see TokenScan.cs).
Add-Type -Path (Join-Path $PSScriptRoot 'TokenScan.cs')

function Format-Tok($n) {
    $n = [double]$n
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($n -ge 1e9) { return ($n / 1e9).ToString('0.00', $inv) + 'B' }
    if ($n -ge 1e6) { return ($n / 1e6).ToString('0.0', $inv) + 'M' }
    if ($n -ge 1e3) { return ($n / 1e3).ToString('0', $inv) + 'k' }
    return ([int64]$n).ToString()
}

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

# Today's slice of a weekly limit: what was still free at the first poll of the day,
# spread evenly over the time left until the reset. Returns the bar position to reach
# by midnight (Target) and how much of today's slice is still unspent (Left).
function Get-TodayBudget($key, $pct, $resetIso) {
    if (-not $resetIso) { return $null }
    $now      = Get-Date
    $reset    = [DateTimeOffset]::Parse($resetIso).LocalDateTime.AddSeconds(30)
    $resetKey = $reset.ToString('yyyy-MM-dd HH:mm')
    $today    = $now.ToString('yyyy-MM-dd')
    $all = @{}
    if (Test-Path $DayPath) {
        try { (Get-Content $DayPath -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $all[$_.Name] = $_.Value } } catch {}
    }
    $s = $all[$key]
    # Baseline = where the bar stood when the day began: the last value seen yesterday,
    # or 0 if the weekly window has reset since. Only a first-ever run has to guess (current value).
    $base = $null
    if (-not $s) { $base = [double]$pct }
    elseif ($s.reset -ne $resetKey) { $base = 0 }
    elseif ($s.day -ne $today) { $base = if ($null -ne $s.last) { [math]::Min([double]$s.last, [double]$pct) } else { [double]$pct } }
    elseif ([double]$pct -lt [double]$s.percent) { $base = [double]$pct }
    if ($null -ne $base -or [double]$s.last -ne [double]$pct) {
        if ($null -eq $base) { $base = [double]$s.percent }
        $s = [pscustomobject]@{ day = $today; reset = $resetKey; percent = $base; last = [double]$pct }
        $all[$key] = $s
        try { $all | ConvertTo-Json | Set-Content $DayPath } catch {}
    }
    # count the whole day (from midnight, or from the start of the weekly window), not from the first poll
    $from = $now.Date
    $weekStart = $reset.AddDays(-7); if ($weekStart -gt $from) { $from = $weekStart }
    $end  = $now.Date.AddDays(1); if ($reset -lt $end) { $end = $reset }
    $span = ($reset - $from).TotalHours
    if ($span -le 0 -or $end -le $from) { return $null }
    $share = (100 - [double]$s.percent) * ($end - $from).TotalHours / $span
    [pscustomobject]@{ Share = $share; Target = [double]$s.percent + $share; Left = [double]$s.percent + $share - [double]$pct }
}

function New-Brush($hex) { [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
function Get-BarColor($p) { if ($p -ge 85) { '#E5484D' } elseif ($p -ge 60) { '#F5A524' } else { $script:T.Accent } }

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
$tokPanel = New-Object Windows.Controls.StackPanel
[void]$root.Children.Add($tokPanel)

function Add-StatHead($left, $right) {
    $top = New-Object Windows.Controls.DockPanel -Property @{ Margin = '0,8,0,0' }
    if ($right) {
        $r = New-Object Windows.Controls.TextBlock -Property @{ Text = $right; Foreground = (New-Brush $script:T.Text); FontWeight = 'SemiBold'; FontSize = 12 }
        [Windows.Controls.DockPanel]::SetDock($r, 'Right')
        [void]$top.Children.Add($r)
    }
    [void]$top.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $left; Foreground = (New-Brush $script:T.Label); FontSize = 12 }))
    [void]$tokPanel.Children.Add($top)
}
function Add-StatLine($text) {
    [void]$tokPanel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $text; Foreground = (New-Brush $script:T.Sub); FontSize = 10; Margin = '0,1,0,0'; TextWrapping = 'Wrap' }))
}
function Add-StatPair($left, $right) {
    $row = New-Object Windows.Controls.DockPanel -Property @{ Margin = '0,1,0,0' }
    $r = New-Object Windows.Controls.TextBlock -Property @{ Text = $right; Foreground = (New-Brush $script:T.Label); FontSize = 10; Margin = '8,0,0,0' }
    [Windows.Controls.DockPanel]::SetDock($r, 'Right')
    [void]$row.Children.Add($r)
    [void]$row.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $left; Foreground = (New-Brush $script:T.Sub); FontSize = 10; TextTrimming = 'CharacterEllipsis'; ToolTip = $left }))
    [void]$tokPanel.Children.Add($row)
}
function Format-Usd($n) {
    $fmt = if ([double]$n -ge 100) { '0' } else { '0.00' }
    '$' + ([double]$n).ToString($fmt, [Globalization.CultureInfo]::InvariantCulture)
}

# Everything below the limit bars: token statistics from the local transcripts.
# Each block can be switched off in Preferences.
function Update-Stats {
    $tokPanel.Children.Clear()
    $s = $script:S
    if (-not ($s.Tokens -or $s.Cost -or $s.Burn -or $s.PerPct -or $s.Models -or $s.Agents -or $s.Sessions -or $s.Week)) { return }
    [TokenScan]::Start($LogRoot)
    $n = [TokenScan]::Snap
    if (-not $n) { Add-StatLine 'reading transcripts ...'; return }
    $dot = " $([char]0xB7) "

    if ($s.Tokens) {
        Add-StatHead 'Tokens today' (Format-Tok ($n.In + $n.Out))
        Add-StatLine ('in ' + (Format-Tok $n.In) + $dot + 'out ' + (Format-Tok $n.Out) + $dot + $n.Messages + ' replies')
        Add-StatLine ('cache: read ' + (Format-Tok $n.CacheRead) + $dot + 'written ' + (Format-Tok $n.CacheWrite))
    }
    if ($s.Cost) {
        Add-StatHead 'API value today' (Format-Usd $n.Cost)
        Add-StatLine ('at API prices' + $dot + 'since weekly reset ' + (Format-Usd $n.WeekCost))
    }
    if ($s.Burn) {
        Add-StatHead 'Burn rate (last hour)' ((Format-Tok $n.HourTokens) + '/h')
        Add-StatLine ((Format-Usd $n.HourCost) + ' per hour at API prices')
    }
    if ($s.PerPct -and $script:WeekPct -ge 1 -and $n.WeekTokens -gt 0) {
        Add-StatHead '1% of the week' (Format-Tok ($n.WeekTokens / $script:WeekPct))
        Add-StatLine ('about ' + (Format-Usd ($n.WeekCost / $script:WeekPct)) + $dot + 'whole week about ' + (Format-Usd ($n.WeekCost / $script:WeekPct * 100)))
    }
    if ($s.Models -and $n.Models.Count) {
        Add-StatHead 'By model today' ''
        foreach ($m in $n.Models) { Add-StatPair ($m.Name -replace '^claude-', '') ((Format-Tok $m.Tokens) + $dot + (Format-Usd $m.Cost)) }
    }
    if ($s.Agents -and $n.Cost -gt 0) {
        Add-StatHead 'Subagent share today' ('{0:0}%' -f (100 * $n.SubCost / $n.Cost))
        Add-StatLine ('subagents ' + (Format-Usd $n.SubCost) + $dot + 'main sessions ' + (Format-Usd $n.MainCost))
    }
    if ($s.Sessions -and $n.Sessions.Count) {
        Add-StatHead 'Top sessions today' ''
        foreach ($m in ($n.Sessions | Select-Object -First 3)) { Add-StatPair $m.Name (Format-Usd $m.Cost) }
    }
    if ($s.Week -and $n.Days.Count) {
        $sum = 0; $max = 0
        foreach ($d in $n.Days) { $sum += $d.Cost; if ($d.Cost -gt $max) { $max = $d.Cost } }
        Add-StatHead 'Last 7 days' (Format-Usd $sum)
        $grid = New-Object Windows.Controls.Grid -Property @{ Margin = '0,4,0,0' }
        for ($i = 0; $i -lt $n.Days.Count; $i++) {
            $d = $n.Days[$i]
            [void]$grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
            $h = if ($max -gt 0) { [math]::Max(1, 30 * $d.Cost / $max) } else { 1 }
            $col = if ($i -eq $n.Days.Count - 1) { $script:T.Accent } else { $script:T.Sub }
            $cell = New-Object Windows.Controls.StackPanel -Property @{ VerticalAlignment = 'Bottom'; Background = 'Transparent'
                ToolTip = ($d.Name + ': ' + (Format-Tok $d.Tokens) + ' tokens' + $dot + (Format-Usd $d.Cost)) }
            [void]$cell.Children.Add((New-Object Windows.Controls.Border -Property @{ Height = $h; Margin = '2,0,2,0'; CornerRadius = 1; Background = (New-Brush $col) }))
            [void]$cell.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $d.Name.Substring(0, 2); Foreground = (New-Brush $script:T.Sub); FontSize = 9; HorizontalAlignment = 'Center' }))
            [Windows.Controls.Grid]::SetColumn($cell, $i)
            [void]$grid.Children.Add($cell)
        }
        [void]$tokPanel.Children.Add($grid)
    }
}

# Pace notes under the limit rows (Preferences > Pace forecasts).
function Get-Forecast($l) {
    if (-not $l.resets_at -or [double]$l.percent -le 0) { return $null }
    $now = Get-Date
    $reset = [DateTimeOffset]::Parse($l.resets_at).LocalDateTime
    $pct = [double]$l.percent
    if ($l.kind -eq 'session') {
        # from the readings this widget took in the last 45 minutes
        $key = ([string]$l.resets_at).Substring(0, 16)
        $h = @($script:SessHist | Where-Object { $_.Key -eq $key -and $_.T -gt $now.AddMinutes(-45) })
        if ($h.Count -lt 2) { return $null }
        $dt = ($now - $h[0].T).TotalHours
        if ($dt -lt 0.08) { return $null }
        $rate = ($pct - $h[0].P) / $dt
        if ($rate -le 0) { return $null }
        $eta = $now.AddHours((100 - $pct) / $rate)
        if ($eta -lt $reset) { return @{ Text = ('at this pace full at {0:HH:mm}, {1:0} min before the reset' -f $eta, ($reset - $eta).TotalMinutes); Color = '#F5A524' } }
        return @{ Text = ('at this pace about {0:0}% used at the reset' -f ($pct + $rate * ($reset - $now).TotalHours)); Color = $script:T.Sub }
    }
    $start = $reset.AddDays(-7)
    $el = ($now - $start).TotalHours
    if ($el -lt 6) { return $null }
    $proj = $pct * 168 / $el
    if ($proj -gt 100) {
        $eta = $start.AddHours($el * 100 / $pct)
        return @{ Text = ('on pace to run out ' + $eta.ToString('ddd HH:mm', [Globalization.CultureInfo]'en-GB')); Color = '#F5A524' }
    }
    @{ Text = ('on pace for {0:0}% by the reset' -f $proj); Color = $script:T.Sub }
}

$PrefItems = [ordered]@{
    Budget   = 'Daily budget on the weekly rows'
    Forecast = 'Pace forecasts (session and week)'
    Tokens   = 'Tokens today'
    Cost     = 'API value in $'
    Burn     = 'Burn rate (last hour)'
    PerPct   = 'Tokens per 1% of the week'
    Models   = 'Split by model'
    Agents   = 'Subagent share'
    Sessions = 'Top sessions today'
    Week     = 'Last 7 days chart'
}
function Show-Preferences {
    if ($script:PrefWin) { $script:PrefWin.Activate(); return }
    $w = New-Object Windows.Window -Property @{
        Title = 'Claude usage - preferences'; SizeToContent = 'WidthAndHeight'; ResizeMode = 'NoResize'
        Topmost = $true; WindowStartupLocation = 'CenterScreen'; ShowInTaskbar = $false
    }
    $p = New-Object Windows.Controls.StackPanel -Property @{ Margin = '16,12,24,14' }
    [void]$p.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = 'Show in the widget'; FontWeight = 'SemiBold'; Margin = '0,0,0,6' }))
    foreach ($k in $PrefItems.Keys) {
        $cb = New-Object Windows.Controls.CheckBox -Property @{ Content = $PrefItems[$k]; Tag = $k; IsChecked = [bool]$script:S[$k]; Margin = '0,3,0,3' }
        $cb.Add_Click({ $script:S[[string]$this.Tag] = [bool]$this.IsChecked; Save-Settings; Apply-Look })
        [void]$p.Children.Add($cb)
    }
    [void]$p.Children.Add((New-Object Windows.Controls.TextBlock -Property @{
        Text = 'Token figures come from the Claude Code transcripts on this PC. Dollar figures are what the same usage would cost at API list prices.'
        Foreground = 'Gray'; FontSize = 11; TextWrapping = 'Wrap'; MaxWidth = 260; Margin = '0,8,0,0' }))
    $w.Content = $p
    $w.Add_Closed({ $script:PrefWin = $null })
    $script:PrefWin = $w
    $w.Show()
}

function Save-Settings { try { $script:S | ConvertTo-Json | Set-Content $SetPath } catch {} }

# Applies theme, transparency and size, then redraws the rows in the new colours.
function Apply-Look {
    $script:T = $Themes[$script:S.Theme]
    $alpha = [int][math]::Round(255 * $script:S.Opacity / 100)
    $border.Background  = New-Brush ('#{0:X2}{1}' -f $alpha, $script:T.Bg)
    $border.BorderBrush = New-Brush $script:T.Border
    $title.Foreground   = New-Brush $script:T.Accent
    if ($stamp.Foreground.Color.ToString() -notin '#FFF5A524', '#FFE5484D') { $stamp.Foreground = New-Brush $script:T.Sub }
    $border.LayoutTransform = New-Object Windows.Media.ScaleTransform($script:S.Scale, $script:S.Scale)
    $win.Width = $BaseWidth * $script:S.Scale
    if ($script:LastUsage) { Show-Usage $script:LastUsage }
    Update-Stats
    foreach ($c in $script:Checks) { $c.Item.IsChecked = ("$($script:S[$c.Key])" -eq "$($c.Value)") }
}

function Add-Row($label, $pct, $sub, $today, $note) {
    $p = [math]::Max(0, [math]::Min(100, [double]$pct))
    $top = New-Object Windows.Controls.DockPanel -Property @{ Margin = '0,6,0,2' }
    $pt  = New-Object Windows.Controls.TextBlock -Property @{ Text = ('{0:0}%' -f $p); Foreground = (New-Brush $script:T.Text); FontWeight = 'SemiBold'; FontSize = 12 }
    [Windows.Controls.DockPanel]::SetDock($pt, 'Right')
    [void]$top.Children.Add($pt)
    [void]$top.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $label; Foreground = (New-Brush $script:T.Label); FontSize = 12 }))
    $bar = New-Object Windows.Controls.ProgressBar -Property @{
        Value = $p; Maximum = 100; Height = 6; BorderThickness = 0
        Background = (New-Brush $script:T.Track); Foreground = (New-Brush (Get-BarColor $p))
    }
    [void]$rows.Children.Add($top)
    if ($today) {
        # white tick on the bar = where the bar should be by midnight
        $t = [math]::Max(0.5, [math]::Min(100, $today.Target))
        $grid = New-Object Windows.Controls.Grid
        [void]$grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = (New-Object Windows.GridLength($t, 'Star')) }))
        [void]$grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = (New-Object Windows.GridLength((100 - $t), 'Star')) }))
        [Windows.Controls.Grid]::SetColumnSpan($bar, 2)
        $tick = New-Object Windows.Controls.Border -Property @{ Width = 2; Background = (New-Brush $script:T.Tick); HorizontalAlignment = 'Right' }
        [void]$grid.Children.Add($bar); [void]$grid.Children.Add($tick)
        [void]$rows.Children.Add($grid)
    } else {
        [void]$rows.Children.Add($bar)
    }
    if ($sub) {
        [void]$rows.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $sub; Foreground = (New-Brush $script:T.Sub); FontSize = 10; Margin = '0,2,0,0' }))
    }
    if ($today) {
        $over = $today.Left -lt -0.5
        $txt  = if ($over) { 'today: {0:0}% over the {1:0}% daily budget' -f (-$today.Left), $today.Share }
                else       { 'today: {0:0}% left of {1:0}% daily budget' -f [math]::Max(0, $today.Left), $today.Share }
        $col  = if ($over) { '#F5A524' } else { $script:T.Good }
        [void]$rows.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $txt; Foreground = (New-Brush $col); FontSize = 10; Margin = '0,1,0,0' }))
    }
    if ($note) {
        [void]$rows.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $note.Text; Foreground = (New-Brush $note.Color); FontSize = 10; Margin = '0,1,0,0' }))
    }
}

function Show-Usage($u) {
    $script:LastUsage = $u
    $rows.Children.Clear()
    $limits = @($u.limits)
    if ($limits.Count -eq 0) {
        # fallback to the older field layout
        $limits = @(
            [pscustomobject]@{ kind = 'session';    percent = $u.five_hour.utilization; resets_at = $u.five_hour.resets_at }
            [pscustomobject]@{ kind = 'weekly_all'; percent = $u.seven_day.utilization; resets_at = $u.seven_day.resets_at }
        )
    }
    foreach ($l in $limits) {
        $label = Get-Label $l
        # the baseline is kept up to date even while the budget line is switched off
        $today = if ($l.kind -like 'weekly*') { Get-TodayBudget $label $l.percent $l.resets_at } else { $null }
        if (-not $script:S.Budget) { $today = $null }
        $note = if ($script:S.Forecast) { Get-Forecast $l } else { $null }
        if ($l.kind -eq 'weekly_all' -and $l.resets_at) {
            $script:WeekPct = [double]$l.percent
            [TokenScan]::WeekStart = [DateTimeOffset]::Parse($l.resets_at).LocalDateTime.AddDays(-7)
        }
        Add-Row $label $l.percent (Format-Reset $l.resets_at) $today $note
    }
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
        # session readings for the pace forecast
        $sess = @($u.limits) | Where-Object { $_.kind -eq 'session' -and $_.resets_at } | Select-Object -First 1
        if ($sess) {
            $script:SessHist = @($script:SessHist) + @{ T = (Get-Date); P = [double]$sess.percent; Key = ([string]$sess.resets_at).Substring(0, 16) } | Select-Object -Last 60
        }
        Show-Usage $u
        try { @{ fetched = (Get-Date).ToString('o'); data = $u } | ConvertTo-Json -Depth 10 | Set-Content $CachePath } catch {}
        $stamp.Text = (Get-Date).ToString('HH:mm')
        $stamp.Foreground = New-Brush $script:T.Sub
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
$script:Checks = @()
# submenus: each entry stores "setting=value" in its Tag, the click handler reads it back
function Add-Choice($header, $key, $choices) {
    $sub = New-Object Windows.Controls.MenuItem -Property @{ Header = $header }
    foreach ($c in $choices) {
        $mi = New-Object Windows.Controls.MenuItem -Property @{ Header = $c.H; Tag = "$key=$($c.V)" }
        $mi.Add_Click({
            $k, $v = ([string]$this.Tag).Split('=')
            $script:S[$k] = switch ($k) { 'Theme' { $v } 'Opacity' { [int]$v } 'Scale' { [double]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) } }
            Save-Settings; Apply-Look
        })
        [void]$sub.Items.Add($mi)
        $script:Checks += @{ Item = $mi; Key = $key; Value = $c.V }
    }
    [void]$menu.Items.Add($sub)
}
$mi = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Refresh now' }
$mi.Add_Click({ Update-View })
[void]$menu.Items.Add($mi)
Add-Choice 'Theme' 'Theme' @($Themes.Keys | ForEach-Object { @{ H = $_; V = $_ } })
Add-Choice 'Transparency' 'Opacity' @(100, 90, 75, 60, 45, 30 | ForEach-Object { @{ H = "$_% solid"; V = $_ } })
Add-Choice 'Size' 'Scale' @(@{ H = 'Small'; V = '0.8' }, @{ H = 'Normal'; V = '1' }, @{ H = 'Large'; V = '1.25' }, @{ H = 'Extra large'; V = '1.5' }, @{ H = 'Huge'; V = '2' })
$mi = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Preferences...' }
$mi.Add_Click({ Show-Preferences })
[void]$menu.Items.Add($mi)
$mi = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Exit' }
$mi.Add_Click({ $win.Close() })
[void]$menu.Items.Add($mi)
$win.ContextMenu = $menu

# Ctrl + mouse wheel = resize in 10 % steps
$win.Add_MouseWheel({
    if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) {
        $step = if ($_.Delta -gt 0) { 0.1 } else { -0.1 }
        $script:S.Scale = [math]::Round([math]::Max(0.7, [math]::Min(2.5, $script:S.Scale + $step)), 2)
        Save-Settings; Apply-Look
    }
})

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
$tokTimer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(15) }
$tokTimer.Add_Tick({ Update-Stats })
$tokTimer.Start()

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

Apply-Look
Update-View
[void]$win.ShowDialog()
