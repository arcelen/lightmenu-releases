# LightMenu Print Agent - Multi-page WPF UI
# ------------------------------------------
# Pages: Dashboard, Analytics, Bills, Daily Report, Staff
# All data sourced from the agent's HTTP endpoints (localhost:3000).
# Works fully offline - the agent stores everything locally.

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$errorLog  = Join-Path $scriptDir '..\app\ui-error.log'
trap {
    $msg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($_.Exception.Message)`n$($_.ScriptStackTrace)`n"
    try { Add-Content -Path $errorLog -Value $msg } catch {}
    try {
        [System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework') | Out-Null
        [System.Windows.MessageBox]::Show("LightMenu UI failed to start.`n`n$($_.Exception.Message)`n`nDetails in ui-error.log", 'LightMenu Station', 'OK', 'Error') | Out-Null
    } catch {}
    exit 1
}

[System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework') | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('PresentationCore')      | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('WindowsBase')           | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic') | Out-Null  # InputBox for quick prompts

# .NET caps concurrent connections per host at 2 by default. Our 4-5s polling
# timers (status/floor/analytics) hold both slots open via keep-alive, so a slow
# request like the AI chat (POST /local/ai, ~4s) would queue forever waiting for
# a slot that never frees — the completion event never fires and the UI hangs on
# "Thinking...". Raise the ceiling so long requests always get their own socket.
[System.Net.ServicePointManager]::DefaultConnectionLimit = 20
[System.Net.ServicePointManager]::Expect100Continue      = $false

# Give this process its own taskbar identity. Without it Windows ties the taskbar
# button to the PowerShell host and shows the PowerShell icon; with an explicit
# AppUserModelID it uses the window's own icon (the LightMenu logo) instead.
try {
    Add-Type -Namespace LMShell -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern void SetCurrentProcessExplicitAppUserModelID([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
'@ -ErrorAction SilentlyContinue
    [LMShell.Native]::SetCurrentProcessExplicitAppUserModelID('LightMenu.Station')
} catch {}

$appDir   = Resolve-Path "$scriptDir\..\app"
$logoPath = Join-Path $appDir 'lightmenu.png'
$logPath  = Join-Path $appDir 'events.log'
$base     = 'http://localhost:3000'
$statusUrl = "$base/status"
$rescanUrl = "$base/rescan"

$script:currencySymbol = 'EUR'
$script:lang = 'en'

function Format-Money($amount) {
    $sym = $script:currencySymbol
    $n   = [double]$amount
    return ('{0} {1:N2}' -f $sym, $n)
}

# ─── XAML ────────────────────────────────────────────────────────────────────
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LightMenu Station" Height="820" Width="940"
        MinHeight="640" MinWidth="780"
        WindowStartupLocation="CenterScreen"
        Background="#0F1117"
        TextElement.Foreground="#FFFFFF">
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
    <Style x:Key="BigValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#14B8A6"/>
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,6,0,0"/>
    </Style>
    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#7A8295"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1A1D29"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
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
    <Style x:Key="PeriodBtn" TargetType="Button" BasedOn="{StaticResource ActionBtn}">
      <Setter Property="Background" Value="#1A1D29"/>
      <Setter Property="Foreground" Value="#9CA3AF"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <!-- Control Center homepage card (icon + title + description, hover lift) -->
    <Style x:Key="HomeCard" TargetType="Button">
      <Setter Property="Background" Value="#1A1D29"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="7"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="#2A2D3A"
                    BorderThickness="1" CornerRadius="14" Padding="18">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#20242F"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#14B8A6"/>
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
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- ───────── ANIMATED BACKGROUND (drifting teal glow orbs, like the web dashboard) ───────── -->
    <Canvas x:Name="BgLayer" Grid.RowSpan="3" Panel.ZIndex="-1" IsHitTestVisible="False" ClipToBounds="True">
      <Ellipse Width="540" Height="540" Canvas.Left="40" Canvas.Top="-60">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#2614B8A6" Offset="0"/>
            <GradientStop Color="#1014B8A6" Offset="0.45"/>
            <GradientStop Color="#0014B8A6" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
        <Ellipse.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="Orb1S" CenterX="270" CenterY="270"/>
            <TranslateTransform x:Name="Orb1T"/>
          </TransformGroup>
        </Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse Width="460" Height="460" Canvas.Left="560" Canvas.Top="300">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#220D9488" Offset="0"/>
            <GradientStop Color="#0E0D9488" Offset="0.45"/>
            <GradientStop Color="#000D9488" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
        <Ellipse.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="Orb2S" CenterX="230" CenterY="230"/>
            <TranslateTransform x:Name="Orb2T"/>
          </TransformGroup>
        </Ellipse.RenderTransform>
      </Ellipse>
      <Ellipse Width="400" Height="400" Canvas.Left="300" Canvas.Top="200">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#1C0F766E" Offset="0"/>
            <GradientStop Color="#000F766E" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
        <Ellipse.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="Orb3S" CenterX="200" CenterY="200"/>
            <TranslateTransform x:Name="Orb3T"/>
          </TransformGroup>
        </Ellipse.RenderTransform>
      </Ellipse>
      <Canvas.Triggers>
        <EventTrigger RoutedEvent="FrameworkElement.Loaded">
          <BeginStoryboard>
            <Storyboard>
              <DoubleAnimation Storyboard.TargetName="Orb1T" Storyboard.TargetProperty="X" From="0" To="70"  Duration="0:0:22" AutoReverse="True" RepeatBehavior="Forever"/>
              <DoubleAnimation Storyboard.TargetName="Orb1T" Storyboard.TargetProperty="Y" From="0" To="-50" Duration="0:0:22" AutoReverse="True" RepeatBehavior="Forever"/>
              <DoubleAnimation Storyboard.TargetName="Orb1S" Storyboard.TargetProperty="ScaleX" From="1" To="1.25" Duration="0:0:22" AutoReverse="True" RepeatBehavior="Forever"/>
              <DoubleAnimation Storyboard.TargetName="Orb1S" Storyboard.TargetProperty="ScaleY" From="1" To="1.25" Duration="0:0:22" AutoReverse="True" RepeatBehavior="Forever"/>

              <DoubleAnimation Storyboard.TargetName="Orb2T" Storyboard.TargetProperty="X" From="0" To="-60" Duration="0:0:28" BeginTime="0:0:2" AutoReverse="True" RepeatBehavior="Forever"/>
              <DoubleAnimation Storyboard.TargetName="Orb2T" Storyboard.TargetProperty="Y" From="0" To="70"  Duration="0:0:28" BeginTime="0:0:2" AutoReverse="True" RepeatBehavior="Forever"/>
              <DoubleAnimation Storyboard.TargetName="Orb2S" Storyboard.TargetProperty="ScaleX" From="1.1" To="0.9" Duration="0:0:28" BeginTime="0:0:2" AutoReverse="True" RepeatBehavior="Forever"/>
              <DoubleAnimation Storyboard.TargetName="Orb2S" Storyboard.TargetProperty="ScaleY" From="1.1" To="0.9" Duration="0:0:28" BeginTime="0:0:2" AutoReverse="True" RepeatBehavior="Forever"/>

              <DoubleAnimation Storyboard.TargetName="Orb3T" Storyboard.TargetProperty="X" From="0" To="40"  Duration="0:0:18" BeginTime="0:0:4" AutoReverse="True" RepeatBehavior="Forever"/>
              <DoubleAnimation Storyboard.TargetName="Orb3T" Storyboard.TargetProperty="Y" From="0" To="-35" Duration="0:0:18" BeginTime="0:0:4" AutoReverse="True" RepeatBehavior="Forever"/>
            </Storyboard>
          </BeginStoryboard>
        </EventTrigger>
      </Canvas.Triggers>
    </Canvas>

    <!-- ───────── HEADER ───────── -->
    <Border Style="{StaticResource CardStyle}" Grid.Row="0" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Image x:Name="LogoImage" Grid.Column="0" Width="48" Height="48" Stretch="Uniform" Margin="0,0,14,0"/>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock x:Name="RestaurantName" Text="LightMenu" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF"/>
          <TextBlock x:Name="VersionText" Text="Station v6.0.0" FontSize="11" Foreground="#7A8295" Margin="0,3,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Grid VerticalAlignment="Center" Width="150" Margin="0,0,16,0">
            <Button x:Name="LangBtn" Background="#0F1117" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" Padding="12,6" HorizontalContentAlignment="Stretch">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border Background="{TemplateBinding Background}" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
                    <Grid>
                      <TextBlock x:Name="LangBtnText" Text="English" Foreground="#FFFFFF" FontSize="12" VerticalAlignment="Center"/>
                      <TextBlock Text="v" Foreground="#9CA3AF" FontSize="10" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                  </Border>
                </ControlTemplate>
              </Button.Template>
            </Button>
            <Popup x:Name="LangPopup" PlacementTarget="{Binding ElementName=LangBtn}" Placement="Bottom" StaysOpen="False" AllowsTransparency="True">
              <Border Background="#1A1D29" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6" Padding="4" Margin="0,4,0,0">
                <ListBox x:Name="LangList" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Width="200" MaxHeight="320">
                  <ListBox.ItemContainerStyle>
                    <Style TargetType="ListBoxItem">
                      <Setter Property="Background" Value="Transparent"/>
                      <Setter Property="Foreground" Value="#FFFFFF"/>
                      <Setter Property="Padding" Value="12,8"/>
                      <Setter Property="FontSize" Value="12"/>
                      <Style.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#2A2D3A"/></Trigger>
                        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#14B8A6"/></Trigger>
                      </Style.Triggers>
                    </Style>
                  </ListBox.ItemContainerStyle>
                </ListBox>
              </Border>
            </Popup>
          </Grid>
          <Ellipse x:Name="StatusDot" Width="10" Height="10" Fill="#6B7280" Margin="0,0,8,0"/>
          <TextBlock x:Name="StatusText" Text="Connecting..." FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ───────── SECTION BACK BAR ───────── -->
    <!-- Inside a section only a Back-to-Control-Center button shows. The old tab
         buttons are kept (collapsed) so existing wiring/ctl lookups still work. -->
    <Border x:Name="NavBar" Grid.Row="1" Background="#0F1117" Margin="0,0,0,12">
      <Grid>
        <ScrollViewer x:Name="NavTabs" Visibility="Collapsed" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Auto">
        <StackPanel Orientation="Horizontal">
          <Button x:Name="NavHome"       Style="{StaticResource NavBtn}" Content="Home" Margin="0,0,4,0"/>
          <Button x:Name="NavDashboard"  Style="{StaticResource NavBtn}" Content="Dashboard"/>
          <Button x:Name="NavAssistant"  Style="{StaticResource NavBtn}" Content="LightMenu AI" Margin="4,0,0,0"/>
          <Button x:Name="NavMenu"       Style="{StaticResource NavBtn}" Content="Menu"         Margin="4,0,0,0"/>
          <Button x:Name="NavKitchen"    Style="{StaticResource NavBtn}" Content="Kitchen"      Margin="4,0,0,0"/>
          <Button x:Name="NavOrders"     Style="{StaticResource NavBtn}" Content="Orders"       Margin="4,0,0,0"/>
          <Button x:Name="NavStaff"      Style="{StaticResource NavBtn}" Content="Staff"        Margin="4,0,0,0"/>
          <Button x:Name="NavAnalytics"  Style="{StaticResource NavBtn}" Content="Analytics"    Margin="4,0,0,0"/>
          <Button x:Name="NavBills"      Style="{StaticResource NavBtn}" Content="Bills"        Margin="4,0,0,0"/>
          <Button x:Name="NavReport"     Style="{StaticResource NavBtn}" Content="Daily Report" Margin="4,0,0,0"/>
        </StackPanel>
        </ScrollViewer>
        <Button x:Name="BackBtn" HorizontalAlignment="Left" Style="{StaticResource NavBtn}"
                FontSize="14" Foreground="#FFFFFF" Content="Control Center"/>
      </Grid>
    </Border>

    <!-- ───────── PAGE CONTAINER ───────── -->
    <Grid Grid.Row="2">

      <!-- ════════ PAGE 0: HOME — Control Center ════════ -->
      <Grid x:Name="PageHome" Visibility="Visible">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="4,2,0,16">
          <TextBlock x:Name="HomeTitle" Text="Control Center" FontSize="26" FontWeight="Bold" Foreground="#FFFFFF"/>
          <TextBlock x:Name="HomeSubtitle" Text="Choose a section to get started" FontSize="13" Foreground="#7A8295" Margin="0,6,0,0"/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <UniformGrid x:Name="HomeGrid" Columns="3" Margin="-7,0,-7,0"/>
        </ScrollViewer>
      </Grid>

      <!-- ════════ PAGE 1: DASHBOARD — Floor Plan ════════ -->
      <Grid x:Name="PageDashboard" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Floor tabs + actions + legend -->
        <Grid Grid.Row="0" Margin="0,0,0,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <StackPanel x:Name="FloorTabs" Orientation="Horizontal" VerticalAlignment="Center"/>
            <Button x:Name="AddFloorBtn"  Style="{StaticResource PeriodBtn}" Content="+ Floor"  Margin="6,0,0,0"/>
            <Button x:Name="AddTableBtn"  Style="{StaticResource PeriodBtn}" Content="+ Table"  Margin="6,0,0,0" Foreground="#FFFFFF">
              <Button.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#14B8A6" Offset="0"/>
                  <GradientStop Color="#06B6D4" Offset="1"/>
                </LinearGradientBrush>
              </Button.Background>
            </Button>
            <Button x:Name="DelFloorBtn"  Style="{StaticResource PeriodBtn}" Content="Delete Floor" Margin="6,0,0,0" Foreground="#F87171"/>
          </StackPanel>
          <!-- hint + legend -->
          <StackPanel Grid.Column="1" VerticalAlignment="Center">
            <TextBlock x:Name="LblDragHint" Text="Drag to arrange · tap to edit" Foreground="#6B7280" FontSize="11" HorizontalAlignment="Right" Margin="0,0,0,4"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Ellipse Width="8" Height="8" Fill="#22C55E" VerticalAlignment="Center" Margin="0,0,5,0"/>
              <TextBlock x:Name="LblFree"    Text="Free"        Foreground="#6B7280" FontSize="11" VerticalAlignment="Center" Margin="0,0,14,0"/>
              <Ellipse Width="8" Height="8" Fill="#38BDF8" VerticalAlignment="Center" Margin="0,0,5,0"/>
              <TextBlock x:Name="LblDishes"  Text="Dishes out"  Foreground="#6B7280" FontSize="11" VerticalAlignment="Center" Margin="0,0,14,0"/>
              <Ellipse Width="8" Height="8" Fill="#F59E0B" VerticalAlignment="Center" Margin="0,0,5,0"/>
              <TextBlock x:Name="LblReclaim" Text="To reclaim"  Foreground="#6B7280" FontSize="11" VerticalAlignment="Center" Margin="0,0,14,0"/>
              <Ellipse Width="8" Height="8" Fill="#A855F7" VerticalAlignment="Center" Margin="0,0,5,0"/>
              <TextBlock x:Name="LblCheck"   Text="Check printed" Foreground="#6B7280" FontSize="11" VerticalAlignment="Center"/>
            </StackPanel>
          </StackPanel>
        </Grid>

        <!-- Floor plan canvas -->
        <Border Style="{StaticResource CardStyle}" Grid.Row="1" Padding="0">
          <Grid>
            <Viewbox x:Name="FloorViewbox" Stretch="Uniform">
              <Canvas x:Name="FloorCanvas" Width="1000" Height="620"
                      Background="Transparent"/>
            </Viewbox>
            <TextBlock x:Name="FloorEmpty" Text="No tables yet. Add them in the web dashboard."
                       Foreground="#6B7280" FontSize="13" HorizontalAlignment="Center"
                       VerticalAlignment="Center" Visibility="Collapsed"/>
          </Grid>
        </Border>

        <!-- Status bar -->
        <Grid Grid.Row="2" Margin="0,10,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="12"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="12"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border Style="{StaticResource CardStyle}" Grid.Column="0" Padding="12,8">
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="LblPrinter" Text="PRINTER" Style="{StaticResource CardLabel}" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock x:Name="PrinterText" Text="--" Foreground="#FFFFFF" FontSize="12" VerticalAlignment="Center"/>
              <TextBlock Text="  ·  " Foreground="#3A3D4A" VerticalAlignment="Center"/>
              <TextBlock x:Name="LblLastUpdate" Text="LAST UPDATE" Style="{StaticResource CardLabel}" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock x:Name="UpdateText" Text="--" Foreground="#7A8295" FontSize="12" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Button x:Name="TestBtn" Grid.Column="2" Style="{StaticResource ActionBtn}" Content="Rescan Printers" Padding="14,8">
            <Button.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#14B8A6" Offset="0"/>
                <GradientStop Color="#06B6D4" Offset="1"/>
              </LinearGradientBrush>
            </Button.Background>
          </Button>
          <Button x:Name="RestartBtn" Grid.Column="4" Style="{StaticResource ActionBtn}" Content="Restart Agent" Padding="14,8"/>
        </Grid>
      </Grid>

      <!-- ════════ PAGE 2: ANALYTICS ════════ -->
      <Grid x:Name="PageAnalytics" Visibility="Collapsed">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
              <Button x:Name="PeriodToday"   Style="{StaticResource PeriodBtn}" Content="Today"/>
              <Button x:Name="PeriodWeek"    Style="{StaticResource PeriodBtn}" Content="This Week"    Margin="8,0,0,0"/>
              <Button x:Name="PeriodMonth"   Style="{StaticResource PeriodBtn}" Content="This Month"   Margin="8,0,0,0"/>
              <Button x:Name="PeriodAll"     Style="{StaticResource PeriodBtn}" Content="All Time"     Margin="8,0,0,0"/>
              <Button x:Name="PeriodRefresh" Style="{StaticResource PeriodBtn}" Content="Refresh"      Margin="24,0,0,0"/>
            </StackPanel>

            <Grid Margin="0,0,0,12">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource CardStyle}" Grid.Column="0">
                <StackPanel>
                  <TextBlock x:Name="LblTotalRevenue" Text="TOTAL REVENUE" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="AnaRevenue" Text="--" Style="{StaticResource BigValue}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardStyle}" Grid.Column="2">
                <StackPanel>
                  <TextBlock x:Name="LblTotalOrders" Text="TOTAL ORDERS" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="AnaOrders" Text="--" Style="{StaticResource BigValue}" Foreground="#06B6D4"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardStyle}" Grid.Column="4">
                <StackPanel>
                  <TextBlock x:Name="LblAvgTicket" Text="AVG TICKET" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="AnaAvg" Text="--" Style="{StaticResource BigValue}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardStyle}" Grid.Column="6">
                <StackPanel>
                  <TextBlock x:Name="LblBestDay" Text="BEST DAY" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="AnaBest" Text="--" Style="{StaticResource BigValue}" Foreground="#F59E0B" FontSize="16"/>
                </StackPanel>
              </Border>
            </Grid>

            <Border Style="{StaticResource CardStyle}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock x:Name="LblPaymentMethods" Text="PAYMENT METHODS" Style="{StaticResource CardLabel}" Margin="0,0,0,10"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Border Grid.Column="0" Background="#0F2920" BorderBrush="#14B8A6" BorderThickness="1" CornerRadius="8" Padding="14">
                    <StackPanel HorizontalAlignment="Center">
                      <TextBlock x:Name="PayCashCount" Text="0" FontSize="22" FontWeight="Bold" Foreground="#14B8A6" HorizontalAlignment="Center"/>
                      <TextBlock x:Name="LblCash" Text="Cash" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center" Margin="0,4,0,0"/>
                      <TextBlock x:Name="PayCashTotal" Text="--" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="2" Background="#0F1929" BorderBrush="#3B82F6" BorderThickness="1" CornerRadius="8" Padding="14">
                    <StackPanel HorizontalAlignment="Center">
                      <TextBlock x:Name="PayCardCount" Text="0" FontSize="22" FontWeight="Bold" Foreground="#3B82F6" HorizontalAlignment="Center"/>
                      <TextBlock x:Name="LblCard" Text="Card" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center" Margin="0,4,0,0"/>
                      <TextBlock x:Name="PayCardTotal" Text="--" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="4" Background="#0F2229" BorderBrush="#06B6D4" BorderThickness="1" CornerRadius="8" Padding="14">
                    <StackPanel HorizontalAlignment="Center">
                      <TextBlock x:Name="PayMixedCount" Text="0" FontSize="22" FontWeight="Bold" Foreground="#06B6D4" HorizontalAlignment="Center"/>
                      <TextBlock x:Name="LblMixed" Text="Mixed" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center" Margin="0,4,0,0"/>
                      <TextBlock x:Name="PayMixedTotal" Text="--" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardStyle}">
              <StackPanel>
                <TextBlock x:Name="ChartTitle" Text="Revenue -- Last 7 Days" Foreground="#FFFFFF" FontWeight="SemiBold" FontSize="13" Margin="0,0,0,12"/>
                <Canvas x:Name="ChartCanvas" Height="220" Background="Transparent"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- ════════ PAGE 3: BILLS ════════ -->
      <Grid x:Name="PageBills" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#3A2E10" BorderBrush="#F59E0B" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,0,0,10">
          <TextBlock x:Name="BillsInfoText" Foreground="#FCD34D" FontSize="12" TextWrapping="Wrap"
                     Text="Bills are stored locally on this PC and survive restarts. Export to CSV for permanent backup."/>
        </Border>

        <Border Style="{StaticResource CardStyle}" Grid.Row="1" Margin="0,0,0,10">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="LblFrom" Grid.Column="0" Text="From:" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <DatePicker x:Name="BillStart" Grid.Column="2" Width="130"/>
            <TextBlock x:Name="LblTo" Grid.Column="3" Text="To:" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="14,0,8,0"/>
            <DatePicker x:Name="BillEnd"   Grid.Column="5" Width="130"/>
            <Button x:Name="BillRefresh" Grid.Column="7" Style="{StaticResource PeriodBtn}" Content="Apply"/>
            <Button x:Name="BillExport"  Grid.Column="9" Style="{StaticResource PeriodBtn}" Content="Export CSV" Foreground="#FFFFFF">
              <Button.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#14B8A6" Offset="0"/>
                  <GradientStop Color="#06B6D4" Offset="1"/>
                </LinearGradientBrush>
              </Button.Background>
            </Button>
          </Grid>
        </Border>

        <Border Style="{StaticResource CardStyle}" Grid.Row="2">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock x:Name="BillCount" Grid.Row="0" Text="0 bills" Foreground="#9CA3AF" FontSize="11" Margin="0,0,0,8"/>
            <ListView x:Name="BillList" Grid.Row="1" Background="Transparent" BorderThickness="0" Foreground="#D1D5DB">
              <ListView.View>
                <GridView>
                  <GridView.ColumnHeaderContainerStyle>
                    <Style TargetType="GridViewColumnHeader">
                      <Setter Property="Background" Value="#0F1117"/>
                      <Setter Property="Foreground" Value="#7A8295"/>
                      <Setter Property="FontSize" Value="10"/>
                      <Setter Property="FontWeight" Value="Bold"/>
                      <Setter Property="HorizontalContentAlignment" Value="Left"/>
                      <Setter Property="Padding" Value="8,6"/>
                    </Style>
                  </GridView.ColumnHeaderContainerStyle>
                  <GridViewColumn Header="BILL #"    DisplayMemberBinding="{Binding BillNum}" Width="160"/>
                  <GridViewColumn Header="DATE/TIME" DisplayMemberBinding="{Binding DateStr}" Width="150"/>
                  <GridViewColumn Header="TABLE"     DisplayMemberBinding="{Binding Table}"   Width="60"/>
                  <GridViewColumn Header="WAITER"    DisplayMemberBinding="{Binding Waiter}"  Width="100"/>
                  <GridViewColumn Header="TOTAL"     DisplayMemberBinding="{Binding TotalStr}" Width="100"/>
                  <GridViewColumn Header="PAYMENT"   DisplayMemberBinding="{Binding Payment}" Width="80"/>
                </GridView>
              </ListView.View>
              <ListView.ItemContainerStyle>
                <Style TargetType="ListViewItem">
                  <Setter Property="Background" Value="Transparent"/>
                  <Setter Property="Foreground" Value="#D1D5DB"/>
                  <Setter Property="BorderBrush" Value="#2A2D3A"/>
                  <Setter Property="BorderThickness" Value="0,0,0,1"/>
                  <Setter Property="Padding" Value="4,8"/>
                  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                  <Style.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter Property="Background" Value="#1A1D29"/>
                    </Trigger>
                    <Trigger Property="IsSelected" Value="True">
                      <Setter Property="Background" Value="#1F2937"/>
                    </Trigger>
                  </Style.Triggers>
                </Style>
              </ListView.ItemContainerStyle>
              <ListView.ContextMenu>
                <ContextMenu Background="#1A1D29" Foreground="#FFFFFF">
                  <MenuItem x:Name="MenuReprint" Header="Reprint bill" Foreground="#FFFFFF" Background="#1A1D29"/>
                </ContextMenu>
              </ListView.ContextMenu>
            </ListView>
          </Grid>
        </Border>
      </Grid>

      <!-- ════════ PAGE 4: DAILY REPORT ════════ -->
      <Grid x:Name="PageReport" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border Style="{StaticResource CardStyle}" Grid.Row="0" Margin="0,0,0,12">
          <StackPanel>
            <TextBlock x:Name="LblGenReport" Text="GENERATE REPORT" Style="{StaticResource CardLabel}" Margin="0,0,0,10"/>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="LblDate"  Grid.Column="0" Text="Date:"  Foreground="#9CA3AF" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <DatePicker x:Name="ReportDate" Grid.Column="1" Width="140" HorizontalAlignment="Left"/>
              <TextBlock x:Name="LblStart" Grid.Column="2" Text="Start:" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="14,0,8,0"/>
              <TextBox x:Name="ReportStart" Grid.Column="3" Width="70" HorizontalAlignment="Left" Text="09:00" Background="#0F1117" Foreground="#FFFFFF" BorderBrush="#2A2D3A" Padding="6,4"/>
              <TextBlock x:Name="LblEnd"   Grid.Column="4" Text="End:"   Foreground="#9CA3AF" VerticalAlignment="Center" Margin="14,0,8,0"/>
              <TextBox x:Name="ReportEnd"  Grid.Column="5" Width="70"  HorizontalAlignment="Left" Text="23:59" Background="#0F1117" Foreground="#FFFFFF" BorderBrush="#2A2D3A" Padding="6,4"/>
              <Button x:Name="ReportGenerate" Grid.Column="6" Style="{StaticResource PeriodBtn}" Content="Generate" Margin="14,0,0,0" Foreground="#FFFFFF">
                <Button.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#14B8A6" Offset="0"/>
                    <GradientStop Color="#06B6D4" Offset="1"/>
                  </LinearGradientBrush>
                </Button.Background>
              </Button>
            </Grid>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource CardStyle}" Grid.Row="1">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="ReportContent">
              <TextBlock x:Name="ReportEmpty" Foreground="#6B7280" HorizontalAlignment="Center" Margin="0,60,0,0" FontSize="13"
                         Text="Generate a report to see the breakdown."/>
              <StackPanel x:Name="ReportResults" Visibility="Collapsed">
                <TextBlock x:Name="ReportHeader" Foreground="#FFFFFF" FontSize="16" FontWeight="Bold" Margin="0,0,0,14"/>
                <Grid Margin="0,0,0,16">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Border Grid.Column="0" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="8" Padding="10">
                    <StackPanel>
                      <TextBlock x:Name="LblRepRevenue" Text="REVENUE" Style="{StaticResource CardLabel}"/>
                      <TextBlock x:Name="RepRevenue" Style="{StaticResource BigValue}" FontSize="20"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="2" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="8" Padding="10">
                    <StackPanel>
                      <TextBlock x:Name="LblRepOrders" Text="ORDERS" Style="{StaticResource CardLabel}"/>
                      <TextBlock x:Name="RepOrders" Style="{StaticResource BigValue}" FontSize="20" Foreground="#06B6D4"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="4" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="8" Padding="10">
                    <StackPanel>
                      <TextBlock x:Name="LblRepAvg" Text="AVG TICKET" Style="{StaticResource CardLabel}"/>
                      <TextBlock x:Name="RepAvg" Style="{StaticResource BigValue}" FontSize="20"/>
                    </StackPanel>
                  </Border>
                </Grid>
                <TextBlock x:Name="LblPayBreakdown" Text="PAYMENT BREAKDOWN" Style="{StaticResource CardLabel}" Margin="0,0,0,8"/>
                <TextBlock x:Name="RepPayments" Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,16"/>
                <TextBlock x:Name="LblTopItems" Text="TOP ITEMS" Style="{StaticResource CardLabel}" Margin="0,0,0,8"/>
                <ItemsControl x:Name="RepItems" Margin="0,0,0,16">
                  <ItemsControl.ItemTemplate>
                    <DataTemplate>
                      <Grid Margin="0,3">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="{Binding Name}"   Foreground="#D1D5DB" FontSize="12"/>
                        <TextBlock Grid.Column="1" Text="{Binding QtyStr}" Foreground="#9CA3AF" FontSize="12" Margin="14,0,14,0"/>
                        <TextBlock Grid.Column="2" Text="{Binding RevStr}" Foreground="#14B8A6" FontSize="12" FontWeight="SemiBold"/>
                      </Grid>
                    </DataTemplate>
                  </ItemsControl.ItemTemplate>
                </ItemsControl>
                <Button x:Name="RepSave" Style="{StaticResource ActionBtn}" Content="Save Report as Text File" HorizontalAlignment="Left"/>
              </StackPanel>
            </StackPanel>
          </ScrollViewer>
        </Border>
      </Grid>

      <!-- ════════ PAGE 5: STAFF ════════ -->
      <Grid x:Name="PageStaff" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,14">
          <TextBlock x:Name="LblStaffTitle" Text="Staff" Foreground="#FFFFFF" FontSize="18" FontWeight="Bold" VerticalAlignment="Center"/>
          <Button x:Name="AddStaffBtn" HorizontalAlignment="Right" Padding="16,8" BorderThickness="0"
                  Foreground="#FFFFFF" Cursor="Hand" FontSize="13" FontWeight="SemiBold">
            <Button.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#14B8A6" Offset="0"/>
                <GradientStop Color="#06B6D4" Offset="1"/>
              </LinearGradientBrush>
            </Button.Background>
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </ControlTemplate>
            </Button.Template>
          </Button>
        </Grid>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <WrapPanel x:Name="StaffCards" Orientation="Horizontal"/>
        </ScrollViewer>
      </Grid>

      <!-- ════════ PAGE 6: MENU ════════ -->
      <Grid x:Name="PageMenu" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,12">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="MenuSearch" Grid.Column="0" Background="#0F1117" Foreground="#FFFFFF"
                   BorderBrush="#2A2D3A" BorderThickness="1" Padding="10,8" VerticalContentAlignment="Center"
                   FontSize="13"/>
          <TextBlock x:Name="MenuSyncBadge" Grid.Column="1" Text="--" Foreground="#7A8295" FontSize="11"
                     VerticalAlignment="Center" Margin="14,0,12,0"/>
          <Button x:Name="AddCategoryBtn" Grid.Column="2" Style="{StaticResource PeriodBtn}" Content="+ Category" Margin="0,0,8,0"/>
          <Button x:Name="AddItemBtn" Grid.Column="3" Style="{StaticResource PeriodBtn}" Content="+ Item" Foreground="#FFFFFF" Margin="0,0,8,0">
            <Button.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#14B8A6" Offset="0"/>
                <GradientStop Color="#06B6D4" Offset="1"/>
              </LinearGradientBrush>
            </Button.Background>
          </Button>
          <Button x:Name="MenuRefresh" Grid.Column="4" Style="{StaticResource PeriodBtn}" Content="Refresh"/>
        </Grid>

        <Grid Grid.Row="1">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="200"/>
            <ColumnDefinition Width="12"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <!-- Category sidebar -->
          <Border Grid.Column="0" Style="{StaticResource CardStyle}" Padding="6">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="MenuCategoryList"/>
            </ScrollViewer>
          </Border>

          <!-- Item list -->
          <Border Grid.Column="2" Style="{StaticResource CardStyle}">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Grid Grid.Row="0" Margin="4,2,4,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="MenuColName"  Grid.Column="0" Text="ITEM"   Style="{StaticResource CardLabel}"/>
                <TextBlock x:Name="MenuColAvail" Grid.Column="1" Text="STATUS" Style="{StaticResource CardLabel}" Margin="0,0,24,0"/>
                <TextBlock x:Name="MenuColPrice" Grid.Column="2" Text="PRICE"  Style="{StaticResource CardLabel}"/>
              </Grid>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="MenuItemList"/>
              </ScrollViewer>
            </Grid>
          </Border>
        </Grid>
      </Grid>

      <!-- ════════ PAGE 7: PRINTER SETUP ════════ -->
      <Grid x:Name="PageKitchen" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,12">
          <TextBlock x:Name="KitchenTitle" Text="Printer Setup" Foreground="#FFFFFF" FontSize="18" FontWeight="Bold" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="KitchenRefresh" Style="{StaticResource PeriodBtn}" Content="Refresh" Margin="0,0,8,0"/>
            <Button x:Name="AddPrinterBtn" Padding="16,8" BorderThickness="0" Foreground="#FFFFFF" Cursor="Hand" FontSize="13" FontWeight="SemiBold">
              <Button.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#14B8A6" Offset="0"/>
                  <GradientStop Color="#06B6D4" Offset="1"/>
                </LinearGradientBrush>
              </Button.Background>
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                </ControlTemplate>
              </Button.Template>
            </Button>
          </StackPanel>
        </Grid>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <!-- Live USB / transport status -->
            <Border Style="{StaticResource CardStyle}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock x:Name="LblLivePrinter" Text="THIS STATION" Style="{StaticResource CardLabel}" Margin="0,0,0,6"/>
                <TextBlock x:Name="KitchenLiveText" Text="--" Style="{StaticResource CardValue}"/>
              </StackPanel>
            </Border>

            <StackPanel x:Name="PrinterCards"/>

            <!-- Inline add-printer form (hidden until Add is clicked) -->
            <Border x:Name="AddPrinterPanel" Style="{StaticResource CardStyle}" Margin="0,2,0,0" Visibility="Collapsed">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="8"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="8"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="8"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="8"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox  x:Name="NewPrinterName" Grid.Column="0" Background="#0F1117" Foreground="#FFFFFF" BorderBrush="#2A2D3A" BorderThickness="1" Padding="8,6" VerticalContentAlignment="Center"/>
                <TextBox  x:Name="NewPrinterIp"   Grid.Column="2" Width="130" Background="#0F1117" Foreground="#FFFFFF" BorderBrush="#2A2D3A" BorderThickness="1" Padding="8,6" VerticalContentAlignment="Center"/>
                <ComboBox x:Name="NewPrinterType" Grid.Column="4" Width="110" SelectedIndex="0">
                  <ComboBoxItem Content="kitchen"/>
                  <ComboBoxItem Content="bar"/>
                  <ComboBoxItem Content="check"/>
                </ComboBox>
                <Button x:Name="SavePrinterBtn"   Grid.Column="6" Style="{StaticResource PeriodBtn}" Content="Save" Foreground="#FFFFFF">
                  <Button.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                      <GradientStop Color="#14B8A6" Offset="0"/>
                      <GradientStop Color="#06B6D4" Offset="1"/>
                    </LinearGradientBrush>
                  </Button.Background>
                </Button>
                <Button x:Name="CancelPrinterBtn" Grid.Column="8" Style="{StaticResource PeriodBtn}" Content="Cancel"/>
              </Grid>
            </Border>

            <!-- ── TICKET SETTINGS ──────────────────────────────────────── -->
            <Border Style="{StaticResource CardStyle}" Margin="0,14,0,0">
              <StackPanel>
                <!-- Dark-themed ComboBox + CheckBox, scoped to this panel only -->
                <StackPanel.Resources>
                  <Style TargetType="ComboBox">
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                    <Setter Property="Background" Value="#0F1117"/>
                    <Setter Property="Height" Value="34"/>
                    <Setter Property="FontSize" Value="12"/>
                    <Setter Property="VerticalContentAlignment" Value="Center"/>
                    <Setter Property="Template">
                      <Setter.Value>
                        <ControlTemplate TargetType="ComboBox">
                          <Grid>
                            <ToggleButton Focusable="false" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                              <ToggleButton.Template>
                                <ControlTemplate TargetType="ToggleButton">
                                  <Border x:Name="bd" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="7">
                                    <Grid>
                                      <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="22"/>
                                      </Grid.ColumnDefinitions>
                                      <Path Grid.Column="1" Data="M 0 0 L 4 4 L 8 0 Z" Fill="#9CA3AF"
                                            HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Grid>
                                  </Border>
                                  <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                      <Setter TargetName="bd" Property="BorderBrush" Value="#14B8A6"/>
                                    </Trigger>
                                  </ControlTemplate.Triggers>
                                </ControlTemplate>
                              </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Content="{TemplateBinding SelectionBoxItem}"
                                              Margin="11,0,24,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                            <Popup Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                              <Border Background="#1A1D29" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="7" Margin="0,4,0,0"
                                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                                <ScrollViewer MaxHeight="240">
                                  <ItemsPresenter/>
                                </ScrollViewer>
                              </Border>
                            </Popup>
                          </Grid>
                        </ControlTemplate>
                      </Setter.Value>
                    </Setter>
                  </Style>
                  <Style TargetType="ComboBoxItem">
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                    <Setter Property="Padding" Value="11,8"/>
                    <Setter Property="FontSize" Value="12"/>
                    <Setter Property="Template">
                      <Setter.Value>
                        <ControlTemplate TargetType="ComboBoxItem">
                          <Border x:Name="ib" Background="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="4">
                            <ContentPresenter/>
                          </Border>
                          <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ib" Property="Background" Value="#2A2D3A"/></Trigger>
                            <Trigger Property="IsSelected" Value="True"><Setter TargetName="ib" Property="Background" Value="#14B8A6"/></Trigger>
                          </ControlTemplate.Triggers>
                        </ControlTemplate>
                      </Setter.Value>
                    </Setter>
                  </Style>
                  <!-- iOS-style toggle switch -->
                  <Style TargetType="CheckBox">
                    <Setter Property="Foreground" Value="#D1D5DB"/>
                    <Setter Property="FontSize" Value="12"/>
                    <Setter Property="Cursor" Value="Hand"/>
                    <Setter Property="Template">
                      <Setter.Value>
                        <ControlTemplate TargetType="CheckBox">
                          <StackPanel Orientation="Horizontal" Background="Transparent">
                            <ContentPresenter VerticalAlignment="Center"/>
                            <Border x:Name="track" Width="38" Height="21" CornerRadius="11" Background="#2A2D3A"
                                    Margin="9,0,0,0" VerticalAlignment="Center">
                              <Ellipse x:Name="knob" Width="15" Height="15" Fill="#9CA3AF"
                                       HorizontalAlignment="Left" Margin="3,0,0,0"/>
                            </Border>
                          </StackPanel>
                          <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                              <Setter TargetName="track" Property="Background" Value="#14B8A6"/>
                              <Setter TargetName="knob" Property="Fill" Value="#FFFFFF"/>
                              <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                              <Setter TargetName="knob" Property="Margin" Value="0,0,3,0"/>
                            </Trigger>
                          </ControlTemplate.Triggers>
                        </ControlTemplate>
                      </Setter.Value>
                    </Setter>
                  </Style>
                </StackPanel.Resources>
                <Grid Margin="0,0,0,16">
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="TsTitle" Text="TICKET SETTINGS" Style="{StaticResource CardLabel}" VerticalAlignment="Center"/>
                  </StackPanel>
                  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                    <Button x:Name="TsTest" Style="{StaticResource PeriodBtn}" Content="Test Print" Margin="0,0,8,0"/>
                    <Button x:Name="TsSave" Style="{StaticResource PeriodBtn}" Content="Save" Foreground="#FFFFFF">
                      <Button.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                          <GradientStop Color="#14B8A6" Offset="0"/>
                          <GradientStop Color="#06B6D4" Offset="1"/>
                        </LinearGradientBrush>
                      </Button.Background>
                    </Button>
                  </StackPanel>
                </Grid>

                <Border Height="1" Background="#2A2D3A" Margin="0,0,0,16"/>

                <!-- Two columns: settings (left) + live preview (right) -->
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="16"/>
                    <ColumnDefinition Width="290"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">

                <!-- Global -->
                <Border Background="#13161F" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="9" Padding="14" Margin="0,0,0,16">
                  <StackPanel>
                    <TextBlock x:Name="TsGlobalLbl" Text="GLOBAL SETTINGS  (apply to all tickets)" Foreground="#7A8295" FontSize="10" FontWeight="Bold" Margin="0,0,0,10"/>
                    <TextBlock Text="Language" Foreground="#9CA3AF" FontSize="11" Margin="0,0,0,6"/>
                    <TextBlock Text="Sets the printed labels (Table, Waiter, TOTAL, …) for every ticket." Foreground="#6B7280" FontSize="10" Margin="0,0,0,8"/>
                    <WrapPanel x:Name="TsLangGrid" Margin="0,0,0,14"/>
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="40"/>
                        <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock x:Name="TsDateLbl" Grid.Column="0" Text="Date" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                      <ComboBox x:Name="TsDateFormat" Grid.Column="1" Width="140">
                        <ComboBoxItem Content="DD/MM/YYYY"/><ComboBoxItem Content="MM/DD/YYYY"/><ComboBoxItem Content="YYYY-MM-DD"/>
                      </ComboBox>
                      <TextBlock x:Name="TsTimeLbl" Grid.Column="3" Text="Time" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                      <ComboBox x:Name="TsTimeFormat" Grid.Column="4" Width="90">
                        <ComboBoxItem Content="24h"/><ComboBoxItem Content="12h"/>
                      </ComboBox>
                    </Grid>

                    <!-- Custom labels (expandable) -->
                    <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="7" Margin="0,14,0,0">
                      <StackPanel>
                        <Grid x:Name="TsLabelsToggle" Background="Transparent" Margin="12,10,12,10">
                          <TextBlock Text="Custom labels" Foreground="#FFFFFF" FontSize="12" VerticalAlignment="Center"/>
                          <TextBlock x:Name="TsLabelsChevron" Text="show" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                        </Grid>
                        <Border x:Name="TsLabelsBody" Visibility="Collapsed" Padding="12,0,12,12">
                          <StackPanel>
                            <TextBlock Text="Override individual words. Leave blank to use the language default." Foreground="#6B7280" FontSize="10" Margin="0,0,0,10" TextWrapping="Wrap"/>
                            <WrapPanel x:Name="TsLabelGrid"/>
                          </StackPanel>
                        </Border>
                      </StackPanel>
                    </Border>

                    <!-- Logo -->
                    <TextBlock Text="Logo" Foreground="#9CA3AF" FontSize="11" Margin="0,14,0,6"/>
                    <Border x:Name="TsLogoDrop" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="7" Padding="14" Cursor="Hand">
                      <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="TsLogoText" Text="Upload logo (PNG/JPG)" Foreground="#9CA3AF" FontSize="12" HorizontalAlignment="Center"/>
                      </StackPanel>
                    </Border>
                    <TextBlock Text="Printed in black &amp; white at the top of every ticket. Floyd–Steinberg dithered for smooth gradients." Foreground="#6B7280" FontSize="10" Margin="0,6,0,0" TextWrapping="Wrap"/>
                    <Grid Margin="0,10,0,0">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="Size" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                      <ComboBox x:Name="TsLogoSize" Grid.Column="1" Width="100"><ComboBoxItem Content="small"/><ComboBoxItem Content="medium"/><ComboBoxItem Content="large"/></ComboBox>
                      <CheckBox x:Name="TsLogoEnabled" Grid.Column="2" Content="Print logo" Margin="16,0,0,0" VerticalAlignment="Center"/>
                      <Button x:Name="TsLogoRemove" Grid.Column="3" Style="{StaticResource PeriodBtn}" Content="Remove"/>
                    </Grid>
                  </StackPanel>
                </Border>

                <!-- Sub-tabs (4 ticket types) -->
                <StackPanel Orientation="Horizontal" Margin="0,0,0,14">
                  <Button x:Name="TsTabOrder" Style="{StaticResource PeriodBtn}" Content="Order" Padding="18,8"/>
                  <Button x:Name="TsTabCheck" Style="{StaticResource PeriodBtn}" Content="Check" Padding="18,8" Margin="8,0,0,0"/>
                  <Button x:Name="TsTabCancel" Style="{StaticResource PeriodBtn}" Content="Cancel" Padding="18,8" Margin="8,0,0,0"/>
                  <Button x:Name="TsTabTransfer" Style="{StaticResource PeriodBtn}" Content="Transfer" Padding="18,8" Margin="8,0,0,0"/>
                </StackPanel>

                <!-- Settings sub-card (holds whichever sub-tab is active) -->
                <Border Background="#13161F" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="9" Padding="14">
                 <Grid>
                <!-- ORDER panel -->
                <StackPanel x:Name="TsOrderPanel">
                  <Grid Margin="0,0,0,12">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="28"/>
                      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Copies" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <StackPanel x:Name="TsOrderCopiesSeg" Grid.Column="1" Orientation="Horizontal"/>
                    <TextBlock Grid.Column="3" Text="Font" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <ComboBox x:Name="TsOrderFont" Grid.Column="4" Width="100"><ComboBoxItem Content="small"/><ComboBoxItem Content="normal"/><ComboBoxItem Content="large"/></ComboBox>
                  </Grid>
                  <TextBlock Text="TICKET MODE" Foreground="#7A8295" FontSize="10" FontWeight="Bold" Margin="0,4,0,6"/>
                  <UniformGrid x:Name="TsModeSeg" Columns="3" Margin="0,0,0,12"/>
                  <TextBlock Text="SEPARATOR STYLE" Foreground="#7A8295" FontSize="10" FontWeight="Bold" Margin="0,0,0,6"/>
                  <StackPanel x:Name="TsSepSeg" Orientation="Horizontal" Margin="0,0,0,12"/>
                  <TextBlock Text="CONTENT" Foreground="#7A8295" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
                  <StackPanel Margin="0,0,0,12">
                    <CheckBox x:Name="TsOrderRestHeader" Content="Show restaurant name" Margin="0,0,0,10"/>
                    <CheckBox x:Name="TsOrderWaiter" Content="Show waiter name" Margin="0,0,0,10"/>
                    <CheckBox x:Name="TsOrderPrice" Content="Show item prices" Margin="0,0,0,10"/>
                    <CheckBox x:Name="TsOrderBold" Content="Bold item names"/>
                  </StackPanel>
                  <TextBlock Text="LAYOUT (PER ZONE)" Foreground="#7A8295" FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
                  <TextBlock Text="Override font size, weight, and alignment for each part of the ticket." Foreground="#6B7280" FontSize="10" Margin="0,0,0,8" TextWrapping="Wrap"/>
                  <StackPanel x:Name="TsZoneMatrix" Margin="0,0,0,6"/>
                  <TextBlock Text="Footer text" Foreground="#9CA3AF" FontSize="11" Margin="0,0,0,4"/>
                  <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
                    <TextBox x:Name="TsOrderFooter" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,7" FontSize="12" CaretBrush="#FFFFFF"/>
                  </Border>
                </StackPanel>

                <!-- CHECK panel -->
                <StackPanel x:Name="TsCheckPanel" Visibility="Collapsed">
                  <Grid Margin="0,0,0,12">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="28"/>
                      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Copies" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <StackPanel x:Name="TsCheckCopiesSeg" Grid.Column="1" Orientation="Horizontal"/>
                    <TextBlock Grid.Column="3" Text="Item size" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <ComboBox x:Name="TsCheckItemSize" Grid.Column="4" Width="100"><ComboBoxItem Content="small"/><ComboBoxItem Content="normal"/><ComboBoxItem Content="large"/></ComboBox>
                  </Grid>
                  <TextBlock Text="CONTENT" Foreground="#7A8295" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>
                  <StackPanel Margin="0,0,0,12">
                    <CheckBox x:Name="TsCheckAddress" Content="Show address" Margin="0,0,0,10"/>
                    <CheckBox x:Name="TsCheckPhone" Content="Show phone" Margin="0,0,0,10"/>
                    <CheckBox x:Name="TsCheckInstagram" Content="Show Instagram" Margin="0,0,0,10"/>
                    <CheckBox x:Name="TsCheckWaiter" Content="Show waiter" Margin="0,0,0,10"/>
                    <CheckBox x:Name="TsCheckBoldTotal" Content="Bold total"/>
                  </StackPanel>
                  <TextBlock Text="LAYOUT (PER ZONE)" Foreground="#7A8295" FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
                  <TextBlock Text="Override font size, weight, and alignment for the info and items zones." Foreground="#6B7280" FontSize="10" Margin="0,0,0,8" TextWrapping="Wrap"/>
                  <StackPanel x:Name="TsCheckZoneMatrix" Margin="0,0,0,8"/>
                  <TextBlock Text="Footer text" Foreground="#9CA3AF" FontSize="11" Margin="0,0,0,4"/>
                  <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
                    <TextBox x:Name="TsCheckFooter" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,7" FontSize="12" CaretBrush="#FFFFFF"/>
                  </Border>
                </StackPanel>

                <!-- CANCEL panel -->
                <StackPanel x:Name="TsCancelPanel" Visibility="Collapsed">
                  <Grid Margin="0,0,0,10">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="24"/>
                      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Header" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <ComboBox x:Name="TsCancelAlign" Grid.Column="1" Width="90"><ComboBoxItem Content="left"/><ComboBoxItem Content="center"/><ComboBoxItem Content="right"/></ComboBox>
                    <TextBlock Grid.Column="3" Text="Item size" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <ComboBox x:Name="TsCancelItemSize" Grid.Column="4" Width="90"><ComboBoxItem Content="small"/><ComboBoxItem Content="normal"/><ComboBoxItem Content="large"/></ComboBox>
                  </Grid>
                  <WrapPanel Margin="0,0,0,10">
                    <CheckBox x:Name="TsCancelEnabled" Content="Print cancel tickets" Margin="0,0,18,6"/>
                    <CheckBox x:Name="TsCancelRestName" Content="Restaurant name" Margin="0,0,18,6"/>
                    <CheckBox x:Name="TsCancelBy" Content="Show cancelled-by" Margin="0,0,18,6"/>
                  </WrapPanel>
                  <TextBlock Text="Footer text" Foreground="#9CA3AF" FontSize="11" Margin="0,0,0,4"/>
                  <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
                    <TextBox x:Name="TsCancelFooter" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,7" FontSize="12" CaretBrush="#FFFFFF"/>
                  </Border>
                </StackPanel>

                <!-- TRANSFER panel -->
                <StackPanel x:Name="TsTransferPanel" Visibility="Collapsed">
                  <Grid Margin="0,0,0,10">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="24"/>
                      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Header" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <ComboBox x:Name="TsTransferAlign" Grid.Column="1" Width="90"><ComboBoxItem Content="left"/><ComboBoxItem Content="center"/><ComboBoxItem Content="right"/></ComboBox>
                    <TextBlock Grid.Column="3" Text="Item size" Foreground="#9CA3AF" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <ComboBox x:Name="TsTransferItemSize" Grid.Column="4" Width="90"><ComboBoxItem Content="small"/><ComboBoxItem Content="normal"/><ComboBoxItem Content="large"/></ComboBox>
                  </Grid>
                  <WrapPanel Margin="0,0,0,10">
                    <CheckBox x:Name="TsTransferEnabled" Content="Print transfer tickets" Margin="0,0,18,6"/>
                    <CheckBox x:Name="TsTransferRestName" Content="Restaurant name" Margin="0,0,18,6"/>
                  </WrapPanel>
                  <TextBlock Text="Footer text" Foreground="#9CA3AF" FontSize="11" Margin="0,0,0,4"/>
                  <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
                    <TextBox x:Name="TsTransferFooter" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,7" FontSize="12" CaretBrush="#FFFFFF"/>
                  </Border>
                </StackPanel>
                 </Grid>
                </Border>
                  </StackPanel>

                  <!-- LIVE PREVIEW (right column) -->
                  <Border Grid.Column="2" Background="#13161F" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="9" Padding="12" VerticalAlignment="Top">
                    <StackPanel>
                      <TextBlock Text="LIVE PREVIEW" Foreground="#7A8295" FontSize="10" FontWeight="Bold" Margin="0,0,0,8" HorizontalAlignment="Center"/>
                      <Border Background="#F5F0E8" CornerRadius="4" Padding="12">
                        <TextBlock x:Name="TsPreview" FontFamily="Consolas" FontSize="11" Foreground="#1A1A1A" TextWrapping="NoWrap"/>
                      </Border>
                    </StackPanel>
                  </Border>
                </Grid>

                <TextBlock x:Name="TsHint" Foreground="#6B7280" FontSize="10" TextWrapping="Wrap" Margin="0,12,0,0"
                           Text="These settings apply to every ticket printed for this restaurant — from the Station, the web dashboard, or the waiter app."/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- ════════ PAGE: ORDERS — Station POS ════════ -->
      <Grid x:Name="PageOrders" Visibility="Collapsed">
        <!-- Table selector overlay (shown when no table selected) -->
        <Grid x:Name="OrderTableSelector" Visibility="Visible">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Select a table to start ordering" Foreground="#7A8295" FontSize="16" HorizontalAlignment="Center" Margin="0,20,0,12"/>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <WrapPanel x:Name="OrderTableGrid" HorizontalAlignment="Center" Margin="8"/>
          </ScrollViewer>
        </Grid>

        <!-- Order view (shown when table is active) — two-column layout -->
        <Grid x:Name="OrderActiveView" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="10"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <!-- LEFT: Cart + actions -->
          <Grid Grid.Column="0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <!-- Table header -->
            <Border Grid.Row="0" Background="#1A1D29" CornerRadius="8,8,0,0" Padding="12,10">
              <TextBlock x:Name="OrderTableLabel" Foreground="#FFFFFF" FontSize="18" FontWeight="Bold"/>
            </Border>
            <!-- Cart items -->
            <Border Grid.Row="1" Background="#161922" Padding="6">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="OrderCartItems"/>
              </ScrollViewer>
            </Border>
            <!-- Action buttons -->
            <Grid Grid.Row="2" Margin="0,6,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="6"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="6"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="OrderSend" Grid.Column="0" Background="#3B82F6" Foreground="#FFFFFF" FontSize="13" FontWeight="Bold" Padding="0,12" BorderThickness="0" Cursor="Hand" Content="✈  SEND">
                <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
              </Button>
              <Button x:Name="OrderReclaim" Grid.Column="2" Background="#374151" Foreground="#FFFFFF" FontSize="13" FontWeight="Bold" Padding="0,12" BorderThickness="0" Cursor="Hand" Content="RECLAIM">
                <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
              </Button>
              <Button x:Name="OrderStop" Grid.Column="4" Background="#EF4444" Foreground="#FFFFFF" FontSize="13" FontWeight="Bold" Padding="0,12" BorderThickness="0" Cursor="Hand" Content="✕  STOP">
                <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
              </Button>
            </Grid>
          </Grid>

          <!-- RIGHT: Course selector + categories + items -->
          <Grid Grid.Column="2">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <!-- Course selector -->
            <Grid Grid.Row="0" Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="4"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="4"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="4"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="4"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="CourseD"  Grid.Column="0" Background="#3B82F6" Foreground="#FFFFFF" FontSize="12" FontWeight="Bold" Padding="0,10" BorderThickness="0" Cursor="Hand" Content="Direct">
                <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
              </Button>
              <Button x:Name="CourseS1" Grid.Column="2" Background="#374151" Foreground="#FFFFFF" FontSize="12" FontWeight="Bold" Padding="0,10" BorderThickness="0" Cursor="Hand" Content="S 1">
                <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
              </Button>
              <Button x:Name="CourseS2" Grid.Column="4" Background="#374151" Foreground="#FFFFFF" FontSize="12" FontWeight="Bold" Padding="0,10" BorderThickness="0" Cursor="Hand" Content="S 2">
                <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
              </Button>
              <Button x:Name="CourseS3" Grid.Column="6" Background="#374151" Foreground="#FFFFFF" FontSize="12" FontWeight="Bold" Padding="0,10" BorderThickness="0" Cursor="Hand" Content="S 3">
                <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
              </Button>
              <Button x:Name="CourseS4" Grid.Column="8" Background="#374151" Foreground="#FFFFFF" FontSize="12" FontWeight="Bold" Padding="0,10" BorderThickness="0" Cursor="Hand" Content="S 4">
                <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
              </Button>
            </Grid>
            <!-- Category buttons -->
            <WrapPanel x:Name="OrderCategoryGrid" Grid.Row="1" HorizontalAlignment="Left" Margin="0,0,0,6"/>
            <!-- Items list (shown when a category is clicked) -->
            <Border Grid.Row="2" Background="#161922" CornerRadius="8" Padding="4">
              <Grid>
                <TextBlock x:Name="OrderItemsHint" Text="Tap a category above" Foreground="#4B5563" FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="OrderItemsList"/>
                </ScrollViewer>
              </Grid>
            </Border>
          </Grid>
        </Grid>
      </Grid>

      <Grid x:Name="PageAssistant" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,12">
          <TextBlock Text="LightMenu AI" Foreground="#FFFFFF" FontSize="18" FontWeight="Bold"/>
          <TextBlock Text="Ask me to add items, change prices, reorganise the menu, or answer questions about it." Foreground="#7A8295" FontSize="11" Margin="0,3,0,0"/>
        </StackPanel>
        <Border Grid.Row="1" Style="{StaticResource CardStyle}" Padding="6">
          <ScrollViewer x:Name="AiScroller" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="AiMessages" Margin="6"/>
          </ScrollViewer>
        </Border>
        <Grid Grid.Row="2" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="10"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="8">
            <TextBox x:Name="AiInput" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" CaretBrush="#FFFFFF" Padding="12,10" FontSize="13" VerticalContentAlignment="Center"/>
          </Border>
          <Button x:Name="AiSend" Grid.Column="2" Padding="22,10" BorderThickness="0" Foreground="#FFFFFF" Cursor="Hand" FontSize="13" FontWeight="SemiBold">
            <Button.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#14B8A6" Offset="0"/>
                <GradientStop Color="#06B6D4" Offset="1"/>
              </LinearGradientBrush>
            </Button.Background>
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </ControlTemplate>
            </Button.Template>
            <TextBlock x:Name="AiSendText" Text="Send"/>
          </Button>
        </Grid>
      </Grid>

    </Grid>
  </Grid>
