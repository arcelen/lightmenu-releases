# LightMenu Print Agent - UI (WPF window)
# ----------------------------------------
# Passive viewer. Polls the agent's /status endpoint for the cards, tails
# events.log for the live log panel, and exposes two action buttons that hit
# endpoints which already exist in main.js.
#
# Closing the window does NOT stop the agent — agent-runner.ps1 keeps it alive
# in the background. Re-opening the icon just reopens this viewer.

# Errors that happen before the window is built would be invisible (hidden
# PowerShell host). Capture everything into ui-error.log so we can diagnose.
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$errorLog  = Join-Path $scriptDir '..\app\ui-error.log'
trap {
    $msg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($_.Exception.Message)`n$($_.ScriptStackTrace)`n"
    try { Add-Content -Path $errorLog -Value $msg } catch {}
    # Surface critical errors so the user sees something instead of silent fail
    try {
        [System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework') | Out-Null
        [System.Windows.MessageBox]::Show("LightMenu UI failed to start.`n`n$($_.Exception.Message)`n`nDetails in ui-error.log", 'LightMenu Print Agent', 'OK', 'Error') | Out-Null
    } catch {}
    exit 1
}

[System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework') | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('PresentationCore')      | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('WindowsBase')           | Out-Null
$appDir      = Resolve-Path "$scriptDir\..\app"
$logoPath    = Join-Path $appDir 'lightmenu.png'
$logPath     = Join-Path $appDir 'events.log'
$statsFile   = Join-Path $appDir 'stats.daily.json'
$statusUrl   = 'http://localhost:3000/status'
$rescanUrl   = 'http://localhost:3000/rescan'

# ─── XAML ────────────────────────────────────────────────────────────────────
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LightMenu Print Agent" Height="780" Width="600"
        MinHeight="580" MinWidth="460"
        WindowStartupLocation="CenterScreen"
        Background="#0F1117">
  <Window.Resources>
    <Style x:Key="CardStyle" TargetType="Border">
      <Setter Property="Background" Value="#1A1D29"/>
      <Setter Property="BorderBrush" Value="#2A2D3A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="14"/>
    </Style>
    <Style x:Key="CardLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7A8295"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="CardValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="ActionBtn" TargetType="Button">
      <Setter Property="Background" Value="#2A2D3A"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#3A3D4A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,10"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#3A3D4A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ───────── HEADER ───────── -->
    <Border Style="{StaticResource CardStyle}" Grid.Row="0" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Image x:Name="LogoImage" Grid.Column="0" Width="56" Height="56" Stretch="Uniform" Margin="0,0,14,0"/>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock x:Name="RestaurantName" Text="LightMenu" FontSize="18" FontWeight="Bold" Foreground="#FFFFFF"/>
          <TextBlock x:Name="VersionText" Text="Print Agent v6.0.0" FontSize="11" Foreground="#7A8295" Margin="0,3,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="StatusDot" Width="11" Height="11" Fill="#6B7280" Margin="0,0,8,0"/>
          <TextBlock x:Name="StatusText" Text="Connecting..." FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ───────── STATUS CARDS ───────── -->
    <Grid Grid.Row="1" Margin="0,0,0,12">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition/>
        <RowDefinition Height="12"/>
        <RowDefinition/>
      </Grid.RowDefinitions>
      <Border Style="{StaticResource CardStyle}" Grid.Row="0" Grid.Column="0">
        <StackPanel>
          <TextBlock Text="PRINTER" Style="{StaticResource CardLabel}"/>
          <TextBlock x:Name="PrinterText" Text="&#x2014;" Style="{StaticResource CardValue}"/>
        </StackPanel>
      </Border>
      <Border Style="{StaticResource CardStyle}" Grid.Row="0" Grid.Column="2">
        <StackPanel>
          <TextBlock Text="TUNNEL" Style="{StaticResource CardLabel}"/>
          <TextBlock x:Name="TunnelText" Text="&#x2014;" Style="{StaticResource CardValue}"/>
        </StackPanel>
      </Border>
      <Border Style="{StaticResource CardStyle}" Grid.Row="2" Grid.Column="0">
        <StackPanel>
          <TextBlock Text="TODAY (SESSION)" Style="{StaticResource CardLabel}"/>
          <TextBlock x:Name="StatsText" Text="&#x2014;" Style="{StaticResource CardValue}"/>
        </StackPanel>
      </Border>
      <Border Style="{StaticResource CardStyle}" Grid.Row="2" Grid.Column="2">
        <StackPanel>
          <TextBlock Text="LAST UPDATE" Style="{StaticResource CardLabel}"/>
          <TextBlock x:Name="UpdateText" Text="&#x2014;" Style="{StaticResource CardValue}"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- ───────── ANALYTICS BAR ───────── -->
    <Border Style="{StaticResource CardStyle}" Grid.Row="2" Margin="0,0,0,12" BorderBrush="#3A2D5A">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="1"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="1"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <!-- Dividers -->
        <Rectangle Grid.Column="1" Fill="#2A2D3A"/>
        <Rectangle Grid.Column="3" Fill="#2A2D3A"/>
        <!-- Stats -->
        <StackPanel Grid.Column="0" HorizontalAlignment="Center">
          <TextBlock Text="PRINTED TODAY" Style="{StaticResource CardLabel}" HorizontalAlignment="Center"/>
          <TextBlock x:Name="AnalyticsPrinted" Text="&#x2014;" Style="{StaticResource CardValue}" HorizontalAlignment="Center" FontSize="22"/>
        </StackPanel>
        <StackPanel Grid.Column="2" HorizontalAlignment="Center">
          <TextBlock Text="FAILED TODAY" Style="{StaticResource CardLabel}" HorizontalAlignment="Center"/>
          <TextBlock x:Name="AnalyticsFailed" Text="&#x2014;" Style="{StaticResource CardValue}" HorizontalAlignment="Center" FontSize="22"/>
        </StackPanel>
        <StackPanel Grid.Column="4" HorizontalAlignment="Center">
          <TextBlock Text="SYNC STATUS" Style="{StaticResource CardLabel}" HorizontalAlignment="Center"/>
          <TextBlock x:Name="AnalyticsSync" Text="&#x2014;" Style="{StaticResource CardValue}" HorizontalAlignment="Center" FontSize="13"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ───────── LIVE LOG ───────── -->
    <Border Style="{StaticResource CardStyle}" Grid.Row="3">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="0,0,0,8">
          <TextBlock Text="LIVE LOG" Style="{StaticResource CardLabel}" VerticalAlignment="Center"/>
          <Button x:Name="ClearBtn" Content="Clear" HorizontalAlignment="Right"
                  Background="Transparent" BorderThickness="0" Foreground="#7A8295" FontSize="10" Cursor="Hand">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border Padding="6,2"><ContentPresenter/></Border>
              </ControlTemplate>
            </Button.Template>
          </Button>
        </Grid>
        <Border Grid.Row="1" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
          <ScrollViewer x:Name="LogScroller" VerticalScrollBarVisibility="Auto">
            <TextBox x:Name="LogBox"
                     Background="Transparent"
                     Foreground="#D1D5DB"
                     BorderThickness="0"
                     FontFamily="Consolas"
                     FontSize="11"
                     IsReadOnly="True"
                     TextWrapping="NoWrap"
                     Padding="8"/>
          </ScrollViewer>
        </Border>
      </Grid>
    </Border>

    <!-- ───────── BUTTONS ───────── -->
    <Grid Grid.Row="4" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Button x:Name="TestBtn" Grid.Column="0" Style="{StaticResource ActionBtn}" Content="&#x1F50D;  Rescan Printers">
        <Button.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#14B8A6" Offset="0"/>
            <GradientStop Color="#06B6D4" Offset="1"/>
          </LinearGradientBrush>
        </Button.Background>
      </Button>
      <Button x:Name="RestartBtn" Grid.Column="2" Style="{StaticResource ActionBtn}" Content="&#x21BB;  Restart Agent"/>
    </Grid>
  </Grid>
</Window>
"@

# ─── Load XAML ──────────────────────────────────────────────────────────────
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Helper to find a named element
function ctl($name) { $window.FindName($name) }

# ─── Logo (header image) ────────────────────────────────────────────────────
if (Test-Path $logoPath) {
    try {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.UriSource = New-Object System.Uri($logoPath, [System.UriKind]::Absolute)
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.EndInit()
        (ctl 'LogoImage').Source = $bi
    } catch {}
}

# ─── Window/taskbar icon ────────────────────────────────────────────────────
$icoPath = Join-Path $appDir 'lightmenu.ico'
if (Test-Path $icoPath) {
    try {
        $iconBi = New-Object System.Windows.Media.Imaging.BitmapImage
        $iconBi.BeginInit()
        $iconBi.UriSource = New-Object System.Uri($icoPath, [System.UriKind]::Absolute)
        $iconBi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $iconBi.EndInit()
        $window.Icon = $iconBi
    } catch {}
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class LMWin32 {
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    public const uint WM_SETICON = 0x0080;
    public const int ICON_BIG = 1;
    public const int ICON_SMALL = 0;
}
'@ -ErrorAction SilentlyContinue

$window.Add_SourceInitialized({
    if (-not (Test-Path $icoPath)) { return }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $icon = New-Object System.Drawing.Icon($icoPath)
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        [LMWin32]::SendMessage($helper.Handle, [LMWin32]::WM_SETICON, [LMWin32]::ICON_BIG,   $icon.Handle) | Out-Null
        [LMWin32]::SendMessage($helper.Handle, [LMWin32]::WM_SETICON, [LMWin32]::ICON_SMALL, $icon.Handle) | Out-Null
    } catch {}
})

# ─── Live log tailing ───────────────────────────────────────────────────────
$logBox       = ctl 'LogBox'
$logScroller  = ctl 'LogScroller'
$script:lastLogLines = ''

function Update-Log {
    if (-not (Test-Path $logPath)) {
        $logBox.Text = "(waiting for agent to start...)"
        return
    }
    $tail = Get-Content $logPath -Tail 200 -ErrorAction SilentlyContinue
    if (-not $tail) { return }
    $text = ($tail -join "`n")
    if ($text -ne $script:lastLogLines) {
        $script:lastLogLines = $text
        $logBox.Text = $text
        $logScroller.ScrollToBottom()
    }
}

# ─── Analytics bar (reads stats.daily.json from disk — works offline) ───────
function Update-Analytics {
    $today = (Get-Date -Format 'yyyy-MM-dd')
    $printed = '—'; $failed = '—'
    if (Test-Path $statsFile) {
        try {
            $s = Get-Content $statsFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($s.date -eq $today) {
                $printed = $s.printed.ToString()
                $failed  = $s.failed.ToString()
                # Sync status
                if ($s.last_sync) {
                    $syncDt  = [datetime]::Parse($s.last_sync).ToLocalTime()
                    $minAgo  = [int]((Get-Date) - $syncDt).TotalMinutes
                    $syncTxt = if ($minAgo -lt 2) { 'Just synced' } elseif ($minAgo -lt 60) { "$minAgo min ago" } else { $syncDt.ToString('HH:mm') }
                    (ctl 'AnalyticsSync').Text       = $syncTxt
                    (ctl 'AnalyticsSync').Foreground = [System.Windows.Media.Brushes]::LimeGreen
                } else {
                    (ctl 'AnalyticsSync').Text       = 'Not synced yet'
                    (ctl 'AnalyticsSync').Foreground = [System.Windows.Media.Brushes]::Orange
                }
            } else {
                $printed = '0'; $failed = '0'
                (ctl 'AnalyticsSync').Text       = 'New day'
                (ctl 'AnalyticsSync').Foreground = [System.Windows.Media.Brushes]::LightGray
            }
        } catch {
            (ctl 'AnalyticsSync').Text       = 'Read error'
            (ctl 'AnalyticsSync').Foreground = [System.Windows.Media.Brushes]::Crimson
        }
    } else {
        (ctl 'AnalyticsSync').Text       = 'No data yet'
        (ctl 'AnalyticsSync').Foreground = [System.Windows.Media.Brushes]::Gray
    }
    (ctl 'AnalyticsPrinted').Text = $printed
    $failedColor = if ($failed -ne '—' -and [int]$failed -gt 0) { [System.Windows.Media.Brushes]::Tomato } else { [System.Windows.Media.Brushes]::White }
    (ctl 'AnalyticsFailed').Text       = $failed
    (ctl 'AnalyticsFailed').Foreground = $failedColor
}

# ─── Status polling ─────────────────────────────────────────────────────────
function Update-Status {
    try {
        $r = Invoke-RestMethod -Uri $statusUrl -TimeoutSec 1 -ErrorAction Stop
        (ctl 'StatusDot').Fill = [System.Windows.Media.Brushes]::LimeGreen
        (ctl 'StatusText').Text = 'Connected'
        (ctl 'VersionText').Text = "Print Agent v$($r.version)"
        if ($r.restaurant_name) { (ctl 'RestaurantName').Text = $r.restaurant_name }

        # Printer
        $printerInfo = '-'
        if ($r.printer) {
            if ($r.printer.mode -eq 'usb-direct') {
                $printerInfo = ('OK  ' + $r.printer.usb + ' (USB direct)')
            } elseif ($r.printer.mode -eq 'usb-spooler') {
                $printerInfo = ('OK  ' + $r.printer.usb + ' (USB spooler)')
            } elseif ($r.printer.mode -eq 'network') {
                $printerInfo = ('OK  ' + $r.printer.ip + ':' + $r.printer.port)
            } else {
                $printerInfo = 'Searching...'
            }
        }
        (ctl 'PrinterText').Text = $printerInfo

        (ctl 'TunnelText').Text = 'OK  print.lightmenu.app'

        # Session stats
        $p = if ($r.printed) { $r.printed } else { 0 }
        $f = if ($r.failed)  { $r.failed }  else { 0 }
        (ctl 'StatsText').Text = ($p.ToString() + ' printed   -   ' + $f.ToString() + ' failed')

        (ctl 'UpdateText').Text = ('v' + $r.version + ' - checked ' + (Get-Date -Format 'HH:mm'))
    } catch {
        (ctl 'StatusDot').Fill = [System.Windows.Media.Brushes]::Crimson
        (ctl 'StatusText').Text = 'Disconnected'
        (ctl 'PrinterText').Text = '-'
        (ctl 'TunnelText').Text = '-'
        (ctl 'StatsText').Text = '-'
        (ctl 'UpdateText').Text = ('checked ' + (Get-Date -Format 'HH:mm'))
    }
}

# ─── Buttons ────────────────────────────────────────────────────────────────
(ctl 'TestBtn').Add_Click({
    try {
        Invoke-RestMethod -Uri $rescanUrl -Method Post -TimeoutSec 10 -ErrorAction Stop | Out-Null
        [System.Windows.MessageBox]::Show("Rescan started. Check the live log for results.", 'LightMenu', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Rescan failed:`n$($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null
    }
})

(ctl 'RestartBtn').Add_Click({
    $result = [System.Windows.MessageBox]::Show(
        "Restart the print agent now? Any in-flight prints will be retried.",
        'LightMenu', 'YesNo', 'Question')
    if ($result -eq 'Yes') {
        Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        # agent-runner.ps1's while-loop will spawn a fresh node.exe within 3 seconds
    }
})

(ctl 'ClearBtn').Add_Click({
    $logBox.Text = ''
    $script:lastLogLines = ''
})

# ─── Timers ─────────────────────────────────────────────────────────────────
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(2)
$statusTimer.Add_Tick({ Update-Status })
$statusTimer.Start()

$logTimer = New-Object System.Windows.Threading.DispatcherTimer
$logTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$logTimer.Add_Tick({ Update-Log })
$logTimer.Start()

$analyticsTimer = New-Object System.Windows.Threading.DispatcherTimer
$analyticsTimer.Interval = [TimeSpan]::FromSeconds(5)
$analyticsTimer.Add_Tick({ Update-Analytics })
$analyticsTimer.Start()

# Initial pulse
Update-Status
Update-Log
Update-Analytics

# ─── Show ───────────────────────────────────────────────────────────────────
$window.ShowDialog() | Out-Null
