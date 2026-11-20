# Heatwatch - one tray app, four desktop widgets:
#   Thermal (GPU temp + graph + plain-language status, CPU, speed, Docker, memory, battery, disk, busiest app)
#   Internet (down/up speed + graph, connection, today's totals, response time)
#   Docker containers (running containers with stop buttons)
#   System health (uptime, unexpected shutdowns with the last readings before each)
# Layout (which widgets are on, positions, lock) is saved to %APPDATA%\Heatwatch\settings.json
# Readings are logged every 10 s to %APPDATA%\Heatwatch\readings.csv for crash forensics.
# Launch: powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File Heatwatch.ps1
#
# NOTE: PowerShell variable names are case-insensitive. Never name a local or handler parameter
# $s, $w, $p, $dot, $up, $down, $deg (they would hide $S settings, $W widgets, $P palette, $DOT, $UP, $DOWN, $DEG).

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# ---------- single instance ----------
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\Heatwatch', [ref]$created)
if (-not $created) { exit }

# ---------- constants ----------
$WarnTemp = 75; $HotTemp = 85
$CpuWarn = 70;  $CpuHot = 90
$BarMin = 40;   $BarMax = 95
$DockerCapGB = 8; $DockerCpus = 4      # match .wslconfig
$HistoryLen = 60                       # 60 x 2 s = 2 minutes
$TileBarW = 68
$Inv = [Globalization.CultureInfo]::InvariantCulture
$DEG = [char]0x00B0; $DOT = [char]0x00B7; $UP = [char]0x2191; $DOWN = [char]0x2193

$AppDir = Join-Path $env:APPDATA 'Heatwatch'
if (-not (Test-Path $AppDir)) {
    New-Item -ItemType Directory -Path $AppDir | Out-Null
    # migrate layout + readings from the pre-rename 'ThermalWidgets' folder
    $old = Join-Path $env:APPDATA 'ThermalWidgets'
    if (Test-Path $old) { Copy-Item (Join-Path $old '*') $AppDir -Force -ErrorAction SilentlyContinue }
}
$SettingsPath = Join-Path $AppDir 'settings.json'
$ReadingsPath = Join-Path $AppDir 'readings.csv'
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Heatwatch.lnk'
$ScriptPath   = $MyInvocation.MyCommand.Path
$DockerExe    = (Get-Command docker -ErrorAction SilentlyContinue).Source
$DockerDesktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'

$smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
if (-not $smi) { $smi = "$env:SystemRoot\System32\nvidia-smi.exe" }

# ---------- settings ----------
$WidgetKeys = @('thermal', 'network', 'containers', 'health')
function Load-Settings {
    $d = @{ lock = $false; widgets = @{}; net = @{ day = (Get-Date -Format 'yyyy-MM-dd'); rx = 0.0; tx = 0.0 } }
    foreach ($k in $WidgetKeys) { $d.widgets[$k] = @{ on = $true; x = $null; y = $null } }
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            if ($null -ne $j.lock) { $d.lock = [bool]$j.lock }
            foreach ($k in $WidgetKeys) {
                $wj = $j.widgets.$k
                if ($wj) {
                    if ($null -ne $wj.on) { $d.widgets[$k].on = [bool]$wj.on }
                    if ($null -ne $wj.x)  { $d.widgets[$k].x = [double]$wj.x }
                    if ($null -ne $wj.y)  { $d.widgets[$k].y = [double]$wj.y }
                }
            }
            if ($j.net -and $j.net.day -eq $d.net.day) { $d.net.rx = [double]$j.net.rx; $d.net.tx = [double]$j.net.tx }
        } catch {}
    }
    $d
}
$S = Load-Settings
$script:dirty = $false

function Save-Settings {
    foreach ($k in $WidgetKeys) {
        $win = $W[$k].win
        if ($win -and $W[$k].placed) { $S.widgets[$k].x = [math]::Round($win.Left); $S.widgets[$k].y = [math]::Round($win.Top) }
    }
    try { $S | ConvertTo-Json -Depth 5 | Set-Content -Path $SettingsPath -Encoding UTF8 } catch {}
    $script:dirty = $false
}

# ---------- background worker (slow things: docker, ping, battery, events, top process) ----------
$shared = [hashtable]::Synchronized(@{ stop = $false; cVer = 0; hVer = 0; dockerOn = $false; containers = @(); cTotal = 0
                                        top = $null; battery = $null; band = $null; latency = $null; crashes = @(); boot = $null
                                        readingsPath = $ReadingsPath; dockerExe = $DockerExe })
$bgScript = {
    $ErrorActionPreference = 'SilentlyContinue'
    $inv = [Globalization.CultureInfo]::InvariantCulture
    function Run-Cmd($exe, $argline, $ms) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo $exe, $argline
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $task = $proc.StandardOutput.ReadToEndAsync()
        if (-not $proc.WaitForExit($ms)) { try { $proc.Kill() } catch {}; return $null }
        $task.Result
    }
    $prev = @{}; $prevT = [DateTime]::Now; $tick = 0; $cores = [Environment]::ProcessorCount; $gw = $null
    while (-not $shared.stop) {
        # busiest process by CPU (every 4 s)
        if ($tick % 4 -eq 0) {
            try {
                $now = [DateTime]::Now; $dt = ($now - $prevT).TotalSeconds; $cur = @{}; $best = $null; $bestCpu = -1.0
                foreach ($proc in [System.Diagnostics.Process]::GetProcesses()) {
                    try { $cpuSec = $proc.TotalProcessorTime.TotalSeconds } catch { continue }
                    $cur[$proc.Id] = $cpuSec
                    if ($proc.Id -gt 4 -and $prev.ContainsKey($proc.Id) -and $dt -gt 0) {
                        $pct = ($cpuSec - $prev[$proc.Id]) / $dt / $cores * 100
                        if ($pct -gt $bestCpu) { $bestCpu = $pct; $best = $proc }
                    }
                }
                if ($best) { $shared.top = @{ name = $best.ProcessName; cpu = [math]::Round($bestCpu); memGB = $best.WorkingSet64 / 1GB } }
                $prev = $cur; $prevT = $now
            } catch {}
        }
        # docker containers (every 5 s)
        if ($tick % 5 -eq 0) {
            try {
                $on = @([System.IO.Directory]::GetFiles('\\.\pipe\')) -contains '\\.\pipe\dockerDesktopLinuxEngine'
                $list = @()
                if ($on -and $shared.dockerExe) {
                    $out = Run-Cmd $shared.dockerExe 'stats --no-stream --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}"' 9000
                    if ($null -ne $out) {
                        foreach ($l in ($out -split "`r?`n")) {
                            if (-not $l.Trim()) { continue }
                            $f = $l.Split('|'); if ($f.Count -lt 3) { continue }
                            $cpu = 0.0; [void][double]::TryParse($f[1].Trim().TrimEnd('%'), [Globalization.NumberStyles]::Float, $inv, [ref]$cpu)
                            $m = ($f[2] -split '/')[0].Trim(); $mem = $m
                            if ($m -match '^([0-9.]+)\s*([KMG])i?B$') {
                                $num = [double]::Parse($matches[1], $inv)
                                $mb = switch ($matches[2]) { 'K' { $num / 1024 } 'M' { $num } 'G' { $num * 1024 } }
                                $mem = $(if ($mb -ge 1024) { '{0:N1} GB' -f ($mb / 1024) } else { '{0:N0} MB' -f $mb })
                            }
                            $list += [pscustomobject]@{ name = $f[0].Trim(); cpu = $cpu; mem = $mem }
                        }
                        $all = Run-Cmd $shared.dockerExe 'ps -a -q' 6000
                        $shared.cTotal = @(($all -split "`r?`n") | Where-Object { $_.Trim() }).Count
                    } else { $list = $shared.containers }
                }
                $shared.dockerOn = $on
                $shared.containers = @($list | Sort-Object cpu -Descending)
                $shared.cVer = $shared.cVer + 1
            } catch {}
        }
        # battery, wi-fi band, response time (every 10 s)
        if ($tick % 10 -eq 0) {
            try {
                $bat = Get-CimInstance Win32_Battery | Select-Object -First 1
                if ($bat) { $shared.battery = @{ pct = [int]$bat.EstimatedChargeRemaining; status = [int]$bat.BatteryStatus } }
            } catch {}
            try {
                $wl = (netsh wlan show interfaces) -join "`n"
                if ($wl -match '(?m)^\s*Band\s*:\s*(.+)$') { $shared.band = $matches[1].Trim() }
                elseif ($wl -match '(?m)^\s*Radio type\s*:\s*(.+)$') { $shared.band = $matches[1].Trim() }
                else { $shared.band = $null }
            } catch {}
            try {
                if (-not $gw -or $tick % 120 -eq 0) { $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop }
                if ($gw) { $r = (New-Object System.Net.NetworkInformation.Ping).Send($gw, 800); $shared.latency = $(if ($r.Status -eq 'Success') { [int]$r.RoundtripTime } else { $null }) }
            } catch {}
        }
        # crashes + boot time (every 5 min)
        if ($tick % 300 -eq 0) {
            try {
                $shared.boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; ProviderName = 'Microsoft-Windows-Kernel-Power'; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 10)
                $rows = New-Object System.Collections.Generic.List[object]
                if (Test-Path $shared.readingsPath) {
                    foreach ($ln in [System.IO.File]::ReadAllLines($shared.readingsPath)) {
                        $f = $ln.Split(','); $ts = [datetime]::MinValue
                        if ($f.Count -ge 4 -and [datetime]::TryParseExact($f[0], 'yyyy-MM-dd HH:mm:ss', $inv, [Globalization.DateTimeStyles]::None, [ref]$ts)) { $rows.Add(@($ts, $f)) }
                    }
                }
                $crashes = @()
                foreach ($e in $ev) {
                    $T = $e.TimeCreated; $last = $null
                    foreach ($r in $rows) { if ($r[0] -lt $T -and $r[0] -gt $T.AddMinutes(-60)) { $last = $r } }
                    $crashes += [pscustomobject]@{ time = $T; code = [uint64]$e.Properties[0].Value; last = $last }
                }
                $shared.crashes = $crashes
                $shared.hVer = $shared.hVer + 1
            } catch {}
        }
        Start-Sleep -Milliseconds 1000
        $tick++
    }
}
$bgRs = [runspacefactory]::CreateRunspace(); $bgRs.ApartmentState = 'MTA'; $bgRs.Open()
$bgRs.SessionStateProxy.SetVariable('shared', $shared)
$bgPs = [powershell]::Create(); $bgPs.Runspace = $bgRs; [void]$bgPs.AddScript($bgScript); [void]$bgPs.BeginInvoke()