</Window>
"@

# ─── Load XAML ──────────────────────────────────────────────────────────────
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
function ctl($name) { $window.FindName($name) }

# ─── Logo + icon ────────────────────────────────────────────────────────────
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

$icoPath = Join-Path $appDir 'lightmenu.ico'
if (Test-Path $icoPath) {
    try {
        $script:appIcon = New-Object System.Windows.Media.Imaging.BitmapImage
        $script:appIcon.BeginInit()
        $script:appIcon.UriSource = New-Object System.Uri($icoPath, [System.UriKind]::Absolute)
        $script:appIcon.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $script:appIcon.EndInit()
        $window.Icon = $script:appIcon
        # Apply the LightMenu icon to EVERY window the app opens (QR popups, editors,
        # confirmations) so none fall back to the PowerShell host icon in the title
        # bar or taskbar. One class handler covers all current and future dialogs.
        [System.Windows.EventManager]::RegisterClassHandler(
            [System.Windows.Window],
            [System.Windows.FrameworkElement]::LoadedEvent,
            [System.Windows.RoutedEventHandler]{ param($s, $e) try { if ($script:appIcon) { $s.Icon = $script:appIcon } } catch {} },
            $true
        )
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

# ─── HELPERS ────────────────────────────────────────────────────────────────
function SolidBrush($hex) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }
# Build a translucent colour. WPF hex is #AARRGGBB (alpha FIRST), unlike CSS's
# #RRGGBBAA, so the alpha byte must be PREFIXED — e.g. Tint '#8b5cf6' '20' -> '#208b5cf6'.
function Tint($hex, $aa) { return '#' + $aa + ($hex -replace '^#','') }

# ─── LANGUAGE SYSTEM ────────────────────────────────────────────────────────
$script:i18n = @{
    en = @{
        nav_home='Home'
        home_title='Control Center'; home_choose='Choose a section to get started'
        home_no_orders='No orders yet today'; home_orders_today='orders today'
        home_orders_t='Orders';            home_orders_d='Take table orders, fire courses, and close checks.'
        home_floor_t='Floor Plan';         home_floor_d="Live floor map — every table's status at a glance."
        home_menu_t='Menu';                home_menu_d='Add and edit items, categories, pricing, and availability.'
        home_kitchen_t='Kitchen & Printing'; home_kitchen_d='Connect thermal printers and customize kitchen tickets.'
        home_ai_t='LightMenu AI';          home_ai_d='Ask the assistant to run the whole station for you.'
        home_staff_t='Team & Roles';       home_staff_d='Manage your staff, roles, and waiter access.'
        home_analytics_t='Analytics';      home_analytics_d='Revenue, payment breakdown, and sales trends.'
        home_bills_t='Bills';              home_bills_d='Browse saved bills and reprint any receipt.'
        home_report_t='Daily Report';      home_report_d='End-of-day revenue and top-selling items.'
        nav_dashboard='Dashboard'; nav_analytics='Analytics'; nav_bills='Bills'; nav_report='Daily Report'; nav_staff='Staff'
        lbl_printer='PRINTER'; lbl_last_update='LAST UPDATE'; lbl_free='Free'; lbl_dishes='Dishes out'; lbl_reclaim='To reclaim'; lbl_check='Check printed'
        lbl_drag_hint='Drag to arrange · tap to edit'; btn_add_floor='+ Floor'; btn_add_table='+ Table'; btn_del_floor='Delete Floor'
        btn_rescan='Rescan Printers'; btn_restart='Restart Agent'
        period_today='Today'; period_week='This Week'; period_month='This Month'; period_all='All Time'; period_refresh='Refresh'
        lbl_total_revenue='TOTAL REVENUE'; lbl_total_orders='TOTAL ORDERS'; lbl_avg_ticket='AVG TICKET'; lbl_best_day='BEST DAY'
        lbl_payment_methods='PAYMENT METHODS'; lbl_cash='Cash'; lbl_card='Card'; lbl_mixed='Mixed'
        lbl_revenue_chart='Revenue - Last 7 Days'
        bills_info='Bills are stored locally on this PC and survive restarts. Export to CSV for permanent backup.'
        lbl_from='From:'; lbl_to='To:'; btn_apply='Apply'; btn_export_csv='Export CSV'
        lbl_gen_report='GENERATE REPORT'; lbl_date='Date:'; lbl_start='Start:'; lbl_end='End:'; btn_generate='Generate'; btn_save_report='Save Report as Text File'
        lbl_rep_revenue='REVENUE'; lbl_rep_orders='ORDERS'; lbl_rep_avg='AVG TICKET'; lbl_pay_breakdown='PAYMENT BREAKDOWN'; lbl_top_items='TOP ITEMS'
        report_empty='Generate a report to see the breakdown.'
        staff_title='Staff'; btn_add_staff='+ Add Staff'; lbl_staff_name='Name'; lbl_staff_role='Role'
        staff_last_used='Last used:'; staff_never_used='Never used'; staff_active='Active'; staff_inactive='Inactive'
        staff_set_pin='Set PIN'; staff_pin_invalid='PIN must be 4 to 6 digits.'
        btn_remove='Remove'; btn_toggle='Toggle'; btn_copy_link='Copy link'
        confirm_remove='Remove this staff member?'; confirm_restart='Restart the print agent now? Any in-flight prints will be retried.'
        rescan_info='Rescan started. Check the live log for results.'
        no_staff='No staff added yet. Click "+ Add Staff" to get started.'
        dlg_add_staff_title='Add Staff Member'; dlg_ok='Add'; dlg_cancel='Cancel'
        nav_menu='Menu'; nav_kitchen='Printer'
        menu_search='Search items...'; menu_refresh='Refresh'; menu_all_items='All items'
        menu_col_item='ITEM'; menu_col_status='STATUS'; menu_col_price='PRICE'
        menu_available='Available'; menu_unavailable='Unavailable'; menu_empty='No items to show.'
        menu_synced='synced'; menu_offline_cache='offline (cached)'
        kitchen_title='Printer Setup'; lbl_this_station='THIS STATION'
        btn_add_printer='+ Add Printer'; btn_test_print='Test Print'; btn_save='Save'
        printer_type='Type'; printer_no_ip='no IP'; printer_searching='Searching for printer...'
        no_printers='No printers configured. Click "+ Add Printer" to set one up.'
        printers_offline='Cannot reach Supabase. Showing nothing while offline.'
        test_print_sent='Test ticket sent to the printer.'; test_print_fail='Could not reach that printer.'
        confirm_remove_printer='Remove this printer?'; printer_remove_fail='Could not remove the printer.'
        printer_add_fail='Could not add the printer.'; invalid_ip='Enter a valid IP address (e.g. 192.168.1.50).'
        new_printer_name='Printer name'; new_printer_ip='IP (optional)'
        btn_edit='Edit'; btn_rename='Rename'; btn_delete='Delete'
        menu_add_item='Add Item'; menu_edit_item='Edit Item'; menu_add_category='Add Category'; menu_rename_category='Rename Category'
        menu_f_name='Name'; menu_f_desc='Description'; menu_f_price='Price'; menu_f_category='Category'
        menu_f_section='Section'; menu_section_hint='Groups categories on your public menu (e.g. menu, drinks). Pick one or type a new name.'
        menu_move_to_section='Move to section'; menu_move_to_category='Move to category'
        menu_new_section='New section...'; menu_new_section_prompt='Name of the new section:'
        menu_f_available='Item is available'; menu_f_addon='Mark as paid add-on'; menu_uncategorized='Uncategorized'
        menu_name_req='Name is required.'; menu_name_price_req='Name and price are required.'
        menu_save_fail='Could not save. Check your connection and try again.'
        confirm_delete_item='Delete'; confirm_delete_category='Delete category and all its items:'
        printer_edit='Edit Printer'; printer_save_fail='Could not save the printer.'
        ts_saved='Ticket settings saved. They apply to every future ticket.'
    }
    fr = @{
        nav_dashboard='Tableau de bord'; nav_analytics='Analytiques'; nav_bills='Factures'; nav_report='Rapport du jour'; nav_staff='Equipe'
        lbl_printer='IMPRIMANTE'; lbl_tunnel='TUNNEL'; lbl_today_session="AUJOURD'HUI"; lbl_last_update='DERNIERE MAJ'; lbl_live_log='JOURNAL'
        btn_rescan='Rechercher imprimantes'; btn_restart='Redemarrer'; btn_clear='Effacer'
        period_today="Aujourd'hui"; period_week='Cette semaine'; period_month='Ce mois'; period_all='Tout'; period_refresh='Actualiser'
        lbl_total_revenue="CHIFFRE D'AFFAIRES"; lbl_total_orders='TOTAL COMMANDES'; lbl_avg_ticket='TICKET MOYEN'; lbl_best_day='MEILLEUR JOUR'
        lbl_payment_methods='MODES DE PAIEMENT'; lbl_cash='Especes'; lbl_card='Carte'; lbl_mixed='Mixte'
        lbl_revenue_chart="Chiffre d'affaires - 7 derniers jours"
        bills_info='Les factures sont stockees localement et survivent aux redemarrages. Exportez en CSV pour une sauvegarde permanente.'
        lbl_from='Du :'; lbl_to='Au :'; btn_apply='Appliquer'; btn_export_csv='Exporter CSV'
        lbl_gen_report='GENERER UN RAPPORT'; lbl_date='Date :'; lbl_start='Debut :'; lbl_end='Fin :'; btn_generate='Generer'; btn_save_report='Enregistrer le rapport'
        lbl_rep_revenue='REVENUS'; lbl_rep_orders='COMMANDES'; lbl_rep_avg='TICKET MOYEN'; lbl_pay_breakdown='REPARTITION PAIEMENTS'; lbl_top_items='ARTICLES TOP'
        report_empty='Generez un rapport pour voir la synthese.'
        staff_title='Equipe'; btn_add_staff='+ Ajouter'; lbl_staff_name='Nom'; lbl_staff_role='Role'
        staff_last_used='Vu :'; staff_never_used='Jamais utilise'; staff_active='Actif'; staff_inactive='Inactif'
        btn_remove='Supprimer'; btn_toggle='Activer/Desact.'; btn_copy_link='Copier lien'
        confirm_remove='Supprimer ce membre du personnel ?'; confirm_restart="Redemarrer l'agent maintenant ?"
        rescan_info='Recherche lancee. Verifiez le journal pour les resultats.'
        no_staff='Aucun personnel. Cliquez sur "+ Ajouter" pour commencer.'
        dlg_add_staff_title='Ajouter un membre'; dlg_ok='Ajouter'; dlg_cancel='Annuler'
        nav_menu='Menu'; nav_kitchen='Cuisine'; menu_all_items='Tous les articles'; menu_available='Disponible'; menu_unavailable='Indisponible'
        kitchen_title='Cuisine et impression'; btn_add_printer='+ Ajouter imprimante'; btn_test_print='Test impression'
        no_printers='Aucune imprimante. Cliquez sur "+ Ajouter imprimante".'; printer_type='Type'
    }
    ar = @{
        nav_dashboard='لوحة التحكم'; nav_analytics='التحليلات'; nav_bills='الفواتير'; nav_report='تقرير اليوم'; nav_staff='الموظفون'
        lbl_printer='الطابعة'; lbl_tunnel='الاتصال'; lbl_today_session='اليوم'; lbl_last_update='آخر تحديث'; lbl_live_log='السجل المباشر'
        btn_rescan='البحث عن طابعات'; btn_restart='إعادة التشغيل'; btn_clear='مسح'
        period_today='اليوم'; period_week='هذا الأسبوع'; period_month='هذا الشهر'; period_all='كل الوقت'; period_refresh='تحديث'
        lbl_total_revenue='إجمالي الإيرادات'; lbl_total_orders='إجمالي الطلبات'; lbl_avg_ticket='متوسط الفاتورة'; lbl_best_day='أفضل يوم'
        lbl_payment_methods='طرق الدفع'; lbl_cash='نقد'; lbl_card='بطاقة'; lbl_mixed='مختلط'
        lbl_revenue_chart='الإيرادات - آخر 7 أيام'
        bills_info='يتم تخزين الفواتير محليا وتبقى بعد إعادة التشغيل. صدّر إلى CSV للنسخ الاحتياطي.'
        lbl_from='من:'; lbl_to='إلى:'; btn_apply='تطبيق'; btn_export_csv='تصدير CSV'
        lbl_gen_report='إنشاء تقرير'; lbl_date='التاريخ:'; lbl_start='البداية:'; lbl_end='النهاية:'; btn_generate='إنشاء'; btn_save_report='حفظ التقرير'
        lbl_rep_revenue='الإيرادات'; lbl_rep_orders='الطلبات'; lbl_rep_avg='متوسط الفاتورة'; lbl_pay_breakdown='توزيع المدفوعات'; lbl_top_items='الأصناف الأكثر طلبا'
        report_empty='أنشئ تقريرا لرؤية الملخص.'
        staff_title='الموظفون'; btn_add_staff='+ إضافة موظف'; lbl_staff_name='الاسم'; lbl_staff_role='الدور'
        staff_last_used='آخر استخدام:'; staff_never_used='لم يستخدم'; staff_active='نشط'; staff_inactive='غير نشط'
        btn_remove='حذف'; btn_toggle='تفعيل/إيقاف'; btn_copy_link='نسخ الرابط'
        confirm_remove='هل تريد حذف هذا الموظف؟'; confirm_restart='إعادة تشغيل الوكيل الآن؟'
        rescan_info='بدأ البحث. تحقق من السجل للنتائج.'
        no_staff='لا يوجد موظفون. اضغط على "+ إضافة موظف" للبدء.'
        dlg_add_staff_title='إضافة موظف'; dlg_ok='إضافة'; dlg_cancel='إلغاء'
        nav_menu='القائمة'; nav_kitchen='المطبخ'; menu_all_items='كل الأصناف'; menu_available='متوفر'; menu_unavailable='غير متوفر'
        kitchen_title='المطبخ والطباعة'; btn_add_printer='+ إضافة طابعة'; btn_test_print='طباعة تجريبية'
        no_printers='لا توجد طابعات. اضغط على "+ إضافة طابعة".'; printer_type='النوع'
    }
}
$script:langCycle = @('en','fr','es','it','de','pt','nl','ru','ar','zh')
$script:langMeta = @{
    en = @{ flag='[US]'; name='English' }
    fr = @{ flag='[FR]'; name='Français' }
    es = @{ flag='[ES]'; name='Español' }
    it = @{ flag='[IT]'; name='Italiano' }
    de = @{ flag='[DE]'; name='Deutsch' }
    pt = @{ flag='[PT]'; name='Português' }
    nl = @{ flag='[NL]'; name='Nederlands' }
    ru = @{ flag='[RU]'; name='Русский' }
    ar = @{ flag='[SA]'; name='العربية' }
    zh = @{ flag='[CN]'; name='中文' }
}

# Translations for the additional languages
$script:i18n['es'] = @{
    nav_dashboard='Panel'; nav_analytics='Analíticas'; nav_bills='Facturas'; nav_report='Reporte Diario'; nav_staff='Personal'
    lbl_printer='IMPRESORA'; lbl_tunnel='TUNEL'; lbl_today_session='HOY'; lbl_last_update='ULTIMA ACT.'; lbl_live_log='REGISTRO'
    btn_rescan='Buscar Impresoras'; btn_restart='Reiniciar'; btn_clear='Limpiar'
    period_today='Hoy'; period_week='Esta Semana'; period_month='Este Mes'; period_all='Todo'; period_refresh='Actualizar'
    lbl_total_revenue='INGRESOS TOTALES'; lbl_total_orders='PEDIDOS TOTALES'; lbl_avg_ticket='TICKET PROMEDIO'; lbl_best_day='MEJOR DIA'
    lbl_payment_methods='METODOS DE PAGO'; lbl_cash='Efectivo'; lbl_card='Tarjeta'; lbl_mixed='Mixto'
    lbl_revenue_chart='Ingresos - Últimos 7 días'
    bills_info='Las facturas se guardan localmente y sobreviven a reinicios. Exporta a CSV para respaldo.'
    lbl_from='Desde:'; lbl_to='Hasta:'; btn_apply='Aplicar'; btn_export_csv='Exportar CSV'
    lbl_gen_report='GENERAR REPORTE'; lbl_date='Fecha:'; lbl_start='Inicio:'; lbl_end='Fin:'; btn_generate='Generar'; btn_save_report='Guardar Reporte'
    lbl_rep_revenue='INGRESOS'; lbl_rep_orders='PEDIDOS'; lbl_rep_avg='TICKET PROM.'; lbl_pay_breakdown='DESGLOSE PAGOS'; lbl_top_items='ARTICULOS TOP'
    report_empty='Genera un reporte para ver el desglose.'
    staff_title='Personal'; btn_add_staff='+ Añadir'; lbl_staff_name='Nombre'; lbl_staff_role='Rol'
    staff_last_used='Última:'; staff_never_used='Nunca usado'; staff_active='Activo'; staff_inactive='Inactivo'
    btn_remove='Eliminar'; btn_toggle='Activar/Desact.'; btn_copy_link='Copiar enlace'
    confirm_remove='¿Eliminar este miembro?'; confirm_restart='¿Reiniciar el agente ahora?'
    rescan_info='Búsqueda iniciada. Revisa el registro.'
    no_staff='Sin personal. Haz clic en "+ Añadir" para empezar.'
    dlg_add_staff_title='Añadir Miembro'; dlg_ok='Añadir'; dlg_cancel='Cancelar'
    nav_menu='Menú'; nav_kitchen='Cocina'; menu_all_items='Todos'; menu_available='Disponible'; menu_unavailable='No disponible'
    kitchen_title='Cocina e impresión'; btn_add_printer='+ Añadir impresora'; btn_test_print='Prueba'
    no_printers='Sin impresoras. Haz clic en "+ Añadir impresora".'; printer_type='Tipo'
}
$script:i18n['it'] = @{
    nav_dashboard='Cruscotto'; nav_analytics='Analisi'; nav_bills='Conti'; nav_report='Rapporto Giornaliero'; nav_staff='Personale'
    lbl_printer='STAMPANTE'; lbl_tunnel='TUNNEL'; lbl_today_session='OGGI'; lbl_last_update='ULTIMO AGG.'; lbl_live_log='LOG'
    btn_rescan='Cerca Stampanti'; btn_restart='Riavvia'; btn_clear='Pulisci'
    period_today='Oggi'; period_week='Questa Settimana'; period_month='Questo Mese'; period_all='Tutto'; period_refresh='Aggiorna'
    lbl_total_revenue='RICAVO TOTALE'; lbl_total_orders='ORDINI TOTALI'; lbl_avg_ticket='TICKET MEDIO'; lbl_best_day='GIORNO MIGLIORE'
    lbl_payment_methods='METODI PAGAMENTO'; lbl_cash='Contanti'; lbl_card='Carta'; lbl_mixed='Misto'
    lbl_revenue_chart='Ricavi - Ultimi 7 giorni'
    bills_info='I conti sono salvati localmente e sopravvivono ai riavvii. Esporta in CSV per backup.'
    lbl_from='Da:'; lbl_to='A:'; btn_apply='Applica'; btn_export_csv='Esporta CSV'
    lbl_gen_report='GENERA RAPPORTO'; lbl_date='Data:'; lbl_start='Inizio:'; lbl_end='Fine:'; btn_generate='Genera'; btn_save_report='Salva Rapporto'
    lbl_rep_revenue='RICAVO'; lbl_rep_orders='ORDINI'; lbl_rep_avg='TICKET MEDIO'; lbl_pay_breakdown='DETTAGLI PAGAMENTI'; lbl_top_items='ARTICOLI TOP'
    report_empty='Genera un rapporto per vedere il dettaglio.'
    staff_title='Personale'; btn_add_staff='+ Aggiungi'; lbl_staff_name='Nome'; lbl_staff_role='Ruolo'
    staff_last_used='Ultimo:'; staff_never_used='Mai usato'; staff_active='Attivo'; staff_inactive='Inattivo'
    btn_remove='Rimuovi'; btn_toggle='Attiva/Disatt.'; btn_copy_link='Copia link'
    confirm_remove='Rimuovere questo membro?'; confirm_restart="Riavviare l'agente ora?"
    rescan_info='Scansione avviata. Controlla il log.'
    no_staff='Nessun personale. Clicca "+ Aggiungi" per iniziare.'
    dlg_add_staff_title='Aggiungi Membro'; dlg_ok='Aggiungi'; dlg_cancel='Annulla'
    nav_menu='Menu'; nav_kitchen='Cucina'; menu_all_items='Tutti'; menu_available='Disponibile'; menu_unavailable='Non disponibile'
    kitchen_title='Cucina e stampa'; btn_add_printer='+ Aggiungi stampante'; btn_test_print='Prova'
    no_printers='Nessuna stampante. Clicca "+ Aggiungi stampante".'; printer_type='Tipo'
}
$script:i18n['de'] = @{
    nav_dashboard='Übersicht'; nav_analytics='Analyse'; nav_bills='Rechnungen'; nav_report='Tagesbericht'; nav_staff='Personal'
    lbl_printer='DRUCKER'; lbl_tunnel='TUNNEL'; lbl_today_session='HEUTE'; lbl_last_update='LETZTES UPDATE'; lbl_live_log='PROTOKOLL'
    btn_rescan='Drucker suchen'; btn_restart='Neustart'; btn_clear='Leeren'
    period_today='Heute'; period_week='Diese Woche'; period_month='Dieser Monat'; period_all='Alle'; period_refresh='Aktualisieren'
    lbl_total_revenue='GESAMTUMSATZ'; lbl_total_orders='BESTELLUNGEN'; lbl_avg_ticket='DURCHSCHNITT'; lbl_best_day='BESTER TAG'
    lbl_payment_methods='ZAHLUNGSARTEN'; lbl_cash='Bar'; lbl_card='Karte'; lbl_mixed='Gemischt'
    lbl_revenue_chart='Umsatz - Letzte 7 Tage'
    bills_info='Rechnungen werden lokal gespeichert und überleben Neustarts. Exportiere in CSV für Backup.'
    lbl_from='Von:'; lbl_to='Bis:'; btn_apply='Anwenden'; btn_export_csv='CSV exportieren'
    lbl_gen_report='BERICHT ERSTELLEN'; lbl_date='Datum:'; lbl_start='Start:'; lbl_end='Ende:'; btn_generate='Erstellen'; btn_save_report='Bericht speichern'
    lbl_rep_revenue='UMSATZ'; lbl_rep_orders='BESTELLUNGEN'; lbl_rep_avg='DURCHSCHNITT'; lbl_pay_breakdown='ZAHLUNGEN'; lbl_top_items='TOP ARTIKEL'
    report_empty='Bericht erstellen für Übersicht.'
    staff_title='Personal'; btn_add_staff='+ Hinzufügen'; lbl_staff_name='Name'; lbl_staff_role='Rolle'
    staff_last_used='Zuletzt:'; staff_never_used='Nie benutzt'; staff_active='Aktiv'; staff_inactive='Inaktiv'
    btn_remove='Entfernen'; btn_toggle='Akt./Deakt.'; btn_copy_link='Link kopieren'
    confirm_remove='Mitglied entfernen?'; confirm_restart='Agent jetzt neustarten?'
    rescan_info='Scan gestartet. Siehe Protokoll.'
    no_staff='Kein Personal. Klicke "+ Hinzufügen" zum Starten.'
    dlg_add_staff_title='Mitglied hinzufügen'; dlg_ok='Hinzufügen'; dlg_cancel='Abbrechen'
    nav_menu='Menü'; nav_kitchen='Küche'; menu_all_items='Alle'; menu_available='Verfügbar'; menu_unavailable='Nicht verfügbar'
    kitchen_title='Küche & Druck'; btn_add_printer='+ Drucker hinzufügen'; btn_test_print='Testdruck'
    no_printers='Keine Drucker. Klicke "+ Drucker hinzufügen".'; printer_type='Typ'
}
$script:i18n['pt'] = @{
    nav_dashboard='Painel'; nav_analytics='Análises'; nav_bills='Faturas'; nav_report='Relatório Diário'; nav_staff='Equipe'
    lbl_printer='IMPRESSORA'; lbl_tunnel='TUNEL'; lbl_today_session='HOJE'; lbl_last_update='ULTIMA ATUAL.'; lbl_live_log='REGISTO'
    btn_rescan='Buscar Impressoras'; btn_restart='Reiniciar'; btn_clear='Limpar'
    period_today='Hoje'; period_week='Esta Semana'; period_month='Este Mês'; period_all='Tudo'; period_refresh='Atualizar'
    lbl_total_revenue='RECEITA TOTAL'; lbl_total_orders='PEDIDOS TOTAIS'; lbl_avg_ticket='TICKET MEDIO'; lbl_best_day='MELHOR DIA'
    lbl_payment_methods='METODOS PAGAMENTO'; lbl_cash='Dinheiro'; lbl_card='Cartão'; lbl_mixed='Misto'
    lbl_revenue_chart='Receita - Últimos 7 dias'
    bills_info='Faturas armazenadas localmente. Exporte para CSV para backup.'
    lbl_from='De:'; lbl_to='Até:'; btn_apply='Aplicar'; btn_export_csv='Exportar CSV'
    lbl_gen_report='GERAR RELATORIO'; lbl_date='Data:'; lbl_start='Início:'; lbl_end='Fim:'; btn_generate='Gerar'; btn_save_report='Salvar Relatório'
    lbl_rep_revenue='RECEITA'; lbl_rep_orders='PEDIDOS'; lbl_rep_avg='TICKET MEDIO'; lbl_pay_breakdown='PAGAMENTOS'; lbl_top_items='TOP ITENS'
    report_empty='Gere um relatório para ver os detalhes.'
    staff_title='Equipe'; btn_add_staff='+ Adicionar'; lbl_staff_name='Nome'; lbl_staff_role='Função'
    staff_last_used='Último:'; staff_never_used='Nunca usado'; staff_active='Ativo'; staff_inactive='Inativo'
    btn_remove='Remover'; btn_toggle='Ativar/Desat.'; btn_copy_link='Copiar link'
    confirm_remove='Remover este membro?'; confirm_restart='Reiniciar o agente agora?'
    rescan_info='Busca iniciada. Veja o registo.'
    no_staff='Sem equipe. Clique "+ Adicionar" para começar.'
    dlg_add_staff_title='Adicionar Membro'; dlg_ok='Adicionar'; dlg_cancel='Cancelar'
    nav_menu='Menu'; nav_kitchen='Cozinha'; menu_all_items='Todos'; menu_available='Disponível'; menu_unavailable='Indisponível'
    kitchen_title='Cozinha e impressão'; btn_add_printer='+ Adicionar impressora'; btn_test_print='Teste'
    no_printers='Sem impressoras. Clique "+ Adicionar impressora".'; printer_type='Tipo'
}
$script:i18n['nl'] = @{
    nav_dashboard='Dashboard'; nav_analytics='Analyse'; nav_bills='Rekeningen'; nav_report='Dagrapport'; nav_staff='Personeel'
    lbl_printer='PRINTER'; lbl_tunnel='TUNNEL'; lbl_today_session='VANDAAG'; lbl_last_update='LAATSTE UPD.'; lbl_live_log='LOG'
    btn_rescan='Printers zoeken'; btn_restart='Herstart'; btn_clear='Wissen'
    period_today='Vandaag'; period_week='Deze Week'; period_month='Deze Maand'; period_all='Alles'; period_refresh='Vernieuwen'
    lbl_total_revenue='TOTALE OMZET'; lbl_total_orders='TOTAAL BESTELLINGEN'; lbl_avg_ticket='GEM. TICKET'; lbl_best_day='BESTE DAG'
    lbl_payment_methods='BETAALMETHODEN'; lbl_cash='Contant'; lbl_card='Kaart'; lbl_mixed='Gemengd'
    lbl_revenue_chart='Omzet - Laatste 7 dagen'
    bills_info='Rekeningen worden lokaal opgeslagen. Exporteer naar CSV voor back-up.'
    lbl_from='Van:'; lbl_to='Tot:'; btn_apply='Toepassen'; btn_export_csv='Exporteer CSV'
    lbl_gen_report='RAPPORT MAKEN'; lbl_date='Datum:'; lbl_start='Start:'; lbl_end='Einde:'; btn_generate='Maken'; btn_save_report='Rapport opslaan'
    lbl_rep_revenue='OMZET'; lbl_rep_orders='BESTELLINGEN'; lbl_rep_avg='GEM. TICKET'; lbl_pay_breakdown='BETALINGEN'; lbl_top_items='TOP ITEMS'
    report_empty='Maak een rapport voor details.'
    staff_title='Personeel'; btn_add_staff='+ Toevoegen'; lbl_staff_name='Naam'; lbl_staff_role='Rol'
    staff_last_used='Laatst:'; staff_never_used='Nooit gebruikt'; staff_active='Actief'; staff_inactive='Inactief'
    btn_remove='Verwijderen'; btn_toggle='Aan/Uit'; btn_copy_link='Kopieer link'
    confirm_remove='Lid verwijderen?'; confirm_restart='Agent nu herstarten?'
    rescan_info='Scan gestart. Zie log.'
    no_staff='Geen personeel. Klik "+ Toevoegen" om te beginnen.'
    dlg_add_staff_title='Lid toevoegen'; dlg_ok='Toevoegen'; dlg_cancel='Annuleren'
    nav_menu='Menu'; nav_kitchen='Keuken'; menu_all_items='Alle'; menu_available='Beschikbaar'; menu_unavailable='Niet beschikbaar'
    kitchen_title='Keuken & printen'; btn_add_printer='+ Printer toevoegen'; btn_test_print='Test'
    no_printers='Geen printers. Klik "+ Printer toevoegen".'; printer_type='Type'
}
$script:i18n['ru'] = @{
    nav_dashboard='Панель'; nav_analytics='Аналитика'; nav_bills='Счета'; nav_report='Дневной Отчет'; nav_staff='Персонал'
    lbl_printer='ПРИНТЕР'; lbl_tunnel='ТУННЕЛЬ'; lbl_today_session='СЕГОДНЯ'; lbl_last_update='ОБНОВЛЕНИЕ'; lbl_live_log='ЖУРНАЛ'
    btn_rescan='Найти принтеры'; btn_restart='Перезапуск'; btn_clear='Очистить'
    period_today='Сегодня'; period_week='Эта Неделя'; period_month='Этот Месяц'; period_all='Все Время'; period_refresh='Обновить'
    lbl_total_revenue='ОБЩАЯ ВЫРУЧКА'; lbl_total_orders='ВСЕГО ЗАКАЗОВ'; lbl_avg_ticket='СРЕДНИЙ ЧЕК'; lbl_best_day='ЛУЧШИЙ ДЕНЬ'
    lbl_payment_methods='СПОСОБЫ ОПЛАТЫ'; lbl_cash='Наличные'; lbl_card='Карта'; lbl_mixed='Смешанная'
    lbl_revenue_chart='Выручка - Последние 7 дней'
    bills_info='Счета хранятся локально. Экспортируйте в CSV для резервной копии.'
    lbl_from='С:'; lbl_to='По:'; btn_apply='Применить'; btn_export_csv='Экспорт CSV'
    lbl_gen_report='СОЗДАТЬ ОТЧЕТ'; lbl_date='Дата:'; lbl_start='Начало:'; lbl_end='Конец:'; btn_generate='Создать'; btn_save_report='Сохранить отчет'
    lbl_rep_revenue='ВЫРУЧКА'; lbl_rep_orders='ЗАКАЗЫ'; lbl_rep_avg='СРЕДНИЙ ЧЕК'; lbl_pay_breakdown='ПЛАТЕЖИ'; lbl_top_items='ТОП ТОВАРОВ'
    report_empty='Создайте отчет, чтобы увидеть детали.'
    staff_title='Персонал'; btn_add_staff='+ Добавить'; lbl_staff_name='Имя'; lbl_staff_role='Роль'
    staff_last_used='Посл.:'; staff_never_used='Не использовался'; staff_active='Активен'; staff_inactive='Неактивен'
    btn_remove='Удалить'; btn_toggle='Вкл/Выкл'; btn_copy_link='Копировать'
    confirm_remove='Удалить сотрудника?'; confirm_restart='Перезапустить агент сейчас?'
    rescan_info='Сканирование начато. Смотрите журнал.'
    no_staff='Нет персонала. Нажмите "+ Добавить" чтобы начать.'
    dlg_add_staff_title='Добавить сотрудника'; dlg_ok='Добавить'; dlg_cancel='Отмена'
    nav_menu='Меню'; nav_kitchen='Кухня'; menu_all_items='Все'; menu_available='Доступно'; menu_unavailable='Недоступно'
    kitchen_title='Кухня и печать'; btn_add_printer='+ Добавить принтер'; btn_test_print='Тест'
    no_printers='Нет принтеров. Нажмите "+ Добавить принтер".'; printer_type='Тип'
}
$script:i18n['zh'] = @{
    nav_dashboard='仪表盘'; nav_analytics='分析'; nav_bills='账单'; nav_report='日报'; nav_staff='员工'
    lbl_printer='打印机'; lbl_tunnel='隧道'; lbl_today_session='今日'; lbl_last_update='最后更新'; lbl_live_log='实时日志'
    btn_rescan='扫描打印机'; btn_restart='重启'; btn_clear='清除'
    period_today='今日'; period_week='本周'; period_month='本月'; period_all='全部'; period_refresh='刷新'
    lbl_total_revenue='总收入'; lbl_total_orders='总订单'; lbl_avg_ticket='平均单价'; lbl_best_day='最佳日'
    lbl_payment_methods='支付方式'; lbl_cash='现金'; lbl_card='卡'; lbl_mixed='混合'
    lbl_revenue_chart='收入 - 过去7天'
    bills_info='账单本地存储。导出CSV以备份。'
    lbl_from='从:'; lbl_to='至:'; btn_apply='应用'; btn_export_csv='导出CSV'
    lbl_gen_report='生成报告'; lbl_date='日期:'; lbl_start='开始:'; lbl_end='结束:'; btn_generate='生成'; btn_save_report='保存报告'
    lbl_rep_revenue='收入'; lbl_rep_orders='订单'; lbl_rep_avg='平均单价'; lbl_pay_breakdown='支付明细'; lbl_top_items='热销商品'
    report_empty='生成报告以查看详情。'
    staff_title='员工'; btn_add_staff='+ 添加员工'; lbl_staff_name='姓名'; lbl_staff_role='角色'
    staff_last_used='最后:'; staff_never_used='未使用'; staff_active='在线'; staff_inactive='离线'
    btn_remove='删除'; btn_toggle='切换'; btn_copy_link='复制链接'
    confirm_remove='删除此员工？'; confirm_restart='立即重启代理？'
    rescan_info='扫描已开始。查看日志。'
    no_staff='暂无员工。点击"+ 添加员工"开始。'
    dlg_add_staff_title='添加员工'; dlg_ok='添加'; dlg_cancel='取消'
    nav_menu='菜单'; nav_kitchen='厨房'; menu_all_items='全部'; menu_available='可用'; menu_unavailable='不可用'
    kitchen_title='厨房与打印'; btn_add_printer='+ 添加打印机'; btn_test_print='测试打印'
    no_printers='无打印机。点击"+ 添加打印机"。'; printer_type='类型'
}

function T($key) {
    $d = $script:i18n[$script:lang]
    if ($d -and $d.ContainsKey($key)) { return $d[$key] }
    $d2 = $script:i18n['en']
    if ($d2 -and $d2.ContainsKey($key)) { return $d2[$key] }
    return $key
}

# Section icon prefix. 0x1Fxxx emoji are above the BMP, so build them with
# ConvertFromUtf32 (a plain [char] cast throws). WPF falls back to Segoe UI Emoji.
function NavIcon([int]$cp, [string]$label) {
    return ([System.Char]::ConvertFromUtf32($cp)) + '  ' + $label
}

function Apply-Language {
    $rtl = ($script:lang -eq 'ar')
    $window.FlowDirection = if ($rtl) { 'RightToLeft' } else { 'LeftToRight' }

    # Nav
    (ctl 'NavDashboard').Content = NavIcon 0x1F5FA (T 'nav_dashboard')   # map
    (ctl 'NavAssistant').Content = NavIcon 0x2728  'LightMenu AI'        # sparkles
    (ctl 'NavMenu').Content      = NavIcon 0x1F37D (T 'nav_menu')        # plate
    (ctl 'NavKitchen').Content   = NavIcon 0x1F5A8 (T 'nav_kitchen')     # printer
    (ctl 'NavOrders').Content    = NavIcon 0x1F4CB 'Orders'              # clipboard
    (ctl 'NavStaff').Content     = NavIcon 0x1F465 (T 'nav_staff')       # people
    (ctl 'NavAnalytics').Content = NavIcon 0x1F4CA (T 'nav_analytics')   # bar chart
    (ctl 'NavBills').Content     = NavIcon 0x1F9FE (T 'nav_bills')       # receipt
    (ctl 'NavReport').Content    = NavIcon 0x1F4C5 (T 'nav_report')      # calendar
    (ctl 'NavHome').Content      = NavIcon 0x1F3E0 (T 'nav_home')        # house

    # Home / Control Center
    (ctl 'BackBtn').Content = ([char]0x2190) + '   ' + (T 'home_title')   # ← Control Center
    (ctl 'HomeTitle').Text = T 'home_title'
    if ($script:activePage -ne 'Home') { (ctl 'HomeSubtitle').Text = T 'home_choose' }
    if ($script:homeLabels) {
        foreach ($h in $script:homeLabels) { $h.Title.Text = (T $h.titleKey); $h.Desc.Text = (T $h.descKey) }
    }

    # Menu page
    (ctl 'MenuRefresh').Content = T 'menu_refresh'
    (ctl 'MenuColName').Text    = T 'menu_col_item'
    (ctl 'MenuColAvail').Text   = T 'menu_col_status'
    (ctl 'MenuColPrice').Text   = T 'menu_col_price'

    # Kitchen page
    (ctl 'KitchenTitle').Text    = T 'kitchen_title'
    (ctl 'KitchenRefresh').Content = T 'menu_refresh'
    (ctl 'LblLivePrinter').Text  = T 'lbl_this_station'
    (ctl 'AddPrinterBtn').Content = T 'btn_add_printer'
    (ctl 'SavePrinterBtn').Content = T 'btn_save'
    (ctl 'CancelPrinterBtn').Content = T 'dlg_cancel'

    # Dashboard labels
    (ctl 'LblPrinter').Text     = T 'lbl_printer'
    (ctl 'LblLastUpdate').Text  = T 'lbl_last_update'
    (ctl 'LblFree').Text        = T 'lbl_free'
    (ctl 'LblDishes').Text      = T 'lbl_dishes'
    (ctl 'LblReclaim').Text     = T 'lbl_reclaim'
    (ctl 'LblCheck').Text       = T 'lbl_check'
    (ctl 'LblDragHint').Text    = T 'lbl_drag_hint'
    (ctl 'AddFloorBtn').Content = T 'btn_add_floor'
    (ctl 'AddTableBtn').Content = T 'btn_add_table'
    (ctl 'DelFloorBtn').Content = T 'btn_del_floor'
    (ctl 'TestBtn').Content     = T 'btn_rescan'
    (ctl 'RestartBtn').Content  = T 'btn_restart'

    # Analytics
    (ctl 'PeriodToday').Content   = T 'period_today'
    (ctl 'PeriodWeek').Content    = T 'period_week'
    (ctl 'PeriodMonth').Content   = T 'period_month'
    (ctl 'PeriodAll').Content     = T 'period_all'
    (ctl 'PeriodRefresh').Content = T 'period_refresh'
    (ctl 'LblTotalRevenue').Text  = T 'lbl_total_revenue'
    (ctl 'LblTotalOrders').Text   = T 'lbl_total_orders'
    (ctl 'LblAvgTicket').Text     = T 'lbl_avg_ticket'
    (ctl 'LblBestDay').Text       = T 'lbl_best_day'
    (ctl 'LblPaymentMethods').Text= T 'lbl_payment_methods'
    (ctl 'LblCash').Text          = T 'lbl_cash'
    (ctl 'LblCard').Text          = T 'lbl_card'
    (ctl 'LblMixed').Text         = T 'lbl_mixed'
    (ctl 'ChartTitle').Text       = T 'lbl_revenue_chart'

    # Bills
    (ctl 'BillsInfoText').Text  = T 'bills_info'
    (ctl 'LblFrom').Text        = T 'lbl_from'
    (ctl 'LblTo').Text          = T 'lbl_to'
    (ctl 'BillRefresh').Content = T 'btn_apply'
    (ctl 'BillExport').Content  = T 'btn_export_csv'

    # Report
    (ctl 'LblGenReport').Text      = T 'lbl_gen_report'
    (ctl 'LblDate').Text           = T 'lbl_date'
    (ctl 'LblStart').Text          = T 'lbl_start'
    (ctl 'LblEnd').Text            = T 'lbl_end'
    (ctl 'ReportGenerate').Content = T 'btn_generate'
    (ctl 'LblRepRevenue').Text     = T 'lbl_rep_revenue'
    (ctl 'LblRepOrders').Text      = T 'lbl_rep_orders'
    (ctl 'LblRepAvg').Text         = T 'lbl_rep_avg'
    (ctl 'LblPayBreakdown').Text   = T 'lbl_pay_breakdown'
    (ctl 'LblTopItems').Text       = T 'lbl_top_items'
    (ctl 'ReportEmpty').Text       = T 'report_empty'
    (ctl 'RepSave').Content        = T 'btn_save_report'

    # Staff
    (ctl 'LblStaffTitle').Text  = T 'staff_title'
    (ctl 'AddStaffBtn').Content = T 'btn_add_staff'

    # Re-render staff cards if on staff page
    if ($script:activePage -eq 'Staff') { Update-Staff-Page }
}

# Populate language dropdown (custom Button + Popup with ListBox)
$langBtn   = ctl 'LangBtn'
$langPopup = ctl 'LangPopup'
$langList  = ctl 'LangList'

function Get-LangBtnText() {
    $btn = ctl 'LangBtn'
    if (-not $btn -or -not $btn.Template) { return $null }
    $btn.ApplyTemplate() | Out-Null
    return $btn.Template.FindName('LangBtnText', $btn)
}

foreach ($code in $script:langCycle) {
    $meta = $script:langMeta[$code]
    $item = New-Object System.Windows.Controls.ListBoxItem
    $item.Content = "$($meta.flag)  $($meta.name)"
    $item.Tag     = $code
    $langList.Items.Add($item) | Out-Null
    if ($code -eq $script:lang) { $langList.SelectedItem = $item }
}

$langBtn.Add_Click({ $langPopup.IsOpen = -not $langPopup.IsOpen })

$langList.Add_SelectionChanged({
    $sel = $langList.SelectedItem
    if (-not $sel -or -not $sel.Tag) { return }
    $langPopup.IsOpen = $false
    if ($sel.Tag -eq $script:lang) { return }
    $script:lang = $sel.Tag
    $btnText = Get-LangBtnText
    if ($btnText) { $btnText.Text = $script:langMeta[$script:lang].name }
    Apply-Language
    Set-Active-Period $script:activePeriod
})

# Set initial label
$initText = Get-LangBtnText
if ($initText) { $initText.Text = $script:langMeta[$script:lang].name }

# ─── PAGE SWITCHING ─────────────────────────────────────────────────────────
$script:activePage  = 'Dashboard'
$script:navButtons  = @{
    'Home'      = (ctl 'NavHome')
    'Dashboard' = (ctl 'NavDashboard')
    'Assistant' = (ctl 'NavAssistant')
    'Menu'      = (ctl 'NavMenu')
    'Kitchen'   = (ctl 'NavKitchen')
    'Orders'    = (ctl 'NavOrders')
    'Analytics' = (ctl 'NavAnalytics')
    'Bills'     = (ctl 'NavBills')
    'Report'    = (ctl 'NavReport')
    'Staff'     = (ctl 'NavStaff')
}
$script:pages = @{
    'Home'      = (ctl 'PageHome')
    'Dashboard' = (ctl 'PageDashboard')
    'Assistant' = (ctl 'PageAssistant')
    'Menu'      = (ctl 'PageMenu')
    'Kitchen'   = (ctl 'PageKitchen')
    'Orders'    = (ctl 'PageOrders')
    'Analytics' = (ctl 'PageAnalytics')
    'Bills'     = (ctl 'PageBills')
    'Report'    = (ctl 'PageReport')
    'Staff'     = (ctl 'PageStaff')
}

function Switch-Page($name) {
    foreach ($k in $script:pages.Keys) {
        if ($k -eq $name) {
            $script:pages[$k].Visibility = 'Visible'
            $script:navButtons[$k].Foreground = [System.Windows.Media.Brushes]::White
            $script:navButtons[$k].Background = SolidBrush '#1A1D29'
        } else {
            $script:pages[$k].Visibility = 'Collapsed'
            $script:navButtons[$k].Foreground = SolidBrush '#7A8295'
            $script:navButtons[$k].Background = [System.Windows.Media.Brushes]::Transparent
        }
    }
    $script:activePage = $name
    # The homepage is the clean landing — hide the tab bar there; show it once
    # the user is inside a section so switching stays one tap.
    (ctl 'NavBar').Visibility = if ($name -eq 'Home') { 'Collapsed' } else { 'Visible' }
    # Defer the (network-bound) page loads until AFTER the page has rendered, so
    # switching tabs is instant instead of freezing the UI while data loads.
    $loader = switch ($name) {
        'Home'      { { Update-Home-Page } }
        'Dashboard' { { Update-FloorPlan } }
        'Analytics' { { Update-Analytics-Page } }
        'Bills'     { { Update-Bills-Page } }
        'Staff'     { { Update-Staff-Page } }
        'Menu'      { { Update-Menu-Page } }
        'Kitchen'   { { Update-Kitchen-Page } }
        'Orders'    { { Update-Orders-Page } }
        default     { $null }
    }
    if ($loader) {
        $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]$loader) | Out-Null
    }
}

