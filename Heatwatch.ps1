# Heatwatch - one tray app, four desktop widgets:
#   Thermal (GPU temp + graph, CPU, clock, Docker, RAM, battery, disk, top process)
#   Network (down/up speed + graph, adapter, today's totals, latency)
#   Containers (running Docker containers with stop buttons)
#   System health (uptime, unexpected shutdowns with the last readings before each)
# Layout (which widgets are on, positions, lock) is saved to %APPDATA%\Heatwatch\settings.json
# Readings are logged every 10 s to %APPDATA%\Heatwatch\readings.csv for crash forensics.
# Launch: powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File Heatwatch.ps1

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
        $p = [System.Diagnostics.Process]::Start($psi)
        $task = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit($ms)) { try { $p.Kill() } catch {}; return $null }
        $task.Result
    }
    $prev = @{}; $prevT = [DateTime]::Now; $tick = 0; $cores = [Environment]::ProcessorCount; $gw = $null
    while (-not $shared.stop) {
        # top process by CPU (every 4 s)
        if ($tick % 4 -eq 0) {
            try {
                $now = [DateTime]::Now; $dt = ($now - $prevT).TotalSeconds; $cur = @{}; $best = $null; $bestCpu = -1.0
                foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
                    try { $c = $p.TotalProcessorTime.TotalSeconds } catch { continue }
                    $cur[$p.Id] = $c
                    if ($p.Id -gt 4 -and $prev.ContainsKey($p.Id) -and $dt -gt 0) {
                        $d = ($c - $prev[$p.Id]) / $dt / $cores * 100
                        if ($d -gt $bestCpu) { $bestCpu = $d; $best = $p }
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
                            if ($m -match '^([0-9.]+)\s*([KMG])i?B$') { $num = [double]::Parse($matches[1], $inv); $mb = switch ($matches[2]) { 'K' { $num / 1024 } 'M' { $num } 'G' { $num * 1024 } }; $mem = $(if ($mb -ge 1024) { '{0:N1} GB' -f ($mb / 1024) } else { '{0:N0} MB' -f $mb }) }
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
        # battery, wi-fi band, latency (every 10 s)
        if ($tick % 10 -eq 0) {
            try {
                $b = Get-CimInstance Win32_Battery | Select-Object -First 1
                if ($b) { $shared.battery = @{ pct = [int]$b.EstimatedChargeRemaining; status = [int]$b.BatteryStatus } }
            } catch {}
            try {
                $w = (netsh wlan show interfaces) -join "`n"
                if ($w -match '(?m)^\s*Band\s*:\s*(.+)$') { $shared.band = $matches[1].Trim() }
                elseif ($w -match '(?m)^\s*Radio type\s*:\s*(.+)$') { $shared.band = $matches[1].Trim() }
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
function B([string]$hex) { $b = $conv.ConvertFrom($hex); $b.Freeze(); $b }
$P = @{
  cool = B '#FF5AC8FA'; coolSoft = B '#245AC8FA'; coolFill = B '#1F5AC8FA'
  warm = B '#FFFFB547'; warmSoft = B '#26FFB547'; warmFill = B '#1FFFB547'
  hot  = B '#FFFF6B5E'; hotText = B '#FFFF8A80'; hotFill = B '#29FF6B5E'; hotPillTxt = B '#FF2C1012'; hotSoft = B '#29FF6B5E'
  purple = B '#FFB9A6FF'
  text = B '#FFE8EAEE'; muted = B '#FF8B92A0'; dim = B '#FF6B7280'; soft = B '#FFA9AFBB'
  hotMuted = B '#FFC9A9A9'; hotText2 = B '#FFF2E6E6'
  cardBg = B '#F214161B'; cardBorder = B '#14FFFFFF'; warmBorder = B '#59FFB547'
  hotBg = B '#F52C1012'; hotBorder = B '#B3FF6B5E'
  track = B '#FF2A2E37'; hotTrack = B '#FF3A2226'
  divider = B '#12FFFFFF'; hotDivider = B '#14FFFFFF'
  box = B '#0BFFFFFF'; hotBox = B '#14FFFFFF'; row = B '#09FFFFFF'; rowBusy = B '#14FFB547'; rowHot = B '#12FF6B5E'
  btn = B '#12FFFFFF'; stopIcon = B '#FFC9CDD5'
  ringA = B '#2EFF6B5E'; ringB = B '#73FF6B5E'; none = [System.Windows.Media.Brushes]::Transparent
}
function Clamp([double]$v, [double]$lo, [double]$hi) { [math]::Max($lo, [math]::Min($hi, $v)) }

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

$ThermalCard = @'
<StackPanel>
  <Grid>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Viewbox Width="11" Height="11" Margin="0,0,6,0">
        <Path x:Name="Thermo" Width="24" Height="24" Stroke="#5AC8FA" StrokeThickness="2.2" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
              Data="M14,14.76 V3.5 A2.5,2.5 0 0 0 9,3.5 V14.76 A4.5,4.5 0 1 0 14,14.76 Z"/>
      </Viewbox>
      <TextBlock x:Name="HeadLbl" Text="GPU TEMP" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold" Foreground="#8B92A0"/>
    </StackPanel>
    <Border x:Name="Pill" HorizontalAlignment="Right" CornerRadius="8" Padding="8,2" Background="#245AC8FA">
      <TextBlock x:Name="PillTxt" Text="COOL" FontFamily="Segoe UI" FontSize="9.5" FontWeight="Bold" Foreground="#5AC8FA"/>
    </Border>
  </Grid>
  <Grid Margin="0,8,0,0">
    <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
      <TextBlock x:Name="TempTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="40" FontWeight="SemiBold" Foreground="#5AC8FA" LineHeight="40" LineStackingStrategy="BlockLineHeight"/>
      <TextBlock x:Name="UnitTxt" Text="&#176;C" FontFamily="Segoe UI" FontSize="14" Foreground="#8B92A0" Margin="3,4,0,0" VerticalAlignment="Top"/>
    </StackPanel>
    <Canvas Width="110" Height="36" HorizontalAlignment="Right" VerticalAlignment="Bottom" ClipToBounds="True">
      <Polygon x:Name="SparkFill" Fill="#1F5AC8FA"/>
      <Polyline x:Name="SparkLine" Stroke="#5AC8FA" StrokeThickness="1.8" StrokeLineJoin="Round"/>
      <Ellipse x:Name="SparkDot" Width="5" Height="5" Fill="#5AC8FA" Visibility="Collapsed"/>
    </Canvas>
  </Grid>
  <Grid Margin="0,10,0,0" Height="10">
    <Border x:Name="BarTrack" Height="5" CornerRadius="2.5" Background="#2A2E37" VerticalAlignment="Center"/>
    <Border x:Name="BarFill" Height="5" CornerRadius="2.5" Background="#5AC8FA" HorizontalAlignment="Left" VerticalAlignment="Center" Width="0"/>
    <Border x:Name="MarkWarn" Width="1.5" Height="10" Background="#FFB547" Opacity="0.6" HorizontalAlignment="Left"/>
    <Border x:Name="MarkHot" Width="1.5" Height="10" Background="#FF6B5E" Opacity="0.6" HorizontalAlignment="Left"/>
  </Grid>
  <Grid Margin="0,3,0,0">
    <TextBlock x:Name="MinLbl" Text="40&#176;" FontFamily="Cascadia Mono, Consolas" FontSize="8.5" Foreground="#8B92A0"/>
    <TextBlock x:Name="MaxLbl" Text="95&#176;" FontFamily="Cascadia Mono, Consolas" FontSize="8.5" Foreground="#8B92A0" HorizontalAlignment="Right"/>
  </Grid>
  <Border x:Name="Divider" Height="1" Background="#12FFFFFF" Margin="0,8,0,8"/>
  <UniformGrid Columns="3">
    <StackPanel Margin="0,0,8,0">
      <TextBlock x:Name="CpuLbl" Text="CPU" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
      <TextBlock x:Name="CpuTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="15" FontWeight="SemiBold" Foreground="#E8EAEE" Margin="0,2,0,4"/>
      <Grid Height="3"><Border x:Name="CpuTrack" CornerRadius="1.5" Background="#2A2E37"/><Border x:Name="CpuBar" CornerRadius="1.5" Background="#5AC8FA" HorizontalAlignment="Left" Width="0"/></Grid>
    </StackPanel>
    <StackPanel Margin="0,0,8,0">
      <TextBlock x:Name="ClkLbl" Text="Clock" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
      <TextBlock Margin="0,2,0,2"><Run x:Name="ClkTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="15" FontWeight="SemiBold" Foreground="#E8EAEE"/><Run x:Name="ClkUnit" Text=" GHz" FontFamily="Segoe UI" FontSize="10" Foreground="#8B92A0"/></TextBlock>
      <TextBlock x:Name="ClkSub" Text="base &#183; turbo off" FontFamily="Segoe UI" FontSize="8.5" Foreground="#8B92A0"/>
    </StackPanel>
    <StackPanel>
      <TextBlock x:Name="DkrLbl" Text="Docker" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
      <TextBlock Margin="0,2,0,4"><Run x:Name="DkrTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="15" FontWeight="SemiBold" Foreground="#E8EAEE"/><Run x:Name="DkrUnit" Text="" FontFamily="Segoe UI" FontSize="10" Foreground="#8B92A0"/></TextBlock>
      <Grid Height="3"><Border x:Name="DkrTrack" CornerRadius="1.5" Background="#2A2E37"/><Border x:Name="DkrBar" CornerRadius="1.5" Background="#8B92A0" HorizontalAlignment="Left" Width="0"/></Grid>
    </StackPanel>
  </UniformGrid>
  <UniformGrid Columns="3" Margin="0,10,0,0">
    <StackPanel Margin="0,0,8,0">
      <TextBlock x:Name="RamLbl" Text="RAM" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
      <TextBlock Margin="0,2,0,4"><Run x:Name="RamTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="15" FontWeight="SemiBold" Foreground="#E8EAEE"/><Run x:Name="RamUnit" Text="" FontFamily="Segoe UI" FontSize="10" Foreground="#8B92A0"/></TextBlock>
      <Grid Height="3"><Border x:Name="RamTrack" CornerRadius="1.5" Background="#2A2E37"/><Border x:Name="RamBar" CornerRadius="1.5" Background="#5AC8FA" HorizontalAlignment="Left" Width="0"/></Grid>
    </StackPanel>
    <StackPanel Margin="0,0,8,0">
      <TextBlock x:Name="BatLbl" Text="Battery" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
      <TextBlock x:Name="BatTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="15" FontWeight="SemiBold" Foreground="#E8EAEE" Margin="0,2,0,2"/>
      <TextBlock x:Name="BatSub" Text="" FontFamily="Segoe UI" FontSize="8.5" Foreground="#8B92A0"/>
    </StackPanel>
    <StackPanel>
      <TextBlock x:Name="DskLbl" Text="Disk C:" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
      <TextBlock Margin="0,2,0,4"><Run x:Name="DskTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="15" FontWeight="SemiBold" Foreground="#E8EAEE"/><Run x:Name="DskUnit" Text=" GB free" FontFamily="Segoe UI" FontSize="10" Foreground="#8B92A0"/></TextBlock>
      <Grid Height="3"><Border x:Name="DskTrack" CornerRadius="1.5" Background="#2A2E37"/><Border x:Name="DskBar" CornerRadius="1.5" Background="#8B92A0" HorizontalAlignment="Left" Width="0"/></Grid>
    </StackPanel>
  </UniformGrid>
  <Border x:Name="TopBox" Margin="0,10,0,0" Height="28" CornerRadius="8" Background="#0BFFFFFF" Padding="9,0">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="TopLbl" Text="TOP" FontFamily="Segoe UI" FontSize="8.5" FontWeight="Bold" Foreground="#8B92A0" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBlock x:Name="TopName" Grid.Column="1" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="11" FontWeight="SemiBold" Foreground="#E8EAEE" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="TopVal" Grid.Column="2" Text="" FontFamily="Cascadia Mono, Consolas" FontSize="10" Foreground="#A9AFBB" VerticalAlignment="Center" Margin="8,0,0,0"/>
    </Grid>
  </Border>
</StackPanel>
'@

$NetworkCard = @'
<StackPanel>
  <Grid>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Viewbox Width="11" Height="11" Margin="0,0,6,0">
        <Path Width="24" Height="24" Stroke="#5AC8FA" StrokeThickness="2.2" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
              Data="M7,4 V20 M3,16 L7,20 L11,16 M17,20 V4 M13,8 L17,4 L21,8"/>
      </Viewbox>
      <TextBlock Text="NETWORK" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold" Foreground="#8B92A0"/>
    </StackPanel>
    <Border x:Name="NPill" HorizontalAlignment="Right" CornerRadius="8" Padding="8,2" Background="#245AC8FA">
      <TextBlock x:Name="NPillTxt" Text="--" FontFamily="Segoe UI" FontSize="9.5" FontWeight="Bold" Foreground="#5AC8FA"/>
    </Border>
  </Grid>
  <UniformGrid Columns="2" Margin="0,10,0,0">
    <StackPanel>
      <TextBlock Text="Download" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
      <TextBlock Margin="0,2,0,0"><Run x:Name="DlTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="20" FontWeight="SemiBold" Foreground="#5AC8FA"/><Run x:Name="DlUnit" Text="" FontFamily="Segoe UI" FontSize="10" Foreground="#8B92A0"/></TextBlock>
    </StackPanel>
    <StackPanel>
      <TextBlock Text="Upload" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
      <TextBlock Margin="0,2,0,0"><Run x:Name="UlTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="20" FontWeight="SemiBold" Foreground="#B9A6FF"/><Run x:Name="UlUnit" Text="" FontFamily="Segoe UI" FontSize="10" Foreground="#8B92A0"/></TextBlock>
    </StackPanel>
  </UniformGrid>
  <Canvas Width="232" Height="46" Margin="0,8,0,0" ClipToBounds="True">
    <Rectangle Canvas.Top="45" Width="232" Height="1" Fill="#2A2E37"/>
    <Polygon x:Name="DlFill" Fill="#215AC8FA"/>
    <Polyline x:Name="DlLine" Stroke="#5AC8FA" StrokeThickness="1.6" StrokeLineJoin="Round"/>
    <Polyline x:Name="UlLine" Stroke="#B9A6FF" StrokeThickness="1.6" StrokeLineJoin="Round"/>
  </Canvas>
  <Border Height="1" Background="#12FFFFFF" Margin="0,8,0,6"/>
  <Grid Margin="0,2">
    <TextBlock Text="Adapter" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
    <TextBlock x:Name="AdTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="10" Foreground="#E8EAEE" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis" MaxWidth="170"/>
  </Grid>
  <Grid Margin="0,2">
    <TextBlock Text="Today" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
    <TextBlock HorizontalAlignment="Right" FontFamily="Cascadia Mono, Consolas" FontSize="10" Foreground="#E8EAEE"><Run x:Name="TdRx" Text="--" Foreground="#5AC8FA"/><Run Text=" &#183; "/><Run x:Name="TdTx" Text="--" Foreground="#B9A6FF"/></TextBlock>
  </Grid>
  <Grid Margin="0,2">
    <TextBlock Text="Latency" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/>
    <TextBlock x:Name="LatTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="10" Foreground="#E8EAEE" HorizontalAlignment="Right"/>
  </Grid>
</StackPanel>
'@

$ContainersCard = @'
<StackPanel>
  <Grid>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Viewbox Width="11" Height="11" Margin="0,0,6,0">
        <Path Width="24" Height="24" Stroke="#5AC8FA" StrokeThickness="2.2" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
              Data="M21,8 L12,3 L3,8 V16 L12,21 L21,16 Z M3,8 L12,13 L21,8 M12,13 V21"/>
      </Viewbox>
      <TextBlock Text="CONTAINERS" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold" Foreground="#8B92A0"/>
    </StackPanel>
    <Border x:Name="CPill" HorizontalAlignment="Right" CornerRadius="8" Padding="8,2" Background="#245AC8FA">
      <TextBlock x:Name="CPillTxt" Text="--" FontFamily="Segoe UI" FontSize="9.5" FontWeight="Bold" Foreground="#5AC8FA"/>
    </Border>
  </Grid>
  <StackPanel x:Name="OnPanel" Margin="0,10,0,0">
    <UniformGrid Columns="2">
      <StackPanel Margin="0,0,8,0">
        <Grid><TextBlock Text="Memory" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/><TextBlock x:Name="CMemTxt" Text="--" HorizontalAlignment="Right" FontFamily="Cascadia Mono, Consolas" FontSize="10" Foreground="#E8EAEE"/></Grid>
        <Grid Height="3" Margin="0,5,0,0"><Border CornerRadius="1.5" Background="#2A2E37"/><Border x:Name="CMemBar" CornerRadius="1.5" Background="#5AC8FA" HorizontalAlignment="Left" Width="0"/></Grid>
      </StackPanel>
      <StackPanel Margin="8,0,0,0">
        <Grid><TextBlock Text="CPU" FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0"/><TextBlock x:Name="CCpuTxt" Text="--" HorizontalAlignment="Right" FontFamily="Cascadia Mono, Consolas" FontSize="10" Foreground="#E8EAEE"/></Grid>
        <Grid Height="3" Margin="0,5,0,0"><Border CornerRadius="1.5" Background="#2A2E37"/><Border x:Name="CCpuBar" CornerRadius="1.5" Background="#5AC8FA" HorizontalAlignment="Left" Width="0"/></Grid>
      </StackPanel>
    </UniformGrid>
    <ScrollViewer MaxHeight="174" Margin="0,10,0,0" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="Rows"/>
    </ScrollViewer>
    <TextBlock x:Name="CEmpty" Text="No containers running" FontFamily="Segoe UI" FontSize="10" Foreground="#8B92A0" Margin="0,2,0,4" Visibility="Collapsed"/>
    <UniformGrid Columns="2" Margin="0,8,0,0">
      <Button x:Name="StopAll" Style="{StaticResource Btn}" Height="26" Margin="0,0,4,0" Background="Transparent" BorderBrush="#8CFF6B5E" BorderThickness="1" Foreground="#FF8A80" Content="Stop all"/>
      <Button x:Name="QuitDocker" Style="{StaticResource Btn}" Height="26" Margin="4,0,0,0" Content="Quit Docker"/>
    </UniformGrid>
  </StackPanel>
  <StackPanel x:Name="OffPanel" Margin="0,10,0,0" Visibility="Collapsed">
    <TextBlock Text="Docker is off" FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold" Foreground="#E8EAEE"/>
    <TextBlock Text="Containers show here while Docker is running." FontFamily="Segoe UI" FontSize="9.5" Foreground="#8B92A0" Margin="0,2,0,8" TextWrapping="Wrap"/>
    <Button x:Name="StartDocker" Style="{StaticResource Btn}" Height="26" Content="Start Docker"/>
  </StackPanel>
</StackPanel>
'@

$HealthCard = @'
<StackPanel>
  <Grid>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Viewbox Width="11" Height="11" Margin="0,0,6,0">
        <Path Width="24" Height="24" Stroke="#FF6B5E" StrokeThickness="2.2" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
              Data="M22,12 H18 L15,20 L9,4 L6,12 H2"/>
      </Viewbox>
      <TextBlock Text="SYSTEM HEALTH" FontFamily="Segoe UI" FontSize="10" FontWeight="SemiBold" Foreground="#8B92A0"/>
    </StackPanel>
    <Border x:Name="HPill" HorizontalAlignment="Right" CornerRadius="8" Padding="8,2" Background="#245AC8FA">
      <TextBlock x:Name="HPillTxt" Text="--" FontFamily="Segoe UI" FontSize="9.5" FontWeight="Bold" Foreground="#5AC8FA"/>
    </Border>
  </Grid>
  <Border Margin="0,10,0,0" CornerRadius="8" Background="#0BFFFFFF" Padding="10,6">
    <Grid>
      <StackPanel>
        <TextBlock Text="Up for" FontFamily="Segoe UI" FontSize="8.5" Foreground="#8B92A0"/>
        <TextBlock x:Name="UpTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="13" FontWeight="SemiBold" Foreground="#E8EAEE"/>
      </StackPanel>
      <StackPanel HorizontalAlignment="Right">
        <TextBlock Text="Started" FontFamily="Segoe UI" FontSize="8.5" Foreground="#8B92A0" HorizontalAlignment="Right"/>
        <TextBlock x:Name="BootTxt" Text="--" FontFamily="Cascadia Mono, Consolas" FontSize="10" Foreground="#E8EAEE" HorizontalAlignment="Right" Margin="0,2,0,0"/>
      </StackPanel>
    </Grid>
  </Border>
  <TextBlock Text="UNEXPECTED SHUTDOWNS &#183; 30 DAYS" FontFamily="Segoe UI" FontSize="8.5" FontWeight="Bold" Foreground="#8B92A0" Margin="0,10,0,6"/>
  <StackPanel x:Name="CrashRows"/>
  <TextBlock TextWrapping="Wrap" FontFamily="Segoe UI" FontSize="8.5" Foreground="#8B92A0" Margin="0,4,0,8" Text="Readings are saved every 10 s, so new crashes show the temperatures just before them."/>
  <Button x:Name="OpenEv" Style="{StaticResource Btn}" Height="26" Content="Open Event Viewer"/>
</StackPanel>
'@

# ---------- widget windows ----------
$W = @{}
function New-Widget([string]$key, [string]$cardXaml) {
    $xml = $WinTpl.Replace('%TITLE%', "Heatwatch - $key").Replace('%STYLE%', $BtnStyle).Replace('%CARD%', $cardXaml)
    $win = [Windows.Markup.XamlReader]::Parse($xml)
    $win.Tag = $key
    $cardEl = $win.FindName('Card'); $cardEl.Tag = $key
    # NOTE: PowerShell variable names are case-insensitive - never name a handler param $s / $w (would hide $S / $W)
    $cardEl.Add_MouseLeftButtonDown({ param($snd, $evt) if (-not $S.lock) { try { [System.Windows.Window]::GetWindow($snd).DragMove() } catch {} } })
    $win.Add_LocationChanged({ $script:dirty = $true })
    $win.Add_Loaded({ param($snd, $evt) Place-Widget $snd })
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
UI 'thermal' 'Ring','Card','Thermo','HeadLbl','Pill','PillTxt','TempTxt','UnitTxt','SparkFill','SparkLine','SparkDot','BarTrack','BarFill','MarkWarn','MarkHot',
             'MinLbl','MaxLbl','Divider','CpuLbl','CpuTxt','CpuTrack','CpuBar','ClkLbl','ClkTxt','ClkUnit','ClkSub','DkrLbl','DkrTxt','DkrUnit','DkrTrack','DkrBar',
             'RamLbl','RamTxt','RamUnit','RamTrack','RamBar','BatLbl','BatTxt','BatSub','DskLbl','DskTxt','DskUnit','DskTrack','DskBar','TopBox','TopLbl','TopName','TopVal'
[void](New-Widget 'network' $NetworkCard)
UI 'network' 'NPill','NPillTxt','DlTxt','DlUnit','UlTxt','UlUnit','DlFill','DlLine','UlLine','AdTxt','TdRx','TdTx','LatTxt'
[void](New-Widget 'containers' $ContainersCard)
UI 'containers' 'CPill','CPillTxt','OnPanel','OffPanel','CMemTxt','CMemBar','CCpuTxt','CCpuBar','Rows','CEmpty','StopAll','QuitDocker','StartDocker'
[void](New-Widget 'health' $HealthCard)
UI 'health' 'HPill','HPillTxt','UpTxt','BootTxt','CrashRows','OpenEv'

$tu = $W.thermal.ui
$innerW = 232
$tu.MarkWarn.Margin = New-Object System.Windows.Thickness ($innerW * ($WarnTemp - $BarMin) / ($BarMax - $BarMin)), 0, 0, 0
$tu.MarkHot.Margin  = New-Object System.Windows.Thickness ($innerW * ($HotTemp  - $BarMin) / ($BarMax - $BarMin)), 0, 0, 0

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
    $W[$key].placed = $true
}

# ---------- tray ----------
function New-TrayIcon([string]$hex) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
    $g.FillEllipse($br, 8, 16, 16, 16)
    $g.FillRectangle($br, 12, 5, 8, 16)
    $g.FillEllipse($br, 12, 1, 8, 8)
    $g.Dispose()
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
$labels = @{ thermal = 'Thermal'; network = 'Network'; containers = 'Containers'; health = 'System health' }
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
function Fmt-Bytes([double]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) }
}
function Push([System.Collections.Generic.List[double]]$list, [double]$v) { $list.Add($v); while ($list.Count -gt $HistoryLen) { $list.RemoveAt(0) } }

function Set-Spark($line, $fill, $dot, $data, [double]$w, [double]$h, [double]$lo, [double]$hi) {
    $n = $data.Count
    if ($n -lt 2) { $line.Points = $null; if ($fill) { $fill.Points = $null }; if ($dot) { $dot.Visibility = 'Collapsed' }; return }
    $pad = 3.0; $step = ($w - $pad) / ($HistoryLen - 1); $x0 = $w - $pad - $step * ($n - 1)
    $pl = New-Object System.Windows.Media.PointCollection
    $pa = New-Object System.Windows.Media.PointCollection
    $pa.Add((New-Object System.Windows.Point $x0, $h))
    for ($i = 0; $i -lt $n; $i++) {
        $pt = New-Object System.Windows.Point ($x0 + $step * $i), ($pad + ($h - 2 * $pad) * (1 - (Clamp (($data[$i] - $lo) / ($hi - $lo)) 0 1)))
        $pl.Add($pt); $pa.Add($pt)
    }
    $pa.Add((New-Object System.Windows.Point ($w - $pad), $h))
    $line.Points = $pl; if ($fill) { $fill.Points = $pa }
    if ($dot) {
        $last = $pl[$pl.Count - 1]
        [System.Windows.Controls.Canvas]::SetLeft($dot, $last.X - 2.5); [System.Windows.Controls.Canvas]::SetTop($dot, $last.Y - 2.5)
        $dot.Visibility = 'Visible'
    }
}

# ---------- widget renderers ----------
function Update-Thermal($t, $load, $perf, $ramUsed, $vmGB, $dFree, $dTot) {
    $ui = $W.thermal.ui
    $state = if ($null -eq $t) { 'cool' } elseif ($t -ge $HotTemp) { 'hot' } elseif ($t -ge $WarnTemp) { 'warm' } else { 'cool' }
    $hot = $state -eq 'hot'
    $accent = $P[$state]
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
    $ui.TopBox.Background = if ($hot) { $P.hotBox } else { $P.box }
    foreach ($l in 'HeadLbl','UnitTxt','MinLbl','MaxLbl','CpuLbl','ClkLbl','DkrLbl','ClkUnit','DkrUnit','RamLbl','RamUnit','BatLbl','DskLbl','DskUnit','TopLbl') { $ui[$l].Foreground = $muted }
    foreach ($l in 'BarTrack','CpuTrack','DkrTrack','RamTrack','DskTrack') { $ui[$l].Background = $trackB }
    $ui.Thermo.Stroke = $accent
    $ui.MarkHot.Background = if ($hot) { [System.Windows.Media.Brushes]::White } else { $P.hot }

    switch ($state) {
        'cool' { $ui.Pill.Background = $P.coolSoft; $ui.PillTxt.Foreground = $P.cool; $ui.PillTxt.Text = 'COOL' }
        'warm' { $ui.Pill.Background = $P.warmSoft; $ui.PillTxt.Foreground = $P.warm; $ui.PillTxt.Text = 'WARM' }
        'hot'  { $ui.Pill.Background = $P.hot; $ui.PillTxt.Foreground = $P.hotPillTxt; $ui.PillTxt.Text = "$([char]0x26A0) HOT" }
    }

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
        Set-Spark $ui.SparkLine $ui.SparkFill $ui.SparkDot $histT 110 36 $lo $hi
    }

    # CPU
    $ui.CpuTxt.Text = "$load%"
    $ui.CpuTxt.Foreground = if ($load -ge $CpuHot) { $P.hotText } elseif ($load -ge $CpuWarn) { $P.warm } else { $textB }
    $ui.CpuBar.Background = if ($load -ge $CpuHot) { $P.hot } elseif ($load -ge $CpuWarn) { $P.warm } else { $P.cool }
    $ui.CpuBar.Width = $TileBarW * (Clamp ($load / 100) 0 1)
    # Clock
    if ($null -ne $perf) {
        $ui.ClkTxt.Text = '{0:N1}' -f ($baseMHz * $perf / 100 / 1000)
        if ($perf -gt 101) { $ui.ClkTxt.Foreground = $P.warm; $ui.ClkSub.Text = 'TURBO ON'; $ui.ClkSub.Foreground = $P.warm; $ui.ClkSub.FontWeight = [System.Windows.FontWeights]::Bold }
        else { $ui.ClkTxt.Foreground = $textB; $ui.ClkSub.Text = "base $DOT turbo off"; $ui.ClkSub.Foreground = $muted; $ui.ClkSub.FontWeight = [System.Windows.FontWeights]::Normal }
    } else { $ui.ClkTxt.Text = 'n/a'; $ui.ClkSub.Text = '' }
    # Docker
    if ($vmGB -gt 0.05) {
        $ui.DkrTxt.Text = '{0:N1}' -f $vmGB; $ui.DkrUnit.Text = ' GB'; $ui.DkrTxt.Foreground = $textB
        $ui.DkrBar.Width = $TileBarW * (Clamp ($vmGB / $DockerCapGB) 0 1); $ui.DkrBar.Background = $muted
    } else { $ui.DkrTxt.Text = 'off'; $ui.DkrUnit.Text = ''; $ui.DkrTxt.Foreground = $P.dim; $ui.DkrBar.Width = 0 }
    # RAM
    $rp = $ramUsed / $ramTotGB
    $ui.RamTxt.Text = '{0:N1}' -f $ramUsed; $ui.RamUnit.Text = " GB"
    $ui.RamTxt.Foreground = if ($rp -ge 0.9) { $P.hotText } elseif ($rp -ge 0.8) { $P.warm } else { $textB }
    $ui.RamBar.Background = if ($rp -ge 0.9) { $P.hot } elseif ($rp -ge 0.8) { $P.warm } else { $P.cool }
    $ui.RamBar.Width = $TileBarW * (Clamp $rp 0 1)
    # Battery
    $bt = $shared.battery
    if ($bt) {
        $ui.BatTxt.Text = "$($bt.pct)%"
        $onBat = $bt.status -eq 1
        $ui.BatSub.Text = if ($bt.status -ge 6 -and $bt.status -le 9) { 'charging' } elseif ($onBat) { 'on battery' } else { 'plugged in' }
        $ui.BatTxt.Foreground = if ($onBat -and $bt.pct -lt 10) { $P.hotText } elseif ($onBat -and $bt.pct -lt 20) { $P.warm } else { $textB }
        $ui.BatSub.Foreground = if ($onBat) { $P.warm } else { $muted }
    } else { $ui.BatTxt.Text = 'n/a'; $ui.BatSub.Text = ''; $ui.BatTxt.Foreground = $textB }
    # Disk C:
    if ($dTot -gt 0) {
        $fp = $dFree / $dTot
        $ui.DskTxt.Text = '{0:N0}' -f ($dFree / 1GB)
        $ui.DskTxt.Foreground = if ($fp -lt 0.05) { $P.hotText } elseif ($fp -lt 0.10) { $P.warm } else { $textB }
        $ui.DskBar.Background = if ($fp -lt 0.05) { $P.hot } elseif ($fp -lt 0.10) { $P.warm } else { $muted }
        $ui.DskBar.Width = $TileBarW * (Clamp (1 - $fp) 0 1)
    }
    # Top process
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
        $ui.NPillTxt.Text = 'OFFLINE'; $ui.NPill.Background = $P.hotSoft; $ui.NPillTxt.Foreground = $P.hotText; $ui.AdTxt.Text = 'none'
    } else {
        if ($n0.NetworkInterfaceType -eq 'Wireless80211') { $ui.NPillTxt.Text = 'WI-FI' + $(if ($shared.band) { " $DOT " + $shared.band } else { '' }) }
        elseif ($n0.NetworkInterfaceType -match 'Ethernet') { $ui.NPillTxt.Text = 'ETHERNET' }
        else { $ui.NPillTxt.Text = ([string]$n0.NetworkInterfaceType).ToUpper() }
        $ui.NPill.Background = $P.coolSoft; $ui.NPillTxt.Foreground = $P.cool
        $ui.AdTxt.Text = $n0.Name
    }
    $d = Fmt-Rate $rxRate; $ui.DlTxt.Text = $d.f -f $d.v; $ui.DlUnit.Text = $d.u
    $u = Fmt-Rate $txRate; $ui.UlTxt.Text = $u.f -f $u.v; $ui.UlUnit.Text = $u.u
    $ui.TdRx.Text = "$DOWN " + (Fmt-Bytes $S.net.rx); $ui.TdTx.Text = "$UP " + (Fmt-Bytes $S.net.tx)
    $ui.LatTxt.Text = if ($null -ne $shared.latency) { "$($shared.latency) ms" } else { '--' }
    $mx = 100KB
    foreach ($v in $histRx) { if ($v -gt $mx) { $mx = $v } }
    foreach ($v in $histTx) { if ($v -gt $mx) { $mx = $v } }
    Set-Spark $ui.DlLine $ui.DlFill $null $histRx 232 46 0 ($mx * 1.15)
    Set-Spark $ui.UlLine $null $null $histTx 232 46 0 ($mx * 1.15)
}

function New-Thick($l, $t, $r, $b) { New-Object System.Windows.Thickness $l, $t, $r, $b }
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
        $ui.CPillTxt.Text = 'OFF'; $ui.CPill.Background = $P.box; $ui.CPillTxt.Foreground = $P.muted
        $ui.StopAll.IsEnabled = $true; $ui.QuitDocker.IsEnabled = $true
        return
    }
    $ui.StartDocker.IsEnabled = $true
    $list = @($shared.containers)
    $ui.CPillTxt.Text = "$($list.Count) RUNNING"; $ui.CPill.Background = $P.coolSoft; $ui.CPillTxt.Foreground = $P.cool
    $ui.CMemTxt.Text = '{0:N1} / {1} GB' -f $vmGB, $DockerCapGB
    $ui.CMemBar.Width = 108 * (Clamp ($vmGB / $DockerCapGB) 0 1)
    $cpuSum = 0.0; foreach ($c in $list) { $cpuSum += $c.cpu }
    $cp = $cpuSum / ($DockerCpus * 100)
    $ui.CCpuTxt.Text = '{0:N0}% of {1}' -f ($cp * 100), $DockerCpus
    $ui.CCpuBar.Width = 108 * (Clamp $cp 0 1)
    $ui.CCpuBar.Background = if ($cp -ge 0.9) { $P.hot } elseif ($cp -ge 0.7) { $P.warm } else { $P.cool }

    if ($shared.cVer -eq $script:lastCVer) { return }
    $script:lastCVer = $shared.cVer
    $ui.Rows.Children.Clear()
    $ui.CEmpty.Visibility = if ($list.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $style = $W.containers.win.FindResource('Btn')
    foreach ($c in $list) {
        $busy = $c.cpu -ge 25
        $b = New-Object System.Windows.Controls.Border
        $b.CornerRadius = New-Object System.Windows.CornerRadius 7; $b.Height = 26; $b.Margin = (New-Thick 0 0 0 3); $b.Padding = (New-Thick 8 0 3 0)
        $b.Background = if ($busy) { $P.rowBusy } else { $P.row }
        $g = New-Object System.Windows.Controls.Grid
        foreach ($wd in @([System.Windows.GridLength]::Auto, (New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)), (New-Object System.Windows.GridLength 34), (New-Object System.Windows.GridLength 50), [System.Windows.GridLength]::Auto)) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd)
        }
        $dotEl = New-Object System.Windows.Shapes.Ellipse; $dotEl.Width = 6; $dotEl.Height = 6; $dotEl.Fill = $(if ($busy) { $P.warm } else { $P.cool }); $dotEl.VerticalAlignment = 'Center'
        $nm = New-TB $c.name 10.5 $P.text $true; $nm.Margin = (New-Thick 7 0 4 0); $nm.TextTrimming = 'CharacterEllipsis'; $nm.ToolTip = $c.name
        $cpuT = New-TB ('{0:N0}%' -f $c.cpu) 9.5 $(if ($busy) { $P.warm } else { $P.soft }) $true; $cpuT.HorizontalAlignment = 'Right'
        $memT = New-TB $c.mem 9.5 $P.soft $true; $memT.HorizontalAlignment = 'Right'
        $btn = New-Object System.Windows.Controls.Button; $btn.Style = $style; $btn.Width = 20; $btn.Height = 20; $btn.Margin = (New-Thick 6 0 0 0)
        $btn.Background = $P.btn; $btn.Tag = $c.name; $btn.ToolTip = "Stop $($c.name)"
        $sq = New-Object System.Windows.Shapes.Rectangle; $sq.Width = 7; $sq.Height = 7; $sq.RadiusX = 1.5; $sq.RadiusY = 1.5; $sq.Fill = $P.stopIcon
        $btn.Content = $sq
        $btn.Add_Click({ param($snd, $evt) Start-DockerCmd ("stop " + [string]$snd.Tag); $snd.IsEnabled = $false })
        $i = 0
        foreach ($el in @($dotEl, $nm, $cpuT, $memT, $btn)) { [System.Windows.Controls.Grid]::SetColumn($el, $i); [void]$g.Children.Add($el); $i++ }
        $b.Child = $g
        [void]$ui.Rows.Children.Add($b)
    }
}

