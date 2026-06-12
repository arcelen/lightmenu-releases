# LightMenu Print Agent - Multi-page WPF UI
# ------------------------------------------
# Pages: Dashboard, Analytics, Bills, Daily Report
# All data sourced from the agent's HTTP endpoints (localhost:3000).
# Works fully offline — the agent stores everything locally.

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$errorLog  = Join-Path $scriptDir '..\app\ui-error.log'
trap {
    $msg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($_.Exception.Message)`n$($_.ScriptStackTrace)`n"
    try { Add-Content -Path $errorLog -Value $msg } catch {}
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
$base        = 'http://localhost:3000'
$statusUrl   = "$base/status"
$rescanUrl   = "$base/rescan"

# Currency symbol cache from last stats fetch
$script:currencySymbol = 'EUR'

function Format-Money($amount) {
    $sym = $script:currencySymbol
    $n   = [double]$amount
    return ('{0} {1:N2}' -f $sym, $n)
}

# ─── XAML ────────────────────────────────────────────────────────────────────
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LightMenu Print Agent" Height="820" Width="900"
        MinHeight="640" MinWidth="780"
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
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

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
          <TextBlock x:Name="VersionText" Text="Print Agent v6.0.0" FontSize="11" Foreground="#7A8295" Margin="0,3,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="StatusDot" Width="10" Height="10" Fill="#6B7280" Margin="0,0,8,0"/>
          <TextBlock x:Name="StatusText" Text="Connecting..." FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ───────── NAV BAR ───────── -->
    <Border Grid.Row="1" Background="#0F1117" Margin="0,0,0,12">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="NavDashboard" Style="{StaticResource NavBtn}" Content="Dashboard"/>
        <Button x:Name="NavAnalytics" Style="{StaticResource NavBtn}" Content="Analytics" Margin="6,0,0,0"/>
        <Button x:Name="NavBills"     Style="{StaticResource NavBtn}" Content="Bills"     Margin="6,0,0,0"/>
        <Button x:Name="NavReport"    Style="{StaticResource NavBtn}" Content="Daily Report" Margin="6,0,0,0"/>
      </StackPanel>
    </Border>

    <!-- ───────── PAGE CONTAINER ───────── -->
    <Grid Grid.Row="2">

      <!-- ════════ PAGE 1: DASHBOARD ════════ -->
      <Grid x:Name="PageDashboard" Visibility="Visible">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,12">
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
              <TextBlock x:Name="PrinterText" Text="--" Style="{StaticResource CardValue}"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardStyle}" Grid.Row="0" Grid.Column="2">
            <StackPanel>
              <TextBlock Text="TUNNEL" Style="{StaticResource CardLabel}"/>
              <TextBlock x:Name="TunnelText" Text="--" Style="{StaticResource CardValue}"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardStyle}" Grid.Row="2" Grid.Column="0">
            <StackPanel>
              <TextBlock Text="TODAY (SESSION)" Style="{StaticResource CardLabel}"/>
              <TextBlock x:Name="StatsText" Text="--" Style="{StaticResource CardValue}"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardStyle}" Grid.Row="2" Grid.Column="2">
            <StackPanel>
              <TextBlock Text="LAST UPDATE" Style="{StaticResource CardLabel}"/>
              <TextBlock x:Name="UpdateText" Text="--" Style="{StaticResource CardValue}"/>
            </StackPanel>
          </Border>
        </Grid>

        <Border Style="{StaticResource CardStyle}" Grid.Row="1">
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
                <TextBox x:Name="LogBox" Background="Transparent" Foreground="#D1D5DB"
                         BorderThickness="0" FontFamily="Consolas" FontSize="11"
                         IsReadOnly="True" TextWrapping="NoWrap" Padding="8"/>
              </ScrollViewer>
            </Border>
          </Grid>
        </Border>

        <Grid Grid.Row="2" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="12"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="TestBtn" Grid.Column="0" Style="{StaticResource ActionBtn}" Content="Rescan Printers">
            <Button.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#14B8A6" Offset="0"/>
                <GradientStop Color="#06B6D4" Offset="1"/>
              </LinearGradientBrush>
            </Button.Background>
          </Button>
          <Button x:Name="RestartBtn" Grid.Column="2" Style="{StaticResource ActionBtn}" Content="Restart Agent"/>
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
                  <TextBlock Text="TOTAL REVENUE" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="AnaRevenue" Text="--" Style="{StaticResource BigValue}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardStyle}" Grid.Column="2">
                <StackPanel>
                  <TextBlock Text="TOTAL ORDERS" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="AnaOrders" Text="--" Style="{StaticResource BigValue}" Foreground="#06B6D4"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardStyle}" Grid.Column="4">
                <StackPanel>
                  <TextBlock Text="AVG TICKET" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="AnaAvg" Text="--" Style="{StaticResource BigValue}"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource CardStyle}" Grid.Column="6">
                <StackPanel>
                  <TextBlock Text="BEST DAY" Style="{StaticResource CardLabel}"/>
                  <TextBlock x:Name="AnaBest" Text="--" Style="{StaticResource BigValue}" Foreground="#F59E0B" FontSize="16"/>
                </StackPanel>
              </Border>
            </Grid>

            <Border Style="{StaticResource CardStyle}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="PAYMENT METHODS" Style="{StaticResource CardLabel}" Margin="0,0,0,10"/>
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
                      <TextBlock Text="Cash" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center" Margin="0,4,0,0"/>
                      <TextBlock x:Name="PayCashTotal" Text="--" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="2" Background="#0F1929" BorderBrush="#3B82F6" BorderThickness="1" CornerRadius="8" Padding="14">
                    <StackPanel HorizontalAlignment="Center">
                      <TextBlock x:Name="PayCardCount" Text="0" FontSize="22" FontWeight="Bold" Foreground="#3B82F6" HorizontalAlignment="Center"/>
                      <TextBlock Text="Card" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center" Margin="0,4,0,0"/>
                      <TextBlock x:Name="PayCardTotal" Text="--" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="4" Background="#0F2229" BorderBrush="#06B6D4" BorderThickness="1" CornerRadius="8" Padding="14">
                    <StackPanel HorizontalAlignment="Center">
                      <TextBlock x:Name="PayMixedCount" Text="0" FontSize="22" FontWeight="Bold" Foreground="#06B6D4" HorizontalAlignment="Center"/>
                      <TextBlock Text="Mixed" Foreground="#9CA3AF" FontSize="11" HorizontalAlignment="Center" Margin="0,4,0,0"/>
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
          <TextBlock Foreground="#FCD34D" FontSize="12" Text="Bills are stored locally on this PC and survive restarts. Export to CSV for permanent backup."/>
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
            <TextBlock Grid.Column="0" Text="From:" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <DatePicker x:Name="BillStart" Grid.Column="2" Width="130"/>
            <TextBlock Grid.Column="3" Text="To:" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="14,0,8,0"/>
            <DatePicker x:Name="BillEnd"   Grid.Column="5" Width="130"/>
            <Button x:Name="BillRefresh" Grid.Column="7" Style="{StaticResource PeriodBtn}" Content="Apply"/>
            <Button x:Name="BillExport"  Grid.Column="9" Style="{StaticResource PeriodBtn}" Content="Export CSV">
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
            <TextBlock Text="GENERATE REPORT" Style="{StaticResource CardLabel}" Margin="0,0,0,10"/>
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
              <TextBlock Grid.Column="0" Text="Date:" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <DatePicker x:Name="ReportDate" Grid.Column="1" Width="140" HorizontalAlignment="Left"/>
              <TextBlock Grid.Column="2" Text="Start:" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="14,0,8,0"/>
              <TextBox x:Name="ReportStart" Grid.Column="3" Width="70" HorizontalAlignment="Left" Text="09:00" Background="#0F1117" Foreground="#FFFFFF" BorderBrush="#2A2D3A" Padding="6,4"/>
              <TextBlock Grid.Column="4" Text="End:" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="14,0,8,0"/>
              <TextBox x:Name="ReportEnd"   Grid.Column="5" Width="70" HorizontalAlignment="Left" Text="23:59" Background="#0F1117" Foreground="#FFFFFF" BorderBrush="#2A2D3A" Padding="6,4"/>
              <Button x:Name="ReportGenerate" Grid.Column="6" Style="{StaticResource PeriodBtn}" Content="Generate" Margin="14,0,0,0">
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
              <TextBlock x:Name="ReportEmpty" Text="Generate a report to see the breakdown." Foreground="#6B7280" HorizontalAlignment="Center" Margin="0,60,0,0" FontSize="13"/>
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
                      <TextBlock Text="REVENUE" Style="{StaticResource CardLabel}"/>
                      <TextBlock x:Name="RepRevenue" Style="{StaticResource BigValue}" FontSize="20"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="2" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="8" Padding="10">
                    <StackPanel>
                      <TextBlock Text="ORDERS" Style="{StaticResource CardLabel}"/>
                      <TextBlock x:Name="RepOrders" Style="{StaticResource BigValue}" FontSize="20" Foreground="#06B6D4"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="4" Background="#0F1117" BorderBrush="#2A2D3A" BorderThickness="1" CornerRadius="8" Padding="10">
                    <StackPanel>
                      <TextBlock Text="AVG TICKET" Style="{StaticResource CardLabel}"/>
                      <TextBlock x:Name="RepAvg" Style="{StaticResource BigValue}" FontSize="20"/>
                    </StackPanel>
                  </Border>
                </Grid>
                <TextBlock Text="PAYMENT BREAKDOWN" Style="{StaticResource CardLabel}" Margin="0,0,0,8"/>
                <TextBlock x:Name="RepPayments" Foreground="#D1D5DB" FontSize="13" Margin="0,0,0,16"/>
                <TextBlock Text="TOP ITEMS" Style="{StaticResource CardLabel}" Margin="0,0,0,8"/>
                <ItemsControl x:Name="RepItems" Margin="0,0,0,16">
                  <ItemsControl.ItemTemplate>
                    <DataTemplate>
                      <Grid Margin="0,3">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="{Binding Name}"  Foreground="#D1D5DB" FontSize="12"/>
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

