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
        [System.Windows.MessageBox]::Show("LightMenu UI failed to start.`n`n$($_.Exception.Message)`n`nDetails in ui-error.log", 'LightMenu Print Agent', 'OK', 'Error') | Out-Null
    } catch {}
    exit 1
}

[System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework') | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('PresentationCore')      | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('WindowsBase')           | Out-Null

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
        Title="LightMenu Print Agent" Height="820" Width="940"
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
      <Grid>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="NavDashboard"  Style="{StaticResource NavBtn}" Content="Dashboard"/>
          <Button x:Name="NavAnalytics"  Style="{StaticResource NavBtn}" Content="Analytics"    Margin="4,0,0,0"/>
          <Button x:Name="NavBills"      Style="{StaticResource NavBtn}" Content="Bills"        Margin="4,0,0,0"/>
          <Button x:Name="NavReport"     Style="{StaticResource NavBtn}" Content="Daily Report" Margin="4,0,0,0"/>
          <Button x:Name="NavStaff"      Style="{StaticResource NavBtn}" Content="Staff"        Margin="4,0,0,0"/>
        </StackPanel>
        <Button x:Name="LangBtn" HorizontalAlignment="Right" VerticalAlignment="Center"
                Style="{StaticResource NavBtn}" Content="EN" FontSize="11" FontWeight="Bold" Padding="10,6"/>
      </Grid>
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
              <TextBlock x:Name="LblPrinter" Text="PRINTER" Style="{StaticResource CardLabel}"/>
              <TextBlock x:Name="PrinterText" Text="--" Style="{StaticResource CardValue}"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardStyle}" Grid.Row="0" Grid.Column="2">
            <StackPanel>
              <TextBlock x:Name="LblTunnel" Text="TUNNEL" Style="{StaticResource CardLabel}"/>
              <TextBlock x:Name="TunnelText" Text="--" Style="{StaticResource CardValue}"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardStyle}" Grid.Row="2" Grid.Column="0">
            <StackPanel>
              <TextBlock x:Name="LblTodaySession" Text="TODAY (SESSION)" Style="{StaticResource CardLabel}"/>
              <TextBlock x:Name="StatsText" Text="--" Style="{StaticResource CardValue}"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource CardStyle}" Grid.Row="2" Grid.Column="2">
            <StackPanel>
              <TextBlock x:Name="LblLastUpdate" Text="LAST UPDATE" Style="{StaticResource CardLabel}"/>
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
              <TextBlock x:Name="LblLiveLog" Text="LIVE LOG" Style="{StaticResource CardLabel}" VerticalAlignment="Center"/>
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

# ─── HELPERS ────────────────────────────────────────────────────────────────
function SolidBrush($hex) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }

# ─── LANGUAGE SYSTEM ────────────────────────────────────────────────────────
$script:i18n = @{
    en = @{
        nav_dashboard='Dashboard'; nav_analytics='Analytics'; nav_bills='Bills'; nav_report='Daily Report'; nav_staff='Staff'
        lbl_printer='PRINTER'; lbl_tunnel='TUNNEL'; lbl_today_session='TODAY (SESSION)'; lbl_last_update='LAST UPDATE'; lbl_live_log='LIVE LOG'
        btn_rescan='Rescan Printers'; btn_restart='Restart Agent'; btn_clear='Clear'
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
        btn_remove='Remove'; btn_toggle='Toggle'; btn_copy_link='Copy link'
        confirm_remove='Remove this staff member?'; confirm_restart='Restart the print agent now? Any in-flight prints will be retried.'
        rescan_info='Rescan started. Check the live log for results.'
        no_staff='No staff added yet. Click "+ Add Staff" to get started.'
        dlg_add_staff_title='Add Staff Member'; dlg_ok='Add'; dlg_cancel='Cancel'
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
    }
}
$script:langCycle = @('en','fr','ar')

function T($key) {
    $d = $script:i18n[$script:lang]
    if ($d -and $d.ContainsKey($key)) { return $d[$key] }
    $d2 = $script:i18n['en']
    if ($d2 -and $d2.ContainsKey($key)) { return $d2[$key] }
    return $key
}