(ctl 'NavDashboard').Add_Click({ Switch-Page 'Dashboard' })
(ctl 'NavAssistant').Add_Click({ Switch-Page 'Assistant'; Init-Assistant })
(ctl 'NavMenu').Add_Click(     { Switch-Page 'Menu' })
(ctl 'NavKitchen').Add_Click(  { Switch-Page 'Kitchen' })
(ctl 'NavOrders').Add_Click(   { Switch-Page 'Orders' })
(ctl 'NavAnalytics').Add_Click({ Switch-Page 'Analytics' })
(ctl 'NavBills').Add_Click(    { Switch-Page 'Bills' })
(ctl 'NavReport').Add_Click(   { Switch-Page 'Report' })
(ctl 'NavStaff').Add_Click(    { Switch-Page 'Staff' })
(ctl 'NavHome').Add_Click(     { Switch-Page 'Home' })
(ctl 'BackBtn').Add_Click(     { Switch-Page 'Home' })

# ─── HOME: Control Center card grid ──────────────────────────────────────────
# A web-app-style landing. Each card routes into a section via Switch-Page.
# icon = emoji code point (built with ConvertFromUtf32 — above-BMP glyphs throw
# on a plain [char] cast). target = the Switch-Page key the card opens.
$script:homeCards = @(
    @{ target='Orders';    icon=0x1F4CB; color='#14B8A6'; titleKey='home_orders_t';    descKey='home_orders_d' }
    @{ target='Dashboard'; icon=0x1F5FA; color='#22C55E'; titleKey='home_floor_t';     descKey='home_floor_d' }
    @{ target='Menu';      icon=0x1F37D; color='#F97316'; titleKey='home_menu_t';      descKey='home_menu_d' }
    @{ target='Kitchen';   icon=0x1F5A8; color='#3B82F6'; titleKey='home_kitchen_t';   descKey='home_kitchen_d' }
    @{ target='Assistant'; icon=0x2728;  color='#8B5CF6'; titleKey='home_ai_t';        descKey='home_ai_d' }
    @{ target='Staff';     icon=0x1F465; color='#6366F1'; titleKey='home_staff_t';     descKey='home_staff_d' }
    @{ target='Analytics'; icon=0x1F4CA; color='#A855F7'; titleKey='home_analytics_t'; descKey='home_analytics_d' }
    @{ target='Bills';     icon=0x1F9FE; color='#EC4899'; titleKey='home_bills_t';     descKey='home_bills_d' }
    @{ target='Report';    icon=0x1F4C5; color='#F59E0B'; titleKey='home_report_t';    descKey='home_report_d' }
)
$script:homeLabels = @()