# ---------- palette ----------
$conv = New-Object System.Windows.Media.BrushConverter
function B([string]$hex) { $br = $conv.ConvertFrom($hex); $br.Freeze(); $br }
$P = @{
  cool = B '#FF5AC8FA'; coolSoft = B '#245AC8FA'; coolFill = B '#1F5AC8FA'; coolBox = B '#175AC8FA'
  warm = B '#FFFFB547'; warmSoft = B '#26FFB547'; warmFill = B '#1FFFB547'; warmBox = B '#1AFFB547'
  hot  = B '#FFFF6B5E'; hotText = B '#FFFF8A80'; hotFill = B '#29FF6B5E'; hotPillTxt = B '#FF2C1012'; hotSoft = B '#29FF6B5E'; hotBox = B '#33FF6B5E'
  good = B '#FF6BD68A'; goodSoft = B '#246BD68A'
  purple = B '#FFB9A6FF'
  text = B '#FFE8EAEE'; label = B '#FFA9AFBB'; muted = B '#FF8B92A0'; dim = B '#FF6B7280'; soft = B '#FFA9AFBB'
  hotLabel = B '#FFD9B8B8'; hotMuted = B '#FFC9A9A9'; hotText2 = B '#FFF2E6E6'
  cardBg = B '#F214161B'; cardBorder = B '#14FFFFFF'; warmBorder = B '#59FFB547'
  hotBg = B '#F52C1012'; hotBorder = B '#B3FF6B5E'
  track = B '#FF2A2E37'; hotTrack = B '#FF3A2226'
  divider = B '#12FFFFFF'; hotDivider = B '#14FFFFFF'
  box = B '#0BFFFFFF'; hotBoxBg = B '#14FFFFFF'; row = B '#09FFFFFF'; rowBusy = B '#17FFB547'; rowHot = B '#12FF6B5E'
  btn = B '#12FFFFFF'; btnHot = B '#24FF6B5E'; stopIcon = B '#FFC9CDD5'
  ringA = B '#2EFF6B5E'; ringB = B '#73FF6B5E'; none = [System.Windows.Media.Brushes]::Transparent
}
function Clamp([double]$v, [double]$lo, [double]$hi) { [math]::Max($lo, [math]::Min($hi, $v)) }