# ─── PAGE SWITCHING ─────────────────────────────────────────────────────────
$script:activePage  = 'Dashboard'
$script:navButtons  = @{
    'Dashboard' = (ctl 'NavDashboard')
    'Analytics' = (ctl 'NavAnalytics')
    'Bills'     = (ctl 'NavBills')
    'Report'    = (ctl 'NavReport')
}
$script:pages = @{
    'Dashboard' = (ctl 'PageDashboard')
    'Analytics' = (ctl 'PageAnalytics')
    'Bills'     = (ctl 'PageBills')
    'Report'    = (ctl 'PageReport')
}

function Switch-Page($name) {
    foreach ($k in $script:pages.Keys) {
        if ($k -eq $name) {
            $script:pages[$k].Visibility = 'Visible'
            $script:navButtons[$k].Foreground = [System.Windows.Media.Brushes]::White
            $script:navButtons[$k].Background = [System.Windows.Media.Brushes]::'#1A1D29'
        } else {
            $script:pages[$k].Visibility = 'Collapsed'
            $script:navButtons[$k].Foreground = [System.Windows.Media.Brushes]::'#7A8295'
            $script:navButtons[$k].Background = [System.Windows.Media.Brushes]::Transparent
        }
    }
    $script:activePage = $name
    switch ($name) {
        'Analytics' { Update-Analytics-Page }
        'Bills'     { Update-Bills-Page }
        'Report'    { } # waits for Generate click
    }
}