function Build-HomeCards {
    $grid = ctl 'HomeGrid'
    $grid.Children.Clear()
    $script:homeLabels = @()
    foreach ($c in $script:homeCards) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $window.FindResource('HomeCard')
        $btn.Tag   = $c.target

        $g = New-Object System.Windows.Controls.Grid
        $cd0 = New-Object System.Windows.Controls.ColumnDefinition; $cd0.Width = 'Auto'
        $cd1 = New-Object System.Windows.Controls.ColumnDefinition
        $g.ColumnDefinitions.Add($cd0); $g.ColumnDefinitions.Add($cd1)

        $iconBorder = New-Object System.Windows.Controls.Border
        $iconBorder.Width = 46; $iconBorder.Height = 46
        $iconBorder.CornerRadius = [System.Windows.CornerRadius]::new(12)
        $iconBorder.Background = SolidBrush $c.color
        $iconBorder.VerticalAlignment = 'Top'
        $iconTb = New-Object System.Windows.Controls.TextBlock
        $iconTb.Text = [System.Char]::ConvertFromUtf32([int]$c.icon)
        $iconTb.FontSize = 22
        $iconTb.Foreground = [System.Windows.Media.Brushes]::White
        $iconTb.HorizontalAlignment = 'Center'; $iconTb.VerticalAlignment = 'Center'
        $iconBorder.Child = $iconTb
        [System.Windows.Controls.Grid]::SetColumn($iconBorder, 0)
        $g.Children.Add($iconBorder) | Out-Null

        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Margin = [System.Windows.Thickness]::new(14,2,0,0)
        $sp.VerticalAlignment = 'Center'
        $title = New-Object System.Windows.Controls.TextBlock
        $title.FontSize = 15; $title.FontWeight = 'Bold'
        $title.Foreground = [System.Windows.Media.Brushes]::White
        $title.Text = (T $c.titleKey)
        $desc = New-Object System.Windows.Controls.TextBlock
        $desc.FontSize = 12; $desc.Foreground = (SolidBrush '#7A8295')
        $desc.TextWrapping = 'Wrap'; $desc.Margin = [System.Windows.Thickness]::new(0,4,0,0)
        $desc.Text = (T $c.descKey)
        $sp.Children.Add($title) | Out-Null; $sp.Children.Add($desc) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $g.Children.Add($sp) | Out-Null

        $btn.Content = $g
        $btn.Add_Click({
            $t = $this.Tag
            Switch-Page $t
            if ($t -eq 'Assistant') { Init-Assistant }
        })
        $grid.Children.Add($btn) | Out-Null
        $script:homeLabels += @{ Title=$title; Desc=$desc; titleKey=$c.titleKey; descKey=$c.descKey }
    }
}

# Fill the subtitle with today's order count (mirrors the web app's
# "No orders yet today"). Best-effort — silent on any failure.
function Update-Home-Page {
    Invoke-AsyncGet "$base/local/stats?period=today" {
        param($r, $bad)
        if ($bad -or -not $r) { return }
        $n = [int]$r.total_orders
        if ($n -le 0) { (ctl 'HomeSubtitle').Text = (T 'home_no_orders') }
        else { (ctl 'HomeSubtitle').Text = "$n " + (T 'home_orders_today') }
    }
}

Build-HomeCards

# ─── DASHBOARD: floor plan ───────────────────────────────────────────────────

# ─── Async HTTP helpers (keep the WPF UI thread responsive) ──────────────────
# Every Invoke-RestMethod call blocks the calling thread. When that thread is the
# WPF UI thread (timer ticks + click handlers run there), the whole window freezes
# for the duration of the request — felt constantly because of the 2s status poll.
# WebClient's async ops run the network wait on a thread-pool thread and raise
# their *Completed event back on the captured SynchronizationContext. We marshal
# the callback onto the dispatcher explicitly so it's always safe to touch
# controls, and the UI stays live while the request is in flight.
function Invoke-AsyncGet {
    param([string]$Url, [scriptblock]$OnDone)
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $handler = {
        param($s, $e)
        try { $s.Dispose() } catch {}
        if ($e.Cancelled) { return }
        $res = $null; $bad = $true
        if (-not $e.Error) { try { $res = $e.Result | ConvertFrom-Json; $bad = $false } catch { $bad = $true } }
        try { $window.Dispatcher.Invoke([action]{ & $OnDone $res $bad }) | Out-Null } catch {}
    }.GetNewClosure()
    $wc.Add_DownloadStringCompleted($handler)
    try { $wc.DownloadStringAsync([Uri]$Url) }
    catch { try { $wc.Dispose() } catch {}; & $OnDone $null $true }
}
function Invoke-AsyncPost {
    param([string]$Url, [string]$Body, [string]$Method = 'POST', [scriptblock]$OnDone, [int]$TimeoutSec = 60)
    # WebClient's event-based async (UploadStringAsync + UploadStringCompleted) is
    # unreliable in this WPF/PowerShell host: for a fast call the completion fires
    # fine, but for a slow one (the AI chat, ~5s) the completion event frequently
    # never fires, leaving the caller (the "Thinking..." bubble) hung forever.
    # A synchronous UploadString, by contrast, is rock-solid. So run the request
    # SYNCHRONOUSLY on a background runspace and poll it from a DispatcherTimer on
    # the UI thread — no completion event, no SynchronizationContext dependency,
    # no chance of a lost callback. A hard TimeoutSec guarantees resolution.
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($u, $m, $b)
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $wc.Headers.Add('Content-Type', 'application/json')
            $r = $wc.UploadString($u, $m, $b)
            [pscustomobject]@{ ok = $true; body = $r; err = '' }
        } catch {
            [pscustomobject]@{ ok = $false; body = ''; err = $_.Exception.Message }
        } finally { if ($wc) { $wc.Dispose() } }
    })
    [void]$ps.AddArgument($Url); [void]$ps.AddArgument($Method); [void]$ps.AddArgument($Body)
    $handle = $ps.BeginInvoke()

    $state = [pscustomobject]@{ Done = $false; Elapsed = 0 }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $finish = {
        param($res, $bad, $emsg)
        if ($state.Done) { return }
        $state.Done = $true
        $timer.Stop()
        try { $ps.Dispose() } catch {}
        # Contain callback errors: a throw here must not bubble to the global trap
        # and take down the whole window (it did once — a null bubble ref).
        try { & $OnDone $res $bad $emsg } catch { try { Add-Content -Path $errorLog -Value ("[" + (Get-Date -Format 'HH:mm:ss') + "] async cb error: " + $_.Exception.Message) } catch {} }
    }.GetNewClosure()
    $timer.Add_Tick({
        if ($state.Done) { $timer.Stop(); return }
        $state.Elapsed += 250
        if ($handle.IsCompleted) {
            $res = $null; $bad = $true; $emsg = ''
            try {
                $out = $ps.EndInvoke($handle) | Select-Object -Last 1
                if ($out.ok) { $bad = $false; try { $res = $out.body | ConvertFrom-Json } catch {} }
                else { $emsg = $out.err }
            } catch { $emsg = $_.Exception.Message }
            & $finish $res $bad $emsg
        } elseif ($state.Elapsed -ge ($TimeoutSec * 1000)) {
            try { $ps.Stop() } catch {}
            & $finish $null $true 'timed out'
        }
    }.GetNewClosure())
    $timer.Start()
}

$script:statusBusy = $false
function Update-Status {
    if ($script:statusBusy) { return }
    $script:statusBusy = $true
    Invoke-AsyncGet $statusUrl {
        param($r, $bad)
        $script:statusBusy = $false
        if ($bad -or -not $r) {
            (ctl 'StatusDot').Fill  = [System.Windows.Media.Brushes]::Crimson
            (ctl 'StatusText').Text = 'Disconnected'
            (ctl 'PrinterText').Text = '-'
            (ctl 'UpdateText').Text  = ('checked ' + (Get-Date -Format 'HH:mm'))
            return
        }
        # configured is false when the install has no restaurant credentials
        # (config.json missing at install time). Show that clearly rather than a
        # green "Connected" that hides why nothing prints.
        if ($r.PSObject.Properties.Name -contains 'configured' -and -not $r.configured) {
            (ctl 'StatusDot').Fill  = [System.Windows.Media.Brushes]::Orange
            (ctl 'StatusText').Text = 'Not configured - re-download from your dashboard'
        } else {
            (ctl 'StatusDot').Fill  = [System.Windows.Media.Brushes]::LimeGreen
            (ctl 'StatusText').Text = 'Connected'
        }
        (ctl 'VersionText').Text = "Station v$($r.version)"
        if ($r.restaurant_name) { (ctl 'RestaurantName').Text = $r.restaurant_name }

        $printerInfo = '-'
        if ($r.printer) {
            if     ($r.printer.mode -eq 'usb-direct')   { $printerInfo = 'OK  ' + $r.printer.usb + ' (USB direct)' }
            elseif ($r.printer.mode -eq 'usb-spooler')  { $printerInfo = 'OK  ' + $r.printer.usb + ' (USB spooler)' }
            elseif ($r.printer.mode -eq 'network')      { $printerInfo = 'OK  ' + $r.printer.ip + ':' + $r.printer.port }
            else                                         { $printerInfo = 'Searching...' }
        }
        (ctl 'PrinterText').Text = $printerInfo
        (ctl 'UpdateText').Text = ('v' + $r.version + ' - checked ' + (Get-Date -Format 'HH:mm'))
    }
}

$script:floorBusy     = $false
$script:activeFloor   = 'Main'
$script:pendingFloors = @()
$script:lastFloorData = @()
$script:FW = 1000.0; $script:FH = 620.0

# Drag state (shared across the per-table mousedown + canvas-level move/up handlers)
$script:dragBorder = $null
$script:dragStarted = $false
$script:editorOpen = $false

# A thrown exception inside any WPF handler bubbles to the top-level trap, which
# shows "failed to start" and kills the app. Floor handlers log + swallow instead,
# so a glitch never takes the whole UI down — and we get the exact failing line.
function FloorLog($where, $err) {
    try {
        $line = if ($err.InvocationInfo) { $err.InvocationInfo.ScriptLineNumber } else { '?' }
        Add-Content -Path $errorLog -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] FLOOR/" + $where + ": " + $err.Exception.Message + " @L" + $line)
    } catch {}
}
$script:moveCount = 0
function FloorDbg($m) {
    try { Add-Content -Path $errorLog -Value ("[" + (Get-Date -Format 'HH:mm:ss') + "] FLOORDBG: " + $m) } catch {}
}

function SolidColor([string]$hex) {
    [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}

function TableZone($t) { if ($t.zone) { [string]$t.zone } else { 'Main' } }

function Render-FloorTables([array]$tables) {
    $canvas    = ctl 'FloorCanvas'
    $tabsPanel = ctl 'FloorTabs'
    $emptyMsg  = ctl 'FloorEmpty'
    $canvas.Children.Clear()
    $tabsPanel.Children.Clear()

    if (-not $tables) { $tables = @() }

    # Zones = Main (always) + zones found on tables + pending (empty) floors
    $zones = @('Main')
    foreach ($t in $tables) { $z = TableZone $t; if ($zones -notcontains $z) { $zones += $z } }
    foreach ($z in $script:pendingFloors) { if ($zones -notcontains $z) { $zones += $z } }
    if ($zones -notcontains $script:activeFloor) { $script:activeFloor = 'Main' }

    # Floor tabs (always shown, with a live table count per floor)
    foreach ($z in $zones) {
        $zCopy = $z
        $count = ($tables | Where-Object { (TableZone $_) -eq $z }).Count
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content    = "$z  $count"
        $btn.FontSize   = 12; $btn.FontWeight = 'SemiBold'
        $btn.Padding    = New-Object System.Windows.Thickness(14,6,14,6)
        $btn.Margin     = New-Object System.Windows.Thickness(0,0,6,0)
        $btn.Cursor     = 'Hand'
        $btn.BorderThickness = New-Object System.Windows.Thickness(0)
        $btn.Template   = (ctl 'NavDashboard').Template
        if ($z -eq $script:activeFloor) {
            $btn.Background = SolidColor '#1A1D29'; $btn.Foreground = [System.Windows.Media.Brushes]::White
        } else {
            $btn.Background = [System.Windows.Media.Brushes]::Transparent; $btn.Foreground = SolidColor '#7A8295'
        }
        $btn.Add_Click({ $script:activeFloor = $zCopy; $script:lastFloorSig = ''; Render-FloorTables $script:lastFloorData }.GetNewClosure())
        $tabsPanel.Children.Add($btn) | Out-Null
    }

    $W = $script:FW; $H = $script:FH
    $floorTables = @($tables | Where-Object { (TableZone $_) -eq $script:activeFloor })
    $emptyMsg.Visibility = if ($floorTables.Count -eq 0) { 'Visible' } else { 'Collapsed' }

    $perRow = 5; $idx = 0
    foreach ($t in $floorTables) {
        $tid = $t.id
        if ($null -ne $t.pos_x -and $null -ne $t.pos_y) {
            $cx = [double]$t.pos_x * $W; $cy = [double]$t.pos_y * $H
        } else {
            $col = $idx % $perRow; $row = [Math]::Floor($idx / $perRow)
            $cx = 130 + $col * 165; $cy = 110 + $row * 150; $idx++
        }

        # 4-colour floor map (global LightMenu convention — same on web & app):
        #   green  free          — no active order
        #   blue   dishes out    — active order, no held secondary plates
        #   yellow to reclaim    — held s1–s4 plates waiting to be fired/reclaimed
        #   purple check printed — bill printed at least once, awaiting close
        $occ   = $t.occupied -or $t.status -eq 'occupied'
        $held  = [bool]$t.has_held_items
        $check = -not [string]::IsNullOrEmpty([string]$t.check_printed_at)
        if     ($check) { $bg = '#241830'; $bc = '#A855F7'; $fg = '#D8B4FE' }
        elseif ($held)  { $bg = '#2D2310'; $bc = '#F59E0B'; $fg = '#FCD34D' }
        elseif ($occ)   { $bg = '#0C2230'; $bc = '#38BDF8'; $fg = '#7DD3FC' }
        else            { $bg = '#0D2318'; $bc = '#22C55E'; $fg = '#86EFAC' }

        $tw = if ($t.shape -eq 'rect') { 104.0 } else { 78.0 }
        $th = 78.0

        $brd = New-Object System.Windows.Controls.Border
        $brd.Width = $tw; $brd.Height = $th
        $brd.Background = SolidColor $bg
        $brd.BorderBrush = SolidColor $bc
        $brd.BorderThickness = New-Object System.Windows.Thickness(2)
        $brd.Cursor = 'Hand'
        $brd.CornerRadius = if ($t.shape -eq 'circle') { New-Object System.Windows.CornerRadius(39) } else { New-Object System.Windows.CornerRadius(12) }

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.HorizontalAlignment = 'Center'; $stack.VerticalAlignment = 'Center'
        $num = New-Object System.Windows.Controls.TextBlock
        $num.Text = [string]$t.table_number
        $num.Foreground = SolidColor $fg
        $num.FontSize = 19; $num.FontWeight = 'Bold'; $num.HorizontalAlignment = 'Center'
        $seat = New-Object System.Windows.Controls.TextBlock
        $cap = if ($t.capacity) { $t.capacity } else { 4 }
        # 0x1F465 (people glyph) is above the BMP, so it can't be a single [char];
        # ConvertFromUtf32 builds the correct surrogate pair.
        $seat.Text = [System.Char]::ConvertFromUtf32(0x1F465) + ' ' + [string]$cap
        $seat.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Emoji')
        $seat.Foreground = SolidColor $fg; $seat.Opacity = 0.75
        $seat.FontSize = 11; $seat.HorizontalAlignment = 'Center'; $seat.Margin = New-Object System.Windows.Thickness(0,2,0,0)
        $stack.Children.Add($num)  | Out-Null
        $stack.Children.Add($seat) | Out-Null
        $brd.Child = $stack

        [System.Windows.Controls.Canvas]::SetLeft($brd, $cx - $tw/2.0)
        [System.Windows.Controls.Canvas]::SetTop($brd,  $cy - $th/2.0)

        # The table object rides on the border's Tag — the canvas-level
        # PreviewMouseLeftButtonDown (wired once) hit-tests by position and reads
        # this back. No per-child mouse handlers (those never fired inside the
        # Viewbox-scaled canvas).
        $brd.Tag = $t
        $canvas.Children.Add($brd) | Out-Null
    }
}

function Show-TableEditor($table) {
    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Edit Table" Height="372" Width="340" WindowStartupLocation="CenterOwner"
        Background="#0F1117" TextElement.Foreground="#FFFFFF" ResizeMode="NoResize">
  <StackPanel Margin="20">
    <TextBlock Text="Table number" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold"/>
    <TextBox x:Name="EdNum" Background="#1A1D29" Foreground="#FFFFFF" BorderBrush="#2A2D3A" Padding="7,5" Margin="0,4,0,12"/>
    <TextBlock Text="Seats" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold"/>
    <TextBox x:Name="EdCap" Background="#1A1D29" Foreground="#FFFFFF" BorderBrush="#2A2D3A" Padding="7,5" Margin="0,4,0,12"/>
    <TextBlock Text="Shape" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold"/>
    <ComboBox x:Name="EdShape" Margin="0,4,0,12">
      <ComboBoxItem Content="Square" Tag="square"/>
      <ComboBoxItem Content="Round"  Tag="circle"/>
      <ComboBoxItem Content="Long"   Tag="rect"/>
    </ComboBox>
    <TextBlock Text="Status" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold"/>
    <ComboBox x:Name="EdStatus" Margin="0,4,0,16">
      <ComboBoxItem Content="Free"     Tag="available"/>
      <ComboBoxItem Content="Reserved" Tag="reserved"/>
    </ComboBox>
    <Grid>
      <Button x:Name="EdDelete" Content="Delete" HorizontalAlignment="Left" Background="#3A1518" Foreground="#F87171" BorderThickness="0" Padding="14,8" Cursor="Hand"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="EdCancel" Content="Cancel" Background="#2A2D3A" Foreground="#FFFFFF" BorderThickness="0" Padding="14,8" Margin="0,0,8,0" Cursor="Hand"/>
        <Button x:Name="EdSave" Content="Save" Background="#14B8A6" Foreground="#FFFFFF" BorderThickness="0" Padding="16,8" Cursor="Hand"/>
      </StackPanel>
    </Grid>
  </StackPanel>
</Window>
"@
    $rd  = New-Object System.Xml.XmlNodeReader $dx
    $dlg = [System.Windows.Markup.XamlReader]::Load($rd)
    $dlg.Owner = $window
    $edNum    = $dlg.FindName('EdNum')
    $edCap    = $dlg.FindName('EdCap')
    $edShape  = $dlg.FindName('EdShape')
    $edStatus = $dlg.FindName('EdStatus')
    $edNum.Text = [string]$table.table_number
    $edCap.Text = if ($table.capacity) { [string]$table.capacity } else { '4' }
    $shp = if ($table.shape) { $table.shape } else { 'square' }
    foreach ($it in $edShape.Items)  { if ($it.Tag -eq $shp) { $edShape.SelectedItem = $it } }
    if (-not $edShape.SelectedItem) { $edShape.SelectedIndex = 0 }
    $stv = if ($table.status -eq 'reserved') { 'reserved' } else { 'available' }
    foreach ($it in $edStatus.Items) { if ($it.Tag -eq $stv) { $edStatus.SelectedItem = $it } }
    if (-not $edStatus.SelectedItem) { $edStatus.SelectedIndex = 0 }

    $tid = $table.id
    $dlg.FindName('EdSave').Add_Click({
        $patch = @{
            table_number = [int]($edNum.Text -replace '[^\d]','')
            capacity     = [int]($edCap.Text -replace '[^\d]','')
            shape        = [string]$edShape.SelectedItem.Tag
            status       = [string]$edStatus.SelectedItem.Tag
        }
        $body = ($patch | ConvertTo-Json -Compress)
        Invoke-AsyncPost "$base/local/tables/$tid" $body 'PATCH' { param($r,$bad,$em); Update-FloorPlan }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.FindName('EdDelete').Add_Click({
        $ans = [System.Windows.MessageBox]::Show("Delete table $($table.table_number)?", 'LightMenu', 'YesNo', 'Warning')
        if ($ans -eq 'Yes') {
            Invoke-AsyncPost "$base/local/tables/$tid" '' 'DELETE' { param($r,$bad,$em); Update-FloorPlan }
            $dlg.Close()
        }
    }.GetNewClosure())
    $dlg.FindName('EdCancel').Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.Add_Closed({ $script:editorOpen = $false })
    $script:editorOpen = $true
    $dlg.ShowDialog() | Out-Null
}

function Show-TableEditorSafe($table) {
    try { Show-TableEditor $table } catch { FloorLog 'editor' $_; $script:editorOpen = $false }
}

function Add-Floor {
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Name this floor / area (e.g. Terrace, Bar):', 'Add Floor', '')
    $clean = ($name | Out-String).Trim()
    if (-not $clean) { return }
    if ($clean -eq 'Main') { return }
    if ($script:pendingFloors -notcontains $clean) { $script:pendingFloors += $clean }
    $script:activeFloor = $clean
    Render-FloorTables $script:lastFloorData
}

function Add-Table {
    # Suggest the next free table number so the field is pre-filled but editable.
    $maxNum = 0
    foreach ($t in $script:lastFloorData) { if ([int]$t.table_number -gt $maxNum) { $maxNum = [int]$t.table_number } }
    $suggest = $maxNum + 1

    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Add Table" Height="322" Width="340" WindowStartupLocation="CenterOwner"
        Background="#0F1117" TextElement.Foreground="#FFFFFF" ResizeMode="NoResize">
  <StackPanel Margin="20">
    <TextBlock x:Name="AddInfo" Text="New table on Main" Foreground="#6B7280" FontSize="11" Margin="0,0,0,12"/>
    <TextBlock Text="Table number" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold"/>
    <TextBox x:Name="AddNum" Background="#1A1D29" Foreground="#FFFFFF" BorderBrush="#2A2D3A" Padding="7,5" Margin="0,4,0,12"/>
    <TextBlock Text="Seats" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold"/>
    <TextBox x:Name="AddCap" Background="#1A1D29" Foreground="#FFFFFF" BorderBrush="#2A2D3A" Padding="7,5" Margin="0,4,0,12"/>
    <TextBlock Text="Shape" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold"/>
    <ComboBox x:Name="AddShape" Margin="0,4,0,16">
      <ComboBoxItem Content="Square" Tag="square"/>
      <ComboBoxItem Content="Round"  Tag="circle"/>
      <ComboBoxItem Content="Long"   Tag="rect"/>
    </ComboBox>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="AddCancel" Content="Cancel" Background="#2A2D3A" Foreground="#FFFFFF" BorderThickness="0" Padding="14,8" Margin="0,0,8,0" Cursor="Hand"/>
      <Button x:Name="AddCreate" Content="Add table" Background="#14B8A6" Foreground="#FFFFFF" BorderThickness="0" Padding="16,8" Cursor="Hand"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $rd  = New-Object System.Xml.XmlNodeReader $dx
    $dlg = [System.Windows.Markup.XamlReader]::Load($rd)
    $dlg.Owner = $window
    $aNum = $dlg.FindName('AddNum'); $aCap = $dlg.FindName('AddCap'); $aShape = $dlg.FindName('AddShape')
    $dlg.FindName('AddInfo').Text = "New table on $($script:activeFloor)"
    $aNum.Text = [string]$suggest
    $aCap.Text = '4'
    $aShape.SelectedIndex = 0

    $zone = if ($script:activeFloor -eq 'Main') { $null } else { $script:activeFloor }
    $dlg.FindName('AddCreate').Add_Click({
        $num = [int]($aNum.Text -replace '[^\d]','')
        $cap = [int]($aCap.Text -replace '[^\d]','')
        if ($num -le 0) { [System.Windows.MessageBox]::Show('Enter a table number.', 'LightMenu', 'OK', 'Info') | Out-Null; return }
        if ($cap -le 0) { $cap = 4 }
        $body = (@{ zone = $zone; table_number = $num; capacity = $cap; shape = [string]$aShape.SelectedItem.Tag } | ConvertTo-Json -Compress)
        Invoke-AsyncPost "$base/local/tables" $body 'POST' {
            param($r, $bad, $em)
            if (-not $bad) {
                $script:pendingFloors = @($script:pendingFloors | Where-Object { $_ -ne $script:activeFloor })
                Update-FloorPlan
            } else {
                [System.Windows.MessageBox]::Show("Could not add table.`n$em", 'LightMenu', 'OK', 'Warning') | Out-Null
            }
        }
        $dlg.Close()
    }.GetNewClosure())
    $dlg.FindName('AddCancel').Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.Add_Closed({ $script:editorOpen = $false })
    $script:editorOpen = $true
    $dlg.ShowDialog() | Out-Null
}

function Delete-Floor {
    $f = $script:activeFloor
    if ($f -eq 'Main') {
        [System.Windows.MessageBox]::Show('The Main floor cannot be deleted.', 'LightMenu', 'OK', 'Info') | Out-Null
        return
    }
    $hasTables = @($script:lastFloorData | Where-Object { (TableZone $_) -eq $f }).Count -gt 0
    if (-not $hasTables) {
        # Empty (pending) floor — just remove the tab.
        $script:pendingFloors = @($script:pendingFloors | Where-Object { $_ -ne $f })
        $script:activeFloor = 'Main'
        Render-FloorTables $script:lastFloorData
        return
    }
    $ans = [System.Windows.MessageBox]::Show("Delete floor '$f' and all its tables?", 'LightMenu', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    $body = (@{ zone = $f } | ConvertTo-Json -Compress)
    Invoke-AsyncPost "$base/local/tables/delete-zone" $body 'POST' {
        param($r, $bad, $em)
        $script:pendingFloors = @($script:pendingFloors | Where-Object { $_ -ne $f })
        $script:activeFloor = 'Main'
        Update-FloorPlan
    }.GetNewClosure()
}

$script:lastFloorSig = ''
function Update-FloorPlan {
    if ($script:floorBusy) { return }
    # Never re-render mid-drag or while the editor is open — it would destroy the
    # element being manipulated and cause the "freezy" feel.
    if ($script:dragBorder -or $script:editorOpen) { return }
    $script:floorBusy = $true
    Invoke-AsyncGet "$base/local/tables" {
        param($r, $bad)
        $script:floorBusy = $false
        if ($bad -or $null -eq $r) { return }
        $tables = if ($r -is [array]) { $r } else { @($r) }
        $script:lastFloorData = $tables
        # Skip the (heavy) full canvas rebuild when nothing visible changed. Most
        # 5s ticks hit this early-out, so the UI no longer churns 39 closures/tick.
        $sig = "$($script:activeFloor)||" + (($tables | ForEach-Object {
            "$($_.id):$($_.table_number):$($_.pos_x):$($_.pos_y):$($_.status):$($_.zone):$($_.occupied):$($_.has_held_items):$($_.check_printed_at)"
        }) -join '|')
        if ($sig -eq $script:lastFloorSig) { return }
        $script:lastFloorSig = $sig
        Render-FloorTables $tables
    }
}

(ctl 'AddFloorBtn').Add_Click({ Add-Floor })
(ctl 'AddTableBtn').Add_Click({ Add-Table })
(ctl 'DelFloorBtn').Add_Click({ Delete-Floor })

# Canvas-level drag handlers — wired ONCE (the canvas object outlives every
# re-render; only its children get rebuilt). Plain scriptblocks, so $args holds
# the real event invocation args (sender, MouseEventArgs) — unlike a closure,
# which would shadow $args with a captured snapshot.
$script:floorCanvas = ctl 'FloorCanvas'
# Preview (tunneling) events fire on the canvas FIRST, before any child — the only
# reliable way to catch the press, since per-border handlers never fired inside the
# Viewbox-scaled canvas. We hit-test by position to find the grabbed table.
$script:floorCanvas.Add_PreviewMouseLeftButtonDown({
    try {
        $p = [System.Windows.Input.Mouse]::GetPosition($script:floorCanvas)
        $hit = $null
        foreach ($child in $script:floorCanvas.Children) {
            if (-not $child.Tag) { continue }
            $l = [System.Windows.Controls.Canvas]::GetLeft($child)
            $tp = [System.Windows.Controls.Canvas]::GetTop($child)
            if ([double]::IsNaN($l) -or [double]::IsNaN($tp)) { continue }
            if ($p.X -ge $l -and $p.X -le ($l + $child.Width) -and $p.Y -ge $tp -and $p.Y -le ($tp + $child.Height)) { $hit = $child; break }
        }
        if (-not $hit) { return }
        $script:dragBorder = $hit; $script:dragTable = $hit.Tag
        $script:dragTW = $hit.Width; $script:dragTH = $hit.Height
        $script:dragMoved = $false; $script:dragStarted = $true; $script:moveCount = 0
        $script:dragSX = $p.X; $script:dragSY = $p.Y
        $script:dragNewX = $hit.Tag.pos_x; $script:dragNewY = $hit.Tag.pos_y
        $script:floorCanvas.CaptureMouse() | Out-Null
        FloorDbg "down t=$($hit.Tag.table_number)"
    } catch { FloorLog 'down' $_ }
})
$script:floorCanvas.Add_PreviewMouseMove({
    if (-not $script:dragBorder) { return }
    try {
        $script:moveCount++
        $W  = $script:FW; $H = $script:FH; $tw = $script:dragTW; $th = $script:dragTH
        $p  = [System.Windows.Input.Mouse]::GetPosition($script:floorCanvas)
        $cxn = [Math]::Max($tw/2.0, [Math]::Min($W - $tw/2.0, $p.X))
        $cyn = [Math]::Max($th/2.0, [Math]::Min($H - $th/2.0, $p.Y))
        [System.Windows.Controls.Canvas]::SetLeft($script:dragBorder, $cxn - $tw/2.0)
        [System.Windows.Controls.Canvas]::SetTop($script:dragBorder,  $cyn - $th/2.0)
        $script:dragNewX = $cxn / $W; $script:dragNewY = $cyn / $H
        if ([Math]::Abs($p.X - $script:dragSX) + [Math]::Abs($p.Y - $script:dragSY) -gt 3) { $script:dragMoved = $true }
    } catch { FloorLog 'move' $_ }
})
$script:floorCanvas.Add_PreviewMouseLeftButtonUp({
    if (-not $script:dragBorder) { return }
    try {
        FloorDbg "up moved=$($script:dragMoved) moves=$($script:moveCount)"
        try { $script:floorCanvas.ReleaseMouseCapture() } catch {}
        $tbl = $script:dragTable; $moved = $script:dragMoved
        $nx = $script:dragNewX; $ny = $script:dragNewY
        $script:dragBorder = $null; $script:dragTable = $null; $script:dragStarted = $false
        if ($moved -and $tbl) {
            $tbl.pos_x = $nx; $tbl.pos_y = $ny
            $body = (@{ pos_x = [Math]::Round([double]$nx,4); pos_y = [Math]::Round([double]$ny,4) } | ConvertTo-Json -Compress)
            Invoke-AsyncPost "$base/local/tables/$($tbl.id)" $body 'PATCH' { param($r,$bad,$em) }
        } elseif ($tbl) {
            Show-TableEditorSafe $tbl
        }
    } catch { FloorLog 'up' $_; $script:dragBorder = $null; $script:dragTable = $null; $script:dragStarted = $false }
})

# ─── ANALYTICS PAGE ─────────────────────────────────────────────────────────
$script:activePeriod = 'today'
$script:periodButtons = @{
    'today' = (ctl 'PeriodToday')
    'week'  = (ctl 'PeriodWeek')
    'month' = (ctl 'PeriodMonth')
    'all'   = (ctl 'PeriodAll')
}

function Set-Active-Period($period) {
    foreach ($k in $script:periodButtons.Keys) {
        if ($k -eq $period) {
            $script:periodButtons[$k].Background = SolidBrush '#14B8A6'
            $script:periodButtons[$k].Foreground = [System.Windows.Media.Brushes]::White
        } else {
            $script:periodButtons[$k].Background = SolidBrush '#1A1D29'
            $script:periodButtons[$k].Foreground = SolidBrush '#9CA3AF'
        }
    }
    $script:activePeriod = $period
}

$script:analyticsBusy = $false
function Update-Analytics-Page {
    if ($script:analyticsBusy) { return }
    $script:analyticsBusy = $true
    Invoke-AsyncGet "$base/local/stats?period=$($script:activePeriod)" {
        param($r, $bad)
        $script:analyticsBusy = $false
        if ($bad -or -not $r) {
            (ctl 'AnaRevenue').Text = '--'
            (ctl 'AnaOrders').Text  = '--'
            (ctl 'AnaAvg').Text     = '--'
            (ctl 'AnaBest').Text    = '--'
            return
        }
        $script:currencySymbol = $r.currency
        (ctl 'AnaRevenue').Text = Format-Money $r.total_revenue
        (ctl 'AnaOrders').Text  = [string]$r.total_orders
        (ctl 'AnaAvg').Text     = Format-Money $r.avg_ticket
        (ctl 'AnaBest').Text    = if ($r.best_day) { $r.best_day + ' - ' + (Format-Money $r.best_amount) } else { '--' }

        (ctl 'PayCashCount').Text  = [string]$r.payment.cash.count
        (ctl 'PayCashTotal').Text  = Format-Money $r.payment.cash.total
        (ctl 'PayCardCount').Text  = [string]$r.payment.card.count
        (ctl 'PayCardTotal').Text  = Format-Money $r.payment.card.total
        (ctl 'PayMixedCount').Text = [string]$r.payment.mixed.count
        (ctl 'PayMixedTotal').Text = Format-Money $r.payment.mixed.total

        Draw-Chart $r.daily
    }
}

function Draw-Chart($daily) {
    $canvas = ctl 'ChartCanvas'
    $canvas.Children.Clear()
    if (-not $daily -or $daily.Count -eq 0) { return }
    $w = if ($canvas.ActualWidth -gt 50) { $canvas.ActualWidth } else { 700 }
    $h = 200
    $padL = 50; $padR = 10; $padT = 10; $padB = 30
    $chartW = $w - $padL - $padR
    $chartH = $h - $padT - $padB
    $max = 0
    foreach ($d in $daily) { if ($d.revenue -gt $max) { $max = $d.revenue } }
    if ($max -eq 0) { $max = 1 }
    $barCount = $daily.Count
    $gap  = 12
    $barW = ($chartW - ($gap * ($barCount - 1))) / $barCount

    # Y-axis gridlines + labels
    for ($i = 0; $i -le 4; $i++) {
        $val = $max * $i / 4
        $y   = $padT + $chartH - ($chartH * $i / 4)
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = $padL; $line.Y1 = $y; $line.X2 = $padL + $chartW; $line.Y2 = $y
        $line.Stroke = SolidBrush '#2A2D3A'
        $line.StrokeThickness = 1
        $canvas.Children.Add($line) | Out-Null
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = Format-Money $val
        $lbl.Foreground = SolidBrush '#7A8295'
        $lbl.FontSize = 9
        [System.Windows.Controls.Canvas]::SetLeft($lbl, 4)
        [System.Windows.Controls.Canvas]::SetTop($lbl, $y - 7)
        $canvas.Children.Add($lbl) | Out-Null
    }

    # Bars
    for ($i = 0; $i -lt $barCount; $i++) {
        $d  = $daily[$i]
        $bh = ($d.revenue / $max) * $chartH
        if ($bh -lt 2 -and $d.revenue -gt 0) { $bh = 2 }
        $x  = $padL + $i * ($barW + $gap)
        $y  = $padT + $chartH - $bh
        $rect = New-Object System.Windows.Shapes.Rectangle
        $rect.Width = $barW; $rect.Height = $bh
        $brush = New-Object System.Windows.Media.LinearGradientBrush
        $brush.StartPoint = New-Object System.Windows.Point(0, 0)
        $brush.EndPoint   = New-Object System.Windows.Point(0, 1)
        $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(20, 184, 166), 0))) | Out-Null
        $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(6, 182, 212), 1)))  | Out-Null
        $rect.Fill = $brush; $rect.RadiusX = 4; $rect.RadiusY = 4
        [System.Windows.Controls.Canvas]::SetLeft($rect, $x)
        [System.Windows.Controls.Canvas]::SetTop($rect, $y)
        $canvas.Children.Add($rect) | Out-Null

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $d.label
        $lbl.Foreground = SolidBrush '#9CA3AF'
        $lbl.FontSize = 10; $lbl.Width = $barW; $lbl.TextAlignment = 'Center'
        [System.Windows.Controls.Canvas]::SetLeft($lbl, $x)
        [System.Windows.Controls.Canvas]::SetTop($lbl, $padT + $chartH + 6)
        $canvas.Children.Add($lbl) | Out-Null
    }
}