function Update-Health {
    $ui = $W.health.ui
    if ($shared.boot) {
        $up = (Get-Date) - $shared.boot
        $ui.UpTxt.Text = if ($up.TotalDays -ge 1) { '{0} d {1} h' -f [math]::Floor($up.TotalDays), $up.Hours } else { '{0} h {1} m' -f $up.Hours, $up.Minutes }
        $ui.BootTxt.Text = $shared.boot.ToString('dd MMM, HH:mm')
    }
    if ($shared.hVer -eq $script:lastHVer) { return }
    $script:lastHVer = $shared.hVer
    $cr = @($shared.crashes)
    $day = @($cr | Where-Object { $_.time -gt (Get-Date).AddHours(-24) }).Count
    if ($day -gt 0) { $ui.HPillTxt.Text = "$day CRASH$(if ($day -gt 1) { 'ES' }) $DOT 24 H"; $ui.HPill.Background = $P.hotSoft; $ui.HPillTxt.Foreground = $P.hotText }
    elseif ($cr.Count -gt 0) { $ui.HPillTxt.Text = "$($cr.Count) IN 30 DAYS"; $ui.HPill.Background = $P.warmSoft; $ui.HPillTxt.Foreground = $P.warm }
    else { $ui.HPillTxt.Text = 'ALL CLEAR'; $ui.HPill.Background = $P.coolSoft; $ui.HPillTxt.Foreground = $P.cool }

    $ui.CrashRows.Children.Clear()
    if ($cr.Count -eq 0) { [void]$ui.CrashRows.Children.Add((New-TB 'None in the last 30 days' 10 $P.muted)); return }
    foreach ($c in ($cr | Select-Object -First 3)) {
        $recent = $c.time -gt (Get-Date).AddHours(-24)
        $b = New-Object System.Windows.Controls.Border
        $b.CornerRadius = New-Object System.Windows.CornerRadius 8; $b.Padding = (New-Thick 9 6 9 6); $b.Margin = (New-Thick 0 0 0 5)
        $b.Background = if ($recent) { $P.rowHot } else { $P.row }
        $g = New-Object System.Windows.Controls.Grid
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c0)
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $g.ColumnDefinitions.Add($c1)
        $dotEl = New-Object System.Windows.Shapes.Ellipse; $dotEl.Width = 6; $dotEl.Height = 6; $dotEl.Fill = $(if ($recent) { $P.hot } else { $P.muted })
        $dotEl.VerticalAlignment = 'Top'; $dotEl.Margin = (New-Thick 0 5 8 0)
        $sp = New-Object System.Windows.Controls.StackPanel; [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $top = New-Object System.Windows.Controls.Grid
        $title = if ($c.code -eq 0) { 'Sudden power loss' } else { 'Crash (stop code 0x{0:X})' -f $c.code }
        $when = if ($c.last) { $c.last[0] } else { $c.time }
        $t1 = New-TB $title 10.5 $P.text; $t1.FontWeight = [System.Windows.FontWeights]::SemiBold
        $t2 = New-TB ($when.ToString('dd MMM HH:mm')) 9.5 $P.soft $true; $t2.HorizontalAlignment = 'Right'
        [void]$top.Children.Add($t1); [void]$top.Children.Add($t2)
        if ($c.last) {
            $f = $c.last[1]
            $dk = if ([double]::Parse($f[3], $Inv) -gt 0.05) { "Docker $($f[3]) GB" } else { 'Docker off' }
            $detail = "Last reading: GPU $($f[1])$DEG $DOT CPU $($f[2])% $DOT $dk"
        } else { $detail = "Restart time shown $DOT no readings before it" }
        $t3 = New-TB $detail 9 $P.soft; $t3.TextWrapping = 'Wrap'; $t3.Margin = (New-Thick 0 2 0 0)
        [void]$sp.Children.Add($top); [void]$sp.Children.Add($t3)
        [void]$g.Children.Add($dotEl); [void]$g.Children.Add($sp)
        $b.Child = $g
        [void]$ui.CrashRows.Children.Add($b)
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