# ---------- icons (24x24 stroke paths) ----------
$IconData = @{
  thermo  = 'M14,14.76 V3.5 A2.5,2.5 0 0 0 9,3.5 V14.76 A4.5,4.5 0 1 0 14,14.76 Z'
  cpu     = 'M8,6 H16 A2,2 0 0 1 18,8 V16 A2,2 0 0 1 16,18 H8 A2,2 0 0 1 6,16 V8 A2,2 0 0 1 8,6 Z M9,2 V6 M15,2 V6 M9,18 V22 M15,18 V22 M2,9 H6 M2,15 H6 M18,9 H22 M18,15 H22'
  gauge   = 'M12,14 L16,10 M3.3,19 A10,10 0 1 1 20.7,19'
  box     = 'M21,8 L12,3 L3,8 V16 L12,21 L21,16 Z M3,8 L12,13 L21,8 M12,13 V21'
  memory  = 'M4,7 H20 A2,2 0 0 1 22,9 V15 A2,2 0 0 1 20,17 H4 A2,2 0 0 1 2,15 V9 A2,2 0 0 1 4,7 Z M6,11 V13 M10,11 V13 M14,11 V13 M18,11 V13 M6,17 V20 M18,17 V20'
  battery = 'M4,7 H17 A2,2 0 0 1 19,9 V15 A2,2 0 0 1 17,17 H4 A2,2 0 0 1 2,15 V9 A2,2 0 0 1 4,7 Z M22,11 V13'
  disk    = 'M5,4 H19 A2,2 0 0 1 21,6 V18 A2,2 0 0 1 19,20 H5 A2,2 0 0 1 3,18 V6 A2,2 0 0 1 5,4 Z M3,14 H21 M16.5,17 H16.6'
  flame   = 'M12,2 C13,5 17,7.5 17,12 A5,5 0 0 1 7,12 C7,10 7.8,8.6 9,7.5 C9.2,9.1 10,10 11,10.5 C11,7.5 11.5,4.5 12,2 Z'
  check   = 'M2,12 A10,10 0 1 0 22,12 A10,10 0 1 0 2,12 Z M8,12.5 L10.8,15.3 L16.5,9'
  alert   = 'M10.3,3.9 L1.8,18 A2,2 0 0 0 3.5,21 H20.5 A2,2 0 0 0 22.2,18 L13.7,3.9 A2,2 0 0 0 10.3,3.9 Z M12,9 V13 M12,17 H12.01'
  wifi    = 'M2,9 A15,15 0 0 1 22,9 M5,12.5 A10,10 0 0 1 19,12.5 M8.5,16 A5,5 0 0 1 15.5,16 M12,19.5 H12.01'
  down    = 'M2,12 A10,10 0 1 0 22,12 A10,10 0 1 0 2,12 Z M12,7 V17 M7.5,12.5 L12,17 L16.5,12.5'
  upload  = 'M2,12 A10,10 0 1 0 22,12 A10,10 0 1 0 2,12 Z M12,17 V7 M7.5,11.5 L12,7 L16.5,11.5'
  link    = 'M10,13 A5,5 0 0 0 17,13 L20,10 A5,5 0 0 0 13,3 L12,4 M14,11 A5,5 0 0 0 7,11 L4,14 A5,5 0 0 0 11,21 L12,20'
  calendar= 'M5,5 H19 A2,2 0 0 1 21,7 V19 A2,2 0 0 1 19,21 H5 A2,2 0 0 1 3,19 V7 A2,2 0 0 1 5,5 Z M3,10 H21 M8,3 V7 M16,3 V7'
  timer   = 'M4,13 A8,8 0 1 0 20,13 A8,8 0 1 0 4,13 Z M12,9 V13 L14.5,15 M10,2 H14'
  clock   = 'M3,12 A9,9 0 1 0 21,12 A9,9 0 1 0 3,12 Z M12,7 V12 L15,14'
  power   = 'M12,2 V12 M5.6,6.6 A9,9 0 1 0 18.4,6.6'
  zap     = 'M13,2 L4,14 H11 L10,22 L19,10 H12 Z'
  activity= 'M22,12 H18 L15,20 L9,4 L6,12 H2'
  info    = 'M2,12 A10,10 0 1 0 22,12 A10,10 0 1 0 2,12 Z M12,16 V12 M12,8 H12.01'
  external= 'M14,3 H21 V10 M10,14 L21,3 M21,14 V19 A2,2 0 0 1 19,21 H5 A2,2 0 0 1 3,19 V5 A2,2 0 0 1 5,3 H10'
}
# XAML snippet for an icon; optional name lets code recolour or swap it
function IX([string]$key, [string]$color, [double]$size, [string]$name = '', [string]$margin = '0,0,5,0') {
    $nm = if ($name) { " x:Name=`"$name`"" } else { '' }
    "<Viewbox Width=`"$size`" Height=`"$size`" Margin=`"$margin`" VerticalAlignment=`"Center`"><Path$nm Width=`"24`" Height=`"24`" Stroke=`"$color`" StrokeThickness=`"2.2`" StrokeLineJoin=`"Round`" StrokeStartLineCap=`"Round`" StrokeEndLineCap=`"Round`" Data=`"$($IconData[$key])`"/></Viewbox>"
}
# Icon element built in code
function New-Icon([string]$key, $brush, [double]$size) {
    $vb = New-Object System.Windows.Controls.Viewbox; $vb.Width = $size; $vb.Height = $size; $vb.VerticalAlignment = 'Center'
    $pa = New-Object System.Windows.Shapes.Path; $pa.Width = 24; $pa.Height = 24; $pa.Stroke = $brush; $pa.StrokeThickness = 2.2
    $pa.StrokeLineJoin = 'Round'; $pa.StrokeStartLineCap = 'Round'; $pa.StrokeEndLineCap = 'Round'
    $pa.Data = [System.Windows.Media.Geometry]::Parse($IconData[$key])
    $vb.Child = $pa; $vb
}

# ---------- XAML ----------
$BtnStyle = @'
<Style x:Key="Btn" TargetType="Button">
  <Setter Property="Foreground" Value="#E8EAEE"/>
  <Setter Property="Background" Value="#12FFFFFF"/>
  <Setter Property="BorderBrush" Value="Transparent"/>
  <Setter Property="BorderThickness" Value="0"/>
  <Setter Property="FontFamily" Value="Segoe UI"/>
  <Setter Property="FontSize" Value="10"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.8"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.6"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.35"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@

$WinTpl = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="%TITLE%" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>%STYLE%</Window.Resources>
  <Border x:Name="Ring" Padding="4" CornerRadius="18" Background="Transparent" Margin="10">
    <Border x:Name="Card" Width="260" CornerRadius="14" Padding="14,12,14,14" Background="#F214161B" BorderBrush="#14FFFFFF" BorderThickness="1">
      <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="4" Opacity="0.5" Color="Black"/></Border.Effect>
%CARD%
    </Border>
  </Border>
</Window>
'@

# shared text styles
$Mono = 'FontFamily="Cascadia Mono, Consolas"'
$Ui = 'FontFamily="Segoe UI"'
function HeaderX([string]$icon, [string]$color, [string]$title, [string]$iconName, [string]$pillName, [bool]$withDot = $false) {
    $dotX = if ($withDot) { "<Ellipse x:Name=`"${pillName}Dot`" Width=`"5`" Height=`"5`" Fill=`"#6BD68A`" Margin=`"0,0,5,0`" VerticalAlignment=`"Center`"/>" } else { '' }
@"
  <Grid>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      $(IX $icon $color 12 $iconName '0,0,6,0')
      <TextBlock x:Name="HeadLbl" Text="$title" $Ui FontSize="11" FontWeight="SemiBold" Foreground="#C9CDD5" VerticalAlignment="Center"/>
    </StackPanel>
    <Border x:Name="$pillName" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="8" Padding="8,2" Background="#245AC8FA">
      <StackPanel Orientation="Horizontal">$dotX<TextBlock x:Name="${pillName}Txt" Text="--" $Ui FontSize="9" FontWeight="Bold" Foreground="#5AC8FA"/></StackPanel>
    </Border>
  </Grid>
"@
}
function TileX([string]$pre, [string]$icon, [string]$label, [bool]$bar, [string]$unit = '', [string]$margin = '0,0,8,0', [string]$iconXaml = '') {
    $ic = if ($iconXaml) { $iconXaml } else { IX $icon '#A9AFBB' 10 '' '0,0,4,0' }
    $barX = if ($bar) { "<Grid Height=`"3`" Margin=`"0,0,0,3`"><Border x:Name=`"${pre}Track`" CornerRadius=`"1.5`" Background=`"#2A2E37`"/><Border x:Name=`"${pre}Bar`" CornerRadius=`"1.5`" Background=`"#5AC8FA`" HorizontalAlignment=`"Left`" Width=`"0`"/></Grid>" } else { '' }
@"
    <StackPanel Margin="$margin">
      <StackPanel Orientation="Horizontal">$ic<TextBlock x:Name="${pre}Lbl" Text="$label" $Ui FontSize="9" Foreground="#A9AFBB" VerticalAlignment="Center"/></StackPanel>
      <TextBlock Margin="0,2,0,3"><Run x:Name="${pre}Txt" Text="--" $Mono FontSize="15" FontWeight="SemiBold" Foreground="#E8EAEE"/><Run x:Name="${pre}Unit" Text="$unit" $Ui FontSize="9" Foreground="#A9AFBB"/></TextBlock>
      $barX
      <TextBlock x:Name="${pre}Sub" Text="" $Ui FontSize="8" Foreground="#8B92A0"/>
    </StackPanel>
"@
}
$BatIconX = "<Viewbox Width=`"10`" Height=`"10`" Margin=`"0,0,4,0`" VerticalAlignment=`"Center`"><Canvas Width=`"24`" Height=`"24`"><Path Width=`"24`" Height=`"24`" Stroke=`"#A9AFBB`" StrokeThickness=`"2.2`" StrokeLineJoin=`"Round`" StrokeStartLineCap=`"Round`" StrokeEndLineCap=`"Round`" Data=`"$($IconData.battery)`"/><Rectangle x:Name=`"BatFill`" Canvas.Left=`"5`" Canvas.Top=`"10`" Width=`"11`" Height=`"4`" Fill=`"#6BD68A`"/></Canvas></Viewbox>"
$warnX = 232 * ($WarnTemp - $BarMin) / ($BarMax - $BarMin)
$hotX  = 232 * ($HotTemp  - $BarMin) / ($BarMax - $BarMin)

$ThermalCard = @"
<StackPanel>
$(HeaderX 'thermo' '#5AC8FA' 'GPU temperature' 'Thermo' 'Pill')
  <Grid Margin="0,8,0,0">
    <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
      <TextBlock x:Name="TempTxt" Text="--" $Mono FontSize="40" FontWeight="SemiBold" Foreground="#5AC8FA" LineHeight="40" LineStackingStrategy="BlockLineHeight"/>
      <TextBlock x:Name="UnitTxt" Text="&#176;C" $Ui FontSize="13" Foreground="#A9AFBB" Margin="3,4,0,0" VerticalAlignment="Top"/>
    </StackPanel>
    <StackPanel HorizontalAlignment="Right" VerticalAlignment="Bottom">
      <Canvas Width="110" Height="30" ClipToBounds="True">
        <Polygon x:Name="SparkFill" Fill="#1F5AC8FA"/>
        <Polyline x:Name="SparkLine" Stroke="#5AC8FA" StrokeThickness="1.8" StrokeLineJoin="Round"/>
        <Ellipse x:Name="SparkDot" Width="5" Height="5" Fill="#5AC8FA" Visibility="Collapsed"/>
      </Canvas>
      <TextBlock x:Name="SparkLbl" Text="last 2 min" $Ui FontSize="7.5" Foreground="#8B92A0" HorizontalAlignment="Right"/>
    </StackPanel>
  </Grid>
  <Border x:Name="StatusBox" Margin="0,7,0,0" Height="23" CornerRadius="7" Background="#175AC8FA" Padding="8,0">
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      $(IX 'check' '#5AC8FA' 11 'StatusIco' '0,0,7,0')
      <TextBlock VerticalAlignment="Center" $Ui FontSize="9.5"><Run x:Name="StatusMain" Text="Starting" Foreground="#E8EAEE"/><Run x:Name="StatusSub" Text="" Foreground="#A9AFBB"/></TextBlock>
    </StackPanel>
  </Border>
  <Grid Margin="0,9,0,0" Height="8">
    <Border x:Name="BarTrack" Height="4" CornerRadius="2" Background="#2A2E37" VerticalAlignment="Center"/>
    <Border x:Name="BarFill" Height="4" CornerRadius="2" Background="#5AC8FA" HorizontalAlignment="Left" VerticalAlignment="Center" Width="0"/>
    <Border Width="1.5" Height="8" Background="#FFB547" HorizontalAlignment="Left" Margin="$warnX,0,0,0"/>
    <Border x:Name="MarkHot" Width="1.5" Height="8" Background="#FF6B5E" HorizontalAlignment="Left" Margin="$hotX,0,0,0"/>
  </Grid>
  <Grid Margin="0,2,0,0" Height="11">
    <TextBlock x:Name="MinLbl" Text="40&#176;" $Ui FontSize="7.5" Foreground="#8B92A0"/>
    <TextBlock Text="warm 75&#176;" $Ui FontSize="7.5" Foreground="#FFB547" Margin="$($warnX - 16),0,0,0"/>
    <TextBlock Text="hot 85&#176;" $Ui FontSize="7.5" Foreground="#FF8A80" Margin="$($hotX - 9),0,0,0"/>
    <TextBlock x:Name="MaxLbl" Text="95&#176;" $Ui FontSize="7.5" Foreground="#8B92A0" HorizontalAlignment="Right"/>
  </Grid>
  <Border x:Name="Divider" Height="1" Background="#12FFFFFF" Margin="0,7,0,9"/>
  <UniformGrid Columns="3">
$(TileX 'Cpu' 'cpu' 'Processor' $true '%')
$(TileX 'Clk' 'gauge' 'Speed' $false ' GHz')
$(TileX 'Dkr' 'box' 'Docker' $true '' '0')
  </UniformGrid>
  <UniformGrid Columns="3" Margin="0,9,0,0">
$(TileX 'Ram' 'memory' 'Memory' $true ' GB')
$(TileX 'Bat' 'battery' 'Battery' $false '%' '0,0,8,0' $BatIconX)
$(TileX 'Dsk' 'disk' 'Disk C:' $true ' GB' '0')
  </UniformGrid>
  <Border x:Name="TopBox" Margin="0,9,0,0" Height="30" CornerRadius="8" Background="#0BFFFFFF" Padding="9,0">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      $(IX 'flame' '#FFB547' 11 '' '0,0,6,0')
      <TextBlock x:Name="TopLbl" Grid.Column="1" Text="Busiest app" $Ui FontSize="9" Foreground="#A9AFBB" VerticalAlignment="Center" Margin="0,0,7,0"/>
      <TextBlock x:Name="TopName" Grid.Column="2" Text="--" $Mono FontSize="10.5" FontWeight="SemiBold" Foreground="#E8EAEE" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="TopVal" Grid.Column="3" Text="" $Mono FontSize="9" Foreground="#A9AFBB" VerticalAlignment="Center" Margin="6,0,0,0"/>
    </Grid>
  </Border>
</StackPanel>
"@

function NetRowX([string]$icon, [string]$label, [string]$valueXaml) {
@"
  <Grid Height="19">
    <StackPanel Orientation="Horizontal">$(IX $icon '#A9AFBB' 10 '' '0,0,6,0')<TextBlock Text="$label" $Ui FontSize="9.5" Foreground="#A9AFBB" VerticalAlignment="Center"/></StackPanel>
    $valueXaml
  </Grid>
"@
}
$NetworkCard = @"
<StackPanel>
$(HeaderX 'wifi' '#5AC8FA' 'Internet' '' 'NPill' $true)
  <UniformGrid Columns="2" Margin="0,8,0,0">
    <Border CornerRadius="8" Background="#155AC8FA" Padding="8,6" Margin="0,0,3,0">
      <StackPanel>
        <StackPanel Orientation="Horizontal">$(IX 'down' '#5AC8FA' 11 '' '0,0,5,0')<TextBlock Text="Download" $Ui FontSize="9" Foreground="#A9AFBB" VerticalAlignment="Center"/></StackPanel>
        <TextBlock Margin="0,3,0,0"><Run x:Name="DlTxt" Text="--" $Mono FontSize="17" FontWeight="SemiBold" Foreground="#5AC8FA"/><Run x:Name="DlUnit" Text="" $Ui FontSize="9" Foreground="#A9AFBB"/></TextBlock>
      </StackPanel>
    </Border>
    <Border CornerRadius="8" Background="#15B9A6FF" Padding="8,6" Margin="3,0,0,0">
      <StackPanel>
        <StackPanel Orientation="Horizontal">$(IX 'upload' '#B9A6FF' 11 '' '0,0,5,0')<TextBlock Text="Upload" $Ui FontSize="9" Foreground="#A9AFBB" VerticalAlignment="Center"/></StackPanel>
        <TextBlock Margin="0,3,0,0"><Run x:Name="UlTxt" Text="--" $Mono FontSize="17" FontWeight="SemiBold" Foreground="#B9A6FF"/><Run x:Name="UlUnit" Text="" $Ui FontSize="9" Foreground="#A9AFBB"/></TextBlock>
      </StackPanel>
    </Border>
  </UniformGrid>
  <Canvas Width="232" Height="46" Margin="0,8,0,0" ClipToBounds="True">
    <Rectangle Canvas.Top="45" Width="232" Height="1" Fill="#2A2E37"/>
    <Polygon x:Name="DlFill" Fill="#215AC8FA"/>
    <Polyline x:Name="DlLine" Stroke="#5AC8FA" StrokeThickness="1.6" StrokeLineJoin="Round"/>
    <Polyline x:Name="UlLine" Stroke="#B9A6FF" StrokeThickness="1.6" StrokeLineJoin="Round"/>
  </Canvas>
  <Grid Margin="0,4,0,0">
    <StackPanel Orientation="Horizontal">
      <Rectangle Width="7" Height="2" Fill="#5AC8FA" VerticalAlignment="Center" Margin="0,0,4,0"/><TextBlock Text="download" $Ui FontSize="7.5" Foreground="#8B92A0" Margin="0,0,9,0"/>
      <Rectangle Width="7" Height="2" Fill="#B9A6FF" VerticalAlignment="Center" Margin="0,0,4,0"/><TextBlock Text="upload" $Ui FontSize="7.5" Foreground="#8B92A0"/>
    </StackPanel>
    <TextBlock Text="last 2 min" $Ui FontSize="7.5" Foreground="#8B92A0" HorizontalAlignment="Right"/>
  </Grid>
  <Border Height="1" Background="#12FFFFFF" Margin="0,8,0,5"/>
$(NetRowX 'link' 'Connected via' "<TextBlock x:Name=`"AdTxt`" Text=`"--`" $Ui FontSize=`"9.5`" Foreground=`"#E8EAEE`" HorizontalAlignment=`"Right`" VerticalAlignment=`"Center`" TextTrimming=`"CharacterEllipsis`" MaxWidth=`"130`"/>")
$(NetRowX 'calendar' 'Used today' "<TextBlock HorizontalAlignment=`"Right`" VerticalAlignment=`"Center`" $Mono FontSize=`"9.5`"><Run x:Name=`"TdRx`" Text=`"--`" Foreground=`"#5AC8FA`"/><Run Text=`"  `"/><Run x:Name=`"TdTx`" Text=`"--`" Foreground=`"#B9A6FF`"/></TextBlock>")
$(NetRowX 'timer' 'Response time' "<TextBlock HorizontalAlignment=`"Right`" VerticalAlignment=`"Center`"><Run x:Name=`"LatTxt`" Text=`"--`" $Mono FontSize=`"9.5`" Foreground=`"#E8EAEE`"/><Run x:Name=`"LatQ`" Text=`"`" $Ui FontSize=`"9.5`" Foreground=`"#6BD68A`"/></TextBlock>")
</StackPanel>
"@

$ContainersCard = @"
<StackPanel>
$(HeaderX 'box' '#5AC8FA' 'Docker containers' '' 'CPill' $true)
  <StackPanel x:Name="OnPanel" Margin="0,8,0,0">
    <UniformGrid Columns="2">
      <Border CornerRadius="8" Background="#0BFFFFFF" Padding="8,6" Margin="0,0,3,0">
        <StackPanel>
          <StackPanel Orientation="Horizontal">$(IX 'memory' '#A9AFBB' 10 '' '0,0,4,0')<TextBlock Text="Memory" $Ui FontSize="9" Foreground="#A9AFBB" VerticalAlignment="Center"/></StackPanel>
          <TextBlock x:Name="CMemTxt" Text="--" Margin="0,3,0,0" $Mono FontSize="11" FontWeight="SemiBold" Foreground="#E8EAEE"/>
          <Grid Height="3" Margin="0,5,0,0"><Border CornerRadius="1.5" Background="#2A2E37"/><Border x:Name="CMemBar" CornerRadius="1.5" Background="#5AC8FA" HorizontalAlignment="Left" Width="0"/></Grid>
        </StackPanel>
      </Border>
      <Border CornerRadius="8" Background="#0BFFFFFF" Padding="8,6" Margin="3,0,0,0">
        <StackPanel>
          <StackPanel Orientation="Horizontal">$(IX 'cpu' '#A9AFBB' 10 '' '0,0,4,0')<TextBlock Text="Processor" $Ui FontSize="9" Foreground="#A9AFBB" VerticalAlignment="Center"/></StackPanel>
          <TextBlock x:Name="CCpuTxt" Text="--" Margin="0,3,0,0" $Mono FontSize="11" FontWeight="SemiBold" Foreground="#E8EAEE"/>
          <Grid Height="3" Margin="0,5,0,0"><Border CornerRadius="1.5" Background="#2A2E37"/><Border x:Name="CCpuBar" CornerRadius="1.5" Background="#5AC8FA" HorizontalAlignment="Left" Width="0"/></Grid>
        </StackPanel>
      </Border>
    </UniformGrid>
    <Grid Margin="0,8,0,3">
      <Grid.ColumnDefinitions><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/><ColumnDefinition Width="34"/><ColumnDefinition Width="50"/><ColumnDefinition Width="29"/></Grid.ColumnDefinitions>
      <TextBlock Grid.Column="1" Text="NAME" $Ui FontSize="7.5" FontWeight="Bold" Foreground="#8B92A0"/>
      <TextBlock Grid.Column="2" Text="CPU" $Ui FontSize="7.5" FontWeight="Bold" Foreground="#8B92A0" HorizontalAlignment="Right"/>
      <TextBlock Grid.Column="3" Text="MEMORY" $Ui FontSize="7.5" FontWeight="Bold" Foreground="#8B92A0" HorizontalAlignment="Right"/>
    </Grid>
    <ScrollViewer MaxHeight="174" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="Rows"/>
    </ScrollViewer>
    <TextBlock x:Name="CEmpty" Text="No containers running" $Ui FontSize="10" Foreground="#8B92A0" Margin="0,2,0,4" Visibility="Collapsed"/>
    <Grid Margin="0,5,0,0">
      <TextBlock x:Name="CMore" Text="" $Ui FontSize="8" Foreground="#8B92A0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">$(IX 'flame' '#FFB547' 8 '' '0,0,3,0')<TextBlock Text="= busy" $Ui FontSize="8" Foreground="#8B92A0"/></StackPanel>
    </Grid>
    <UniformGrid Columns="2" Margin="0,8,0,0">
      <Button x:Name="StopAll" Style="{StaticResource Btn}" Height="27" Margin="0,0,4,0" Background="Transparent" BorderBrush="#8CFF6B5E" BorderThickness="1" Foreground="#FF8A80">
        <StackPanel Orientation="Horizontal"><Rectangle Width="7" Height="7" RadiusX="1.5" RadiusY="1.5" Fill="#FF8A80" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="Stop all" VerticalAlignment="Center"/></StackPanel>
      </Button>
      <Button x:Name="QuitDocker" Style="{StaticResource Btn}" Height="27" Margin="4,0,0,0">
        <StackPanel Orientation="Horizontal">$(IX 'power' '#E8EAEE' 10 '' '0,0,6,0')<TextBlock Text="Quit Docker" VerticalAlignment="Center"/></StackPanel>
      </Button>
    </UniformGrid>
  </StackPanel>
  <StackPanel x:Name="OffPanel" Margin="0,10,0,0" Visibility="Collapsed">
    <StackPanel Orientation="Horizontal">$(IX 'power' '#8B92A0' 13 '' '0,0,8,0')<TextBlock Text="Docker is off" $Ui FontSize="12" FontWeight="SemiBold" Foreground="#E8EAEE" VerticalAlignment="Center"/></StackPanel>
    <TextBlock Text="Containers show here while Docker is running." $Ui FontSize="9.5" Foreground="#A9AFBB" Margin="0,4,0,9" TextWrapping="Wrap"/>
    <Button x:Name="StartDocker" Style="{StaticResource Btn}" Height="27">
      <StackPanel Orientation="Horizontal">$(IX 'power' '#E8EAEE' 10 '' '0,0,6,0')<TextBlock Text="Start Docker" VerticalAlignment="Center"/></StackPanel>
    </Button>
  </StackPanel>
</StackPanel>
"@

$HealthCard = @"
<StackPanel>
$(HeaderX 'activity' '#FF6B5E' 'System health' '' 'HPill')
  <Border x:Name="HAlert" Margin="0,8,0,0" CornerRadius="7" Background="#175AC8FA" Padding="8,5">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      $(IX 'check' '#5AC8FA' 12 'HAlertIco' '0,0,7,0')
      <TextBlock Grid.Column="1" TextWrapping="Wrap" VerticalAlignment="Center" $Ui FontSize="9.5"><Run x:Name="HAlertMain" Text="Checking" Foreground="#E8EAEE"/><Run x:Name="HAlertSub" Text="" Foreground="#A9AFBB"/></TextBlock>
    </Grid>
  </Border>
  <UniformGrid Columns="2" Margin="0,8,0,0">
    <Border CornerRadius="8" Background="#0BFFFFFF" Padding="8,6" Margin="0,0,3,0">
      <StackPanel>
        <StackPanel Orientation="Horizontal">$(IX 'clock' '#A9AFBB' 10 '' '0,0,4,0')<TextBlock Text="Running for" $Ui FontSize="8.5" Foreground="#A9AFBB" VerticalAlignment="Center"/></StackPanel>
        <TextBlock x:Name="UpTxt" Text="--" $Mono FontSize="12" FontWeight="SemiBold" Foreground="#E8EAEE" Margin="0,2,0,0"/>
      </StackPanel>
    </Border>
    <Border CornerRadius="8" Background="#0BFFFFFF" Padding="8,6" Margin="3,0,0,0">
      <StackPanel>
        <StackPanel Orientation="Horizontal">$(IX 'power' '#A9AFBB' 10 '' '0,0,4,0')<TextBlock Text="Last started" $Ui FontSize="8.5" Foreground="#A9AFBB" VerticalAlignment="Center"/></StackPanel>
        <TextBlock x:Name="BootTxt" Text="--" $Mono FontSize="10" FontWeight="SemiBold" Foreground="#E8EAEE" Margin="0,3,0,0"/>
      </StackPanel>
    </Border>
  </UniformGrid>
  <TextBlock Text="UNEXPECTED SHUTDOWNS &#183; LAST 30 DAYS" $Ui FontSize="7.5" FontWeight="Bold" Foreground="#8B92A0" Margin="0,9,0,5"/>
  <StackPanel x:Name="CrashRows"/>
  <Grid Margin="0,4,0,8">
    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    $(IX 'info' '#8B92A0' 9 '' '0,1,5,0')
    <TextBlock Grid.Column="1" TextWrapping="Wrap" $Ui FontSize="8.5" Foreground="#8B92A0" Text="Readings are saved every 10 s, so each new crash shows what the laptop was doing just before."/>
  </Grid>
  <Button x:Name="OpenEv" Style="{StaticResource Btn}" Height="27">
    <StackPanel Orientation="Horizontal">$(IX 'external' '#E8EAEE' 10 '' '0,0,6,0')<TextBlock Text="Open Event Viewer" VerticalAlignment="Center"/></StackPanel>
  </Button>
</StackPanel>
"@

# ---------- widget windows ----------
$W = @{}
function New-Widget([string]$key, [string]$cardXaml) {
    $xml = $WinTpl.Replace('%TITLE%', "Heatwatch - $key").Replace('%STYLE%', $BtnStyle).Replace('%CARD%', $cardXaml)
    $win = [Windows.Markup.XamlReader]::Parse($xml)
    $win.Tag = $key
    $cardEl = $win.FindName('Card'); $cardEl.Tag = $key
    $cardEl.Add_MouseLeftButtonDown({ param($snd, $evt) if (-not $S.lock) { try { [System.Windows.Window]::GetWindow($snd).DragMove() } catch {} } })
    $win.Add_LocationChanged({ $script:dirty = $true })
    $win.Add_Loaded({ param($snd, $evt) Place-Widget $snd })
    $win.Add_SizeChanged({ param($snd, $evt) if ($W[[string]$snd.Tag].placed) { Fit-OnScreen $snd } })
    $cm = New-Object System.Windows.Controls.ContextMenu
    $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = 'Hide this widget'; $mi.Tag = $key
    $mi.Add_Click({ param($snd, $evt) Set-WidgetOn ([string]$snd.Tag) $false }); [void]$cm.Items.Add($mi)
    $ml = New-Object System.Windows.Controls.MenuItem; $ml.Header = 'Lock positions'; $ml.IsCheckable = $true; $ml.IsChecked = $S.lock
    $ml.Add_Click({ param($snd, $evt) Set-Lock $snd.IsChecked }); [void]$cm.Items.Add($ml)
    $cardEl.ContextMenu = $cm
    $W[$key] = @{ win = $win; lockItem = $ml; placed = $false; ui = @{} }
    $win
}
function UI([string]$key, [string[]]$names) { foreach ($n in $names) { $W[$key].ui[$n] = $W[$key].win.FindName($n) } }

[void](New-Widget 'thermal' $ThermalCard)
UI 'thermal' 'Ring','Card','Thermo','HeadLbl','Pill','PillTxt','TempTxt','UnitTxt','SparkFill','SparkLine','SparkDot','SparkLbl',
             'StatusBox','StatusIco','StatusMain','StatusSub','BarTrack','BarFill','MarkHot','MinLbl','MaxLbl','Divider',
             'CpuLbl','CpuTxt','CpuUnit','CpuTrack','CpuBar','CpuSub','ClkLbl','ClkTxt','ClkUnit','ClkSub',
             'DkrLbl','DkrTxt','DkrUnit','DkrTrack','DkrBar','DkrSub','RamLbl','RamTxt','RamUnit','RamTrack','RamBar','RamSub',
             'BatLbl','BatTxt','BatUnit','BatSub','BatFill','DskLbl','DskTxt','DskUnit','DskTrack','DskBar','DskSub',
             'TopBox','TopLbl','TopName','TopVal'
[void](New-Widget 'network' $NetworkCard)
UI 'network' 'NPill','NPillTxt','NPillDot','DlTxt','DlUnit','UlTxt','UlUnit','DlFill','DlLine','UlLine','AdTxt','TdRx','TdTx','LatTxt','LatQ'
[void](New-Widget 'containers' $ContainersCard)
UI 'containers' 'CPill','CPillTxt','CPillDot','OnPanel','OffPanel','CMemTxt','CMemBar','CCpuTxt','CCpuBar','Rows','CEmpty','CMore','StopAll','QuitDocker','StartDocker'
[void](New-Widget 'health' $HealthCard)
UI 'health' 'HPill','HPillTxt','HAlert','HAlertIco','HAlertMain','HAlertSub','UpTxt','BootTxt','CrashRows','OpenEv'

$innerW = 232
$Geo = @{}; foreach ($k in 'check','alert') { $Geo[$k] = [System.Windows.Media.Geometry]::Parse($IconData[$k]) }

function Place-Widget($win) {
    $key = [string]$win.Tag
    $wa = [System.Windows.SystemParameters]::WorkArea
    $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
    $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
    $ww = $win.ActualWidth; $wh = $win.ActualHeight
    $x = $S.widgets[$key].x; $y = $S.widgets[$key].y
    $ok = ($null -ne $x -and $null -ne $y -and $x -gt ($vl - $ww + 60) -and $x -lt ($vl + $vw - 60) -and $y -gt ($vt - 20) -and $y -lt ($vt + $vh - 60))
    if (-not $ok) {
        switch ($key) {
            'thermal'    { $x = $wa.Right - $ww;          $y = $wa.Bottom - $wh }
            'network'    { $x = $wa.Right - $ww;          $y = $wa.Top }
            'containers' { $x = $wa.Right - 2 * $ww + 20; $y = $wa.Top }
            'health'     { $x = $wa.Right - 3 * $ww + 40; $y = $wa.Top }
        }
    }
    $win.Left = $x; $win.Top = $y
    Fit-OnScreen $win
    $W[$key].placed = $true
}
# keep the whole widget inside its monitor's work area (above the taskbar), e.g. after it grew taller
function Fit-OnScreen($win) {
    $x = $win.Left; $y = $win.Top; $ww = $win.ActualWidth; $wh = $win.ActualHeight
    try {
        $scale = [System.Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformToDevice.M11
        $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point ([int](($x + 20) * $scale)), ([int](($y + 20) * $scale))))
        $wr = $scr.WorkingArea
        $l = $wr.Left / $scale; $tp = $wr.Top / $scale; $r = $wr.Right / $scale; $bt = $wr.Bottom / $scale
        if ($x + $ww -gt $r) { $x = $r - $ww }; if ($x -lt $l) { $x = $l }
        if ($y + $wh -gt $bt) { $y = $bt - $wh }; if ($y -lt $tp) { $y = $tp }
    } catch {}
    if ($win.Left -ne $x) { $win.Left = $x }; if ($win.Top -ne $y) { $win.Top = $y }
}

# ---------- tray ----------
function New-TrayIcon([string]$hex) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gr.Clear([System.Drawing.Color]::Transparent)
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
    $gr.FillEllipse($br, 8, 16, 16, 16)
    $gr.FillRectangle($br, 12, 5, 8, 16)
    $gr.FillEllipse($br, 12, 1, 8, 8)
    $gr.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$Icons = @{ cool = (New-TrayIcon '#5AC8FA'); warm = (New-TrayIcon '#FFB547'); hot = (New-TrayIcon '#FF6B5E') }
$script:trayState = 'cool'

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $Icons.cool; $tray.Text = 'Heatwatch'; $tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$hdr = New-Object System.Windows.Forms.ToolStripMenuItem 'Heatwatch'; $hdr.Enabled = $false; [void]$menu.Items.Add($hdr)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$TrayItems = @{}
$labels = @{ thermal = 'GPU temperature'; network = 'Internet'; containers = 'Docker containers'; health = 'System health' }
foreach ($k in $WidgetKeys) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem $labels[$k]
    $it.CheckOnClick = $true; $it.Checked = $S.widgets[$k].on; $it.Tag = $k
    $it.Add_Click({ param($snd, $evt) Set-WidgetOn ([string]$snd.Tag) $snd.Checked })
    [void]$menu.Items.Add($it); $TrayItems[$k] = $it
}
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$lockIt = New-Object System.Windows.Forms.ToolStripMenuItem 'Lock positions'; $lockIt.CheckOnClick = $true; $lockIt.Checked = $S.lock
$lockIt.Add_Click({ param($snd, $evt) Set-Lock $snd.Checked }); [void]$menu.Items.Add($lockIt)
$startIt = New-Object System.Windows.Forms.ToolStripMenuItem 'Start at sign-in'; $startIt.CheckOnClick = $true; $startIt.Checked = (Test-Path $StartupLnk)
$startIt.Add_Click({ param($snd, $evt) Set-Startup $snd.Checked }); [void]$menu.Items.Add($startIt)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$resetIt = New-Object System.Windows.Forms.ToolStripMenuItem 'Reset positions'
$resetIt.Add_Click({ Reset-Positions }); [void]$menu.Items.Add($resetIt)
$exitIt = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
$exitIt.Add_Click({ Exit-App }); [void]$menu.Items.Add($exitIt)
$tray.ContextMenuStrip = $menu
$tray.Add_MouseDoubleClick({ foreach ($k in $WidgetKeys) { if ($S.widgets[$k].on) { $W[$k].win.Show(); $W[$k].win.Activate() | Out-Null } } })

function Set-WidgetOn([string]$key, [bool]$on) {
    $S.widgets[$key].on = $on
    $TrayItems[$key].Checked = $on
    if ($on) { $W[$key].win.Show() } else { $W[$key].win.Hide() }
    $script:dirty = $true
}
function Set-Lock([bool]$v) {
    $S.lock = $v; $lockIt.Checked = $v
    foreach ($k in $WidgetKeys) { $W[$k].lockItem.IsChecked = $v }
    $script:dirty = $true
}
function Set-Startup([bool]$v) {
    try {
        if ($v) {
            $ws = New-Object -ComObject WScript.Shell; $l = $ws.CreateShortcut($StartupLnk)
            $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $l.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
            $l.WorkingDirectory = Split-Path $ScriptPath; $l.WindowStyle = 7; $l.Save()
        } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
    } catch {}
    $startIt.Checked = (Test-Path $StartupLnk)
}
function Reset-Positions {
    foreach ($k in $WidgetKeys) { $S.widgets[$k].x = $null; $S.widgets[$k].y = $null; if ($W[$k].win.IsLoaded) { Place-Widget $W[$k].win } }
    Save-Settings
}
function Exit-App {
    Save-Settings
    $shared.stop = $true
    $tray.Visible = $false; $tray.Dispose()
    foreach ($k in $WidgetKeys) { try { $W[$k].win.Close() } catch {} }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

# ---------- container actions ----------
function Start-DockerCmd([string]$argline) {
    if ($DockerExe) { Start-Process -FilePath $DockerExe -ArgumentList $argline -WindowStyle Hidden }
}
$cu = $W.containers.ui
$cu.StopAll.Add_Click({
    $names = @($shared.containers | ForEach-Object { $_.name })
    if ($names.Count -eq 0) { return }
    $r = [System.Windows.MessageBox]::Show("Stop all $($names.Count) running containers?", 'Heatwatch', 'YesNo', 'Question')
    if ($r -eq 'Yes') { Start-DockerCmd ('stop ' + ($names -join ' ')); $this.IsEnabled = $false }
})
$cu.QuitDocker.Add_Click({
    $r = [System.Windows.MessageBox]::Show('Quit Docker Desktop? All containers will stop.', 'Heatwatch', 'YesNo', 'Question')
    if ($r -eq 'Yes') { Start-DockerCmd 'desktop stop'; $this.IsEnabled = $false }
})
$cu.StartDocker.Add_Click({ if (Test-Path $DockerDesktop) { Start-Process $DockerDesktop; $this.IsEnabled = $false } })
$W.health.ui.OpenEv.Add_Click({ Start-Process 'eventvwr.msc' })

# ---------- sensors on the UI thread (fast ones) ----------
$cpuLoad = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
$cpuPerf = $null
try { $cpuPerf = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Performance', '_Total') } catch {}
$memAvail = New-Object System.Diagnostics.PerformanceCounter('Memory', 'Available MBytes')
[void]$cpuLoad.NextValue(); if ($cpuPerf) { [void]$cpuPerf.NextValue() }
$baseMHz = (Get-CimInstance Win32_Processor | Select-Object -First 1).MaxClockSpeed
$ramTotGB = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB

$histT = New-Object System.Collections.Generic.List[double]
$histRx = New-Object System.Collections.Generic.List[double]
$histTx = New-Object System.Collections.Generic.List[double]
$script:netPrev = $null; $script:netSw = [System.Diagnostics.Stopwatch]::StartNew()
$script:pulse = $false; $script:tick = 0; $script:lastCVer = -1; $script:lastHVer = -1

function Get-NetSample {
    $nics = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
        $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' -and $_.NetworkInterfaceType -ne 'Tunnel' -and
        $_.Description -notmatch 'Hyper-V|Virtual|WSL|TAP|VPN|Bluetooth|Loopback' -and $_.Name -notmatch 'vEthernet' })
    $rx = [double]0; $tx = [double]0
    foreach ($n in $nics) { try { $st = $n.GetIPStatistics(); $rx += $st.BytesReceived; $tx += $st.BytesSent } catch {} }
    [pscustomobject]@{ nics = $nics; rx = $rx; tx = $tx; t = $script:netSw.Elapsed.TotalSeconds }
}
function Fmt-Rate([double]$bps) {
    if ($bps -ge 1MB) { [pscustomobject]@{ v = $bps / 1MB; f = '{0:N1}'; u = ' MB/s' } }
    elseif ($bps -ge 1KB) { [pscustomobject]@{ v = $bps / 1KB; f = '{0:N0}'; u = ' KB/s' } }
    else { [pscustomobject]@{ v = $bps; f = '{0:N0}'; u = ' B/s' } }
}
function Fmt-Bytes([double]$bytes) {
    if ($bytes -ge 1GB) { '{0:N1} GB' -f ($bytes / 1GB) } elseif ($bytes -ge 1MB) { '{0:N0} MB' -f ($bytes / 1MB) } else { '{0:N0} KB' -f ($bytes / 1KB) }
}
function Push([System.Collections.Generic.List[double]]$list, [double]$v) { $list.Add($v); while ($list.Count -gt $HistoryLen) { $list.RemoveAt(0) } }

function Set-Spark($line, $fill, $marker, $data, [double]$cw, [double]$ch, [double]$lo, [double]$hi) {
    $n = $data.Count
    if ($n -lt 2) { $line.Points = $null; if ($fill) { $fill.Points = $null }; if ($marker) { $marker.Visibility = 'Collapsed' }; return }
    $pad = 3.0; $step = ($cw - $pad) / ($HistoryLen - 1); $x0 = $cw - $pad - $step * ($n - 1)
    $pl = New-Object System.Windows.Media.PointCollection
    $pa = New-Object System.Windows.Media.PointCollection
    $pa.Add((New-Object System.Windows.Point $x0, $ch))
    for ($i = 0; $i -lt $n; $i++) {
        $pt = New-Object System.Windows.Point ($x0 + $step * $i), ($pad + ($ch - 2 * $pad) * (1 - (Clamp (($data[$i] - $lo) / ($hi - $lo)) 0 1)))
        $pl.Add($pt); $pa.Add($pt)
    }
    $pa.Add((New-Object System.Windows.Point ($cw - $pad), $ch))
    $line.Points = $pl; if ($fill) { $fill.Points = $pa }
    if ($marker) {
        $last = $pl[$pl.Count - 1]
        [System.Windows.Controls.Canvas]::SetLeft($marker, $last.X - 2.5); [System.Windows.Controls.Canvas]::SetTop($marker, $last.Y - 2.5)
        $marker.Visibility = 'Visible'
    }
}
function Set-Pill($border, $txt, $dotEl, [string]$text, $bg, $fg) {
    $border.Background = $bg; $txt.Text = $text; $txt.Foreground = $fg
    if ($dotEl) { $dotEl.Fill = $fg }
}

# ---------- widget renderers ----------
function Update-Thermal($t, $load, $perf, $ramUsed, $vmGB, $dFree, $dTot) {
    $ui = $W.thermal.ui
    $state = if ($null -eq $t) { 'cool' } elseif ($t -ge $HotTemp) { 'hot' } elseif ($t -ge $WarnTemp) { 'warm' } else { 'cool' }
    $hot = $state -eq 'hot'
    $accent = $P[$state]
    $lbl   = if ($hot) { $P.hotLabel } else { $P.label }
    $muted = if ($hot) { $P.hotMuted } else { $P.muted }
    $trackB = if ($hot) { $P.hotTrack } else { $P.track }
    $textB = if ($hot) { $P.hotText2 } else { $P.text }

    switch ($state) {
        'cool' { $ui.Card.Background = $P.cardBg; $ui.Card.BorderBrush = $P.cardBorder; $ui.Ring.Background = $P.none }
        'warm' { $ui.Card.Background = $P.cardBg; $ui.Card.BorderBrush = $P.warmBorder; $ui.Ring.Background = $P.none }
        'hot'  { $ui.Card.Background = $P.hotBg; $ui.Card.BorderBrush = $P.hotBorder
                 $script:pulse = -not $script:pulse; $ui.Ring.Background = $(if ($script:pulse) { $P.ringB } else { $P.ringA }) }
    }
    $ui.Divider.Background = if ($hot) { $P.hotDivider } else { $P.divider }
    $ui.TopBox.Background = if ($hot) { $P.hotBoxBg } else { $P.box }
    foreach ($l in 'UnitTxt','CpuLbl','ClkLbl','DkrLbl','RamLbl','BatLbl','DskLbl','TopLbl','CpuUnit','ClkUnit','DkrUnit','RamUnit','BatUnit','DskUnit') { $ui[$l].Foreground = $lbl }
    foreach ($l in 'MinLbl','MaxLbl','SparkLbl','CpuSub','DkrSub','RamSub','DskSub') { $ui[$l].Foreground = $muted }
    foreach ($l in 'BarTrack','CpuTrack','DkrTrack','RamTrack','DskTrack') { $ui[$l].Background = $trackB }
    $ui.Thermo.Stroke = $accent
    $ui.MarkHot.Background = if ($hot) { [System.Windows.Media.Brushes]::White } else { $P.hot }

    # badge + plain-language status line
    switch ($state) {
        'cool' { Set-Pill $ui.Pill $ui.PillTxt $null 'COOL' $P.coolSoft $P.cool
                 $ui.StatusBox.Background = $P.coolBox; $ui.StatusIco.Data = $Geo.check; $ui.StatusIco.Stroke = $P.cool
                 $ui.StatusMain.Text = 'Running cool'; $ui.StatusSub.Text = " $DOT nothing to do" }
        'warm' { Set-Pill $ui.Pill $ui.PillTxt $null 'WARM' $P.warmSoft $P.warm
                 $ui.StatusBox.Background = $P.warmBox; $ui.StatusIco.Data = $Geo.alert; $ui.StatusIco.Stroke = $P.warm
                 $ui.StatusMain.Text = 'Getting warm'; $ui.StatusSub.Text = " $DOT close heavy apps" }
        'hot'  { Set-Pill $ui.Pill $ui.PillTxt $null "$([char]0x26A0) HOT" $P.hot $P.hotPillTxt
                 $ui.StatusBox.Background = $P.hotBox; $ui.StatusIco.Data = $Geo.alert; $ui.StatusIco.Stroke = $P.hotText
                 $ui.StatusMain.Text = 'Too hot'; $ui.StatusSub.Text = " $DOT shutdown risk, ease off now" }
    }
    $ui.StatusMain.Foreground = $textB; $ui.StatusSub.Foreground = $lbl
    if ($null -eq $t) { $ui.StatusMain.Text = 'No GPU reading'; $ui.StatusSub.Text = " $DOT is nvidia-smi installed?" }

    if ($null -ne $t) {
        $ui.TempTxt.Text = "$t"; $ui.TempTxt.Foreground = $(if ($hot) { $P.hotText } else { $accent })
        $ui.BarFill.Width = $innerW * (Clamp (($t - $BarMin) / ($BarMax - $BarMin)) 0 1)
    } else { $ui.TempTxt.Text = 'n/a'; $ui.TempTxt.Foreground = $muted; $ui.BarFill.Width = 0 }
    $ui.BarFill.Background = $accent
    $ui.SparkLine.Stroke = $accent; $ui.SparkDot.Fill = $accent
    $ui.SparkFill.Fill = switch ($state) { 'cool' { $P.coolFill } 'warm' { $P.warmFill } 'hot' { $P.hotFill } }
    if ($histT.Count -gt 0) {
        $lo = ($histT | Measure-Object -Minimum).Minimum - 2; $hi = ($histT | Measure-Object -Maximum).Maximum + 2
        if ($hi - $lo -lt 10) { $mid = ($hi + $lo) / 2; $lo = $mid - 5; $hi = $mid + 5 }
        Set-Spark $ui.SparkLine $ui.SparkFill $ui.SparkDot $histT 110 30 $lo $hi
    }

    # Processor
    $ui.CpuTxt.Text = "$load"
    $ui.CpuTxt.Foreground = if ($load -ge $CpuHot) { $P.hotText } elseif ($load -ge $CpuWarn) { $P.warm } else { $textB }
    $ui.CpuBar.Background = if ($load -ge $CpuHot) { $P.hot } elseif ($load -ge $CpuWarn) { $P.warm } else { $P.cool }
    $ui.CpuBar.Width = $TileBarW * (Clamp ($load / 100) 0 1)
    $ui.CpuSub.Text = if ($load -ge 90) { 'maxed out' } elseif ($load -ge 70) { 'heavy load' } elseif ($load -ge 30) { 'moderate load' } else { 'light load' }
    # Speed (100% = base clock; above = Turbo Boost)
    if ($null -ne $perf) {
        $ui.ClkTxt.Text = '{0:N1}' -f ($baseMHz * $perf / 100 / 1000)
        if ($perf -gt 101) { $ui.ClkTxt.Foreground = $P.warm; $ui.ClkSub.Text = "turbo on $DOT hotter"; $ui.ClkSub.Foreground = $P.warm; $ui.ClkSub.FontWeight = [System.Windows.FontWeights]::Bold }
        else { $ui.ClkTxt.Foreground = $textB; $ui.ClkSub.Text = "turbo off $DOT cooler"; $ui.ClkSub.Foreground = $muted; $ui.ClkSub.FontWeight = [System.Windows.FontWeights]::Normal }
    } else { $ui.ClkTxt.Text = 'n/a'; $ui.ClkSub.Text = '' }
    # Docker
    if ($vmGB -gt 0.05) {
        $ui.DkrTxt.Text = '{0:N1}' -f $vmGB; $ui.DkrUnit.Text = ' GB'; $ui.DkrTxt.Foreground = $textB
        $ui.DkrBar.Width = $TileBarW * (Clamp ($vmGB / $DockerCapGB) 0 1); $ui.DkrBar.Background = $lbl
        $ui.DkrSub.Text = "of $DockerCapGB GB limit"
    } else { $ui.DkrTxt.Text = 'off'; $ui.DkrUnit.Text = ''; $ui.DkrTxt.Foreground = $P.dim; $ui.DkrBar.Width = 0; $ui.DkrSub.Text = 'not running' }
    # Memory
    $rp = $ramUsed / $ramTotGB
    $ui.RamTxt.Text = '{0:N1}' -f $ramUsed
    $ui.RamTxt.Foreground = if ($rp -ge 0.9) { $P.hotText } elseif ($rp -ge 0.8) { $P.warm } else { $textB }
    $ui.RamBar.Background = if ($rp -ge 0.9) { $P.hot } elseif ($rp -ge 0.8) { $P.warm } else { $P.cool }
    $ui.RamBar.Width = $TileBarW * (Clamp $rp 0 1)
    $ui.RamSub.Text = "of $([math]::Round($ramTotGB)) GB used"
    # Battery
    $bt = $shared.battery
    if ($bt) {
        $ui.BatTxt.Text = "$($bt.pct)"
        $onBat = $bt.status -eq 1
        $ui.BatSub.Text = if ($bt.status -ge 6 -and $bt.status -le 9) { 'charging' } elseif ($onBat) { 'on battery' } else { 'plugged in' }
        $low = if ($bt.pct -lt 10) { 'hot' } elseif ($bt.pct -lt 20) { 'warm' } else { 'ok' }
        $ui.BatTxt.Foreground = if ($onBat -and $low -eq 'hot') { $P.hotText } elseif ($onBat -and $low -eq 'warm') { $P.warm } else { $textB }
        $ui.BatSub.Foreground = if ($onBat) { $P.warm } else { $muted }
        $ui.BatFill.Width = 11 * (Clamp ($bt.pct / 100) 0.08 1)
        $ui.BatFill.Fill = if ($low -eq 'hot') { $P.hot } elseif ($low -eq 'warm') { $P.warm } else { $P.good }
    } else { $ui.BatTxt.Text = 'n/a'; $ui.BatUnit.Text = ''; $ui.BatSub.Text = 'no battery'; $ui.BatTxt.Foreground = $textB }
    # Disk C:
    if ($dTot -gt 0) {
        $fp = $dFree / $dTot
        $ui.DskTxt.Text = '{0:N0}' -f ($dFree / 1GB)
        $ui.DskTxt.Foreground = if ($fp -lt 0.05) { $P.hotText } elseif ($fp -lt 0.10) { $P.warm } else { $textB }
        $ui.DskBar.Background = if ($fp -lt 0.05) { $P.hot } elseif ($fp -lt 0.10) { $P.warm } else { $muted }
        $ui.DskBar.Width = $TileBarW * (Clamp (1 - $fp) 0 1)
        $ui.DskSub.Text = "free of {0:N0} GB" -f ($dTot / 1GB)
    }
    # Busiest app
    $tp = $shared.top
    if ($tp) {
        $memTxt = if ($tp.memGB -ge 1) { '{0:N1} GB' -f $tp.memGB } else { '{0:N0} MB' -f ($tp.memGB * 1024) }
        $ui.TopName.Text = $tp.name; $ui.TopVal.Text = "$($tp.cpu)% $DOT $memTxt"; $ui.TopName.Foreground = $textB
    }

    # tray icon follows the thermal state
    if ($state -ne $script:trayState) { $tray.Icon = $Icons[$state]; $script:trayState = $state }
}

function Update-Network($ns, $rxRate, $txRate) {
    $ui = $W.network.ui
    $n0 = $ns.nics | Select-Object -First 1
    if ($null -eq $n0) {
        Set-Pill $ui.NPill $ui.NPillTxt $ui.NPillDot 'Offline' $P.hotSoft $P.hotText; $ui.AdTxt.Text = 'nothing'
    } else {
        $kind = if ($n0.NetworkInterfaceType -eq 'Wireless80211') { 'Wi-Fi' + $(if ($shared.band) { " $DOT " + $shared.band } else { '' }) }
                elseif ($n0.NetworkInterfaceType -match 'Ethernet') { 'Ethernet' } else { [string]$n0.NetworkInterfaceType }
        Set-Pill $ui.NPill $ui.NPillTxt $ui.NPillDot $kind $P.goodSoft $P.good
        $ui.AdTxt.Text = $n0.Name
    }
    $d = Fmt-Rate $rxRate; $ui.DlTxt.Text = $d.f -f $d.v; $ui.DlUnit.Text = $d.u
    $u = Fmt-Rate $txRate; $ui.UlTxt.Text = $u.f -f $u.v; $ui.UlUnit.Text = $u.u
    $ui.TdRx.Text = "$DOWN " + (Fmt-Bytes $S.net.rx); $ui.TdTx.Text = "$UP " + (Fmt-Bytes $S.net.tx)
    $lat = $shared.latency
    if ($null -ne $lat) {
        $ui.LatTxt.Text = "$lat ms"
        if ($lat -lt 30) { $ui.LatQ.Text = " $DOT good"; $ui.LatQ.Foreground = $P.good }
        elseif ($lat -lt 100) { $ui.LatQ.Text = " $DOT ok"; $ui.LatQ.Foreground = $P.warm }
        else { $ui.LatQ.Text = " $DOT slow"; $ui.LatQ.Foreground = $P.hotText }
    } else { $ui.LatTxt.Text = '--'; $ui.LatQ.Text = '' }
    $mx = 100KB
    foreach ($v in $histRx) { if ($v -gt $mx) { $mx = $v } }
    foreach ($v in $histTx) { if ($v -gt $mx) { $mx = $v } }
    Set-Spark $ui.DlLine $ui.DlFill $null $histRx 232 46 0 ($mx * 1.15)
    Set-Spark $ui.UlLine $null $null $histTx 232 46 0 ($mx * 1.15)
}

function New-Thick($l, $tp, $r, $bt) { New-Object System.Windows.Thickness $l, $tp, $r, $bt }
function New-TB([string]$text, [double]$size, $brush, [bool]$mono = $false) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.Foreground = $brush; $tb.VerticalAlignment = 'Center'
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily $(if ($mono) { 'Cascadia Mono, Consolas' } else { 'Segoe UI' })
    $tb
}

function Update-Containers($vmGB) {
    $ui = $W.containers.ui
    $on = [bool]$shared.dockerOn
    $ui.OnPanel.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    $ui.OffPanel.Visibility = if ($on) { 'Collapsed' } else { 'Visible' }
    if (-not $on) {
        Set-Pill $ui.CPill $ui.CPillTxt $ui.CPillDot 'off' $P.box $P.muted
        $ui.StopAll.IsEnabled = $true; $ui.QuitDocker.IsEnabled = $true
        return
    }
    $ui.StartDocker.IsEnabled = $true
    $list = @($shared.containers)
    Set-Pill $ui.CPill $ui.CPillTxt $ui.CPillDot "$($list.Count) running" $P.goodSoft $P.good
    $ui.CMemTxt.Text = '{0:N1} of {1} GB' -f $vmGB, $DockerCapGB
    $ui.CMemBar.Width = 97 * (Clamp ($vmGB / $DockerCapGB) 0 1)
    $cpuSum = 0.0; foreach ($c in $list) { $cpuSum += $c.cpu }
    $cp = $cpuSum / ($DockerCpus * 100)
    $ui.CCpuTxt.Text = '{0:N0}% of {1}' -f ($cp * 100), $DockerCpus
    $ui.CCpuBar.Width = 97 * (Clamp $cp 0 1)
    $ui.CCpuBar.Background = if ($cp -ge 0.9) { $P.hot } elseif ($cp -ge 0.7) { $P.warm } else { $P.cool }

    if ($shared.cVer -eq $script:lastCVer) { return }
    $script:lastCVer = $shared.cVer
    $ui.Rows.Children.Clear()
    $ui.CEmpty.Visibility = if ($list.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $ui.CMore.Text = if ($list.Count -gt 6) { "+ $($list.Count - 6) more $DOT scroll to see all" } else { '' }
    $style = $W.containers.win.FindResource('Btn')
    foreach ($c in $list) {
        $busy = $c.cpu -ge 25
        $rowB = New-Object System.Windows.Controls.Border
        $rowB.CornerRadius = New-Object System.Windows.CornerRadius 7; $rowB.Height = 26; $rowB.Margin = (New-Thick 0 0 0 3); $rowB.Padding = (New-Thick 4 0 3 0)
        $rowB.Background = if ($busy) { $P.rowBusy } else { $P.row }
        $g = New-Object System.Windows.Controls.Grid
        foreach ($wd in @((New-Object System.Windows.GridLength 14), (New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)), (New-Object System.Windows.GridLength 34), (New-Object System.Windows.GridLength 50), [System.Windows.GridLength]::Auto)) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd)
        }
        if ($busy) { $mark = New-Icon 'flame' $P.warm 10; $mark.HorizontalAlignment = 'Center'; $mark.ToolTip = 'busy' }
        else { $mark = New-Object System.Windows.Shapes.Ellipse; $mark.Width = 6; $mark.Height = 6; $mark.Fill = $P.good; $mark.VerticalAlignment = 'Center'; $mark.HorizontalAlignment = 'Center' }
        $nm = New-TB $c.name 10.5 $P.text $true; $nm.Margin = (New-Thick 4 0 4 0); $nm.TextTrimming = 'CharacterEllipsis'; $nm.ToolTip = $c.name
        $cpuT = New-TB ('{0:N0}%' -f $c.cpu) 9.5 $(if ($busy) { $P.warm } else { $P.soft }) $true; $cpuT.HorizontalAlignment = 'Right'
        $memT = New-TB $c.mem 9.5 $P.soft $true; $memT.HorizontalAlignment = 'Right'
        $btn = New-Object System.Windows.Controls.Button; $btn.Style = $style; $btn.Width = 20; $btn.Height = 20; $btn.Margin = (New-Thick 6 0 0 0)
        $btn.Background = if ($busy) { $P.btnHot } else { $P.btn }; $btn.Tag = $c.name; $btn.ToolTip = "Stop $($c.name)"
        $sq = New-Object System.Windows.Shapes.Rectangle; $sq.Width = 7; $sq.Height = 7; $sq.RadiusX = 1.5; $sq.RadiusY = 1.5; $sq.Fill = $(if ($busy) { $P.hotText } else { $P.stopIcon })
        $btn.Content = $sq
        $btn.Add_Click({ param($snd, $evt) Start-DockerCmd ("stop " + [string]$snd.Tag); $snd.IsEnabled = $false })
        $i = 0
        foreach ($el in @($mark, $nm, $cpuT, $memT, $btn)) { [System.Windows.Controls.Grid]::SetColumn($el, $i); [void]$g.Children.Add($el); $i++ }
        $rowB.Child = $g
        [void]$ui.Rows.Children.Add($rowB)
    }
}