(ctl 'NavDashboard').Add_Click({ Switch-Page 'Dashboard' })
(ctl 'NavAnalytics').Add_Click({ Switch-Page 'Analytics' })
(ctl 'NavBills').Add_Click(    { Switch-Page 'Bills' })
(ctl 'NavReport').Add_Click(   { Switch-Page 'Report' })

# Initial active style
Switch-Page 'Dashboard'

# ─── DASHBOARD: live log + status ──────────────────────────────────────────
$logBox       = ctl 'LogBox'
$logScroller  = ctl 'LogScroller'
$script:lastLogLines = ''

function Update-Log {
    if (-not (Test-Path $logPath)) { $logBox.Text = "(waiting for agent to start...)"; return }
    $tail = Get-Content $logPath -Tail 200 -ErrorAction SilentlyContinue
    if (-not $tail) { return }
    $text = ($tail -join "`n")
    if ($text -ne $script:lastLogLines) {
        $script:lastLogLines = $text
        $logBox.Text = $text
        $logScroller.ScrollToBottom()
    }
}

function Update-Status {
    try {
        $r = Invoke-RestMethod -Uri $statusUrl -TimeoutSec 1 -ErrorAction Stop
        (ctl 'StatusDot').Fill = [System.Windows.Media.Brushes]::LimeGreen
        (ctl 'StatusText').Text = 'Connected'
        (ctl 'VersionText').Text = "Print Agent v$($r.version)"
        if ($r.restaurant_name) { (ctl 'RestaurantName').Text = $r.restaurant_name }

        $printerInfo = '-'
        if ($r.printer) {
            if ($r.printer.mode -eq 'usb-direct')  { $printerInfo = 'OK  ' + $r.printer.usb + ' (USB direct)' }
            elseif ($r.printer.mode -eq 'usb-spooler') { $printerInfo = 'OK  ' + $r.printer.usb + ' (USB spooler)' }
            elseif ($r.printer.mode -eq 'network') { $printerInfo = 'OK  ' + $r.printer.ip + ':' + $r.printer.port }
            else { $printerInfo = 'Searching...' }
        }
        (ctl 'PrinterText').Text = $printerInfo
        (ctl 'TunnelText').Text = 'OK  print.lightmenu.app'

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

# ─── ANALYTICS PAGE ─────────────────────────────────────────────────────────
$script:activePeriod = 'today'

function Update-Analytics-Page {
    try {
        $r = Invoke-RestMethod -Uri "$base/local/stats?period=$($script:activePeriod)" -TimeoutSec 3 -ErrorAction Stop
        $script:currencySymbol = $r.currency
        (ctl 'AnaRevenue').Text = Format-Money $r.total_revenue
        (ctl 'AnaOrders').Text  = [string]$r.total_orders
        (ctl 'AnaAvg').Text     = Format-Money $r.avg_ticket
        if ($r.best_day) {
            (ctl 'AnaBest').Text = ($r.best_day + ' - ' + (Format-Money $r.best_amount))
        } else { (ctl 'AnaBest').Text = '--' }

        (ctl 'PayCashCount').Text  = [string]$r.payment.cash.count
        (ctl 'PayCashTotal').Text  = Format-Money $r.payment.cash.total
        (ctl 'PayCardCount').Text  = [string]$r.payment.card.count
        (ctl 'PayCardTotal').Text  = Format-Money $r.payment.card.total
        (ctl 'PayMixedCount').Text = [string]$r.payment.mixed.count
        (ctl 'PayMixedTotal').Text = Format-Money $r.payment.mixed.total

        Draw-Chart $r.daily
    } catch {
        (ctl 'AnaRevenue').Text = '--'
        (ctl 'AnaOrders').Text  = '--'
        (ctl 'AnaAvg').Text     = '--'
        (ctl 'AnaBest').Text    = '--'
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
    $gap = 12
    $barW = ($chartW - ($gap * ($barCount - 1))) / $barCount

    # Y-axis gridlines + labels
    for ($i = 0; $i -le 4; $i++) {
        $val = $max * $i / 4
        $y = $padT + $chartH - ($chartH * $i / 4)
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = $padL; $line.Y1 = $y; $line.X2 = $padL + $chartW; $line.Y2 = $y
        $line.Stroke = [System.Windows.Media.Brushes]::'#2A2D3A'
        $line.StrokeThickness = 1
        $canvas.Children.Add($line) | Out-Null
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = Format-Money $val
        $lbl.Foreground = [System.Windows.Media.Brushes]::'#7A8295'
        $lbl.FontSize = 9
        [System.Windows.Controls.Canvas]::SetLeft($lbl, 4)
        [System.Windows.Controls.Canvas]::SetTop($lbl, $y - 7)
        $canvas.Children.Add($lbl) | Out-Null
    }

    # Bars
    for ($i = 0; $i -lt $barCount; $i++) {
        $d = $daily[$i]
        $bh = ($d.revenue / $max) * $chartH
        if ($bh -lt 2 -and $d.revenue -gt 0) { $bh = 2 }
        $x = $padL + $i * ($barW + $gap)
        $y = $padT + $chartH - $bh
        $rect = New-Object System.Windows.Shapes.Rectangle
        $rect.Width = $barW
        $rect.Height = $bh
        $brush = New-Object System.Windows.Media.LinearGradientBrush
        $brush.StartPoint = New-Object System.Windows.Point(0, 0)
        $brush.EndPoint   = New-Object System.Windows.Point(0, 1)
        $stop1 = New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(20, 184, 166), 0)
        $stop2 = New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromRgb(6, 182, 212), 1)
        $brush.GradientStops.Add($stop1) | Out-Null
        $brush.GradientStops.Add($stop2) | Out-Null
        $rect.Fill = $brush
        $rect.RadiusX = 4
        $rect.RadiusY = 4
        [System.Windows.Controls.Canvas]::SetLeft($rect, $x)
        [System.Windows.Controls.Canvas]::SetTop($rect, $y)
        $canvas.Children.Add($rect) | Out-Null

        # X-axis label
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $d.label
        $lbl.Foreground = [System.Windows.Media.Brushes]::'#7A8295'
        $lbl.FontSize = 10
        $lbl.Width = $barW
        $lbl.TextAlignment = 'Center'
        [System.Windows.Controls.Canvas]::SetLeft($lbl, $x)
        [System.Windows.Controls.Canvas]::SetTop($lbl, $padT + $chartH + 6)
        $canvas.Children.Add($lbl) | Out-Null
    }
}

(ctl 'PeriodToday').Add_Click({   $script:activePeriod = 'today'; Update-Analytics-Page })
(ctl 'PeriodWeek').Add_Click({    $script:activePeriod = 'week';  Update-Analytics-Page })
(ctl 'PeriodMonth').Add_Click({   $script:activePeriod = 'month'; Update-Analytics-Page })
(ctl 'PeriodAll').Add_Click({     $script:activePeriod = 'all';   Update-Analytics-Page })
(ctl 'PeriodRefresh').Add_Click({ Update-Analytics-Page })

# ─── BILLS PAGE ─────────────────────────────────────────────────────────────
$script:billsData = @()
(ctl 'BillStart').SelectedDate = (Get-Date).AddDays(-7)
(ctl 'BillEnd').SelectedDate   = (Get-Date)

function Update-Bills-Page {
    try {
        $s = (ctl 'BillStart').SelectedDate
        $e = (ctl 'BillEnd').SelectedDate
        $qs = @()
        if ($s) { $qs += "start=$($s.ToString('yyyy-MM-dd'))" }
        if ($e) { $qs += "end=$($e.ToString('yyyy-MM-dd'))" }
        $url = "$base/local/bills" + $(if ($qs.Count) { '?' + ($qs -join '&') } else { '' })
        $bills = Invoke-RestMethod -Uri $url -TimeoutSec 5 -ErrorAction Stop
        if ($bills -isnot [System.Array]) { $bills = @($bills) }
        # Newest first
        $sorted = $bills | Sort-Object -Property date -Descending
        $rows = foreach ($b in $sorted) {
            $dt = try { [datetime]::Parse($b.date).ToString('MM/dd HH:mm') } catch { $b.date }
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

(ctl 'MenuReprint').Add_Click({
    $sel = (ctl 'BillList').SelectedItem
    if (-not $sel) { return }
    try {
        $body = @{ id = $sel.BillNum } | ConvertTo-Json
        Invoke-RestMethod -Uri "$base/local/reprint" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
        [System.Windows.MessageBox]::Show("Reprint sent: $($sel.BillNum)", 'LightMenu', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Reprint failed: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null
    }
})

# ─── DAILY REPORT PAGE ──────────────────────────────────────────────────────
(ctl 'ReportDate').SelectedDate = Get-Date

(ctl 'ReportGenerate').Add_Click({
    try {
        $d  = (ctl 'ReportDate').SelectedDate
        if (-not $d) { return }
        $st = (ctl 'ReportStart').Text
        $en = (ctl 'ReportEnd').Text
        $url = "$base/local/report?date=$($d.ToString('yyyy-MM-dd'))&start=$st&end=$en"
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 5 -ErrorAction Stop

        (ctl 'ReportEmpty').Visibility   = 'Collapsed'
        (ctl 'ReportResults').Visibility = 'Visible'
        (ctl 'ReportHeader').Text = "Report - $($r.date) ($($r.startTime) to $($r.endTime))"
        $sym = if ($script:currencySymbol) { $script:currencySymbol } else { 'EUR' }
        (ctl 'RepRevenue').Text = ('{0} {1:N2}' -f $sym, [double]$r.total_revenue)
        (ctl 'RepOrders').Text  = [string]$r.total_orders
        (ctl 'RepAvg').Text     = ('{0} {1:N2}' -f $sym, [double]$r.avg_ticket)
        (ctl 'RepPayments').Text = ('Cash: {0:N2}     Card: {1:N2}     Mixed: {2:N2}     Unpaid: {3:N2}' -f `
            [double]$r.payment.cash, [double]$r.payment.card, [double]$r.payment.mixed, [double]$r.payment.unpaid)

        $items = foreach ($it in $r.top_items) {
            [PSCustomObject]@{
                Name   = $it.name
                QtyStr = "x$($it.qty)"
                RevStr = ('{0} {1:N2}' -f $sym, [double]$it.revenue)
            }
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
    $dlg.Filter = 'Text files (*.txt)|*.txt'
    if ($dlg.ShowDialog()) {
        $r = $script:lastReport
        $sym = if ($script:currencySymbol) { $script:currencySymbol } else { 'EUR' }
        $txt = @()
        $txt += "LightMenu Daily Report"
        $txt += "======================"
        $txt += "Date:    $($r.date)"
        $txt += "Window:  $($r.startTime) - $($r.endTime)"
        $txt += ""
        $txt += "Revenue:  $sym $('{0:N2}' -f [double]$r.total_revenue)"
        $txt += "Orders:   $($r.total_orders)"
        $txt += "Average:  $sym $('{0:N2}' -f [double]$r.avg_ticket)"
        $txt += ""
        $txt += "Payment Breakdown"
        $txt += "  Cash:   $sym $('{0:N2}' -f [double]$r.payment.cash)"
        $txt += "  Card:   $sym $('{0:N2}' -f [double]$r.payment.card)"
        $txt += "  Mixed:  $sym $('{0:N2}' -f [double]$r.payment.mixed)"
        $txt += "  Unpaid: $sym $('{0:N2}' -f [double]$r.payment.unpaid)"
        $txt += ""
        $txt += "Top Items"
        foreach ($it in $r.top_items) {
            $txt += ("  x{0,-4} {1,-30} {2} {3:N2}" -f $it.qty, $it.name, $sym, [double]$it.revenue)
        }
        $txt -join "`r`n" | Set-Content -Path $dlg.FileName -Encoding UTF8
        [System.Windows.MessageBox]::Show("Report saved.", 'LightMenu', 'OK', 'Information') | Out-Null
    }
})

# ─── Buttons ────────────────────────────────────────────────────────────────
(ctl 'TestBtn').Add_Click({
    try {
        Invoke-RestMethod -Uri $rescanUrl -Method Post -TimeoutSec 10 -ErrorAction Stop | Out-Null
        [System.Windows.MessageBox]::Show("Rescan started. Check the live log for results.", 'LightMenu', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Rescan failed: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null
    }
})

(ctl 'RestartBtn').Add_Click({
    $result = [System.Windows.MessageBox]::Show("Restart the print agent now? Any in-flight prints will be retried.", 'LightMenu', 'YesNo', 'Question')
    if ($result -eq 'Yes') {
        Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
})

(ctl 'ClearBtn').Add_Click({ $logBox.Text = ''; $script:lastLogLines = '' })

# ─── Timers ─────────────────────────────────────────────────────────────────
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(2)
$statusTimer.Add_Tick({ Update-Status })
$statusTimer.Start()

$logTimer = New-Object System.Windows.Threading.DispatcherTimer
$logTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$logTimer.Add_Tick({ Update-Log })
$logTimer.Start()

# Refresh active analytics page every 10s while open
$analyticsTimer = New-Object System.Windows.Threading.DispatcherTimer
$analyticsTimer.Interval = [TimeSpan]::FromSeconds(10)
$analyticsTimer.Add_Tick({ if ($script:activePage -eq 'Analytics') { Update-Analytics-Page } })
$analyticsTimer.Start()

Update-Status
Update-Log

$window.ShowDialog() | Out-Null