function Apply-Language {
    $rtl = ($script:lang -eq 'ar')
    $window.FlowDirection = if ($rtl) { 'RightToLeft' } else { 'LeftToRight' }

    # Nav
    (ctl 'NavDashboard').Content = T 'nav_dashboard'
    (ctl 'NavAnalytics').Content = T 'nav_analytics'
    (ctl 'NavBills').Content     = T 'nav_bills'
    (ctl 'NavReport').Content    = T 'nav_report'
    (ctl 'NavStaff').Content     = T 'nav_staff'
    (ctl 'LangBtn').Content      = $script:lang.ToUpper()

    # Dashboard labels
    (ctl 'LblPrinter').Text      = T 'lbl_printer'
    (ctl 'LblTunnel').Text       = T 'lbl_tunnel'
    (ctl 'LblTodaySession').Text = T 'lbl_today_session'
    (ctl 'LblLastUpdate').Text   = T 'lbl_last_update'
    (ctl 'LblLiveLog').Text      = T 'lbl_live_log'
    (ctl 'ClearBtn').Content     = T 'btn_clear'
    (ctl 'TestBtn').Content      = T 'btn_rescan'
    (ctl 'RestartBtn').Content   = T 'btn_restart'

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

(ctl 'LangBtn').Add_Click({
    $idx = $script:langCycle.IndexOf($script:lang)
    $script:lang = $script:langCycle[($idx + 1) % $script:langCycle.Count]
    Apply-Language
    Set-Active-Period $script:activePeriod
})

# ─── PAGE SWITCHING ─────────────────────────────────────────────────────────
$script:activePage  = 'Dashboard'
$script:navButtons  = @{
    'Dashboard' = (ctl 'NavDashboard')
    'Analytics' = (ctl 'NavAnalytics')
    'Bills'     = (ctl 'NavBills')
    'Report'    = (ctl 'NavReport')
    'Staff'     = (ctl 'NavStaff')
}
$script:pages = @{
    'Dashboard' = (ctl 'PageDashboard')
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
    switch ($name) {
        'Analytics' { Update-Analytics-Page }
        'Bills'     { Update-Bills-Page }
        'Staff'     { Update-Staff-Page }
        'Report'    { }
    }
}

(ctl 'NavDashboard').Add_Click({ Switch-Page 'Dashboard' })
(ctl 'NavAnalytics').Add_Click({ Switch-Page 'Analytics' })
(ctl 'NavBills').Add_Click(    { Switch-Page 'Bills' })
(ctl 'NavReport').Add_Click(   { Switch-Page 'Report' })
(ctl 'NavStaff').Add_Click(    { Switch-Page 'Staff' })

# ─── DASHBOARD: live log + status ───────────────────────────────────────────
$logBox      = ctl 'LogBox'
$logScroller = ctl 'LogScroller'
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
            if     ($r.printer.mode -eq 'usb-direct')   { $printerInfo = 'OK  ' + $r.printer.usb + ' (USB direct)' }
            elseif ($r.printer.mode -eq 'usb-spooler')  { $printerInfo = 'OK  ' + $r.printer.usb + ' (USB spooler)' }
            elseif ($r.printer.mode -eq 'network')      { $printerInfo = 'OK  ' + $r.printer.ip + ':' + $r.printer.port }
            else                                         { $printerInfo = 'Searching...' }
        }
        (ctl 'PrinterText').Text = $printerInfo
        (ctl 'TunnelText').Text  = 'OK  print.lightmenu.app'

        $p = if ($r.printed) { $r.printed } else { 0 }
        $f = if ($r.failed)  { $r.failed }  else { 0 }
        (ctl 'StatsText').Text  = ($p.ToString() + ' printed   -   ' + $f.ToString() + ' failed')
        (ctl 'UpdateText').Text = ('v' + $r.version + ' - checked ' + (Get-Date -Format 'HH:mm'))
    } catch {
        (ctl 'StatusDot').Fill  = [System.Windows.Media.Brushes]::Crimson
        (ctl 'StatusText').Text = 'Disconnected'
        (ctl 'PrinterText').Text = '-'
        (ctl 'TunnelText').Text  = '-'
        (ctl 'StatsText').Text   = '-'
        (ctl 'UpdateText').Text  = ('checked ' + (Get-Date -Format 'HH:mm'))
    }
}

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