function Update-Health {
    $ui = $W.health.ui
    if ($shared.boot) {
        $upT = (Get-Date) - $shared.boot
        $ui.UpTxt.Text = if ($upT.TotalDays -ge 1) { '{0} d {1} h' -f [math]::Floor($upT.TotalDays), $upT.Hours } else { '{0} h {1} m' -f $upT.Hours, $upT.Minutes }
        $ui.BootTxt.Text = $shared.boot.ToString('dd MMM, HH:mm')
    }
    if ($shared.hVer -eq $script:lastHVer) { return }
    $script:lastHVer = $shared.hVer
    $cr = @($shared.crashes)
    $day = @($cr | Where-Object { $_.time -gt (Get-Date).AddHours(-24) }).Count
    if ($day -gt 0) {
        Set-Pill $ui.HPill $ui.HPillTxt $null "$day crash$(if ($day -gt 1) { 'es' }) $DOT 24 h" $P.hotSoft $P.hotText
        $ui.HAlert.Background = $P.hotBox; $ui.HAlertIco.Data = $Geo.alert; $ui.HAlertIco.Stroke = $P.hotText
        $times = switch ($day) { 1 { 'once' } 2 { 'twice' } default { "$day times" } }
        $ui.HAlertMain.Text = "Shut off suddenly $times in the last day"; $ui.HAlertSub.Text = " $DOT likely overheating"
    } elseif ($cr.Count -gt 0) {
        Set-Pill $ui.HPill $ui.HPillTxt $null "$($cr.Count) in 30 days" $P.warmSoft $P.warm
        $ui.HAlert.Background = $P.warmBox; $ui.HAlertIco.Data = $Geo.alert; $ui.HAlertIco.Stroke = $P.warm
        $ui.HAlertMain.Text = "$($cr.Count) unexpected shutdown$(if ($cr.Count -gt 1) { 's' }) this month"; $ui.HAlertSub.Text = " $DOT none today"
    } else {
        Set-Pill $ui.HPill $ui.HPillTxt $null 'all clear' $P.goodSoft $P.good
        $ui.HAlert.Background = $P.coolBox; $ui.HAlertIco.Data = $Geo.check; $ui.HAlertIco.Stroke = $P.cool
        $ui.HAlertMain.Text = 'No unexpected shutdowns'; $ui.HAlertSub.Text = " $DOT all good"
    }

    $ui.CrashRows.Children.Clear()
    if ($cr.Count -eq 0) { [void]$ui.CrashRows.Children.Add((New-TB 'None in the last 30 days' 10 $P.muted)); return }
    foreach ($c in ($cr | Select-Object -First 3)) {
        $recent = $c.time -gt (Get-Date).AddHours(-24)
        $rowB = New-Object System.Windows.Controls.Border
        $rowB.CornerRadius = New-Object System.Windows.CornerRadius 8; $rowB.Padding = (New-Thick 8 6 9 6); $rowB.Margin = (New-Thick 0 0 0 5)
        $rowB.Background = if ($recent) { $P.rowHot } else { $P.row }
        $g = New-Object System.Windows.Controls.Grid
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c0)
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $g.ColumnDefinitions.Add($c1)
        $zap = New-Icon 'zap' $(if ($recent) { $P.hot } else { $P.muted }) 12; $zap.VerticalAlignment = 'Top'; $zap.Margin = (New-Thick 0 1 8 0)
        $sp = New-Object System.Windows.Controls.StackPanel; [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $topG = New-Object System.Windows.Controls.Grid
        $title = if ($c.code -eq 0) { 'Sudden power-off' } else { 'Crash (stop code 0x{0:X})' -f $c.code }
        $when = if ($c.last) { $c.last[0] } else { $c.time }
        $t1 = New-TB $title 10 $P.text; $t1.FontWeight = [System.Windows.FontWeights]::SemiBold
        $t2 = New-TB ($when.ToString('dd MMM HH:mm')) 8.5 $P.soft $true; $t2.HorizontalAlignment = 'Right'
        [void]$topG.Children.Add($t1); [void]$topG.Children.Add($t2)
        if ($c.last) {
            $f = $c.last[1]
            $dk = if ([double]::Parse($f[3], $Inv) -gt 0.05) { "Docker $($f[3]) GB" } else { 'Docker off' }
            $detail = "Before it: GPU $($f[1])$DEG $DOT CPU $($f[2])% $DOT $dk"; $dBrush = $P.soft
        } else { $detail = 'No readings saved before this one'; $dBrush = $P.muted }
        $t3 = New-TB $detail 8.5 $dBrush; $t3.TextWrapping = 'Wrap'; $t3.Margin = (New-Thick 0 2 0 0)
        [void]$sp.Children.Add($topG); [void]$sp.Children.Add($t3)
        [void]$g.Children.Add($zap); [void]$g.Children.Add($sp)
        $rowB.Child = $g
        [void]$ui.CrashRows.Children.Add($rowB)
    }
}