(ctl 'PeriodToday').Add_Click({   Set-Active-Period 'today'; Update-Analytics-Page })
(ctl 'PeriodWeek').Add_Click({    Set-Active-Period 'week';  Update-Analytics-Page })
(ctl 'PeriodMonth').Add_Click({   Set-Active-Period 'month'; Update-Analytics-Page })
(ctl 'PeriodAll').Add_Click({     Set-Active-Period 'all';   Update-Analytics-Page })
(ctl 'PeriodRefresh').Add_Click({ Update-Analytics-Page })

# ─── BILLS PAGE ─────────────────────────────────────────────────────────────
$script:billsData = @()
(ctl 'BillStart').SelectedDate = (Get-Date).AddDays(-7)
(ctl 'BillEnd').SelectedDate   = (Get-Date)

function Update-Bills-Page {
    try {
        $s  = (ctl 'BillStart').SelectedDate
        $e  = (ctl 'BillEnd').SelectedDate
        $qs = @()
        if ($s) { $qs += "start=$($s.ToString('yyyy-MM-dd'))" }
        if ($e) { $qs += "end=$($e.ToString('yyyy-MM-dd'))" }
        $url   = "$base/local/bills" + $(if ($qs.Count) { '?' + ($qs -join '&') } else { '' })
        $bills = Invoke-RestMethod -Uri $url -TimeoutSec 5 -ErrorAction Stop
        if ($bills -isnot [System.Array]) { $bills = @($bills) }
        $sorted = $bills | Sort-Object -Property date -Descending
        $rows = foreach ($b in $sorted) {
            $dt  = try { [datetime]::Parse($b.date).ToString('MM/dd HH:mm') } catch { $b.date }
            $sym = if ($b.currency) { $b.currency } else { 'EUR' }
            $script:currencySymbol = $sym
            [PSCustomObject]@{
                BillNum  = $b.id
                DateStr  = $dt
                Table    = "#$($b.table)"
                Waiter   = $b.waiter
                TotalStr = ('{0} {1:N2}' -f $sym, [double]$b.total)
                Payment  = $b.payment_method
                Raw      = $b
            }
        }
        $script:billsData = @($rows)
        (ctl 'BillList').ItemsSource = $script:billsData
        (ctl 'BillCount').Text = "$($script:billsData.Count) bill(s)"
    } catch {
        (ctl 'BillCount').Text = 'Failed to load bills'
    }
}

(ctl 'BillRefresh').Add_Click({ Update-Bills-Page })