function Update-Analytics-Page {
    try {
        $r = Invoke-RestMethod -Uri "$base/local/stats?period=$($script:activePeriod)" -TimeoutSec 3 -ErrorAction Stop
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

function Get-RoleColor($role) {
    switch -Wildcard ($role) {
        '*anager*' { return '#8B5CF6' }
        '*hef*'    { return '#F59E0B' }
        '*ashier*' { return '#10B981' }
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
    $card.Width         = 280

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

    $dotColor = if ($member.active) { '#22C55E' } else { '#6B7280' }
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
    $roleColor  = Get-RoleColor $member.role
    $roleBorder.Background  = SolidBrush ($roleColor + '33')
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
    $copyBtn.Content = [char]0x2398; $copyBtn.FontSize = 13; $copyBtn.Margin = New-Object System.Windows.Thickness(6,0,0,0)
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

    # Action buttons
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'; $btnRow.Margin = New-Object System.Windows.Thickness(0,12,0,0)

    $makeSmallBtn = {
        param($content, $color, $memberId)
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $content; $b.FontSize = 11; $b.Cursor = 'Hand'
        $b.Background = SolidBrush ($color + '22'); $b.Foreground = SolidBrush $color
        $b.BorderBrush = SolidBrush ($color + '55'); $b.BorderThickness = New-Object System.Windows.Thickness(1)
        $b.Padding = New-Object System.Windows.Thickness(10,4,10,4)
        $b.Margin = New-Object System.Windows.Thickness(0,0,6,0)
        $b.Tag = $memberId
        return $b
    }

    $removeBtn = & $makeSmallBtn (T 'btn_remove') '#EF4444' $member.id
    $removeBtn.Add_Click({
        $mid = $this.Tag
        $res = [System.Windows.MessageBox]::Show((T 'confirm_remove'), 'LightMenu', 'YesNo', 'Question')
        if ($res -eq 'Yes') {
            try {
                Invoke-RestMethod -Uri "$base/local/staff/$([System.Uri]::EscapeDataString($mid))" -Method Delete -TimeoutSec 5 -ErrorAction Stop | Out-Null
                Update-Staff-Page
            } catch { [System.Windows.MessageBox]::Show("Failed: $($_.Exception.Message)", 'LightMenu', 'OK', 'Warning') | Out-Null }
        }
    })
    $btnRow.Children.Add($removeBtn) | Out-Null

    $card.Child = $sp
    $sp.Children.Add($btnRow) | Out-Null
    return $card
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
    [xml]$dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="290" Width="380" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        Background="#0F1117" TextElement.Foreground="#FFFFFF">
  <StackPanel Margin="24">
    <TextBlock x:Name="DlgTitle" Text="Add Staff Member" FontSize="15" FontWeight="Bold" Margin="0,0,0,18"/>
    <TextBlock x:Name="DlgNameLbl" Text="Name" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,0,0,6"/>
    <TextBox x:Name="DlgName" Background="#1A1D29" BorderBrush="#2A2D3A" Foreground="#FFFFFF" Padding="8,6" FontSize="13"/>
    <TextBlock x:Name="DlgRoleLbl" Text="Role" Foreground="#9CA3AF" FontSize="11" FontWeight="Bold" Margin="0,14,0,6"/>
    <ComboBox x:Name="DlgRole" Background="#1A1D29" BorderBrush="#2A2D3A" Foreground="#FFFFFF" Padding="6,4" FontSize="13" SelectedIndex="0">
      <ComboBoxItem Content="Waiter"/>
      <ComboBoxItem Content="Manager"/>
      <ComboBoxItem Content="Chef"/>
      <ComboBoxItem Content="Cashier"/>
    </ComboBox>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
      <Button x:Name="DlgCancel" Padding="16,8" Background="#2A2D3A" Foreground="#FFFFFF"
              BorderThickness="0" Cursor="Hand" Margin="0,0,10,0" FontSize="13"/>
      <Button x:Name="DlgOk" Padding="16,8" BorderThickness="0" Cursor="Hand" Foreground="#FFFFFF" FontSize="13" FontWeight="SemiBold">
        <Button.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#14B8A6" Offset="0"/>
            <GradientStop Color="#06B6D4" Offset="1"/>
          </LinearGradientBrush>
        </Button.Background>
      </Button>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $r2   = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlg  = [Windows.Markup.XamlReader]::Load($r2)
    $dlg.Owner = $window
    $dlg.Title = T 'dlg_add_staff_title'
    $dlg.FindName('DlgTitle').Text   = T 'dlg_add_staff_title'
    $dlg.FindName('DlgNameLbl').Text = T 'lbl_staff_name'
    $dlg.FindName('DlgRoleLbl').Text = T 'lbl_staff_role'
    $dlg.FindName('DlgCancel').Content = T 'dlg_cancel'
    $dlg.FindName('DlgOk').Content     = T 'dlg_ok'
    $script:dlgResult = $null

    $dlg.FindName('DlgCancel').Add_Click({ $dlg.Close() })
    $dlg.FindName('DlgOk').Add_Click({
        $name = $dlg.FindName('DlgName').Text.Trim()
        if ($name -eq '') { return }
        $roleItem = $dlg.FindName('DlgRole').SelectedItem
        $role = if ($roleItem) { $roleItem.Content } else { 'Waiter' }
        $script:dlgResult = @{ name = $name; role = $role }
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

$analyticsTimer = New-Object System.Windows.Threading.DispatcherTimer
$analyticsTimer.Interval = [TimeSpan]::FromSeconds(10)
$analyticsTimer.Add_Tick({ if ($script:activePage -eq 'Analytics') { Update-Analytics-Page } })
$analyticsTimer.Start()

# ─── Initial state ──────────────────────────────────────────────────────────
Apply-Language
Switch-Page 'Dashboard'
Set-Active-Period 'today'
Update-Status
Update-Log

$window.ShowDialog() | Out-Null