# ---------- main tick ----------
$mainTick = {
    $script:tick++
    # GPU
    $t = $null
    try { $out = & $smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null; if ($out) { $t = [int](($out | Select-Object -First 1).Trim()) } } catch {}
    if ($null -ne $t) { Push $histT $t }
    $load = [math]::Round($cpuLoad.NextValue())
    $perf = if ($cpuPerf) { $cpuPerf.NextValue() } else { $null }
    $ramUsed = $ramTotGB - ($memAvail.NextValue() / 1024)
    $vm = Get-Process vmmemWSL, vmmem -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum
    $vmGB = if ($vm.Count -gt 0) { $vm.Sum / 1GB } else { 0 }
    $dFree = 0; $dTot = 0
    try { $dc = New-Object System.IO.DriveInfo 'C'; $dFree = $dc.AvailableFreeSpace; $dTot = $dc.TotalSize } catch {}

    # network (always sampled so today's totals stay right)
    $ns = Get-NetSample; $rxRate = 0.0; $txRate = 0.0
    if ($script:netPrev) {
        $dt = $ns.t - $script:netPrev.t
        $drx = $ns.rx - $script:netPrev.rx; $dtx = $ns.tx - $script:netPrev.tx
        if ($dt -gt 0 -and $drx -ge 0 -and $dtx -ge 0) { $rxRate = $drx / $dt; $txRate = $dtx / $dt; $S.net.rx += $drx; $S.net.tx += $dtx }
    }
    $script:netPrev = $ns
    $today = Get-Date -Format 'yyyy-MM-dd'
    if ($S.net.day -ne $today) { $S.net.day = $today; $S.net.rx = 0.0; $S.net.tx = 0.0 }
    Push $histRx $rxRate; Push $histTx $txRate

    try { if ($S.widgets.thermal.on)    { Update-Thermal $t $load $perf $ramUsed $vmGB $dFree $dTot } } catch {}
    try { if ($S.widgets.network.on)    { Update-Network $ns $rxRate $txRate } } catch {}
    try { if ($S.widgets.containers.on) { Update-Containers $vmGB } } catch {}
    try { if ($S.widgets.health.on -and ($script:tick % 15 -eq 1 -or $shared.hVer -ne $script:lastHVer)) { Update-Health } } catch {}

    # tray tooltip (max 63 chars)
    $tip = "GPU $(if ($null -ne $t) { "$t$DEG" + 'C' } else { 'n/a' }) $DOT CPU $load% $DOT Docker $(if ($vmGB -gt 0.05) { '{0:N1} GB' -f $vmGB } else { 'off' })"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $tray.Text = $tip

    # readings log every 10 s (for crash forensics)
    if ($script:tick % 5 -eq 0) {
        try {
            $line = [string]::Format($Inv, '{0:yyyy-MM-dd HH:mm:ss},{1},{2},{3:0.0},{4:0.0}', (Get-Date), $(if ($null -ne $t) { $t } else { '' }), $load, $vmGB, $ramUsed)
            [System.IO.File]::AppendAllText($ReadingsPath, $line + "`r`n")
            if ($script:tick % 900 -eq 0 -and (Get-Item $ReadingsPath).Length -gt 3MB) {
                $all = [System.IO.File]::ReadAllLines($ReadingsPath); [System.IO.File]::WriteAllLines($ReadingsPath, $all[($all.Length - 20000)..($all.Length - 1)])
            }
        } catch {}
    }
    # save settings when something changed, and today's network totals every minute
    if ($script:dirty -or $script:tick % 30 -eq 0) { Save-Settings }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick($mainTick)

# ---------- go ----------
foreach ($k in $WidgetKeys) { if ($S.widgets[$k].on) { $W[$k].win.Show() } }
& $mainTick
$timer.Start()
[System.Windows.Threading.Dispatcher]::Run()

# cleanup after dispatcher shutdown
$shared.stop = $true
try { $script:mutex.ReleaseMutex() } catch {}