(ctl 'BillExport').Add_Click({
    if (-not $script:billsData -or $script:billsData.Count -eq 0) {
        [System.Windows.MessageBox]::Show('No bills to export.', 'LightMenu', 'OK', 'Information') | Out-Null
        return
    }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = "lightmenu-bills-$(Get-Date -Format 'yyyyMMdd').csv"
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    if ($dlg.ShowDialog()) {
        try {
            $script:billsData | Select-Object BillNum, DateStr, Table, Waiter, TotalStr, Payment |
                Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
            [System.Windows.MessageBox]::Show("Exported $($script:billsData.Count) bills.", 'LightMenu', 'OK', 'Information') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show("Export failed: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null
        }
    }
})

function Invoke-Reprint($id) {
    try {
        $body = @{ id = $id } | ConvertTo-Json
        Invoke-RestMethod -Uri "$base/local/reprint" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
        [System.Windows.MessageBox]::Show("Reprint sent: $id", 'LightMenu', 'OK', 'Information') | Out-Null
        return $true
    } catch {
        [System.Windows.MessageBox]::Show("Reprint failed: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null
        return $false
    }
}

# Bill details popup — opens on double-click; shows the full bill and a Reprint
# button that fires /local/reprint for that bill.
function Show-BillDetails($row) {
    if (-not $row) { return }
    $b   = $row.Raw
    $sym = if ($b.currency) { $b.currency } else { 'EUR' }
    $dt  = try { [datetime]::Parse($b.date).ToString('yyyy-MM-dd HH:mm') } catch { "$($b.date)" }
    $pay = if ($b.payment_method) { $b.payment_method } else { '-' }
    $cov = if ($b.guest_count) { " . $($b.guest_count) covers" } else { '' }

    $itemRows = New-Object System.Collections.ArrayList
    if ($b.items) {
        foreach ($it in $b.items) {
            $q  = if ($it.qty) { [int]$it.qty } elseif ($it.quantity) { [int]$it.quantity } else { 1 }
            $nm = if ($it.name) { "$($it.name)" } elseif ($it.menu_item_name) { "$($it.menu_item_name)" } else { 'Item' }
            $up = if ($it.price -ne $null) { [double]$it.price } elseif ($it.price_at_order_time -ne $null) { [double]$it.price_at_order_time } else { 0 }
            [void]$itemRows.Add([PSCustomObject]@{ Qty = "$q x"; Name = $nm; Line = ('{0} {1:N2}' -f $sym, ($up * $q)) })
        }
    }

    [xml]$dxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Bill Details" Height="560" Width="440"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#0F1117" TextElement.Foreground="#FFFFFF">
  <Border Margin="16" Background="#1A1D29" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="10" Padding="18">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="DlgBillNum" Grid.Row="0" FontSize="16" FontWeight="Bold" Foreground="#FFFFFF"/>
      <TextBlock x:Name="DlgMeta"    Grid.Row="1" FontSize="12" Foreground="#9CA3AF" Margin="0,4,0,0"/>
      <Border Grid.Row="2" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="0,1,0,1" Padding="0,8" Margin="0,12,0,0">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="ITEM" FontSize="10" FontWeight="Bold" Foreground="#7A8295"/>
          <TextBlock Grid.Column="1" Text="AMOUNT" FontSize="10" FontWeight="Bold" Foreground="#7A8295"/>
        </Grid>
      </Border>
      <ListView x:Name="DlgItems" Grid.Row="3" Background="Transparent" BorderThickness="0" Foreground="#D1D5DB" Margin="0,4,0,0">
        <ListView.View>
          <GridView>
            <GridViewColumn Header="" DisplayMemberBinding="{Binding Qty}"  Width="44"/>
            <GridViewColumn Header="" DisplayMemberBinding="{Binding Name}" Width="250"/>
            <GridViewColumn Header="" DisplayMemberBinding="{Binding Line}" Width="90"/>
          </GridView>
        </ListView.View>
      </ListView>
      <Border Grid.Row="4" BorderBrush="#2A2D3A" BorderThickness="0,1,0,0" Padding="0,10,0,0" Margin="0,8,0,0">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="TOTAL" FontSize="14" FontWeight="Bold" Foreground="#FFFFFF"/>
          <TextBlock x:Name="DlgTotal" Grid.Column="1" FontSize="16" FontWeight="Bold" Foreground="#14B8A6"/>
        </Grid>
      </Border>
      <Grid Grid.Row="5" Margin="0,16,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Button x:Name="DlgClose"   Grid.Column="0" Content="Close"        Height="38" Background="#374151" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand"/>
        <Button x:Name="DlgReprint" Grid.Column="2" Content="Reprint Check" Height="38" Background="#14B8A6" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" FontWeight="Bold"/>
      </Grid>
    </Grid>
  </Border>
</Window>
"@
    $dr  = New-Object System.Xml.XmlNodeReader $dxaml
    $dlg = [Windows.Markup.XamlReader]::Load($dr)
    $dlg.Owner = $window
    $dlg.FindName('DlgBillNum').Text = "$($b.id)"
    $dlg.FindName('DlgMeta').Text    = "$dt  .  Table #$($b.table)  .  $($b.waiter)  .  $pay$cov"
    $dlg.FindName('DlgItems').ItemsSource = $itemRows
    $dlg.FindName('DlgTotal').Text   = ('{0} {1:N2}' -f $sym, [double]$b.total)
    $dlg.FindName('DlgClose').Add_Click({ $dlg.Close() })
    $dlg.FindName('DlgReprint').Add_Click({ if (Invoke-Reprint $b.id) { $dlg.Close() } }.GetNewClosure())
    $dlg.ShowDialog() | Out-Null
}

(ctl 'MenuReprint').Add_Click({
    $sel = (ctl 'BillList').SelectedItem
    if (-not $sel) { return }
    Invoke-Reprint $sel.BillNum | Out-Null
})

(ctl 'BillList').Add_MouseDoubleClick({
    $sel = (ctl 'BillList').SelectedItem
    if ($sel) { Show-BillDetails $sel }
})

# ─── DAILY REPORT PAGE ──────────────────────────────────────────────────────
$script:lastReport = $null
(ctl 'ReportDate').SelectedDate = Get-Date

(ctl 'ReportGenerate').Add_Click({
    try {
        $d  = (ctl 'ReportDate').SelectedDate
        if (-not $d) { return }
        $st  = (ctl 'ReportStart').Text
        $en  = (ctl 'ReportEnd').Text
        $url = "$base/local/report?date=$($d.ToString('yyyy-MM-dd'))&start=$st&end=$en"
        $r   = Invoke-RestMethod -Uri $url -TimeoutSec 5 -ErrorAction Stop

        (ctl 'ReportEmpty').Visibility   = 'Collapsed'
        (ctl 'ReportResults').Visibility = 'Visible'
        (ctl 'ReportHeader').Text = "Report - $($r.date) ($($r.startTime) to $($r.endTime))"
        $sym = if ($script:currencySymbol) { $script:currencySymbol } else { 'EUR' }
        (ctl 'RepRevenue').Text  = ('{0} {1:N2}' -f $sym, [double]$r.total_revenue)
        (ctl 'RepOrders').Text   = [string]$r.total_orders
        (ctl 'RepAvg').Text      = ('{0} {1:N2}' -f $sym, [double]$r.avg_ticket)
        (ctl 'RepPayments').Text = ('Cash: {0:N2}     Card: {1:N2}     Mixed: {2:N2}     Unpaid: {3:N2}' -f `
            [double]$r.payment.cash, [double]$r.payment.card, [double]$r.payment.mixed, [double]$r.payment.unpaid)
        $items = foreach ($it in $r.top_items) {
            [PSCustomObject]@{ Name = $it.name; QtyStr = "x$($it.qty)"; RevStr = ('{0} {1:N2}' -f $sym, [double]$it.revenue) }
        }
        (ctl 'RepItems').ItemsSource = @($items)
        $script:lastReport = $r
    } catch {
        [System.Windows.MessageBox]::Show("Report failed: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null
    }
})

(ctl 'RepSave').Add_Click({
    if (-not $script:lastReport) { return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = "report-$($script:lastReport.date).txt"
    $dlg.Filter   = 'Text files (*.txt)|*.txt'
    if ($dlg.ShowDialog()) {
        $r   = $script:lastReport
        $sym = if ($script:currencySymbol) { $script:currencySymbol } else { 'EUR' }
        $txt = @(
            'LightMenu Daily Report', '======================',
            "Date:    $($r.date)", "Window:  $($r.startTime) - $($r.endTime)", '',
            "Revenue:  $sym $('{0:N2}' -f [double]$r.total_revenue)",
            "Orders:   $($r.total_orders)", "Average:  $sym $('{0:N2}' -f [double]$r.avg_ticket)", '',
            'Payment Breakdown',
            "  Cash:   $sym $('{0:N2}' -f [double]$r.payment.cash)",
            "  Card:   $sym $('{0:N2}' -f [double]$r.payment.card)",
            "  Mixed:  $sym $('{0:N2}' -f [double]$r.payment.mixed)",
            "  Unpaid: $sym $('{0:N2}' -f [double]$r.payment.unpaid)", '',
            'Top Items'
        )
        foreach ($it in $r.top_items) {
            $txt += ("  x{0,-4} {1,-30} {2} {3:N2}" -f $it.qty, $it.name, $sym, [double]$it.revenue)
        }
        $txt -join "`r`n" | Set-Content -Path $dlg.FileName -Encoding UTF8
        [System.Windows.MessageBox]::Show('Report saved.', 'LightMenu', 'OK', 'Information') | Out-Null
    }
})

# ─── STAFF PAGE ─────────────────────────────────────────────────────────────
$script:staffData = @()

# Fallback role colours, matching the web app's default role palette. Used only
# when the role's own DB colour isn't available (role_color).
function Get-RoleColor($role) {
    switch -Wildcard ($role) {
        '*anager*' { return '#8B5CF6' }   # violet
        '*hef*'    { return '#F97316' }   # orange
        '*wner*'   { return '#EF4444' }   # red
        '*aiter*'  { return '#3B82F6' }   # blue
        '*ashier*' { return '#10B981' }   # green
        default    { return '#3B82F6' }
    }
}

function New-StaffCard($member) {
    $card = New-Object System.Windows.Controls.Border
    $card.Background    = SolidBrush '#1A1D29'
    $card.BorderBrush   = SolidBrush '#2A2D3A'
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.CornerRadius  = New-Object System.Windows.CornerRadius(10)
    $card.Padding       = New-Object System.Windows.Thickness(16)
    $card.Margin        = New-Object System.Windows.Thickness(0,0,12,12)
    $card.Width         = 350

    $sp = New-Object System.Windows.Controls.StackPanel

    # Top row: name + active dot
    $topRow = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::Auto
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = [System.Windows.GridLength]::Auto
    $topRow.ColumnDefinitions.Add($c1); $topRow.ColumnDefinitions.Add($c2); $topRow.ColumnDefinitions.Add($c3)

    $nameBlock = New-Object System.Windows.Controls.TextBlock
    $nameBlock.Text       = $member.name
    $nameBlock.Foreground = [System.Windows.Media.Brushes]::White
    $nameBlock.FontSize   = 15; $nameBlock.FontWeight = 'Bold'
    [System.Windows.Controls.Grid]::SetColumn($nameBlock, 0)

    $dotColor = if ($member.active) { '#34D399' } else { '#6B7280' }
    $activeDot = New-Object System.Windows.Shapes.Ellipse
    $activeDot.Width = 8; $activeDot.Height = 8; $activeDot.Fill = SolidBrush $dotColor
    $activeDot.VerticalAlignment = 'Center'; $activeDot.Margin = New-Object System.Windows.Thickness(0,0,5,0)
    [System.Windows.Controls.Grid]::SetColumn($activeDot, 2)

    $activeLabel = New-Object System.Windows.Controls.TextBlock
    $activeLabel.Foreground = SolidBrush $dotColor
    $activeLabel.FontSize   = 11
    $activeLabel.Text       = if ($member.active) { T 'staff_active' } else { T 'staff_inactive' }
    $activeLabel.VerticalAlignment = 'Center'

    $activeSp = New-Object System.Windows.Controls.StackPanel
    $activeSp.Orientation = 'Horizontal'; $activeSp.VerticalAlignment = 'Center'
    $activeSp.Children.Add($activeDot) | Out-Null
    $activeSp.Children.Add($activeLabel) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($activeSp, 2)

    $topRow.Children.Add($nameBlock) | Out-Null
    $topRow.Children.Add($activeSp)  | Out-Null
    $sp.Children.Add($topRow) | Out-Null

    # Role badge
    $roleBorder = New-Object System.Windows.Controls.Border
    $roleColor  = if ($member.role_color) { $member.role_color } else { Get-RoleColor $member.role }
    $roleBorder.Background  = SolidBrush (Tint $roleColor '20')
    $roleBorder.BorderBrush = SolidBrush $roleColor
    $roleBorder.BorderThickness = New-Object System.Windows.Thickness(1)
    $roleBorder.CornerRadius = New-Object System.Windows.CornerRadius(4)
    $roleBorder.Padding = New-Object System.Windows.Thickness(8,2,8,2)
    $roleBorder.HorizontalAlignment = 'Left'
    $roleBorder.Margin = New-Object System.Windows.Thickness(0,8,0,0)
    $roleText = New-Object System.Windows.Controls.TextBlock
    $roleText.Text = $member.role; $roleText.Foreground = SolidBrush $roleColor; $roleText.FontSize = 11; $roleText.FontWeight = 'SemiBold'
    $roleBorder.Child = $roleText
    $sp.Children.Add($roleBorder) | Out-Null

    # Waiter link
    $linkSp = New-Object System.Windows.Controls.StackPanel
    $linkSp.Orientation = 'Horizontal'; $linkSp.Margin = New-Object System.Windows.Thickness(0,10,0,0)
    $linkBox = New-Object System.Windows.Controls.TextBox
    $linkBox.Width = 190; $linkBox.IsReadOnly = $true; $linkBox.FontSize = 11; $linkBox.Padding = New-Object System.Windows.Thickness(6,4,6,4)
    $linkBox.Background = SolidBrush '#0F1117'; $linkBox.Foreground = SolidBrush '#9CA3AF'; $linkBox.BorderBrush = SolidBrush '#2A2D3A'
    $linkBox.Text = if ($member.waiter_link) { $member.waiter_link } else { '- no link -' }
    $copyBtn = New-Object System.Windows.Controls.Button
    $copyBtn.Content = [char]0xE8C8
    $copyBtn.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
    $copyBtn.FontSize = 12; $copyBtn.Margin = New-Object System.Windows.Thickness(6,0,0,0)
    $copyBtn.Background = SolidBrush '#2A2D3A'; $copyBtn.Foreground = [System.Windows.Media.Brushes]::White
    $copyBtn.BorderThickness = New-Object System.Windows.Thickness(0); $copyBtn.Cursor = 'Hand'
    $copyBtn.Padding = New-Object System.Windows.Thickness(8,4,8,4)
    $copyLink = $member.waiter_link
    $copyBtn.Add_Click({ if ($copyLink) { [System.Windows.Clipboard]::SetText($copyLink) } })
    $linkSp.Children.Add($linkBox) | Out-Null
    $linkSp.Children.Add($copyBtn) | Out-Null
    $sp.Children.Add($linkSp) | Out-Null

    # Last used
    $lastUsedText = New-Object System.Windows.Controls.TextBlock
    $lastUsedText.Foreground = SolidBrush '#6B7280'; $lastUsedText.FontSize = 11
    $lastUsedText.Margin = New-Object System.Windows.Thickness(0,6,0,0)
    if ($member.last_used) {
        try {
            $ago = [datetime]::UtcNow - [datetime]::Parse($member.last_used)
            $agoStr = if ($ago.TotalMinutes -lt 60) { [int]$ago.TotalMinutes.ToString() + ' min ago' }
                      elseif ($ago.TotalHours -lt 24) { [int]$ago.TotalHours.ToString() + ' hours ago' }
                      else { [int]$ago.TotalDays.ToString() + ' days ago' }
            $lastUsedText.Text = (T 'staff_last_used') + ' ' + $agoStr
        } catch { $lastUsedText.Text = (T 'staff_last_used') + ' ' + $member.last_used }
    } else {
        $lastUsedText.Text = (T 'staff_never_used')
    }
    $sp.Children.Add($lastUsedText) | Out-Null

    # Action buttons (Share, On/Off, New Link, Role, Delete)
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.Margin = New-Object System.Windows.Thickness(0,14,0,0)

    $memberData = $member

    # SHARE — opens QR popup
    $shareBtn = Make-PillButton 'Share' '#4ADE80' $member.id ([char]0xE72D)
    $shareBtn.Add_Click({ Show-QrDialog $memberData.id $memberData.name $memberData.waiter_link }.GetNewClosure())
    $btnRow.Children.Add($shareBtn) | Out-Null

    # ON/OFF toggle
    $toggleText = if ($member.active) { 'Off' } else { 'On' }
    $toggleColor = if ($member.active) { '#F87171' } else { '#4ADE80' }
    $toggleBtn = Make-PillButton $toggleText $toggleColor $member.id ([char]0xE7E8)
    $toggleBtn.Add_Click({
        $mid = $this.Tag
        try {
            Invoke-RestMethod -Uri "$base/local/staff/$([System.Uri]::EscapeDataString($mid))/toggle" -Method Post -TimeoutSec 8 -ErrorAction Stop | Out-Null
            Update-Staff-Page
        } catch { Show-SupabaseError $_ 'Toggle' }
    })
    $btnRow.Children.Add($toggleBtn) | Out-Null

    # NEW LINK
    $newLinkBtn = Make-PillButton 'New Link' '#9CA3AF' $member.id ([char]0xE72C)
    $newLinkBtn.Add_Click({
        $mid = $this.Tag
        $res = [System.Windows.MessageBox]::Show("Generate a new link? The old link will stop working.", 'LightMenu', 'YesNo', 'Question')
        if ($res -ne 'Yes') { return }
        try {
            Invoke-RestMethod -Uri "$base/local/staff/$([System.Uri]::EscapeDataString($mid))/new_link" -Method Post -TimeoutSec 8 -ErrorAction Stop | Out-Null
            Update-Staff-Page
        } catch { Show-SupabaseError $_ 'New Link' }
    })
    $btnRow.Children.Add($newLinkBtn) | Out-Null

    # ROLE
    $roleBtn = Make-PillButton 'Role' '#60A5FA' $member.id ([char]0xE77B)
    $roleBtn.Add_Click({ Show-RoleDialog $memberData.id $memberData.role }.GetNewClosure())
    $btnRow.Children.Add($roleBtn) | Out-Null

    # PIN — set/replace the waiter's login PIN
    $pinBtn = Make-PillButton 'PIN' '#A78BFA' $member.id ([char]0xE192)
    $pinBtn.Add_Click({ Show-PinDialog $memberData.id $memberData.name }.GetNewClosure())
    $btnRow.Children.Add($pinBtn) | Out-Null

    # DELETE
    $removeBtn = Make-PillButton 'Delete' '#F87171' $member.id ([char]0xE74D)
    $removeBtn.Add_Click({
        $mid = $this.Tag
        $res = [System.Windows.MessageBox]::Show((T 'confirm_remove'), 'LightMenu', 'YesNo', 'Question')
        if ($res -eq 'Yes') {
            try {
                Invoke-RestMethod -Uri "$base/local/staff/$([System.Uri]::EscapeDataString($mid))" -Method Delete -TimeoutSec 8 -ErrorAction Stop | Out-Null
                Update-Staff-Page
            } catch { Show-SupabaseError $_ 'Delete' }
        }
    })
    $btnRow.Children.Add($removeBtn) | Out-Null

    $sp.Children.Add($btnRow) | Out-Null
    $card.Child = $sp
    return $card
}

function Show-SupabaseError($errorRecord, $action) {
    $detail = if ($errorRecord.Exception) { $errorRecord.Exception.Message } else { "$errorRecord" }
    $msg = "$action failed.`n`n$detail"
    [System.Windows.MessageBox]::Show($msg, 'LightMenu', 'OK', 'Warning') | Out-Null
}

function Make-PillButton($content, $color, $tag, $iconGlyph) {
    # Web-matching tinted pill: colour/10 background, colour/30 border, colour text
    # (alpha PREFIXED for WPF). Hover deepens the tint. An optional Segoe MDL2
    # Assets glyph (monochrome, inherits the pill colour) sits left of the label,
    # matching the web app's icon buttons.
    $bg      = Tint $color '1A'   # ~10%
    $bd      = Tint $color '4D'   # ~30%
    $hoverBg = Tint $color '2E'   # ~18%
    $hoverBd = Tint $color '80'   # ~50%
    $b = New-Object System.Windows.Controls.Button
    if ($iconGlyph) {
        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Orientation = 'Horizontal'
        $ico = New-Object System.Windows.Controls.TextBlock
        $ico.Text = [string]$iconGlyph
        $ico.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
        $ico.FontSize = 11; $ico.VerticalAlignment = 'Center'
        $ico.Foreground = SolidBrush $color
        $ico.Margin = New-Object System.Windows.Thickness(0,0,5,0)
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = [string]$content; $txt.VerticalAlignment = 'Center'
        $txt.Foreground = SolidBrush $color
        $stack.Children.Add($ico) | Out-Null
        $stack.Children.Add($txt) | Out-Null
        $b.Content = $stack
    } else {
        $b.Content = $content
    }
    $b.FontSize    = 11
    $b.FontWeight  = 'Medium'
    $b.Cursor      = 'Hand'
    $b.Background  = SolidBrush $bg
    $b.Foreground  = SolidBrush $color
    $b.BorderBrush = SolidBrush $bd
    $b.BorderThickness = New-Object System.Windows.Thickness(1)
    $b.Padding     = New-Object System.Windows.Thickness(11,5,11,5)
    $b.Margin      = New-Object System.Windows.Thickness(0,0,6,0)
    $b.Tag         = $tag
    $b.Template = [System.Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                 TargetType="Button">
  <Border x:Name="bdr" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter TargetName="bdr" Property="Background" Value="$hoverBg"/>
      <Setter TargetName="bdr" Property="BorderBrush" Value="$hoverBd"/>
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Setter TargetName="bdr" Property="Background" Value="$bd"/>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
"@)
    return $b
}

function Show-QrDialog($staffId, $staffName, $waiterLink) {
    # Prefer passing the link directly (avoids Supabase round-trip).
    # Fallback to legacy lookup-by-id if no link provided.
    try {
        if ($waiterLink) {
            $encoded = [System.Uri]::EscapeDataString($waiterLink)
            $r = Invoke-RestMethod -Uri "$base/local/qr?text=$encoded" -TimeoutSec 8 -ErrorAction Stop
        } else {
            $r = Invoke-RestMethod -Uri "$base/local/staff/$([System.Uri]::EscapeDataString($staffId))/qr" -TimeoutSec 8 -ErrorAction Stop
        }
    } catch {
        [System.Windows.MessageBox]::Show("Could not generate QR: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $r -or -not $r.modules) {
        [System.Windows.MessageBox]::Show("No link available for $staffName. Click 'New Link' first.", 'LightMenu', 'OK', 'Information') | Out-Null
        return
    }

    [xml]$qrXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="520" Width="420" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#0F1117" TextElement.Foreground="#FFFFFF">
  <Border Background="#161922" CornerRadius="12">
    <StackPanel Margin="28">
      <TextBlock x:Name="QrTitle" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,6"/>
      <TextBlock Text="Scan to open the waiter app" Foreground="#9CA3AF" FontSize="12" Margin="0,0,0,18"/>
      <Border Background="#FFFFFF" CornerRadius="8" Padding="16" HorizontalAlignment="Center">
        <Canvas x:Name="QrCanvas" Width="280" Height="280" Background="White"/>
      </Border>
      <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6" Margin="0,18,0,0" Padding="10,8">
        <TextBox x:Name="QrLink" Background="Transparent" BorderThickness="0" Foreground="#9CA3AF" FontSize="11" IsReadOnly="True"/>
      </Border>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="QrCopy" Padding="14,7" Margin="0,0,8,0" Background="#2A2D3A" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" Content="Copy link" FontSize="12"/>
        <Button x:Name="QrClose" Padding="14,7" BorderThickness="0" Cursor="Hand" Foreground="#FFFFFF" FontSize="12" FontWeight="SemiBold" Content="Close">
          <Button.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#14B8A6" Offset="0"/>
              <GradientStop Color="#06B6D4" Offset="1"/>
            </LinearGradientBrush>
          </Button.Background>
        </Button>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $qrXaml
    $qrDlg  = [Windows.Markup.XamlReader]::Load($reader)
    $qrDlg.Owner = $window
    $qrDlg.Title = "Share - $staffName"
    $qrDlg.FindName('QrTitle').Text = "Share with $staffName"
    $qrDlg.FindName('QrLink').Text  = $r.link

    # Draw QR onto Canvas
    $canvas = $qrDlg.FindName('QrCanvas')
    $size = [int]$r.size
    $cell = 280 / $size
    $black = SolidBrush '#000000'
    for ($row = 0; $row -lt $size; $row++) {
        for ($col = 0; $col -lt $size; $col++) {
            if ($r.modules[$row][$col] -eq 1) {
                $rect = New-Object System.Windows.Shapes.Rectangle
                $rect.Width = [Math]::Ceiling($cell) + 0.5
                $rect.Height = [Math]::Ceiling($cell) + 0.5
                $rect.Fill = $black
                [System.Windows.Controls.Canvas]::SetLeft($rect, $col * $cell)
                [System.Windows.Controls.Canvas]::SetTop($rect, $row * $cell)
                $canvas.Children.Add($rect) | Out-Null
            }
        }
    }

    $linkText = $r.link
    $qrDlg.FindName('QrCopy').Add_Click({ [System.Windows.Clipboard]::SetText($linkText) }.GetNewClosure())
    $qrDlg.FindName('QrClose').Add_Click({ $qrDlg.Close() }.GetNewClosure())
    $qrDlg.ShowDialog() | Out-Null
}

function Show-RoleDialog($staffId, $currentRole) {
    # Fetch available roles
    $roles = @()
    try {
        $r = Invoke-RestMethod -Uri "$base/local/roles" -TimeoutSec 5 -ErrorAction Stop
        if ($r -isnot [array]) { $r = @($r) }
        $roles = $r
    } catch {}
    if ($roles.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No roles found. Create roles in the web dashboard first.", 'LightMenu', 'OK', 'Information') | Out-Null
        return
    }

    [xml]$roleXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="280" Width="380" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#0F1117" TextElement.Foreground="#FFFFFF">
  <Border Background="#161922" CornerRadius="12">
    <StackPanel Margin="28">
      <TextBlock Text="Change Role" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,18"/>
      <TextBlock Text="Role" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,8"/>
      <ListBox x:Name="RoleList" Background="#0F1117" Foreground="#FFFFFF" BorderBrush="#2A2D3A" BorderThickness="1" Height="120" FontSize="13">
        <ListBox.ItemContainerStyle>
          <Style TargetType="ListBoxItem">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="Padding" Value="10,8"/>
            <Style.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#2A2D3A"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#14B8A6"/></Trigger>
            </Style.Triggers>
          </Style>
        </ListBox.ItemContainerStyle>
      </ListBox>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button x:Name="RoleCancel" Padding="14,7" Margin="0,0,8,0" Background="#2A2D3A" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" Content="Cancel" FontSize="12"/>
        <Button x:Name="RoleOk" Padding="18,7" BorderThickness="0" Cursor="Hand" Foreground="#FFFFFF" FontSize="12" FontWeight="SemiBold" Content="Save">
          <Button.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#14B8A6" Offset="0"/>
              <GradientStop Color="#06B6D4" Offset="1"/>
            </LinearGradientBrush>
          </Button.Background>
        </Button>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $roleXaml
    $dlg    = [Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $window
    $dlg.Title = "Change Role"

    $listBox = $dlg.FindName('RoleList')
    foreach ($r in $roles) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $r.name
        $item.Tag     = $r.id
        $listBox.Items.Add($item) | Out-Null
        if ($r.name -eq $currentRole) { $listBox.SelectedItem = $item }
    }

    $dlg.FindName('RoleCancel').Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.FindName('RoleOk').Add_Click({
        $sel = $listBox.SelectedItem
        if (-not $sel) { $dlg.Close(); return }
        try {
            $body = @{ role_id = $sel.Tag } | ConvertTo-Json
            Invoke-RestMethod -Uri "$base/local/staff/$([System.Uri]::EscapeDataString($staffId))/role" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 8 -ErrorAction Stop | Out-Null
            $dlg.Close()
            Update-Staff-Page
        } catch { [System.Windows.MessageBox]::Show("Role update failed: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null }
    }.GetNewClosure())
    $dlg.ShowDialog() | Out-Null
}

function Show-PinDialog($staffId, $staffName) {
    [xml]$pinXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="250" Width="360" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#0F1117" TextElement.Foreground="#FFFFFF">
  <Border Background="#161922" CornerRadius="12">
    <StackPanel Margin="28">
      <TextBlock x:Name="PinTitle" Text="Set PIN" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,6"/>
      <TextBlock x:Name="PinHint" Text="4-digit login PIN for this waiter" Foreground="#9CA3AF" FontSize="11" Margin="0,0,0,16"/>
      <TextBox x:Name="PinBox" MaxLength="6" FontSize="22" FontWeight="Bold" Padding="10,8"
               HorizontalContentAlignment="Center" Background="#0F1117" Foreground="#FFFFFF" BorderBrush="#2A2D3A" BorderThickness="1"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
        <Button x:Name="PinCancel" Padding="14,7" Margin="0,0,8,0" Background="#2A2D3A" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" Content="Cancel" FontSize="12"/>
        <Button x:Name="PinOk" Padding="18,7" BorderThickness="0" Cursor="Hand" Foreground="#FFFFFF" FontSize="12" FontWeight="SemiBold" Content="Save">
          <Button.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#14B8A6" Offset="0"/>
              <GradientStop Color="#06B6D4" Offset="1"/>
            </LinearGradientBrush>
          </Button.Background>
        </Button>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $pinXaml
    $dlg    = [Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $window
    $dlg.Title = "Set PIN"
    if ($staffName) { $dlg.FindName('PinTitle').Text = (T 'staff_set_pin') + " - $staffName" }

    $pinBox = $dlg.FindName('PinBox')
    # Digits only
    $pinBox.Add_PreviewTextInput({ param($s,$e) if ($e.Text -notmatch '^[0-9]+$') { $e.Handled = $true } })
    $pinBox.Focus() | Out-Null

    $dlg.FindName('PinCancel').Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.FindName('PinOk').Add_Click({
        $pin = ($pinBox.Text).Trim()
        if ($pin -notmatch '^\d{4,6}$') {
            [System.Windows.MessageBox]::Show((T 'staff_pin_invalid'), 'LightMenu', 'OK', 'Warning') | Out-Null
            return
        }
        try {
            $body = @{ pin = $pin } | ConvertTo-Json
            Invoke-RestMethod -Uri "$base/local/staff/$([System.Uri]::EscapeDataString($staffId))/pin" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 8 -ErrorAction Stop | Out-Null
            $dlg.Close()
            Update-Staff-Page
        } catch { Show-SupabaseError $_ 'PIN' }
    }.GetNewClosure())
    $dlg.ShowDialog() | Out-Null
}

function Update-Staff-Page {
    try {
        $staff = Invoke-RestMethod -Uri "$base/local/staff" -TimeoutSec 3 -ErrorAction Stop
        if ($staff -isnot [System.Array]) { $staff = @($staff) }
        $script:staffData = $staff
    } catch { $script:staffData = @() }

    $panel = ctl 'StaffCards'
    $panel.Children.Clear()

    if ($script:staffData.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = T 'no_staff'; $empty.Foreground = SolidBrush '#6B7280'
        $empty.FontSize = 13; $empty.Margin = New-Object System.Windows.Thickness(0,40,0,0)
        $panel.Children.Add($empty) | Out-Null
        return
    }

    foreach ($m in $script:staffData) {
        $panel.Children.Add((New-StaffCard $m)) | Out-Null
    }
}

function Show-AddStaffDialog {
    # Load roles from Supabase
    $roles = @()
    try {
        $r = Invoke-RestMethod -Uri "$base/local/roles" -TimeoutSec 5 -ErrorAction Stop
        if ($r -isnot [array]) { $r = @($r) }
        $roles = $r
    } catch {}

    [xml]$dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="420" Width="430" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#0F1117" TextElement.Foreground="#FFFFFF">
  <Border Background="#161922" CornerRadius="12">
    <StackPanel Margin="28,24,28,24">
      <TextBlock x:Name="DlgTitle" Text="Add Staff Member" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,20"/>

      <TextBlock x:Name="DlgNameLbl" Text="Name" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,8"/>
      <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
        <TextBox x:Name="DlgName" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,8" FontSize="13" CaretBrush="#FFFFFF"/>
      </Border>

      <TextBlock x:Name="DlgRoleLbl" Text="Role" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,18,0,8"/>
      <ListBox x:Name="DlgRole" Background="#0F1117" Foreground="#FFFFFF" BorderBrush="#2A2D3A" BorderThickness="1" Height="130" FontSize="13">
        <ListBox.ItemContainerStyle>
          <Style TargetType="ListBoxItem">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="Padding" Value="10,8"/>
            <Style.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#2A2D3A"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#14B8A6"/></Trigger>
            </Style.Triggers>
          </Style>
        </ListBox.ItemContainerStyle>
      </ListBox>

      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
        <Button x:Name="DlgCancel" Padding="18,9" Background="#2A2D3A" Foreground="#FFFFFF"
                BorderThickness="0" Cursor="Hand" Margin="0,0,10,0" FontSize="13">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </ControlTemplate>
          </Button.Template>
        </Button>
        <Button x:Name="DlgOk" Padding="22,9" BorderThickness="0" Cursor="Hand" Foreground="#FFFFFF" FontSize="13" FontWeight="SemiBold">
          <Button.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#14B8A6" Offset="0"/>
              <GradientStop Color="#06B6D4" Offset="1"/>
            </LinearGradientBrush>
          </Button.Background>
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </ControlTemplate>
          </Button.Template>
        </Button>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $r2   = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlg  = [Windows.Markup.XamlReader]::Load($r2)
    $dlg.Owner = $window
    $dlg.Title = T 'dlg_add_staff_title'
    $dlg.FindName('DlgTitle').Text     = T 'dlg_add_staff_title'
    $dlg.FindName('DlgNameLbl').Text   = T 'lbl_staff_name'
    $dlg.FindName('DlgRoleLbl').Text   = T 'lbl_staff_role'
    $dlg.FindName('DlgCancel').Content = T 'dlg_cancel'
    $dlg.FindName('DlgOk').Content     = T 'dlg_ok'
    $script:dlgResult = $null

    $roleList = $dlg.FindName('DlgRole')
    if ($roles.Count -eq 0) {
        $emptyItem = New-Object System.Windows.Controls.ListBoxItem
        $emptyItem.Content = 'Waiter'
        $emptyItem.Tag = $null
        $roleList.Items.Add($emptyItem) | Out-Null
        $roleList.SelectedIndex = 0
    } else {
        foreach ($r in $roles) {
            $item = New-Object System.Windows.Controls.ListBoxItem
            $item.Content = $r.name
            $item.Tag     = $r.id
            $roleList.Items.Add($item) | Out-Null
        }
        $roleList.SelectedIndex = 0
    }

    $dlg.FindName('DlgCancel').Add_Click({ $dlg.Close() })
    $dlg.FindName('DlgOk').Add_Click({
        $name = $dlg.FindName('DlgName').Text.Trim()
        if ($name -eq '') { return }
        $sel = $roleList.SelectedItem
        $script:dlgResult = @{ name = $name; role = ($sel.Content); role_id = $sel.Tag }
        $dlg.Close()
    })
    $dlg.ShowDialog() | Out-Null
    return $script:dlgResult
}

(ctl 'AddStaffBtn').Add_Click({
    $data = Show-AddStaffDialog
    if (-not $data) { return }
    try {
        $body = ($data | ConvertTo-Json)
        Invoke-RestMethod -Uri "$base/local/staff" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop | Out-Null
        Update-Staff-Page
    } catch {
        [System.Windows.MessageBox]::Show("Failed to add staff: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null
    }
})

# ─── Buttons ────────────────────────────────────────────────────────────────
(ctl 'TestBtn').Add_Click({
    try {
        Invoke-RestMethod -Uri $rescanUrl -Method Post -TimeoutSec 10 -ErrorAction Stop | Out-Null
        [System.Windows.MessageBox]::Show((T 'rescan_info'), 'LightMenu', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Rescan failed: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null
    }
})

(ctl 'RestartBtn').Add_Click({
    $result = [System.Windows.MessageBox]::Show((T 'confirm_restart'), 'LightMenu', 'YesNo', 'Question')
    if ($result -eq 'Yes') {
        Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
})


# ─── MENU PAGE ──────────────────────────────────────────────────────────────
$script:menuData      = $null
$script:menuActiveCat = '__all__'

# A small uppercase divider above the categories that belong to a section
# (e.g. MENU, DRINKS). Mirrors the web SectionsPanel grouping.
function New-SectionHeader($sectionName) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $sectionName.ToUpper()
    $tb.FontSize = 10; $tb.FontWeight = 'Bold'
    $tb.Foreground = SolidBrush '#7A8295'
    $tb.Margin = New-Object System.Windows.Thickness(10,12,0,4)
    return $tb
}

function New-MenuCatButton($id, $label, $count) {
    $active = ($id -eq $script:menuActiveCat)
    $bd = New-Object System.Windows.Controls.Border
    $bd.Tag = $id
    $bd.Cursor = 'Hand'
    $bd.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $bd.Padding = New-Object System.Windows.Thickness(10,8,10,8)
    $bd.Margin = New-Object System.Windows.Thickness(0,0,0,2)
    $bd.Background = if ($active) { SolidBrush '#14B8A6' } else { [System.Windows.Media.Brushes]::Transparent }
    $g = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = '*'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $label; $name.FontSize = 13
    $name.Foreground = if ($active) { [System.Windows.Media.Brushes]::White } else { SolidBrush '#D1D5DB' }
    $name.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($name, 0)
    $cnt = New-Object System.Windows.Controls.TextBlock
    $cnt.Text = [string]$count; $cnt.FontSize = 11; $cnt.VerticalAlignment = 'Center'
    $cnt.Foreground = if ($active) { [System.Windows.Media.Brushes]::White } else { SolidBrush '#7A8295' }
    [System.Windows.Controls.Grid]::SetColumn($cnt, 1)
    $g.Children.Add($name) | Out-Null; $g.Children.Add($cnt) | Out-Null
    $bd.Child = $g
    $bd.Add_MouseLeftButtonUp({ $script:menuActiveCat = $this.Tag; Render-Menu }) | Out-Null
    # Real categories get a right-click menu to rename / delete. "All items" doesn't.
    if ($id -ne '__all__') {
        $cm = New-Object System.Windows.Controls.ContextMenu
        $cm.Background = SolidBrush '#1A1D29'; $cm.Foreground = [System.Windows.Media.Brushes]::White
        $miRename = New-Object System.Windows.Controls.MenuItem
        $miRename.Header = T 'btn_rename'; $miRename.Tag = @{ id = $id; name = $label }
        $miRename.Add_Click({ Show-CategoryDialog $this.Tag }) | Out-Null
        # Move-to-section submenu — lists every existing section plus "New section…".
        $miMove = New-Object System.Windows.Controls.MenuItem
        $miMove.Header = T 'menu_move_to_section'
        $curSec = 'menu'
        if ($script:menuData) {
            $cc = @($script:menuData.categories | Where-Object { $_.id -eq $id })[0]
            if ($cc -and $cc.section) { $curSec = $cc.section }
        }
        $secList = @()
        if ($script:menuData) {
            $secList = @($script:menuData.categories | ForEach-Object { if ($_.section) { $_.section } else { 'menu' } } | Select-Object -Unique)
        }
        if ($secList -notcontains 'menu') { $secList = @('menu') + $secList }
        foreach ($s in $secList) {
            $smi = New-Object System.Windows.Controls.MenuItem
            $smi.Header = $s.ToUpper()
            $smi.IsCheckable = $false
            if ($s -eq $curSec) { $smi.IsEnabled = $false; $smi.Header = $s.ToUpper() + '  (current)' }
            $smi.Tag = @{ id = $id; section = $s }
            $smi.Add_Click({ Move-CategoryToSection $this.Tag.id $this.Tag.section }) | Out-Null
            $miMove.Items.Add($smi) | Out-Null
        }
        $sep = New-Object System.Windows.Controls.Separator
        $miMove.Items.Add($sep) | Out-Null
        $smiNew = New-Object System.Windows.Controls.MenuItem
        $smiNew.Header = T 'menu_new_section'; $smiNew.Tag = $id
        $smiNew.Add_Click({
            $cid = $this.Tag
            $ns = [Microsoft.VisualBasic.Interaction]::InputBox((T 'menu_new_section_prompt'), 'LightMenu', '')
            if ($ns) { Move-CategoryToSection $cid ($ns.Trim().ToLower()) }
        }) | Out-Null
        $miMove.Items.Add($smiNew) | Out-Null

        $miDelete = New-Object System.Windows.Controls.MenuItem
        $miDelete.Header = T 'btn_delete'; $miDelete.Tag = @{ id = $id; name = $label }
        $miDelete.Add_Click({
            $cat = $this.Tag
            $ok = [System.Windows.MessageBox]::Show(((T 'confirm_delete_category') + " `"$($cat.name)`"?"), 'LightMenu', 'YesNo', 'Warning')
            if ($ok -ne 'Yes') { return }
            try {
                Invoke-RestMethod -Uri "$base/local/menu/category/$($cat.id)" -Method Delete -TimeoutSec 12 -ErrorAction Stop | Out-Null
                if ($script:menuActiveCat -eq $cat.id) { $script:menuActiveCat = '__all__' }
                Update-Menu-Page
            } catch {
                [System.Windows.MessageBox]::Show((T 'menu_save_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
            }
        }) | Out-Null
        $cm.Items.Add($miRename) | Out-Null
        $cm.Items.Add($miMove) | Out-Null
        $cm.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
        $cm.Items.Add($miDelete) | Out-Null
        $bd.ContextMenu = $cm
    }
    return $bd
}

# PATCH a category's section, then refresh.
function Move-CategoryToSection($categoryId, $section) {
    if (-not $section) { return }
    try {
        Invoke-RestMethod -Uri "$base/local/menu/category/$categoryId" -Method Patch -Body (@{ section = $section } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Update-Menu-Page
    } catch {
        [System.Windows.MessageBox]::Show((T 'menu_save_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
    }
}

# PATCH an item's category, then refresh.
function Move-ItemToCategory($itemId, $categoryId) {
    try {
        Invoke-RestMethod -Uri "$base/local/menu/item/$itemId" -Method Patch -Body (@{ menu_category_id = $categoryId } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Update-Menu-Page
    } catch {
        [System.Windows.MessageBox]::Show((T 'menu_save_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
    }
}

function New-MenuItemRow($item) {
    $bd = New-Object System.Windows.Controls.Border
    $bd.BorderBrush = SolidBrush '#2A2D3A'
    $bd.BorderThickness = New-Object System.Windows.Thickness(0,0,0,1)
    $bd.Padding = New-Object System.Windows.Thickness(4,8,4,8)
    $g = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = '*'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '70'
    $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = 'Auto'
    $c4 = New-Object System.Windows.Controls.ColumnDefinition; $c4.Width = 'Auto'
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $g.ColumnDefinitions.Add($c3); $g.ColumnDefinitions.Add($c4)
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = $item.name; $name.FontSize = 13; $name.Foreground = SolidBrush '#FFFFFF'
    $name.VerticalAlignment = 'Center'; $name.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($name, 0)
    # Availability badge — clicking it flips is_available in Supabase.
    $status = New-Object System.Windows.Controls.TextBlock
    if ($item.available) { $status.Text = T 'menu_available';   $status.Foreground = SolidBrush '#14B8A6' }
    else                 { $status.Text = T 'menu_unavailable'; $status.Foreground = SolidBrush '#F59E0B' }
    $status.FontSize = 11; $status.VerticalAlignment = 'Center'; $status.Cursor = 'Hand'
    $status.Margin = New-Object System.Windows.Thickness(0,0,16,0)
    $status.Tag = $item
    $status.Add_MouseLeftButtonUp({
        $it = $this.Tag
        try {
            $body = @{ is_available = (-not $it.available) } | ConvertTo-Json
            Invoke-RestMethod -Uri "$base/local/menu/item/$($it.id)" -Method Patch -Body $body -ContentType 'application/json' -TimeoutSec 8 -ErrorAction Stop | Out-Null
            Update-Menu-Page
        } catch {
            [System.Windows.MessageBox]::Show((T 'menu_save_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
        }
    }) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($status, 1)
    $price = New-Object System.Windows.Controls.TextBlock
    $price.Text = Format-Money $item.price; $price.FontSize = 13; $price.FontWeight = 'SemiBold'
    $price.Foreground = SolidBrush '#D1D5DB'; $price.VerticalAlignment = 'Center'; $price.TextAlignment = 'Right'
    [System.Windows.Controls.Grid]::SetColumn($price, 2)
    $edit = New-Object System.Windows.Controls.Button
    $edit.Content = T 'btn_edit'; $edit.Style = (ctl 'MenuRefresh').Style
    $edit.Margin = New-Object System.Windows.Thickness(10,0,0,0); $edit.Tag = $item
    $edit.Add_Click({ Show-MenuItemDialog $this.Tag }) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($edit, 3)
    $del = New-Object System.Windows.Controls.Button
    $del.Content = 'X'; $del.Style = (ctl 'MenuRefresh').Style
    $del.Margin = New-Object System.Windows.Thickness(6,0,0,0); $del.Tag = $item
    $del.Add_Click({
        $it = $this.Tag
        $ok = [System.Windows.MessageBox]::Show(((T 'confirm_delete_item') + " `"$($it.name)`"?"), 'LightMenu', 'YesNo', 'Question')
        if ($ok -ne 'Yes') { return }
        try {
            Invoke-RestMethod -Uri "$base/local/menu/item/$($it.id)" -Method Delete -TimeoutSec 8 -ErrorAction Stop | Out-Null
            Update-Menu-Page
        } catch {
            [System.Windows.MessageBox]::Show((T 'menu_save_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
        }
    }) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($del, 4)
    $g.Children.Add($name) | Out-Null; $g.Children.Add($status) | Out-Null; $g.Children.Add($price) | Out-Null
    $g.Children.Add($edit) | Out-Null; $g.Children.Add($del) | Out-Null
    $bd.Child = $g

    # Right-click → Move to category (every category + Uncategorized).
    $cm = New-Object System.Windows.Controls.ContextMenu
    $cm.Background = SolidBrush '#1A1D29'; $cm.Foreground = [System.Windows.Media.Brushes]::White
    $miMove = New-Object System.Windows.Controls.MenuItem
    $miMove.Header = T 'menu_move_to_category'
    $unc = New-Object System.Windows.Controls.MenuItem
    $unc.Header = T 'menu_uncategorized'; $unc.Tag = @{ item = $item.id; cat = '' }
    if (-not $item.category_id) { $unc.IsEnabled = $false }
    $unc.Add_Click({ Move-ItemToCategory $this.Tag.item $this.Tag.cat }) | Out-Null
    $miMove.Items.Add($unc) | Out-Null
    $miMove.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    if ($script:menuData) {
        foreach ($c in @($script:menuData.categories)) {
            $cmi = New-Object System.Windows.Controls.MenuItem
            $cmi.Header = $c.name; $cmi.Tag = @{ item = $item.id; cat = $c.id }
            if ($c.id -eq $item.category_id) { $cmi.IsEnabled = $false; $cmi.Header = $c.name + '  (current)' }
            $cmi.Add_Click({ Move-ItemToCategory $this.Tag.item $this.Tag.cat }) | Out-Null
            $miMove.Items.Add($cmi) | Out-Null
        }
    }
    $miEdit2 = New-Object System.Windows.Controls.MenuItem
    $miEdit2.Header = T 'btn_edit'; $miEdit2.Tag = $item
    $miEdit2.Add_Click({ Show-MenuItemDialog $this.Tag }) | Out-Null
    $cm.Items.Add($miEdit2) | Out-Null
    $cm.Items.Add($miMove) | Out-Null
    $bd.ContextMenu = $cm
    return $bd
}

function Render-Menu {
    if (-not $script:menuData) { return }
    $cats  = @($script:menuData.categories)
    $items = @($script:menuData.items)
    $search = ((ctl 'MenuSearch').Text).Trim().ToLower()

    # Category sidebar — grouped by section (mirrors the web SectionsPanel).
    # Each category carries a `section` ('menu' by default). We list a header
    # per section, then the categories that belong to it.
    $catPanel = ctl 'MenuCategoryList'
    $catPanel.Children.Clear()
    $catPanel.Children.Add((New-MenuCatButton '__all__' (T 'menu_all_items') $items.Count)) | Out-Null

    # Unique section names — 'menu' always first, the rest alphabetical.
    $sections = @($cats | ForEach-Object { if ($_.section) { $_.section } else { 'menu' } } | Select-Object -Unique)
    $sections = @($sections | Sort-Object @{ Expression = { if ($_ -eq 'menu') { 0 } else { 1 } } }, @{ Expression = { $_ } })

    foreach ($sec in $sections) {
        $secCats = @($cats | Where-Object { $cs = $(if ($_.section) { $_.section } else { 'menu' }); $cs -eq $sec })
        if ($secCats.Count -eq 0) { continue }
        # Only show a section header when there's more than one section, so a
        # simple single-section menu stays clean.
        if ($sections.Count -gt 1) {
            $catPanel.Children.Add((New-SectionHeader $sec)) | Out-Null
        }
        foreach ($c in $secCats) {
            $cnt = (@($items | Where-Object { $_.category_id -eq $c.id })).Count
            $catPanel.Children.Add((New-MenuCatButton $c.id $c.name $cnt)) | Out-Null
        }
    }

    # Item list (filter by active category + search)
    $list = $items
    if ($script:menuActiveCat -ne '__all__') {
        $list = @($list | Where-Object { $_.category_id -eq $script:menuActiveCat })
    }
    if ($search) {
        $list = @($list | Where-Object { $_.name.ToLower().Contains($search) })
    }
    $itemPanel = ctl 'MenuItemList'
    $itemPanel.Children.Clear()
    if (@($list).Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = T 'menu_empty'; $empty.Foreground = SolidBrush '#6B7280'
        $empty.FontSize = 13; $empty.Margin = New-Object System.Windows.Thickness(4,30,0,0)
        $itemPanel.Children.Add($empty) | Out-Null
    } else {
        foreach ($it in $list) { $itemPanel.Children.Add((New-MenuItemRow $it)) | Out-Null }
    }
}

function Update-Menu-Page {
    try {
        $r = Invoke-RestMethod -Uri "$base/local/menu" -TimeoutSec 6 -ErrorAction Stop
        $script:menuData = $r
        $badge = ctl 'MenuSyncBadge'
        if ($r.source -eq 'cache') {
            $badge.Text = (T 'menu_offline_cache'); $badge.Foreground = SolidBrush '#F59E0B'
        } elseif ($r.synced_at) {
            $badge.Text = (T 'menu_synced') + ' ' + (Get-Date -Format 'HH:mm'); $badge.Foreground = SolidBrush '#7A8295'
        } else {
            $badge.Text = '--'; $badge.Foreground = SolidBrush '#7A8295'
        }
    } catch {
        $script:menuData = @{ categories = @(); items = @() }
        (ctl 'MenuSyncBadge').Text = (T 'menu_offline_cache')
    }
    Render-Menu
}

(ctl 'MenuRefresh').Add_Click({ Update-Menu-Page })
(ctl 'MenuSearch').Add_TextChanged({ Render-Menu })

# Add/Edit item dialog. Pass $null to add a new item, or an item object to edit.
function Show-MenuItemDialog($item) {
    $isEdit = ($null -ne $item)
    $cats = if ($script:menuData) { @($script:menuData.categories) } else { @() }

    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="560" Width="440" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="#0F1117" TextElement.Foreground="#FFFFFF">
  <Border Background="#161922" CornerRadius="12">
    <StackPanel Margin="28,24,28,24">
      <TextBlock x:Name="DTitle" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,18"/>
      <TextBlock x:Name="LName" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,6"/>
      <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
        <TextBox x:Name="FName" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,8" FontSize="13" CaretBrush="#FFFFFF"/>
      </Border>
      <TextBlock x:Name="LDesc" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,14,0,6"/>
      <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
        <TextBox x:Name="FDesc" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,8" FontSize="13" CaretBrush="#FFFFFF" TextWrapping="Wrap" AcceptsReturn="True" Height="60" VerticalScrollBarVisibility="Auto"/>
      </Border>
      <Grid Margin="0,14,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock x:Name="LPrice" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,6"/>
          <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
            <TextBox x:Name="FPrice" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,8" FontSize="13" CaretBrush="#FFFFFF"/>
          </Border>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock x:Name="LCat" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,6"/>
          <ComboBox x:Name="FCat" Height="34" FontSize="13"/>
        </StackPanel>
      </Grid>
      <CheckBox x:Name="FAvail" Foreground="#D1D5DB" FontSize="13" Margin="0,18,0,0" IsChecked="True"/>
      <CheckBox x:Name="FAddon" Foreground="#D1D5DB" FontSize="13" Margin="0,12,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0">
        <Button x:Name="DCancel" Padding="18,9" Background="#2A2D3A" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" Margin="0,0,10,0" FontSize="13">
          <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
        </Button>
        <Button x:Name="DSave" Padding="18,9" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" FontSize="13">
          <Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#14B8A6" Offset="0"/><GradientStop Color="#06B6D4" Offset="1"/></LinearGradientBrush></Button.Background>
          <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
        </Button>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $dlg.Owner = $window
    function dctl($n) { $dlg.FindName($n) }
    (dctl 'DTitle').Text  = if ($isEdit) { T 'menu_edit_item' } else { T 'menu_add_item' }
    (dctl 'LName').Text   = (T 'menu_f_name') + ' *'
    (dctl 'LDesc').Text   = T 'menu_f_desc'
    (dctl 'LPrice').Text  = (T 'menu_f_price') + ' *'
    (dctl 'LCat').Text    = T 'menu_f_category'
    (dctl 'FAvail').Content = T 'menu_f_available'
    (dctl 'FAddon').Content = T 'menu_f_addon'
    (dctl 'DCancel').Content = T 'dlg_cancel'
    (dctl 'DSave').Content   = if ($isEdit) { T 'btn_save' } else { T 'menu_add_item' }

    # Populate category dropdown — first entry = uncategorized.
    $combo = dctl 'FCat'
    $none = New-Object System.Windows.Controls.ComboBoxItem; $none.Content = (T 'menu_uncategorized'); $none.Tag = ''
    $combo.Items.Add($none) | Out-Null
    foreach ($c in $cats) {
        $ci = New-Object System.Windows.Controls.ComboBoxItem; $ci.Content = $c.name; $ci.Tag = $c.id
        $combo.Items.Add($ci) | Out-Null
    }
    if ($isEdit) {
        (dctl 'FName').Text  = [string]$item.name
        (dctl 'FDesc').Text  = [string]$item.description
        (dctl 'FPrice').Text = [string]$item.price
        (dctl 'FAvail').IsChecked = [bool]$item.available
        $sel = $null
        foreach ($ci in $combo.Items) { if ($ci.Tag -eq $item.category_id) { $sel = $ci; break } }
        $combo.SelectedItem = if ($sel) { $sel } else { $none }
    } else {
        $combo.SelectedItem = $none
        if ($script:menuActiveCat -ne '__all__') {
            foreach ($ci in $combo.Items) { if ($ci.Tag -eq $script:menuActiveCat) { $combo.SelectedItem = $ci; break } }
        }
    }

    (dctl 'DCancel').Add_Click({ $dlg.DialogResult = $false }) | Out-Null
    (dctl 'DSave').Add_Click({
        $nm = ((dctl 'FName').Text).Trim()
        $pr = ((dctl 'FPrice').Text).Trim()
        if (-not $nm -or -not $pr) {
            [System.Windows.MessageBox]::Show((T 'menu_name_price_req'), 'LightMenu', 'OK', 'Warning') | Out-Null
            return
        }
        $catTag = if ($combo.SelectedItem) { $combo.SelectedItem.Tag } else { '' }
        $payload = @{
            name             = $nm
            description      = (dctl 'FDesc').Text
            price            = ([double]($pr -replace ',', '.'))
            menu_category_id = $catTag
            is_available     = [bool](dctl 'FAvail').IsChecked
            is_addon         = [bool](dctl 'FAddon').IsChecked
        }
        try {
            if ($isEdit) {
                Invoke-RestMethod -Uri "$base/local/menu/item/$($item.id)" -Method Patch -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
            } else {
                Invoke-RestMethod -Uri "$base/local/menu/item" -Method Post -Body ($payload | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
            }
            $dlg.DialogResult = $true
        } catch {
            [System.Windows.MessageBox]::Show((T 'menu_save_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
        }
    }) | Out-Null

    if ($dlg.ShowDialog()) { Update-Menu-Page }
}

# Add/Rename category dialog. Pass $null to add, or @{id;name} to rename.
function Show-CategoryDialog($cat) {
    $isEdit = ($null -ne $cat)
    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="320" Width="400" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="#0F1117" TextElement.Foreground="#FFFFFF">
  <Border Background="#161922" CornerRadius="12">
    <StackPanel Margin="28,24,28,24">
      <TextBlock x:Name="DTitle" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,18"/>
      <TextBlock x:Name="LName" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,6"/>
      <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
        <TextBox x:Name="FName" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,8" FontSize="13" CaretBrush="#FFFFFF"/>
      </Border>
      <TextBlock x:Name="LSection" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,16,0,6"/>
      <ComboBox x:Name="FSection" Height="34" FontSize="13" IsEditable="True"/>
      <TextBlock x:Name="HSection" Foreground="#6B7280" FontSize="10" TextWrapping="Wrap" Margin="0,6,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
        <Button x:Name="DCancel" Padding="18,9" Background="#2A2D3A" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" Margin="0,0,10,0" FontSize="13">
          <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
        </Button>
        <Button x:Name="DSave" Padding="18,9" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" FontSize="13">
          <Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#14B8A6" Offset="0"/><GradientStop Color="#06B6D4" Offset="1"/></LinearGradientBrush></Button.Background>
          <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
        </Button>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $dlg.Owner = $window
    function dctl2($n) { $dlg.FindName($n) }
    (dctl2 'DTitle').Text = if ($isEdit) { T 'menu_rename_category' } else { T 'menu_add_category' }
    (dctl2 'LName').Text  = (T 'menu_f_name') + ' *'
    (dctl2 'LSection').Text = T 'menu_f_section'
    (dctl2 'HSection').Text = T 'menu_section_hint'
    (dctl2 'DCancel').Content = T 'dlg_cancel'
    (dctl2 'DSave').Content   = T 'btn_save'

    # Populate the section dropdown with the sections already in use, so the
    # owner can drop the category into an existing group or type a new one.
    $secBox = dctl2 'FSection'
    $existing = @()
    if ($script:menuData) {
        $existing = @($script:menuData.categories | ForEach-Object { if ($_.section) { $_.section } else { 'menu' } } | Select-Object -Unique)
    }
    if ($existing -notcontains 'menu') { $secBox.Items.Add('menu') | Out-Null }
    foreach ($s in $existing) { $secBox.Items.Add($s) | Out-Null }

    if ($isEdit) {
        (dctl2 'FName').Text = [string]$cat.name
        # The context-menu tag only carries id+name; look up the live section.
        $cur = $null
        if ($script:menuData) { $cur = @($script:menuData.categories | Where-Object { $_.id -eq $cat.id })[0] }
        $secBox.Text = if ($cur -and $cur.section) { $cur.section } else { 'menu' }
    } else {
        $secBox.Text = 'menu'
    }

    (dctl2 'DCancel').Add_Click({ $dlg.DialogResult = $false }) | Out-Null
    (dctl2 'DSave').Add_Click({
        $nm = ((dctl2 'FName').Text).Trim()
        if (-not $nm) { [System.Windows.MessageBox]::Show((T 'menu_name_req'), 'LightMenu', 'OK', 'Warning') | Out-Null; return }
        $sec = ((dctl2 'FSection').Text).Trim().ToLower()
        if (-not $sec) { $sec = 'menu' }
        try {
            if ($isEdit) {
                Invoke-RestMethod -Uri "$base/local/menu/category/$($cat.id)" -Method Patch -Body (@{ name = $nm; section = $sec } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
            } else {
                Invoke-RestMethod -Uri "$base/local/menu/category" -Method Post -Body (@{ name = $nm; section = $sec } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
            }
            $dlg.DialogResult = $true
        } catch {
            [System.Windows.MessageBox]::Show((T 'menu_save_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
        }
    }) | Out-Null

    if ($dlg.ShowDialog()) { Update-Menu-Page }
}

(ctl 'AddItemBtn').Add_Click({ Show-MenuItemDialog $null })
(ctl 'AddCategoryBtn').Add_Click({ Show-CategoryDialog $null })

# ─── KITCHEN & PRINTING PAGE ────────────────────────────────────────────────
function New-PrinterCard($p) {
    $card = New-Object System.Windows.Controls.Border
    $card.Background = SolidBrush '#1A1D29'
    $card.BorderBrush = SolidBrush '#2A2D3A'
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $card.Padding = New-Object System.Windows.Thickness(14)
    $card.Margin = New-Object System.Windows.Thickness(0,0,0,10)

    $g = New-Object System.Windows.Controls.Grid
    $cL = New-Object System.Windows.Controls.ColumnDefinition; $cL.Width = '*'
    $cR = New-Object System.Windows.Controls.ColumnDefinition; $cR.Width = 'Auto'
    $g.ColumnDefinitions.Add($cL); $g.ColumnDefinitions.Add($cR)

    $info = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.Grid]::SetColumn($info, 0)
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $p.name; $title.FontSize = 14; $title.FontWeight = 'SemiBold'; $title.Foreground = SolidBrush '#FFFFFF'
    $sub = New-Object System.Windows.Controls.TextBlock
    $ipTxt = if ($p.ip) { $p.ip + ':' + $p.port } else { (T 'printer_no_ip') }
    $sub.Text = (T 'printer_type') + ': ' + $p.type + '   ' + $ipTxt
    $sub.FontSize = 11; $sub.Foreground = SolidBrush '#9CA3AF'; $sub.Margin = New-Object System.Windows.Thickness(0,4,0,0)
    $info.Children.Add($title) | Out-Null; $info.Children.Add($sub) | Out-Null

    $actions = New-Object System.Windows.Controls.StackPanel
    $actions.Orientation = 'Horizontal'; $actions.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($actions, 1)

    $editP = New-Object System.Windows.Controls.Button
    $editP.Content = T 'btn_edit'; $editP.Style = (ctl 'MenuRefresh').Style
    $editP.Tag = $p
    $editP.Add_Click({ Show-PrinterDialog $this.Tag }) | Out-Null

    $test = New-Object System.Windows.Controls.Button
    $test.Content = T 'btn_test_print'; $test.Style = (ctl 'MenuRefresh').Style
    $test.Margin = New-Object System.Windows.Thickness(8,0,0,0)
    $test.Tag = $p
    $test.Add_Click({
        $pp = $this.Tag
        try {
            $body = @{ name = $pp.name; ip = $pp.ip; port = $pp.port } | ConvertTo-Json
            Invoke-RestMethod -Uri "$base/local/printers/test" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 8 -ErrorAction Stop | Out-Null
            [System.Windows.MessageBox]::Show((T 'test_print_sent'), 'LightMenu', 'OK', 'Information') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show((T 'test_print_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
        }
    })

    $del = New-Object System.Windows.Controls.Button
    $del.Content = T 'btn_remove'; $del.Style = (ctl 'MenuRefresh').Style
    $del.Margin = New-Object System.Windows.Thickness(8,0,0,0)
    $del.Tag = $p
    $del.Add_Click({
        $pp = $this.Tag
        $ok = [System.Windows.MessageBox]::Show((T 'confirm_remove_printer'), 'LightMenu', 'YesNo', 'Question')
        if ($ok -ne 'Yes') { return }
        try {
            Invoke-RestMethod -Uri "$base/local/printers/$($pp.id)" -Method Delete -TimeoutSec 8 -ErrorAction Stop | Out-Null
            Update-Kitchen-Page
        } catch {
            [System.Windows.MessageBox]::Show((T 'printer_remove_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
        }
    })

    $actions.Children.Add($editP) | Out-Null; $actions.Children.Add($test) | Out-Null; $actions.Children.Add($del) | Out-Null
    $g.Children.Add($info) | Out-Null; $g.Children.Add($actions) | Out-Null
    $card.Child = $g
    return $card
}

# Edit an existing printer (name / IP / type).
function Show-PrinterDialog($p) {
    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="340" Width="400" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="#0F1117" TextElement.Foreground="#FFFFFF">
  <Border Background="#161922" CornerRadius="12">
    <StackPanel Margin="28,24,28,24">
      <TextBlock x:Name="DTitle" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,18"/>
      <TextBlock x:Name="LName" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,6"/>
      <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
        <TextBox x:Name="FName" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,8" FontSize="13" CaretBrush="#FFFFFF"/>
      </Border>
      <Grid Margin="0,14,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock x:Name="LIp" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,6"/>
          <Border Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="6">
            <TextBox x:Name="FIp" Background="Transparent" BorderThickness="0" Foreground="#FFFFFF" Padding="10,8" FontSize="13" CaretBrush="#FFFFFF"/>
          </Border>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock x:Name="LType" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,6"/>
          <ComboBox x:Name="FType" Width="110" Height="34" FontSize="13">
            <ComboBoxItem Content="kitchen"/><ComboBoxItem Content="bar"/><ComboBoxItem Content="check"/>
          </ComboBox>
        </StackPanel>
      </Grid>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0">
        <Button x:Name="DCancel" Padding="18,9" Background="#2A2D3A" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" Margin="0,0,10,0" FontSize="13">
          <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
        </Button>
        <Button x:Name="DSave" Padding="18,9" Foreground="#FFFFFF" BorderThickness="0" Cursor="Hand" FontSize="13">
          <Button.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#14B8A6" Offset="0"/><GradientStop Color="#06B6D4" Offset="1"/></LinearGradientBrush></Button.Background>
          <Button.Template><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
        </Button>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $dlg.Owner = $window
    function dctl3($n) { $dlg.FindName($n) }
    (dctl3 'DTitle').Text = T 'printer_edit'
    (dctl3 'LName').Text  = T 'menu_f_name'
    (dctl3 'LIp').Text    = 'IP'
    (dctl3 'LType').Text  = T 'printer_type'
    (dctl3 'DCancel').Content = T 'dlg_cancel'
    (dctl3 'DSave').Content   = T 'btn_save'
    (dctl3 'FName').Text = [string]$p.name
    (dctl3 'FIp').Text   = [string]$p.ip
    $ftype = dctl3 'FType'
    foreach ($ti in $ftype.Items) { if ($ti.Content -eq $p.type) { $ftype.SelectedItem = $ti; break } }
    if (-not $ftype.SelectedItem) { $ftype.SelectedIndex = 0 }

    (dctl3 'DCancel').Add_Click({ $dlg.DialogResult = $false }) | Out-Null
    (dctl3 'DSave').Add_Click({
        $nm = ((dctl3 'FName').Text).Trim()
        $ip = ((dctl3 'FIp').Text).Trim()
        if ($ip -and $ip -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            [System.Windows.MessageBox]::Show((T 'invalid_ip'), 'LightMenu', 'OK', 'Warning') | Out-Null
            return
        }
        $tp = if ($ftype.SelectedItem) { $ftype.SelectedItem.Content } else { 'kitchen' }
        try {
            $body = @{ name = $nm; ip = $ip; type = $tp } | ConvertTo-Json
            Invoke-RestMethod -Uri "$base/local/printers/$($p.id)" -Method Patch -Body $body -ContentType 'application/json' -TimeoutSec 8 -ErrorAction Stop | Out-Null
            $dlg.DialogResult = $true
        } catch {
            [System.Windows.MessageBox]::Show((T 'printer_save_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
        }
    }) | Out-Null

    if ($dlg.ShowDialog()) { Update-Kitchen-Page }
}

# ─── ORDERS: Station POS ─────────────────────────────────────────────────────
$script:orderTable     = $null   # current table number
$script:orderId        = $null   # current order ID (from Supabase)
$script:orderCart      = @()     # new items not yet sent
$script:orderSent      = @()     # items already sent (from server)
$script:orderCourse    = 'direct'
$script:orderMenuData  = $null
$script:orderBusy      = $false

$script:catColors = @('#3B82F6','#10B981','#F59E0B','#EF4444','#8B5CF6','#EC4899','#14B8A6','#F97316')

function Select-Course($c) {
    $script:orderCourse = $c
    $map = @{ 'direct' = 'CourseD'; 'first_plate' = 'CourseS1'; 'second_plate' = 'CourseS2'; 'third_plate' = 'CourseS3'; 'fourth_plate' = 'CourseS4' }
    foreach ($k in $map.Keys) {
        $btn = ctl $map[$k]
        if ($k -eq $c) { $btn.Background = SolidBrush '#3B82F6' }
        else           { $btn.Background = SolidBrush '#374151' }
    }
}

(ctl 'CourseD').Add_Click({  Select-Course 'direct' })
(ctl 'CourseS1').Add_Click({ Select-Course 'first_plate' })
(ctl 'CourseS2').Add_Click({ Select-Course 'second_plate' })
(ctl 'CourseS3').Add_Click({ Select-Course 'third_plate' })
(ctl 'CourseS4').Add_Click({ Select-Course 'fourth_plate' })

function Render-OrderCart {
    $panel = ctl 'OrderCartItems'
    $panel.Children.Clear()

    $courseLabels = @{ 'direct' = 'Direct'; 'first_plate' = 'S1'; 'second_plate' = 'S2'; 'third_plate' = 'S3'; 'fourth_plate' = 'S4' }

    # Sent items (gray)
    foreach ($item in $script:orderSent) {
        $status = $item.status
        $bg = if ($status -eq 'pending') { '#92400E' } else { '#374151' }
        $lbl = $courseLabels[$item.course]; if (-not $lbl) { $lbl = $item.course }
        $statusTag = if ($status -eq 'pending') { " [$lbl - HELD]" } else { " [$lbl]" }

        $row = New-Object System.Windows.Controls.Border
        $row.Background = SolidBrush $bg
        $row.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $row.Padding = [System.Windows.Thickness]::new(12,8,12,8)
        $row.Margin  = [System.Windows.Thickness]::new(0,0,0,4)

        $g = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
        $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)

        $nameTb = New-Object System.Windows.Controls.TextBlock
        $nameTb.Text = "$($item.quantity)x $($item.menu_item_name)$statusTag"
        $nameTb.Foreground = [System.Windows.Media.Brushes]::White
        $nameTb.FontSize = 13
        $nameTb.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($nameTb, 0)
        $g.Children.Add($nameTb) | Out-Null

        $priceTb = New-Object System.Windows.Controls.TextBlock
        $price = [math]::Round(($item.price_at_order_time * $item.quantity), 2)
        $priceTb.Text = [string]::Format('{0:N2}', $price) + ' EUR'
        $priceTb.Foreground = SolidBrush '#9CA3AF'
        $priceTb.FontSize = 13
        $priceTb.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($priceTb, 1)
        $g.Children.Add($priceTb) | Out-Null

        $row.Child = $g
        $panel.Children.Add($row) | Out-Null
    }

    # New cart items (green)
    for ($i = 0; $i -lt $script:orderCart.Count; $i++) {
        $item = $script:orderCart[$i]
        $idx = $i
        $lbl = $courseLabels[$item.course]; if (-not $lbl) { $lbl = $item.course }

        $row = New-Object System.Windows.Controls.Border
        $row.Background = SolidBrush '#065F46'
        $row.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $row.Padding = [System.Windows.Thickness]::new(12,8,12,8)
        $row.Margin  = [System.Windows.Thickness]::new(0,0,0,4)

        $g = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
        $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = [System.Windows.GridLength]::Auto
        $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2); $g.ColumnDefinitions.Add($c3)

        $nameTb = New-Object System.Windows.Controls.TextBlock
        $nameTb.Text = "$($item.quantity)x $($item.menu_item_name) [$lbl]"
        $nameTb.Foreground = [System.Windows.Media.Brushes]::White
        $nameTb.FontSize = 13
        $nameTb.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($nameTb, 0)
        $g.Children.Add($nameTb) | Out-Null

        $priceTb = New-Object System.Windows.Controls.TextBlock
        $price = [math]::Round(($item.price * $item.quantity), 2)
        $priceTb.Text = [string]::Format('{0:N2}', $price) + ' EUR'
        $priceTb.Foreground = SolidBrush '#A7F3D0'
        $priceTb.FontSize = 13
        $priceTb.VerticalAlignment = 'Center'
        $priceTb.Margin = [System.Windows.Thickness]::new(8,0,0,0)
        [System.Windows.Controls.Grid]::SetColumn($priceTb, 1)
        $g.Children.Add($priceTb) | Out-Null

        # +/- buttons
        $btnPanel = New-Object System.Windows.Controls.StackPanel
        $btnPanel.Orientation = 'Horizontal'
        $btnPanel.Margin = [System.Windows.Thickness]::new(8,0,0,0)
        [System.Windows.Controls.Grid]::SetColumn($btnPanel, 2)

        $minus = New-Object System.Windows.Controls.Button
        $minus.Content = '-'; $minus.Width = 28; $minus.Height = 28
        $minus.Background = SolidBrush '#374151'; $minus.Foreground = [System.Windows.Media.Brushes]::White
        $minus.BorderThickness = [System.Windows.Thickness]::new(0); $minus.Cursor = [System.Windows.Input.Cursors]::Hand
        $minus.Tag = $idx
        $minus.Add_Click({
            param($s,$e)
            $ci = [int]$s.Tag
            if ($ci -lt $script:orderCart.Count) {
                if ($script:orderCart[$ci].quantity -gt 1) { $script:orderCart[$ci].quantity-- }
                else { $script:orderCart = @($script:orderCart | Where-Object { $_ -ne $script:orderCart[$ci] }) }
                Render-OrderCart
            }
        }.GetNewClosure())
        $btnPanel.Children.Add($minus) | Out-Null

        $plus = New-Object System.Windows.Controls.Button
        $plus.Content = '+'; $plus.Width = 28; $plus.Height = 28
        $plus.Background = SolidBrush '#374151'; $plus.Foreground = [System.Windows.Media.Brushes]::White
        $plus.BorderThickness = [System.Windows.Thickness]::new(0); $plus.Cursor = [System.Windows.Input.Cursors]::Hand
        $plus.Margin = [System.Windows.Thickness]::new(4,0,0,0)
        $plus.Tag = $idx
        $plus.Add_Click({
            param($s,$e)
            $ci = [int]$s.Tag
            if ($ci -lt $script:orderCart.Count) { $script:orderCart[$ci].quantity++; Render-OrderCart }
        }.GetNewClosure())
        $btnPanel.Children.Add($plus) | Out-Null

        $g.Children.Add($btnPanel) | Out-Null
        $row.Child = $g
        $panel.Children.Add($row) | Out-Null
    }

    if ($script:orderSent.Count -eq 0 -and $script:orderCart.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = 'Select items to add to order...'
        $empty.Foreground = SolidBrush '#7A8295'
        $empty.FontSize = 14
        $empty.HorizontalAlignment = 'Center'
        $empty.Margin = [System.Windows.Thickness]::new(0,40,0,0)
        $panel.Children.Add($empty) | Out-Null
    }
}

function Render-OrderCategories {
    $grid = ctl 'OrderCategoryGrid'
    $grid.Children.Clear()
    $cats = if ($script:orderMenuData) { @($script:orderMenuData.categories) } else { @() }
    $items = if ($script:orderMenuData) { @($script:orderMenuData.items) } else { @() }

    for ($ci = 0; $ci -lt $cats.Count; $ci++) {
        $cat = $cats[$ci]
        $color = $script:catColors[$ci % $script:catColors.Count]
        $catItems = @($items | Where-Object { $_.category_id -eq $cat.id -and $_.available })

        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $cat.name.ToUpper()
        $btn.MinWidth = 110; $btn.Height = 36
        $btn.FontSize = 11; $btn.FontWeight = 'Bold'
        $btn.Foreground = [System.Windows.Media.Brushes]::White
        $btn.Background = SolidBrush $color
        $btn.BorderThickness = [System.Windows.Thickness]::new(0)
        $btn.Cursor = [System.Windows.Input.Cursors]::Hand
        $btn.Margin = [System.Windows.Thickness]::new(0,0,4,4)
        $btn.Tag = @{ cat = $cat; items = $catItems; color = $color }

        $tpl = New-Object System.Windows.Controls.ControlTemplate ([System.Windows.Controls.Button])
        $bdr = New-Object System.Windows.FrameworkElementFactory ([System.Windows.Controls.Border])
        $bdr.SetBinding([System.Windows.Controls.Border]::BackgroundProperty, (New-Object System.Windows.Data.Binding 'Background') )
        $bdr.SetValue([System.Windows.Controls.Border]::CornerRadiusProperty, [System.Windows.CornerRadius]::new(8))
        $bdr.SetValue([System.Windows.Controls.Border]::PaddingProperty, [System.Windows.Thickness]::new(10,0,10,0))
        $cp = New-Object System.Windows.FrameworkElementFactory ([System.Windows.Controls.ContentPresenter])
        $cp.SetValue([System.Windows.Controls.ContentPresenter]::HorizontalAlignmentProperty, [System.Windows.HorizontalAlignment]::Center)
        $cp.SetValue([System.Windows.Controls.ContentPresenter]::VerticalAlignmentProperty, [System.Windows.VerticalAlignment]::Center)
        $bdr.AppendChild($cp)
        $tpl.VisualTree = $bdr
        $btn.Template = $tpl

        $btn.Add_Click({
            param($s,$e)
            $info = $s.Tag
            Show-OrderItems $info.cat $info.items $info.color
        }.GetNewClosure())
        $grid.Children.Add($btn) | Out-Null
    }
}

function Show-OrderItems($cat, $items, $color) {
    $panel = ctl 'OrderItemsList'
    $panel.Children.Clear()
    (ctl 'OrderItemsHint').Visibility = 'Collapsed'

    if ($items.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = 'No items in this category'
        $empty.Foreground = SolidBrush '#6B7280'; $empty.FontSize = 13
        $empty.HorizontalAlignment = 'Center'; $empty.Margin = [System.Windows.Thickness]::new(0,20,0,0)
        $panel.Children.Add($empty) | Out-Null
        return
    }

    foreach ($item in $items) {
        $row = New-Object System.Windows.Controls.Button
        $row.Height = 42
        $row.Background = SolidBrush '#1A1D29'
        $row.Foreground = [System.Windows.Media.Brushes]::White
        $row.BorderThickness = [System.Windows.Thickness]::new(0)
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $row.Margin = [System.Windows.Thickness]::new(0,0,0,3)
        $row.HorizontalContentAlignment = 'Stretch'
        $row.Tag = $item

        $tpl = New-Object System.Windows.Controls.ControlTemplate ([System.Windows.Controls.Button])
        $bdr = New-Object System.Windows.FrameworkElementFactory ([System.Windows.Controls.Border])
        $bdr.SetBinding([System.Windows.Controls.Border]::BackgroundProperty, (New-Object System.Windows.Data.Binding 'Background') )
        $bdr.SetValue([System.Windows.Controls.Border]::CornerRadiusProperty, [System.Windows.CornerRadius]::new(6))
        $bdr.SetValue([System.Windows.Controls.Border]::PaddingProperty, [System.Windows.Thickness]::new(10,0,10,0))
        $cp = New-Object System.Windows.FrameworkElementFactory ([System.Windows.Controls.ContentPresenter])
        $cp.SetValue([System.Windows.Controls.ContentPresenter]::HorizontalAlignmentProperty, [System.Windows.HorizontalAlignment]::Stretch)
        $cp.SetValue([System.Windows.Controls.ContentPresenter]::VerticalAlignmentProperty, [System.Windows.VerticalAlignment]::Center)
        $bdr.AppendChild($cp)
        $tpl.VisualTree = $bdr
        $row.Template = $tpl

        $g = New-Object System.Windows.Controls.Grid
        $gc1 = New-Object System.Windows.Controls.ColumnDefinition; $gc1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $gc2 = New-Object System.Windows.Controls.ColumnDefinition; $gc2.Width = [System.Windows.GridLength]::Auto
        $g.ColumnDefinitions.Add($gc1); $g.ColumnDefinitions.Add($gc2)

        $nt = New-Object System.Windows.Controls.TextBlock
        $nt.Text = $item.name; $nt.FontSize = 13; $nt.Foreground = [System.Windows.Media.Brushes]::White; $nt.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($nt, 0)
        $g.Children.Add($nt) | Out-Null

        $pt = New-Object System.Windows.Controls.TextBlock
        $pt.Text = [string]::Format('{0:N2} EUR', $item.price); $pt.FontSize = 13; $pt.Foreground = SolidBrush '#10B981'; $pt.FontWeight = 'SemiBold'; $pt.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($pt, 1)
        $g.Children.Add($pt) | Out-Null

        $row.Content = $g
        $row.Add_Click({
            param($s,$e)
            $it = $s.Tag
            $existing = $script:orderCart | Where-Object { $_.menu_item_id -eq $it.id -and $_.course -eq $script:orderCourse }
            if ($existing) {
                $existing.quantity++
            } else {
                $script:orderCart += @([pscustomobject]@{
                    menu_item_id   = $it.id
                    menu_item_name = $it.name
                    price          = $it.price
                    quantity       = 1
                    course         = $script:orderCourse
                })
            }
            Render-OrderCart
        }.GetNewClosure())
        $panel.Children.Add($row) | Out-Null
    }
}

function Enter-OrderTable($tableNum) {
    $script:orderTable = $tableNum
    $script:orderCart = @()
    $script:orderSent = @()
    $script:orderId = $null
    Select-Course 'direct'

    (ctl 'OrderTableSelector').Visibility = 'Collapsed'
    (ctl 'OrderActiveView').Visibility = 'Visible'
    (ctl 'OrderTableLabel').Text = "Table $tableNum"

    Invoke-AsyncGet "$base/local/order/items?table=$tableNum" {
        param($r, $bad)
        if (-not $bad -and $r) {
            $script:orderId = $r.order_id
            $script:orderSent = @($r.items)
        }
        Render-OrderCart
    }
}

function Leave-OrderTable {
    $script:orderTable = $null
    $script:orderId = $null
    $script:orderCart = @()
    $script:orderSent = @()
    (ctl 'OrderActiveView').Visibility = 'Collapsed'
    (ctl 'OrderTableSelector').Visibility = 'Visible'
    Update-Orders-Page
}

function Update-Orders-Page {
    # Load tables for selector
    Invoke-AsyncGet "$base/local/tables" {
        param($r, $bad)
        if ($bad -or -not $r) { return }
        $grid = ctl 'OrderTableGrid'
        $grid.Children.Clear()
        foreach ($t in $r) {
            $num = $t.table_number
            $bg = '#22C55E'
            if ($t.check_printed_at) { $bg = '#A855F7' }
            elseif ($t.has_held_items) { $bg = '#F59E0B' }
            elseif ($t.occupied) { $bg = '#38BDF8' }

            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = "T $num"
            $btn.Width = 70; $btn.Height = 70
            $btn.FontSize = 16; $btn.FontWeight = 'Bold'
            $btn.Foreground = [System.Windows.Media.Brushes]::White
            $btn.Background = SolidBrush $bg
            $btn.BorderThickness = [System.Windows.Thickness]::new(0)
            $btn.Cursor = [System.Windows.Input.Cursors]::Hand
            $btn.Margin = [System.Windows.Thickness]::new(4)
            $btn.Tag = $num

            $tpl = New-Object System.Windows.Controls.ControlTemplate ([System.Windows.Controls.Button])
            $bdr = New-Object System.Windows.FrameworkElementFactory ([System.Windows.Controls.Border])
            $bdr.SetBinding([System.Windows.Controls.Border]::BackgroundProperty, (New-Object System.Windows.Data.Binding 'Background') )
            $bdr.SetValue([System.Windows.Controls.Border]::CornerRadiusProperty, [System.Windows.CornerRadius]::new(10))
            $cp = New-Object System.Windows.FrameworkElementFactory ([System.Windows.Controls.ContentPresenter])
            $cp.SetValue([System.Windows.Controls.ContentPresenter]::HorizontalAlignmentProperty, [System.Windows.HorizontalAlignment]::Center)
            $cp.SetValue([System.Windows.Controls.ContentPresenter]::VerticalAlignmentProperty, [System.Windows.VerticalAlignment]::Center)
            $bdr.AppendChild($cp)
            $tpl.VisualTree = $bdr
            $btn.Template = $tpl

            $btn.Add_Click({
                param($s,$e)
                Enter-OrderTable $s.Tag
            }.GetNewClosure())
            $grid.Children.Add($btn) | Out-Null
        }
    }

    # Load menu for categories
    Invoke-AsyncGet "$base/local/menu" {
        param($r, $bad)
        if (-not $bad -and $r) {
            $script:orderMenuData = $r
            Render-OrderCategories
        }
    }
}

# SEND button
(ctl 'OrderSend').Add_Click({
    if ($script:orderBusy) { return }
    if (-not $script:orderTable) { return }
    if ($script:orderCart.Count -eq 0) { return }
    $script:orderBusy = $true
    (ctl 'OrderSend').Background = SolidBrush '#6B7280'

    $payload = @{
        table_number = $script:orderTable
        order_id     = $script:orderId
        items        = @($script:orderCart | ForEach-Object {
            @{
                menu_item_id   = $_.menu_item_id
                menu_item_name = $_.menu_item_name
                price          = $_.price
                quantity       = $_.quantity
                course         = $_.course
            }
        })
    } | ConvertTo-Json -Depth 5

    Invoke-AsyncPost "$base/local/order/send" $payload 'POST' {
        param($r, $bad, $emsg)
        $script:orderBusy = $false
        (ctl 'OrderSend').Background = SolidBrush '#3B82F6'
        if (-not $bad -and $r -and $r.ok) {
            $script:orderId = $r.order_id
            $script:orderCart = @()
            # Reload sent items
            Invoke-AsyncGet "$base/local/order/items?table=$($script:orderTable)" {
                param($r2, $bad2)
                if (-not $bad2 -and $r2) {
                    $script:orderSent = @($r2.items)
                }
                Render-OrderCart
            }
        } else {
            Render-OrderCart
        }
    }
})

# RECLAIM button
(ctl 'OrderReclaim').Add_Click({
    if ($script:orderBusy) { return }
    if (-not $script:orderTable) { return }
    $script:orderBusy = $true
    (ctl 'OrderReclaim').Background = SolidBrush '#6B7280'

    $payload = @{ table_number = $script:orderTable } | ConvertTo-Json

    Invoke-AsyncPost "$base/local/order/reclaim" $payload 'POST' {
        param($r, $bad, $emsg)
        $script:orderBusy = $false
        (ctl 'OrderReclaim').Background = SolidBrush '#374151'
        if (-not $bad -and $r -and $r.ok) {
            # Reload sent items
            Invoke-AsyncGet "$base/local/order/items?table=$($script:orderTable)" {
                param($r2, $bad2)
                if (-not $bad2 -and $r2) {
                    $script:orderSent = @($r2.items)
                }
                Render-OrderCart
            }
        }
    }
})

# STOP button
(ctl 'OrderStop').Add_Click({
    if (-not $script:orderTable) { return }
    Leave-OrderTable
})

function Update-Kitchen-Page {
    # Live transport status from /status
    try {
        $st = Invoke-RestMethod -Uri "$statusUrl" -TimeoutSec 2 -ErrorAction Stop
        $liveTxt = '-'
        if ($st.printer) {
            switch ($st.printer.mode) {
                'usb-direct'  { $liveTxt = 'USB direct: ' + $st.printer.usb }
                'usb-spooler' { $liveTxt = 'USB spooler: ' + $st.printer.usb }
                'network'     { $liveTxt = 'Network: ' + $st.printer.ip + ':' + $st.printer.port }
                default       { $liveTxt = T 'printer_searching' }
            }
        }
        (ctl 'KitchenLiveText').Text = $liveTxt
    } catch {
        (ctl 'KitchenLiveText').Text = T 'printer_searching'
    }

    $panel = ctl 'PrinterCards'
    $panel.Children.Clear()
    try {
        $r = Invoke-RestMethod -Uri "$base/local/printers" -TimeoutSec 3 -ErrorAction Stop
        $list = @($r.printers)
        if ($list.Count -eq 0) {
            $empty = New-Object System.Windows.Controls.TextBlock
            $empty.Text = T 'no_printers'; $empty.Foreground = SolidBrush '#6B7280'
            $empty.FontSize = 13; $empty.Margin = New-Object System.Windows.Thickness(0,30,0,0)
            $panel.Children.Add($empty) | Out-Null
        } else {
            foreach ($p in $list) { $panel.Children.Add((New-PrinterCard $p)) | Out-Null }
        }
    } catch {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = T 'printers_offline'; $empty.Foreground = SolidBrush '#F59E0B'
        $empty.FontSize = 13; $empty.Margin = New-Object System.Windows.Thickness(0,30,0,0)
        $panel.Children.Add($empty) | Out-Null
    }
    Load-TicketSettings
}

# ── Ticket settings helpers ──────────────────────────────────────────────────
function Set-ComboByContent($combo, $value) {
    foreach ($it in $combo.Items) { if ([string]$it.Content -eq [string]$value) { $combo.SelectedItem = $it; return } }
    if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
}
function Get-ComboContent($combo) {
    if ($combo.SelectedItem) { return [string]$combo.SelectedItem.Content }
    return ''
}

# ── Language grid ────────────────────────────────────────────────────────────
$script:tsLang = 'en'
$script:tsLangMeta = @(
    @{ code='en'; flag='US'; name='English' }, @{ code='fr'; flag='FR'; name='Français' },
    @{ code='es'; flag='ES'; name='Español' }, @{ code='it'; flag='IT'; name='Italiano' },
    @{ code='de'; flag='DE'; name='Deutsch' }, @{ code='nl'; flag='NL'; name='Nederlands' },
    @{ code='ru'; flag='RU'; name='Русский' }, @{ code='ar'; flag='SA'; name='العربية' },
    @{ code='zh'; flag='CN'; name='中文' },    @{ code='pt'; flag='PT'; name='Português' }
)
$script:tsLangBtns = @{}
function Build-LangGrid {
    $grid = ctl 'TsLangGrid'; $grid.Children.Clear(); $script:tsLangBtns = @{}
    foreach ($m in $script:tsLangMeta) {
        $b = New-Object System.Windows.Controls.Border
        $b.Tag = $m.code; $b.Cursor = 'Hand'; $b.Width = 132; $b.Height = 38
        $b.CornerRadius = New-Object System.Windows.CornerRadius(7)
        $b.BorderThickness = New-Object System.Windows.Thickness(1)
        $b.Margin = New-Object System.Windows.Thickness(0,0,8,8)
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'; $sp.VerticalAlignment = 'Center'
        $sp.Margin = New-Object System.Windows.Thickness(10,0,0,0)
        $fl = New-Object System.Windows.Controls.TextBlock
        $fl.Text = $m.flag; $fl.FontSize = 10; $fl.FontWeight = 'Bold'; $fl.Foreground = SolidBrush '#7A8295'
        $fl.VerticalAlignment = 'Center'; $fl.Margin = New-Object System.Windows.Thickness(0,0,8,0)
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $m.name; $nm.FontSize = 12; $nm.Foreground = SolidBrush '#FFFFFF'; $nm.VerticalAlignment = 'Center'
        $sp.Children.Add($fl) | Out-Null; $sp.Children.Add($nm) | Out-Null
        $b.Child = $sp
        $b.Add_MouseLeftButtonUp({ $script:tsLang = $this.Tag; Refresh-LangGrid; Update-TsPreview }) | Out-Null
        $grid.Children.Add($b) | Out-Null
        $script:tsLangBtns[$m.code] = $b
    }
    Refresh-LangGrid
}
function Refresh-LangGrid {
    foreach ($code in $script:tsLangBtns.Keys) {
        $b = $script:tsLangBtns[$code]
        if ($code -eq $script:tsLang) { $b.Background = SolidBrush '#0F2A26'; $b.BorderBrush = SolidBrush '#14B8A6' }
        else { $b.Background = SolidBrush '#0F1117'; $b.BorderBrush = SolidBrush '#2A2D3A' }
    }
}

# ── Custom labels ────────────────────────────────────────────────────────────
# Editable subset of the printed-label keys. Blank = use the language default.
$script:tsLabelKeys = @(
    @{ key='table'; name='Table' },        @{ key='waiter'; name='Waiter' },
    @{ key='covers'; name='Covers' },       @{ key='total'; name='Total' },
    @{ key='thank_you'; name='Thank-you' }, @{ key='tel'; name='Tel' },
    @{ key='cash'; name='Cash' },           @{ key='card'; name='Card' },
    @{ key='mixed'; name='Cash + Card' },   @{ key='invitation'; name='Invitation' },
    @{ key='gratis'; name='Gratis' },       @{ key='drinks'; name='Drinks title' },
    @{ key='food'; name='Food title' }
)
$script:tsLabelBoxes = @{}
function Build-LabelGrid {
    $grid = ctl 'TsLabelGrid'; $grid.Children.Clear(); $script:tsLabelBoxes = @{}
    foreach ($lk in $script:tsLabelKeys) {
        $col = New-Object System.Windows.Controls.StackPanel
        $col.Width = 150; $col.Margin = New-Object System.Windows.Thickness(0,0,12,10)
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $lk.name; $lbl.Foreground = SolidBrush '#9CA3AF'; $lbl.FontSize = 10; $lbl.Margin = New-Object System.Windows.Thickness(0,0,0,3)
        $bd = New-Object System.Windows.Controls.Border
        $bd.Background = SolidBrush '#161922'; $bd.BorderBrush = SolidBrush '#2A2D3A'
        $bd.BorderThickness = New-Object System.Windows.Thickness(1); $bd.CornerRadius = New-Object System.Windows.CornerRadius(5)
        $tx = New-Object System.Windows.Controls.TextBox
        $tx.Background = [System.Windows.Media.Brushes]::Transparent; $tx.BorderThickness = New-Object System.Windows.Thickness(0)
        $tx.Foreground = SolidBrush '#FFFFFF'; $tx.CaretBrush = SolidBrush '#FFFFFF'
        $tx.Padding = New-Object System.Windows.Thickness(8,6,8,6); $tx.FontSize = 12
        $tx.Add_TextChanged({ Update-TsPreview }) | Out-Null
        $bd.Child = $tx
        $col.Children.Add($lbl) | Out-Null; $col.Children.Add($bd) | Out-Null
        $grid.Children.Add($col) | Out-Null
        $script:tsLabelBoxes[$lk.key] = $tx
    }
}
function Get-LabelOverrides {
    $ov = @{}
    foreach ($k in $script:tsLabelBoxes.Keys) {
        $v = ($script:tsLabelBoxes[$k].Text).Trim()
        if ($v) { $ov[$k] = $v }
    }
    return $ov
}
(ctl 'TsLabelsToggle').Add_MouseLeftButtonUp({
    $body = ctl 'TsLabelsBody'
    if ($body.Visibility -eq 'Visible') { $body.Visibility = 'Collapsed'; (ctl 'TsLabelsChevron').Text = 'show' }
    else { $body.Visibility = 'Visible'; (ctl 'TsLabelsChevron').Text = 'hide' }
}) | Out-Null

# ── Segmented controls (Ticket mode cards + Separator style) ─────────────────
$script:tsSeg = @{}          # key -> selected value
$script:tsSegBtns = @{}      # key -> @{ value = Border }
function Set-Seg($key, $val) { $script:tsSeg[$key] = $val; Refresh-Seg $key }
function Get-Seg($key) { return $script:tsSeg[$key] }
function Refresh-Seg($key) {
    $cur = $script:tsSeg[$key]
    if (-not $script:tsSegBtns[$key]) { return }
    foreach ($val in $script:tsSegBtns[$key].Keys) {
        $b = $script:tsSegBtns[$key][$val]
        if ($val -eq $cur) { $b.Background = SolidBrush '#0F2A26'; $b.BorderBrush = SolidBrush '#14B8A6' }
        else { $b.Background = SolidBrush '#0F1117'; $b.BorderBrush = SolidBrush '#2A2D3A' }
    }
}
# Big card-style segment (used for Ticket Mode).
function Build-ModeSeg {
    $host_ = ctl 'TsModeSeg'; $host_.Children.Clear(); $script:tsSegBtns['ticket_mode'] = @{}
    $opts = @(
        @{ v='per_item';    t='Per Item';    d='One ticket per item' },
        @{ v='per_table';   t='Per Table';   d='All items on one ticket' },
        @{ v='per_section'; t='Per Section'; d='Split by Drinks / Food' }
    )
    foreach ($o in $opts) {
        $b = New-Object System.Windows.Controls.Border
        $b.Tag = $o.v; $b.Cursor = 'Hand'; $b.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $b.BorderThickness = New-Object System.Windows.Thickness(1); $b.Padding = New-Object System.Windows.Thickness(12,10,12,10)
        $b.Margin = New-Object System.Windows.Thickness(0,0,8,0)
        $sp = New-Object System.Windows.Controls.StackPanel
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $o.t; $t.Foreground = SolidBrush '#FFFFFF'; $t.FontSize = 12; $t.FontWeight = 'SemiBold'
        $d = New-Object System.Windows.Controls.TextBlock
        $d.Text = $o.d; $d.Foreground = SolidBrush '#7A8295'; $d.FontSize = 10; $d.TextWrapping = 'Wrap'
        $d.Margin = New-Object System.Windows.Thickness(0,3,0,0)
        $sp.Children.Add($t) | Out-Null; $sp.Children.Add($d) | Out-Null
        $b.Child = $sp
        $b.Add_MouseLeftButtonUp({ Set-Seg 'ticket_mode' $this.Tag; Update-TsPreview }) | Out-Null
        $host_.Children.Add($b) | Out-Null
        $script:tsSegBtns['ticket_mode'][$o.v] = $b
    }
}
# Compact segmented bar (used for Separator style).
function Build-SepSeg {
    $host_ = ctl 'TsSepSeg'; $host_.Children.Clear(); $script:tsSegBtns['separator_style'] = @{}
    $opts = @(@{ v='lines'; t='===' }, @{ v='dashes'; t='---' }, @{ v='stars'; t='***' }, @{ v='dots'; t='...' })
    foreach ($o in $opts) {
        $b = New-Object System.Windows.Controls.Border
        $b.Tag = $o.v; $b.Cursor = 'Hand'; $b.Width = 80; $b.Height = 32
        $b.CornerRadius = New-Object System.Windows.CornerRadius(6); $b.BorderThickness = New-Object System.Windows.Thickness(1)
        $b.Margin = New-Object System.Windows.Thickness(0,0,8,0)
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $o.t; $t.Foreground = SolidBrush '#FFFFFF'; $t.FontFamily = 'Consolas'; $t.FontSize = 13
        $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
        $b.Child = $t
        $b.Add_MouseLeftButtonUp({ Set-Seg 'separator_style' $this.Tag; Update-TsPreview }) | Out-Null
        $host_.Children.Add($b) | Out-Null
        $script:tsSegBtns['separator_style'][$o.v] = $b
    }
}

# A small self-contained segment button. $tagObj travels with the button so the
# click handler never depends on captured loop variables.
function New-SegBtn($label, $w, $tagObj, $onClick) {
    $b = New-Object System.Windows.Controls.Border
    $b.Tag = $tagObj; $b.Cursor = 'Hand'; $b.Width = $w; $b.Height = 28
    $b.CornerRadius = New-Object System.Windows.CornerRadius(5); $b.BorderThickness = New-Object System.Windows.Thickness(1)
    $b.BorderBrush = SolidBrush '#2A2D3A'; $b.Background = SolidBrush '#0F1117'
    $b.Margin = New-Object System.Windows.Thickness(0,0,5,0)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $label; $t.Foreground = SolidBrush '#D1D5DB'; $t.FontSize = 11
    $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $b.Child = $t
    $b.Add_MouseLeftButtonUp($onClick) | Out-Null
    return $b
}
# Copies 1|2|3 segmented (uses the tsSeg store, key 'order_copies' / 'check_copies').
function Build-CopiesSeg($containerName, $key) {
    $host_ = ctl $containerName; $host_.Children.Clear(); $script:tsSegBtns[$key] = @{}
    foreach ($v in @('1','2','3')) {
        $b = New-SegBtn $v 36 @{ key=$key; val=$v } { Set-Seg $this.Tag.key $this.Tag.val; Update-TsPreview }
        $host_.Children.Add($b) | Out-Null; $script:tsSegBtns[$key][$v] = $b
    }
    Refresh-Seg $key
}

# ── Per-zone layout matrix (prefix-aware: order = 4 zones, check = 2 zones) ─────
$script:tsZoneState = @{
    order = @{ header=@{size='';bold='';align=''}; info=@{size='';bold='';align=''}; items=@{size='';bold='';align=''}; footer=@{size='';bold='';align=''} }
    check = @{ info=@{size='';bold='';align=''}; items=@{size='';bold='';align=''} }
}
$script:tsZoneBtns = @{}    # "prefix|zone|prop|val" -> Border
function Refresh-Zone($prefix, $zone) {
    foreach ($k in $script:tsZoneBtns.Keys) {
        $parts = $k -split '\|'
        if ($parts[0] -ne $prefix -or $parts[1] -ne $zone) { continue }
        $b = $script:tsZoneBtns[$k]
        $on = ($parts[3] -eq [string]$script:tsZoneState[$prefix][$zone][$parts[2]])
        if ($on) { $b.Background = SolidBrush '#0F2A26'; $b.BorderBrush = SolidBrush '#14B8A6' }
        else { $b.Background = SolidBrush '#0F1117'; $b.BorderBrush = SolidBrush '#2A2D3A' }
    }
}
function Set-Zone($prefix, $zone, $prop, $val) {
    if ($prop -eq 'bold') {
        $script:tsZoneState[$prefix][$zone].bold = if ($script:tsZoneState[$prefix][$zone].bold -eq 'bold') { '' } else { 'bold' }
    } else {
        $script:tsZoneState[$prefix][$zone][$prop] = $val
    }
    Refresh-Zone $prefix $zone; Update-TsPreview
}
function Build-ZoneMatrix($containerName, $prefix, $zones) {
    $host_ = ctl $containerName; $host_.Children.Clear()
    foreach ($zd in $zones) {
        $zone = $zd.z
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'; $row.Margin = New-Object System.Windows.Thickness(0,0,0,8)
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $zd.n; $lbl.Width = 50; $lbl.Foreground = SolidBrush '#9CA3AF'; $lbl.FontSize = 12; $lbl.VerticalAlignment = 'Center'
        $row.Children.Add($lbl) | Out-Null
        foreach ($sv in @(@{ l='Auto'; v='' }, @{ l='S'; v='S' }, @{ l='M'; v='M' }, @{ l='L'; v='L' })) {
            $w = if ($sv.l -eq 'Auto') { 44 } else { 30 }
            $b = New-SegBtn $sv.l $w @{ p=$prefix; zone=$zone; prop='size'; val=$sv.v } { Set-Zone $this.Tag.p $this.Tag.zone 'size' $this.Tag.val }
            $row.Children.Add($b) | Out-Null; $script:tsZoneBtns["$prefix|$zone|size|$($sv.v)"] = $b
        }
        $g1 = New-Object System.Windows.Controls.Border; $g1.Width = 8; $row.Children.Add($g1) | Out-Null
        $bb = New-SegBtn 'B' 30 @{ p=$prefix; zone=$zone; prop='bold'; val='bold' } { Set-Zone $this.Tag.p $this.Tag.zone 'bold' 'bold' }
        $row.Children.Add($bb) | Out-Null; $script:tsZoneBtns["$prefix|$zone|bold|bold"] = $bb
        $g2 = New-Object System.Windows.Controls.Border; $g2.Width = 8; $row.Children.Add($g2) | Out-Null
        foreach ($av in @(@{ l='L'; v='left' }, @{ l='C'; v='center' }, @{ l='R'; v='right' })) {
            $b = New-SegBtn $av.l 30 @{ p=$prefix; zone=$zone; prop='align'; val=$av.v } { Set-Zone $this.Tag.p $this.Tag.zone 'align' $this.Tag.val }
            $row.Children.Add($b) | Out-Null; $script:tsZoneBtns["$prefix|$zone|align|$($av.v)"] = $b
        }
        $host_.Children.Add($row) | Out-Null
        Refresh-Zone $prefix $zone
    }
}

function Load-TicketSettings {
    $script:tsLoading = $true   # suppress preview re-render while we set many controls
    try {
        $r = Invoke-RestMethod -Uri "$base/local/ticket-settings" -TimeoutSec 3 -ErrorAction Stop
        $s = $r.settings
        # Global
        if ($s.ticket_language) { $script:tsLang = [string]$s.ticket_language }; Refresh-LangGrid
        # Custom label overrides
        foreach ($k in $script:tsLabelBoxes.Keys) { $script:tsLabelBoxes[$k].Text = '' }
        if ($s.label_overrides) {
            foreach ($k in $script:tsLabelBoxes.Keys) {
                $v = $s.label_overrides.$k
                if ($v) { $script:tsLabelBoxes[$k].Text = [string]$v }
            }
        }
        Set-ComboByContent (ctl 'TsDateFormat') $s.date_format
        Set-ComboByContent (ctl 'TsTimeFormat') $s.time_format
        (ctl 'TsLogoEnabled').IsChecked = [bool]$s.logo_print_enabled
        Set-ComboByContent (ctl 'TsLogoSize') $(if ($s.logo_size) { [string]$s.logo_size } else { 'medium' })
        (ctl 'TsLogoText').Text = $(if ($r.has_logo) { 'Logo set - click to replace' } else { 'Upload logo (PNG/JPG)' })
        # Order
        Set-Seg 'order_copies' ([string]$s.order_copies)
        Set-ComboByContent (ctl 'TsOrderFont')   $s.font_size
        # Per-zone layout
        $script:tsZoneState.order.header = @{ size=[string]$s.order_header_font_size; bold=[string]$s.order_header_font_bold; align=[string]$s.order_header_align }
        $script:tsZoneState.order.info   = @{ size=[string]$s.order_info_font_size;   bold=[string]$s.order_info_font_bold;   align=[string]$s.order_info_font_align }
        $script:tsZoneState.order.items  = @{ size=[string]$s.order_items_font_size;  bold=[string]$s.order_items_font_bold;  align=[string]$s.order_items_font_align }
        $script:tsZoneState.order.footer = @{ size=[string]$s.order_footer_font_size; bold=[string]$s.order_footer_font_bold; align=[string]$s.order_footer_font_align }
        foreach ($z in @('header','info','items','footer')) { Refresh-Zone 'order' $z }
        $script:tsZoneState.check.info  = @{ size=[string]$s.check_info_font_size;  bold=[string]$s.check_info_font_bold;  align=[string]$s.check_info_font_align }
        $script:tsZoneState.check.items = @{ size=[string]$s.check_items_font_size; bold=[string]$s.check_items_font_bold; align=[string]$s.check_items_font_align }
        foreach ($z in @('info','items')) { Refresh-Zone 'check' $z }
        Set-Seg 'separator_style' (if ($s.separator_style) { [string]$s.separator_style } else { 'lines' })
        Set-Seg 'ticket_mode'     (if ($s.ticket_mode)     { [string]$s.ticket_mode }     else { 'per_item' })
        (ctl 'TsOrderBold').IsChecked       = [bool]$s.order_item_bold
        (ctl 'TsOrderRestHeader').IsChecked = [bool]$s.show_restaurant_header
        (ctl 'TsOrderWaiter').IsChecked     = [bool]$s.show_waiter_name
        (ctl 'TsOrderPrice').IsChecked      = [bool]$s.show_item_price
        (ctl 'TsOrderFooter').Text          = [string]$s.kitchen_footer_text
        # Check
        Set-Seg 'check_copies' ([string]$s.check_copies)
        Set-ComboByContent (ctl 'TsCheckItemSize') $s.check_item_size
        (ctl 'TsCheckAddress').IsChecked   = [bool]$s.check_show_address
        (ctl 'TsCheckPhone').IsChecked     = [bool]$s.check_show_phone
        (ctl 'TsCheckInstagram').IsChecked = [bool]$s.check_show_instagram
        (ctl 'TsCheckWaiter').IsChecked    = [bool]$s.check_show_waiter
        (ctl 'TsCheckBoldTotal').IsChecked = [bool]$s.check_bold_total
        (ctl 'TsCheckFooter').Text         = [string]$s.check_footer_text
        # Cancel
        Set-ComboByContent (ctl 'TsCancelAlign')    $s.cancel_header_align
        Set-ComboByContent (ctl 'TsCancelItemSize') $s.cancel_item_size
        (ctl 'TsCancelEnabled').IsChecked  = [bool]$s.cancel_ticket_enabled
        (ctl 'TsCancelRestName').IsChecked = [bool]$s.cancel_show_restaurant_name
        (ctl 'TsCancelBy').IsChecked       = [bool]$s.cancel_show_cancelled_by
        (ctl 'TsCancelFooter').Text        = [string]$s.cancel_footer_text
        # Transfer
        Set-ComboByContent (ctl 'TsTransferAlign')    $s.transfer_header_align
        Set-ComboByContent (ctl 'TsTransferItemSize') $s.transfer_item_size
        (ctl 'TsTransferEnabled').IsChecked  = [bool]$s.transfer_ticket_enabled
        (ctl 'TsTransferRestName').IsChecked = [bool]$s.transfer_show_restaurant_name
        (ctl 'TsTransferFooter').Text        = [string]$s.transfer_footer_text
    } catch { }
    $script:tsLoading = $false
    Update-TsPreview
}

function Get-TicketSettingsFromUI {
    return @{
        ticket_language        = $script:tsLang
        label_overrides        = (Get-LabelOverrides)
        date_format            = Get-ComboContent (ctl 'TsDateFormat')
        time_format            = Get-ComboContent (ctl 'TsTimeFormat')
        logo_print_enabled     = [bool](ctl 'TsLogoEnabled').IsChecked
        logo_size              = Get-ComboContent (ctl 'TsLogoSize')
        order_copies           = [int](Get-Seg 'order_copies')
        order_header_align     = $script:tsZoneState.order.header.align
        order_header_font_size = $script:tsZoneState.order.header.size
        order_header_font_bold = $script:tsZoneState.order.header.bold
        order_info_font_size   = $script:tsZoneState.order.info.size
        order_info_font_bold   = $script:tsZoneState.order.info.bold
        order_info_font_align  = $script:tsZoneState.order.info.align
        order_items_font_size  = $script:tsZoneState.order.items.size
        order_items_font_bold  = $script:tsZoneState.order.items.bold
        order_items_font_align = $script:tsZoneState.order.items.align
        order_footer_font_size = $script:tsZoneState.order.footer.size
        order_footer_font_bold = $script:tsZoneState.order.footer.bold
        order_footer_font_align= $script:tsZoneState.order.footer.align
        check_info_font_size   = $script:tsZoneState.check.info.size
        check_info_font_bold   = $script:tsZoneState.check.info.bold
        check_info_font_align  = $script:tsZoneState.check.info.align
        check_items_font_size  = $script:tsZoneState.check.items.size
        check_items_font_bold  = $script:tsZoneState.check.items.bold
        check_items_font_align = $script:tsZoneState.check.items.align
        font_size              = Get-ComboContent (ctl 'TsOrderFont')
        separator_style        = Get-Seg 'separator_style'
        ticket_mode            = Get-Seg 'ticket_mode'
        order_item_bold        = [bool](ctl 'TsOrderBold').IsChecked
        show_restaurant_header = [bool](ctl 'TsOrderRestHeader').IsChecked
        show_waiter_name       = [bool](ctl 'TsOrderWaiter').IsChecked
        show_item_price        = [bool](ctl 'TsOrderPrice').IsChecked
        kitchen_footer_text    = (ctl 'TsOrderFooter').Text
        check_copies           = [int](Get-Seg 'check_copies')
        check_item_size        = Get-ComboContent (ctl 'TsCheckItemSize')
        check_show_address     = [bool](ctl 'TsCheckAddress').IsChecked
        check_show_phone       = [bool](ctl 'TsCheckPhone').IsChecked
        check_show_instagram   = [bool](ctl 'TsCheckInstagram').IsChecked
        check_show_waiter      = [bool](ctl 'TsCheckWaiter').IsChecked
        check_bold_total       = [bool](ctl 'TsCheckBoldTotal').IsChecked
        check_footer_text      = (ctl 'TsCheckFooter').Text
        cancel_header_align         = Get-ComboContent (ctl 'TsCancelAlign')
        cancel_item_size            = Get-ComboContent (ctl 'TsCancelItemSize')
        cancel_ticket_enabled       = [bool](ctl 'TsCancelEnabled').IsChecked
        cancel_show_restaurant_name = [bool](ctl 'TsCancelRestName').IsChecked
        cancel_show_cancelled_by    = [bool](ctl 'TsCancelBy').IsChecked
        cancel_footer_text          = (ctl 'TsCancelFooter').Text
        transfer_header_align         = Get-ComboContent (ctl 'TsTransferAlign')
        transfer_item_size            = Get-ComboContent (ctl 'TsTransferItemSize')
        transfer_ticket_enabled       = [bool](ctl 'TsTransferEnabled').IsChecked
        transfer_show_restaurant_name = [bool](ctl 'TsTransferRestName').IsChecked
        transfer_footer_text          = (ctl 'TsTransferFooter').Text
    }
}

# ── Live preview ─────────────────────────────────────────────────────────────
# A handful of preview-only label translations so the mock reflects the chosen
# language. (Full label set is resolved server-side on Save / Test Print.)
$script:tsPrevLbl = @{
    en=@{table='Table';waiter='Waiter';total='TOTAL';invit='[INVIT]';cancelled='!! CANCELLED !!';transfer='** TRANSFER **';from='FROM';to='TO';by='Cancelled by'}
    fr=@{table='Table';waiter='Serveur';total='TOTAL';invit='[OFFERT]';cancelled='!! ANNULÉ !!';transfer='** TRANSFERT **';from='DE';to='VERS';by='Annulé par'}
    es=@{table='Mesa';waiter='Camarero';total='TOTAL';invit='[INVIT]';cancelled='!! CANCELADO !!';transfer='** TRANSFERIDO **';from='DESDE';to='A';by='Cancelado por'}
    it=@{table='Tavolo';waiter='Cameriere';total='TOTALE';invit='[OMAGGIO]';cancelled='!! ANNULLATO !!';transfer='** TRASFERITO **';from='DA';to='A';by='Annullato da'}
    de=@{table='Tisch';waiter='Kellner';total='GESAMT';invit='[EINLADUNG]';cancelled='!! STORNIERT !!';transfer='** ÜBERTRAGEN **';from='VON';to='NACH';by='Storniert von'}
    nl=@{table='Tafel';waiter='Ober';total='TOTAAL';invit='[GRATIS]';cancelled='!! GEANNULEERD !!';transfer='** OVERGEZET **';from='VAN';to='NAAR';by='Geannuleerd door'}
    ru=@{table='Стол';waiter='Официант';total='ИТОГО';invit='[УГОЩЕНИЕ]';cancelled='!! ОТМЕНЕНО !!';transfer='** ПЕРЕНОС **';from='ОТ';to='К';by='Отменил'}
    ar=@{table='طاولة';waiter='النادل';total='المجموع';invit='[دعوة]';cancelled='!! تم الإلغاء !!';transfer='** تم النقل **';from='من';to='إلى';by='تم الإلغاء بواسطة'}
    zh=@{table='桌号';waiter='服务员';total='总计';invit='[赠送]';cancelled='!! 已取消 !!';transfer='** 已转移 **';from='从';to='到';by='取消人'}
    pt=@{table='Mesa';waiter='Garçom';total='TOTAL';invit='[CORTESIA]';cancelled='!! CANCELADO !!';transfer='** TRANSFERIDO **';from='DE';to='PARA';by='Cancelado por'}
}
function Get-PrevLbl($k) {
    # A custom override (if set) wins over the language default in the preview.
    $map = @{ table='table'; waiter='waiter'; total='total'; invit='invitation' }
    if ($map.ContainsKey($k) -and $script:tsLabelBoxes -and $script:tsLabelBoxes[$map[$k]]) {
        $ov = ($script:tsLabelBoxes[$map[$k]].Text).Trim()
        if ($ov) { return $ov }
    }
    $d = $script:tsPrevLbl[$script:tsLang]; if (-not $d) { $d = $script:tsPrevLbl['en'] }; return $d[$k]
}
$script:TS_W = 32
function Ts-Sep($style) {
    $ch = switch ($style) { 'dashes' { '-' } 'stars' { '*' } 'dots' { '.' } default { '=' } }
    return ($ch * $script:TS_W)
}
function Ts-Align($text, $align) {
    if ($text.Length -ge $script:TS_W) { return $text }
    $pad = $script:TS_W - $text.Length
    if ($align -eq 'right') { return (' ' * $pad) + $text }
    if ($align -eq 'center') { $l = [math]::Floor($pad/2); return (' ' * $l) + $text }
    return $text
}
function Ts-LR($l, $r) {
    $sp = $script:TS_W - $l.Length - $r.Length
    if ($sp -lt 1) { $sp = 1 }
    return $l + (' ' * $sp) + $r
}
$script:tsLoading = $false
function Update-TsPreview {
    if ($script:tsLoading) { return }   # skip churn while Load-TicketSettings sets many controls
    $tb = ctl 'TsPreview'; if (-not $tb) { return }
    try {
    $lines = @()
    $tab = $script:tsActiveTab
    $rest = 'COFFEES'
    if ($tab -eq 'order') {
        $sep = Ts-Sep (Get-Seg 'separator_style')
        $hAlign = if ($script:tsZoneState.order.header.align) { $script:tsZoneState.order.header.align } else { 'center' }
        if ((ctl 'TsOrderRestHeader').IsChecked) { $lines += (Ts-Align $rest $hAlign) }
        $lines += $sep
        $lines += (Ts-LR ((Get-PrevLbl 'table') + ': 5') '27/06/2026')
        if ((ctl 'TsOrderWaiter').IsChecked) { $lines += (Ts-LR ((Get-PrevLbl 'waiter') + ': Emran') '04:05') }
        $lines += $sep
        $price = [bool](ctl 'TsOrderPrice').IsChecked
        $lines += if ($price) { Ts-LR '2x Expresso' '4.00' } else { '2x Expresso' }
        $lines += if ($price) { Ts-LR '1x Croissant' '3.50' } else { '1x Croissant' }
        $lines += if ($price) { Ts-LR '1x Orange Juice' '4.50' } else { '1x Orange Juice' }
        $lines += ((Get-PrevLbl 'invit') + ' 1x Water')
        $ft = ((ctl 'TsOrderFooter').Text).Trim()
        if ($ft) { $lines += ''; $lines += (Ts-Align $ft 'center') }
    } elseif ($tab -eq 'check') {
        $lines += (Ts-Align $rest 'center')
        $lines += (Ts-Sep 'lines')
        $lines += ((Get-PrevLbl 'table') + ': 5')
        $lines += (Ts-Sep 'dashes')
        $lines += (Ts-LR '2x Expresso' '4.00')
        $lines += (Ts-LR '1x Croissant' '3.50')
        $lines += (Ts-LR '1x Orange Juice' '4.50')
        $lines += (Ts-Sep 'dashes')
        $lines += (Ts-LR (Get-PrevLbl 'total') '12.00')
        $ft = ((ctl 'TsCheckFooter').Text).Trim()
        if ($ft) { $lines += ''; $lines += (Ts-Align $ft 'center') }
    } elseif ($tab -eq 'cancel') {
        $lines += (Ts-Align (Get-PrevLbl 'cancelled') (Get-ComboContent (ctl 'TsCancelAlign')))
        if ((ctl 'TsCancelRestName').IsChecked) { $lines += (Ts-Align $rest 'center') }
        $lines += (Ts-Sep 'lines')
        $lines += ((Get-PrevLbl 'table') + ': 5')
        $lines += '2x Expresso'
        if ((ctl 'TsCancelBy').IsChecked) { $lines += ''; $lines += ((Get-PrevLbl 'by') + ': Manager') }
        $ft = ((ctl 'TsCancelFooter').Text).Trim()
        if ($ft) { $lines += ''; $lines += (Ts-Align $ft 'center') }
    } else {
        $lines += (Ts-Align (Get-PrevLbl 'transfer') (Get-ComboContent (ctl 'TsTransferAlign')))
        if ((ctl 'TsTransferRestName').IsChecked) { $lines += (Ts-Align $rest 'center') }
        $lines += (Ts-Sep 'lines')
        $lines += (Ts-LR ((Get-PrevLbl 'from') + ' 5') ((Get-PrevLbl 'to') + ' 8'))
        $lines += '2x Expresso'
        $ft = ((ctl 'TsTransferFooter').Text).Trim()
        if ($ft) { $lines += ''; $lines += (Ts-Align $ft 'center') }
    }
    $tb.Text = ($lines -join "`n")
    } catch { }
}

$script:tsActiveTab = 'order'
function Set-TsTab($tab) {
    $script:tsActiveTab = $tab
    $panels = @{ order='TsOrderPanel'; check='TsCheckPanel'; cancel='TsCancelPanel'; transfer='TsTransferPanel' }
    $tabs   = @{ order='TsTabOrder';   check='TsTabCheck';   cancel='TsTabCancel';   transfer='TsTabTransfer' }
    foreach ($k in $panels.Keys) {
        (ctl $panels[$k]).Visibility = if ($k -eq $tab) { 'Visible' } else { 'Collapsed' }
        $btn = ctl $tabs[$k]
        if ($k -eq $tab) { $btn.Background = SolidBrush '#14B8A6'; $btn.Foreground = [System.Windows.Media.Brushes]::White }
        else { $btn.Background = SolidBrush '#1A1D29'; $btn.Foreground = SolidBrush '#9CA3AF' }
    }
    Update-TsPreview
}

(ctl 'TsTabOrder').Add_Click({ Set-TsTab 'order' })
(ctl 'TsTabCheck').Add_Click({ Set-TsTab 'check' })
(ctl 'TsTabCancel').Add_Click({ Set-TsTab 'cancel' })
(ctl 'TsTabTransfer').Add_Click({ Set-TsTab 'transfer' })
(ctl 'TsSave').Add_Click({
    try {
        $body = (Get-TicketSettingsFromUI) | ConvertTo-Json
        Invoke-RestMethod -Uri "$base/local/ticket-settings" -Method Patch -Body $body -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
        [System.Windows.MessageBox]::Show((T 'ts_saved'), 'LightMenu', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show((T 'menu_save_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
    }
})
(ctl 'TsTest').Add_Click({
    try {
        $type = switch ($script:tsActiveTab) { 'check' { 'check' } 'cancel' { 'cancel' } 'transfer' { 'transfer' } default { 'kitchen' } }
        $body = @{ type = $type; settings = (Get-TicketSettingsFromUI) } | ConvertTo-Json
        Invoke-RestMethod -Uri "$base/local/ticket-settings/test" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 8 -ErrorAction Stop | Out-Null
        [System.Windows.MessageBox]::Show((T 'test_print_sent'), 'LightMenu', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show((T 'test_print_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
    }
})
# Live preview reacts to the controls that affect it.
foreach ($n in @('TsOrderBold','TsOrderRestHeader','TsOrderWaiter','TsOrderPrice','TsCancelRestName','TsCancelBy','TsTransferRestName')) {
    (ctl $n).Add_Click({ Update-TsPreview }) | Out-Null
}
foreach ($n in @('TsCancelAlign','TsTransferAlign')) {
    (ctl $n).Add_SelectionChanged({ Update-TsPreview }) | Out-Null
}
foreach ($n in @('TsOrderFooter','TsCheckFooter','TsCancelFooter','TsTransferFooter')) {
    (ctl $n).Add_TextChanged({ Update-TsPreview }) | Out-Null
}
# ── Logo upload ──────────────────────────────────────────────────────────────
# PowerShell decodes + resizes the image and extracts per-pixel luminance; the
# agent does the Floyd–Steinberg dither + ESC/POS packing.
function Convert-LogoToGray($path, $targetWidth) {
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($path)
    try {
        $scale = $targetWidth / $img.Width
        $w = [int][Math]::Max(8, [Math]::Round($img.Width * $scale))
        $h = [int][Math]::Max(1, [Math]::Round($img.Height * $scale))
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($img, 0, 0, $w, $h)
        $g.Dispose()
        $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
        $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $stride = $bd.Stride
        $buf = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
        $bmp.UnlockBits($bd); $bmp.Dispose()
        $gray = New-Object byte[] ($w * $h)
        for ($y = 0; $y -lt $h; $y++) {
            $ro = $y * $stride
            for ($x = 0; $x -lt $w; $x++) {
                $o = $ro + $x * 4   # BGRA
                $lum = [int](0.114 * $buf[$o] + 0.587 * $buf[$o + 1] + 0.299 * $buf[$o + 2])
                if ($lum -gt 255) { $lum = 255 }
                $gray[$y * $w + $x] = [byte]$lum
            }
        }
        return @{ w = $w; h = $h; gray_b64 = [Convert]::ToBase64String($gray) }
    } finally { $img.Dispose() }
}
(ctl 'TsLogoDrop').Add_MouseLeftButtonUp({
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $sizeName = Get-ComboContent (ctl 'TsLogoSize'); if (-not $sizeName) { $sizeName = 'medium' }
    $tw = switch ($sizeName) { 'small' { 192 } 'large' { 384 } default { 288 } }
    (ctl 'TsLogoText').Text = 'Processing...'
    try {
        $r = Convert-LogoToGray $dlg.FileName $tw
        $body = @{ width = $r.w; height = $r.h; gray_b64 = $r.gray_b64; size = $sizeName; enabled = $true } | ConvertTo-Json
        # Async upload so the (heavy, server-round-trip) store doesn't freeze the UI.
        Invoke-AsyncPost "$base/local/logo" $body 'POST' {
            param($resp, $bad, $emsg)
            if ($bad) { (ctl 'TsLogoText').Text = 'Upload failed - try a smaller image.' }
            else {
                (ctl 'TsLogoText').Text = 'Logo set - click to replace'
                (ctl 'TsLogoEnabled').IsChecked = $true
            }
        }
    } catch {
        (ctl 'TsLogoText').Text = 'Upload failed - try a smaller image.'
    }
}) | Out-Null
(ctl 'TsLogoEnabled').Add_Click({
    try { Invoke-RestMethod -Uri "$base/local/ticket-settings" -Method Patch -Body ((Get-TicketSettingsFromUI) | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null } catch {}
}) | Out-Null
(ctl 'TsLogoRemove').Add_Click({
    try {
        Invoke-RestMethod -Uri "$base/local/logo/remove" -Method Post -TimeoutSec 8 -ErrorAction Stop | Out-Null
        (ctl 'TsLogoText').Text = 'Upload logo (PNG/JPG)'; (ctl 'TsLogoEnabled').IsChecked = $false
    } catch {}
}) | Out-Null

Build-LangGrid
Build-LabelGrid
Build-ModeSeg
Build-SepSeg
Build-CopiesSeg 'TsOrderCopiesSeg' 'order_copies'
Build-CopiesSeg 'TsCheckCopiesSeg' 'check_copies'
Build-ZoneMatrix 'TsZoneMatrix'      'order' @(@{z='header';n='Header'},@{z='info';n='Info'},@{z='items';n='Items'},@{z='footer';n='Footer'})
Build-ZoneMatrix 'TsCheckZoneMatrix' 'check' @(@{z='info';n='Info'},@{z='items';n='Items'})
Set-Seg 'ticket_mode' 'per_item'
Set-Seg 'separator_style' 'lines'
Set-Seg 'order_copies' '1'
Set-Seg 'check_copies' '1'
Set-TsTab 'order'

(ctl 'KitchenRefresh').Add_Click({ Update-Kitchen-Page })
(ctl 'AddPrinterBtn').Add_Click({ (ctl 'AddPrinterPanel').Visibility = 'Visible' })
(ctl 'CancelPrinterBtn').Add_Click({
    (ctl 'AddPrinterPanel').Visibility = 'Collapsed'
    (ctl 'NewPrinterName').Text = ''; (ctl 'NewPrinterIp').Text = ''
})
(ctl 'SavePrinterBtn').Add_Click({
    $name = ((ctl 'NewPrinterName').Text).Trim()
    $ip   = ((ctl 'NewPrinterIp').Text).Trim()
    $typeItem = (ctl 'NewPrinterType').SelectedItem
    $type = if ($typeItem) { $typeItem.Content } else { 'kitchen' }
    if (-not $name) { $name = 'Printer' }
    if ($ip -and $ip -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        [System.Windows.MessageBox]::Show((T 'invalid_ip'), 'LightMenu', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $body = @{ name = $name; ip = $ip; port = 9100; type = $type } | ConvertTo-Json
        Invoke-RestMethod -Uri "$base/local/printers" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 8 -ErrorAction Stop | Out-Null
        (ctl 'AddPrinterPanel').Visibility = 'Collapsed'
        (ctl 'NewPrinterName').Text = ''; (ctl 'NewPrinterIp').Text = ''
        Update-Kitchen-Page
    } catch {
        [System.Windows.MessageBox]::Show((T 'printer_add_fail'), 'LightMenu', 'OK', 'Warning') | Out-Null
    }
})

# ─── ASSISTANT (AI chat) ─────────────────────────────────────────────────────
$script:aiHistory = @()
$script:aiBusy = $false
$script:aiInited = $false
function Add-AiBubble($role, $text) {
    $wrap = New-Object System.Windows.Controls.Border
    $wrap.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $wrap.Padding = New-Object System.Windows.Thickness(12,9,12,9)
    $wrap.Margin = New-Object System.Windows.Thickness(0,0,0,8)
    $wrap.MaxWidth = 560
    if ($role -eq 'user') {
        $wrap.Background = SolidBrush '#14B8A6'; $wrap.HorizontalAlignment = 'Right'
    } elseif ($role -eq 'system') {
        $wrap.Background = SolidBrush '#2A2D3A'; $wrap.HorizontalAlignment = 'Center'
    } else {
        $wrap.Background = SolidBrush '#1A1D29'; $wrap.HorizontalAlignment = 'Left'
        $wrap.BorderBrush = SolidBrush '#2A2D3A'; $wrap.BorderThickness = New-Object System.Windows.Thickness(1)
    }
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text; $tb.Foreground = SolidBrush '#FFFFFF'; $tb.FontSize = 13; $tb.TextWrapping = 'Wrap'
    $wrap.Child = $tb
    (ctl 'AiMessages').Children.Add($wrap) | Out-Null
    (ctl 'AiScroller').ScrollToBottom()
    return $tb
}
function Init-Assistant {
    if ($script:aiInited) { return }
    $script:aiInited = $true
    Add-AiBubble 'assistant' "Hi! I'm your Station assistant. Try: ""add a Mojito for 8 euros to Cocktails"", ""rename Glaces to Desserts"", or ""how many items are in Mekla?""" | Out-Null
}
function Send-AiMessage {
    if ($script:aiBusy) { return }
    $msg = ((ctl 'AiInput').Text).Trim()
    if (-not $msg) { return }
    (ctl 'AiInput').Text = ''
    Add-AiBubble 'user' $msg | Out-Null
    $script:aiBusy = $true
    (ctl 'AiSendText').Text = '...'
    # The callback fires AFTER this function returns, so it can't see locals. Use
    # $script:-scoped state instead of a closure: a GetNewClosure() callback runs
    # in its own module where "$script:" points at the module (so "$script:aiBusy
    # = $false" wouldn't reach the real flag and the Send button would stay dead).
    # Only one AI request runs at a time (guarded by $script:aiBusy), so a single
    # shared pending-bubble/message is safe.
    $script:aiThinking   = Add-AiBubble 'assistant' 'Thinking...'
    $script:aiPendingMsg = $msg
    # Fully async: the user bubble + "Thinking..." render immediately and the UI
    # stays responsive while the (up to 45s) AI request runs on a pool thread.
    $body = @{ message = $msg; history = $script:aiHistory } | ConvertTo-Json -Depth 5
    Invoke-AsyncPost "$base/local/ai" $body 'POST' {
        param($r, $bad, $emsg)
        try {
            $errMsg = ''
            if ($bad) { $errMsg = $emsg }
            elseif ($r -and -not $r.ok -and $r.error) { $errMsg = [string]$r.error }

            if ($errMsg) {
                if ($errMsg -match 'quota|limit reached') { $script:aiThinking.Text = "You've hit your monthly AI limit. Upgrade your plan for more." }
                elseif ($errMsg -match '401|Invalid station') { $script:aiThinking.Text = 'The Station could not authenticate with the AI service. Make sure the agent is set up for this restaurant.' }
                elseif ($errMsg -match 'timed out') { $script:aiThinking.Text = "The AI took too long to respond. Please try again." }
                else { $script:aiThinking.Text = "Sorry, I couldn't reach the AI service. Check the internet connection and try again." }
            } else {
                $reply = if ($r -and $r.reply) { [string]$r.reply } else { 'Done.' }
                $script:aiThinking.Text = $reply
                if ($r -and $r.actions -and @($r.actions).Count -gt 0) {
                    Add-AiBubble 'system' ('actions: ' + (@($r.actions) -join ', ')) | Out-Null
                }
                $script:aiHistory += @{ role = 'user'; text = $script:aiPendingMsg }
                $script:aiHistory += @{ role = 'assistant'; text = $reply }
                if (@($script:aiHistory).Count -gt 12) { $script:aiHistory = @($script:aiHistory)[-12..-1] }
                $script:menuData = $null
            }
        } finally {
            $script:aiBusy = $false
            (ctl 'AiSendText').Text = 'Send'
            (ctl 'AiScroller').ScrollToBottom()
        }
    }
}
(ctl 'AiSend').Add_Click({ Send-AiMessage })
(ctl 'AiInput').Add_KeyDown({ if ($_.Key -eq 'Return') { Send-AiMessage } })

# ─── Timers ─────────────────────────────────────────────────────────────────
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(4)
$statusTimer.Add_Tick({ Update-Status })
$statusTimer.Start()

$floorTimer = New-Object System.Windows.Threading.DispatcherTimer
$floorTimer.Interval = [TimeSpan]::FromSeconds(5)
$floorTimer.Add_Tick({ if ($script:activePage -eq 'Dashboard') { Update-FloorPlan } })
$floorTimer.Start()

$analyticsTimer = New-Object System.Windows.Threading.DispatcherTimer
$analyticsTimer.Interval = [TimeSpan]::FromSeconds(10)
$analyticsTimer.Add_Tick({ if ($script:activePage -eq 'Analytics') { Update-Analytics-Page } })
$analyticsTimer.Start()

# ─── Self-reload on update ───────────────────────────────────────────────────
# The auto-updater replaces this ui.ps1 on disk, but a running WPF window keeps
# executing the copy it loaded at launch — so UI updates never showed until a
# reboot. Here the window watches its OWN file's timestamp; when the updater
# swaps it, we launch a fresh copy and close this one. Deferred while a table
# order is open so an update never interrupts someone taking an order.
$script:selfPath = $PSCommandPath
if (-not $script:selfPath) { try { $script:selfPath = $MyInvocation.MyCommand.Path } catch {} }
$script:selfMTime = $null
try { if ($script:selfPath) { $script:selfMTime = (Get-Item $script:selfPath).LastWriteTimeUtc } } catch {}
$script:restarting = $false

function Restart-Self {
    if ($script:restarting -or -not $script:selfPath) { return }
    if ($script:orderTable) { return }   # mid-order — try again on the next tick
    $script:restarting = $true
    try {
        $argStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script:selfPath + '"'
        Start-Process 'powershell.exe' -WindowStyle Hidden -ArgumentList $argStr | Out-Null
    } catch { $script:restarting = $false; return }
    # Let the new window spin up before this one disappears (avoids a visible gap).
    $script:restartTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:restartTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $script:restartTimer.Add_Tick({
        $script:restartTimer.Stop()
        try { $window.Close() } catch {}
        [System.Environment]::Exit(0)
    })
    $script:restartTimer.Start()
}

$updateWatchTimer = New-Object System.Windows.Threading.DispatcherTimer
$updateWatchTimer.Interval = [TimeSpan]::FromSeconds(15)
$updateWatchTimer.Add_Tick({
    if (-not $script:selfPath -or $script:restarting) { return }
    try {
        $m = (Get-Item $script:selfPath).LastWriteTimeUtc
        if ($script:selfMTime -and $m -gt $script:selfMTime) { Restart-Self }
    } catch {}
})
$updateWatchTimer.Start()

# ─── Initial state ──────────────────────────────────────────────────────────
Apply-Language
Switch-Page 'Home'
Set-Active-Period 'today'
# The first status refresh must run only AFTER ShowDialog starts the dispatcher.
# Calling the async Update-Status before the message loop is pumping makes the
# WebClient completion fire on a thread-pool thread with no PowerShell runspace,
# which crashes the process silently (window opens then closes, no trap log).
# ContentRendered fires under the running dispatcher, so the async callback
# marshals safely back to the UI thread. Update-Log is synchronous and safe.
$window.Add_ContentRendered({ Update-Status; Update-FloorPlan })

$window.ShowDialog() | Out-Null
