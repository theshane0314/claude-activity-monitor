Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @'
public class ActEvent {
    public string Time { get; set; }
    public string Sid { get; set; }
    public string Ev { get; set; }
    public string Tool { get; set; }
    public string Detail { get; set; }
    public string Kind { get; set; }
    public System.Windows.Media.Brush Brush { get; set; }
    public string Tip { get; set; }
}
'@

$dir = Join-Path $env:LOCALAPPDATA 'ClaudeActivityMonitor'
$log = Join-Path $dir 'activity.jsonl'
$projRoot = Join-Path $env:USERPROFILE '.claude\projects'
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $log)) { New-Item -ItemType File -Path $log | Out-Null }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Activity Monitor" Width="720" Height="900" MinWidth="480" MinHeight="420"
        Background="#0F1115" Foreground="#C8CDD8" FontFamily="Segoe UI" FontSize="12">
  <Window.Resources>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="#151923"/>
      <Setter Property="Foreground" Value="#8A93A6"/>
      <Setter Property="BorderBrush" Value="#242B3A"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#1A1F2B"/>
      <Setter Property="Foreground" Value="#C8CDD8"/>
      <Setter Property="BorderBrush" Value="#2A3244"/>
      <Setter Property="Padding" Value="8,3"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1A1F2B"/>
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="BorderBrush" Value="#2A3244"/>
      <Setter Property="Padding" Value="4,3"/>
      <Setter Property="CaretBrush" Value="#E6EAF2"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#1A1F2B"/>
      <Setter Property="Foreground" Value="#1A1F2B"/>
      <Setter Property="BorderBrush" Value="#2A3244"/>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="#0F1115"/>
      <Setter Property="BorderBrush" Value="#242B3A"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#C8CDD8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="#151923" BorderBrush="#2A3244" BorderThickness="1,1,1,0" CornerRadius="4,4,0,0" Padding="10,4" Margin="0,0,2,0">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#232B3B"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3A4560"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,8">
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Left" VerticalAlignment="Center">
        <Ellipse x:Name="LiveDot" Width="10" Height="10" Fill="#9ECE6A" VerticalAlignment="Center"/>
        <TextBlock Text=" CLAUDE ACTIVITY MONITOR" FontWeight="Bold" FontSize="14" Foreground="#E6EAF2" VerticalAlignment="Center" Margin="6,0,0,0"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right">
        <CheckBox x:Name="ChkTop" Content="pin on top" Foreground="#C8CDD8" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <Button x:Name="BtnPause" Content="pause" Width="56" Margin="0,0,6,0"/>
        <Button x:Name="BtnClear" Content="clear" Width="56"/>
      </StackPanel>
    </DockPanel>

    <Border Grid.Row="1" x:Name="TokBorder" Background="#12161F" BorderBrush="#2A3244" BorderThickness="1" CornerRadius="4" Padding="8,5" Margin="0,0,0,8">
      <TextBlock x:Name="TokText" Foreground="#7DCFFF" FontSize="11" Text="tokens: scanning transcripts..."/>
    </Border>

    <TabControl Grid.Row="2" x:Name="Tabs">
      <TabItem Header="activity">
        <Grid Margin="6">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,6">
            <ComboBox x:Name="CmbType" Width="120" DockPanel.Dock="Right" Margin="6,0,0,0" SelectedIndex="0">
              <ComboBoxItem Content="all events"/>
              <ComboBoxItem Content="commands"/>
              <ComboBoxItem Content="files"/>
              <ComboBoxItem Content="search"/>
              <ComboBoxItem Content="web"/>
              <ComboBoxItem Content="agents"/>
              <ComboBoxItem Content="prompts"/>
              <ComboBoxItem Content="alerts"/>
              <ComboBoxItem Content="errors"/>
              <ComboBoxItem Content="sessions"/>
              <ComboBoxItem Content="detached"/>
            </ComboBox>
            <TextBox x:Name="FilterBox"/>
          </DockPanel>
          <Border Grid.Row="1" x:Name="RunBorder" Background="#12161F" BorderBrush="#2A3244" BorderThickness="1" CornerRadius="4" Padding="6" Margin="0,0,0,6" Visibility="Collapsed">
            <StackPanel>
              <TextBlock Text="NOW RUNNING" Foreground="#E0AF68" FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
              <ItemsControl x:Name="RunPanel">
                <ItemsControl.ItemsPanel>
                  <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
                </ItemsControl.ItemsPanel>
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Background="#2A2416" BorderBrush="#E0AF68" BorderThickness="1" CornerRadius="3" Padding="6,2" Margin="0,0,6,4">
                      <TextBlock Text="{Binding}" Foreground="#E0AF68" FontSize="11"/>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </Border>
          <ListView Grid.Row="2" x:Name="Lv" Background="#0F1115" BorderBrush="#242B3A" BorderThickness="1"
                    VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling"
                    ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListView.ItemContainerStyle>
              <Style TargetType="ListViewItem">
                <Setter Property="Foreground" Value="{Binding Brush}"/>
                <Setter Property="ToolTip" Value="{Binding Tip}"/>
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="BorderThickness" Value="0"/>
                <Setter Property="Padding" Value="2,1"/>
                <Style.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#1A1F2B"/>
                  </Trigger>
                  <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#242B3A"/>
                  </Trigger>
                </Style.Triggers>
              </Style>
            </ListView.ItemContainerStyle>
            <ListView.View>
              <GridView>
                <GridViewColumn Header="time" Width="62" DisplayMemberBinding="{Binding Time}"/>
                <GridViewColumn Header="sess" Width="58" DisplayMemberBinding="{Binding Sid}"/>
                <GridViewColumn Header="event" Width="64" DisplayMemberBinding="{Binding Ev}"/>
                <GridViewColumn Header="tool" Width="112" DisplayMemberBinding="{Binding Tool}"/>
                <GridViewColumn Header="detail" Width="340" DisplayMemberBinding="{Binding Detail}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </Grid>
      </TabItem>
      <TabItem Header="detached">
        <Grid Margin="6">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="110"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="DETACHED CLAUDE PROCESSES" Foreground="#FF9E64" FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
          <ListBox Grid.Row="1" x:Name="ProcList" Background="#12161F" Foreground="#FF9E64" BorderBrush="#2A3244" FontFamily="Consolas" FontSize="11"/>
          <DockPanel Grid.Row="2" Margin="0,8,0,6">
            <TextBlock Text="tail log:  " Foreground="#8A93A6" VerticalAlignment="Center"/>
            <ComboBox x:Name="LogCombo"/>
          </DockPanel>
          <TextBox Grid.Row="3" x:Name="TailBox" IsReadOnly="True" Background="#0B0D12" Foreground="#9ECE6A" BorderBrush="#2A3244"
                   FontFamily="Consolas" FontSize="11" TextWrapping="NoWrap" AcceptsReturn="True"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
        </Grid>
      </TabItem>
      <TabItem Header="monitors">
        <Grid Margin="6">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="130"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="JOB MONITORS (ClaudeProjects\monitors)" Foreground="#9ECE6A" FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
          <ListBox Grid.Row="1" x:Name="MonList" Background="#12161F" Foreground="#9ECE6A" BorderBrush="#2A3244" FontFamily="Consolas" FontSize="11"/>
          <TextBox Grid.Row="2" x:Name="MonTail" IsReadOnly="True" Background="#0B0D12" Foreground="#9ECE6A" BorderBrush="#2A3244"
                   FontFamily="Consolas" FontSize="11" TextWrapping="NoWrap" AcceptsReturn="True"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="0,6,0,0"/>
        </Grid>
      </TabItem>
    </TabControl>

    <DockPanel Grid.Row="3" Margin="0,6,0,0">
      <TextBlock x:Name="StatusText" Foreground="#8A93A6" FontSize="11"/>
    </DockPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)

foreach ($n in @('LiveDot', 'ChkTop', 'BtnPause', 'BtnClear', 'TokBorder', 'TokText', 'Tabs', 'CmbType', 'FilterBox', 'RunBorder', 'RunPanel', 'Lv', 'ProcList', 'LogCombo', 'TailBox', 'StatusText', 'MonList', 'MonTail')) {
    Set-Variable -Name $n -Value $win.FindName($n)
}

$wa = [System.Windows.SystemParameters]::WorkArea
$win.Left = $wa.Right - $win.Width - 16
$win.Top = $wa.Top + 16

$items = New-Object 'System.Collections.ObjectModel.ObservableCollection[ActEvent]'
$Lv.ItemsSource = $items
$view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($items)

$script:pos = 0
$script:paused = $false
$script:running = @{}
$script:sids = @{}
$script:total = 0
$script:tick = 0
$script:consoles = @{}
$script:tailPath = $null
$script:tailPos = 0
$script:lastTok = ''
$script:lastDetStamp = -1
$script:monDir = Join-Path $env:USERPROFILE 'ClaudeProjects\monitors'
$script:monData = @()
$script:monLines = ''
$script:monTailPath = $null
$script:monTailPos = [long]0
$script:monAutoSelected = $false

function New-Brush($hex) {
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
    $b.Freeze()
    return $b
}

$brushes = @{
    run     = New-Brush '#E0AF68'
    done    = New-Brush '#9ECE6A'
    err     = New-Brush '#F7768E'
    prompt  = New-Brush '#7AA2F7'
    notify  = New-Brush '#BB9AF7'
    session = New-Brush '#6B7488'
    agent   = New-Brush '#7DCFFF'
    det     = New-Brush '#FF9E64'
}
$cbr = @{
    user   = New-Brush '#7AA2F7'
    claude = New-Brush '#DDE3EE'
    dim    = New-Brush '#565F73'
    tool   = New-Brush '#E0AF68'
    out    = New-Brush '#89B15C'
    err    = New-Brush '#F7768E'
}

function Get-Kind($ev, $tool) {
    switch ($ev) {
        'UserPromptSubmit' { return 'prompt' }
        'Notification' { return 'notify' }
        'PermissionRequest' { return 'notify' }
        'PermissionDenied' { return 'err' }
        'PostToolUseFailure' { return 'err' }
        'Stop' { return 'session' }
        'StopFailure' { return 'err' }
        'SessionStart' { return 'session' }
        'SessionEnd' { return 'session' }
        'PreCompact' { return 'session' }
        'PostCompact' { return 'session' }
        'SubagentStart' { return 'agent' }
        'SubagentStop' { return 'agent' }
        'DetachedStart' { return 'det' }
        'DetachedEnd' { return 'det' }
    }
    if ($tool -match '^(Bash|PowerShell)$') { return 'cmd' }
    if ($tool -match '^(Read|Edit|Write|NotebookEdit|MultiEdit)$') { return 'file' }
    if ($tool -match '^(Glob|Grep)$') { return 'search' }
    if ($tool -match '^(WebSearch|WebFetch)$') { return 'web' }
    if ($tool -match '^(Agent|Task)') { return 'agent' }
    return 'tool'
}

function Get-EvLabel($ev) {
    switch ($ev) {
        'PreToolUse' { return 'run' }
        'PostToolUse' { return 'done' }
        'PostToolUseFailure' { return 'FAIL' }
        'UserPromptSubmit' { return 'prompt' }
        'Notification' { return 'alert' }
        'PermissionRequest' { return 'perm?' }
        'PermissionDenied' { return 'denied' }
        'Stop' { return 'idle' }
        'StopFailure' { return 'FAIL' }
        'SessionStart' { return 'start' }
        'SessionEnd' { return 'end' }
        'SubagentStart' { return 'agent+' }
        'SubagentStop' { return 'agent-' }
        'PreCompact' { return 'compact' }
        'PostCompact' { return 'compctd' }
        'DetachedStart' { return 'spawn' }
        'DetachedEnd' { return 'ended' }
    }
    return $ev
}

function Get-EvBrush($ev, $kind) {
    if ($kind -eq 'det') { return $brushes.det }
    if ($ev -eq 'PreToolUse') { return $brushes.run }
    if ($ev -eq 'PostToolUse') { return $brushes.done }
    if ($kind -eq 'err') { return $brushes.err }
    if ($kind -eq 'prompt') { return $brushes.prompt }
    if ($kind -eq 'notify') { return $brushes.notify }
    if ($kind -eq 'agent') { return $brushes.agent }
    if ($kind -eq 'session') { return $brushes.session }
    return $brushes.done
}

function Add-Rec($r) {
    $ev = [string]$r.ev
    $tool = [string]$r.tool
    $kind = Get-Kind $ev $tool
    $t = ''
    try { $t = ([datetime]$r.ts).ToString('HH:mm:ss') } catch { }
    $sid = [string]$r.sid
    if ($sid) { $script:sids[$sid] = $true }
    $detail = [string]$r.detail

    $key = "$sid|$tool|$detail"
    if ($ev -eq 'PreToolUse') {
        $label = $tool
        if ($detail) { $label = "$tool  $(if ($detail.Length -gt 46) { $detail.Substring(0,46) + '...' } else { $detail })" }
        $script:running[$key] = $label
    }
    elseif ($ev -in @('PostToolUse', 'PostToolUseFailure')) {
        $script:running.Remove($key)
    }
    elseif ($ev -in @('Stop', 'SessionEnd')) {
        $stale = @($script:running.Keys | Where-Object { $_ -like "$sid|*" })
        foreach ($k in $stale) { $script:running.Remove($k) }
    }

    $it = New-Object ActEvent
    $it.Time = $t
    $it.Sid = $sid
    $it.Ev = Get-EvLabel $ev
    $it.Tool = $tool
    $it.Detail = $detail
    $it.Kind = $kind
    $it.Brush = Get-EvBrush $ev $kind
    $it.Tip = "$ev  ($($r.cwd))`n$detail"
    $items.Add($it)
    $script:total++
    while ($items.Count -gt 3000) { $items.RemoveAt(0) }
}

function Read-FileChunk($path, $posRef) {
    $chunk = ''
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            if ($fs.Length -lt $posRef.Value) { $posRef.Value = 0 }
            if ($fs.Length -eq $posRef.Value) { return '' }
            $null = $fs.Seek($posRef.Value, [System.IO.SeekOrigin]::Begin)
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $chunk = $sr.ReadToEnd()
            $newPos = $fs.Length
        }
        finally { $fs.Dispose() }
    }
    catch { return '' }
    if (-not $chunk) { return '' }
    $lastNl = $chunk.LastIndexOf("`n")
    if ($lastNl -lt 0) { return '' }
    if ($lastNl -lt ($chunk.Length - 1)) {
        $tail = $chunk.Substring($lastNl + 1)
        $newPos -= [System.Text.Encoding]::UTF8.GetByteCount($tail)
        $chunk = $chunk.Substring(0, $lastNl + 1)
    }
    $posRef.Value = $newPos
    return $chunk
}

function Read-New {
    $chunk = Read-FileChunk $log ([ref]$script:pos)
    if (-not $chunk) { return }
    $added = $false
    foreach ($ln in ($chunk -split "`n")) {
        $ln = $ln.Trim()
        if (-not $ln) { continue }
        try { Add-Rec (ConvertFrom-Json $ln); $added = $true } catch { }
    }
    if ($added -and -not $script:paused -and $items.Count -gt 0) {
        $Lv.ScrollIntoView($items[$items.Count - 1])
    }
    if ($added) { Update-Chrome }
}

function Update-Chrome {
    if ($script:running.Count -gt 0) {
        $RunPanel.ItemsSource = @($script:running.Values)
        $RunBorder.Visibility = 'Visible'
        $LiveDot.Fill = $brushes.run
    }
    else {
        $RunBorder.Visibility = 'Collapsed'
        $LiveDot.Fill = $brushes.done
    }
    $StatusText.Text = "$($script:total) events  ·  $($script:sids.Count) sessions  ·  $($script:consoles.Count) consoles  ·  $log"
}

function Apply-Filter {
    $txt = $FilterBox.Text
    $sel = $CmbType.SelectedIndex
    $kindMap = @($null, 'cmd', 'file', 'search', 'web', 'agent', 'prompt', 'notify', 'err', 'session', 'det')
    $wantKind = $null
    if ($sel -ge 1 -and $sel -lt $kindMap.Count) { $wantKind = $kindMap[$sel] }
    $view.Filter = [Predicate[object]] {
        param($o)
        if ($wantKind -and $o.Kind -ne $wantKind) { return $false }
        if ($txt) {
            $hay = "$($o.Tool) $($o.Detail) $($o.Sid) $($o.Ev)"
            if ($hay.IndexOf($txt, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        }
        return $true
    }.GetNewClosure()
}

function TruncD($s, $n) {
    if ($null -eq $s) { return '' }
    $s = [string]$s
    if ($s.Length -gt $n) { return $s.Substring(0, $n) + "`n... (truncated)" }
    return $s
}

function Get-InputSummary($ti) {
    if ($null -eq $ti) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('description', 'command', 'file_path', 'notebook_path', 'pattern', 'query', 'url', 'skill', 'prompt', 'message', 'title')) {
        $p = $ti.PSObject.Properties[$k]
        if ($p -and $p.Value -and $p.Value -is [string]) {
            $v = ($p.Value -replace '\s+', ' ').Trim()
            if ($v.Length -gt 200) { $v = $v.Substring(0, 200) + '...' }
            $parts.Add($v)
        }
    }
    if ($parts.Count -eq 0) {
        try {
            $v = ConvertTo-Json $ti -Compress -Depth 2
            if ($v.Length -gt 200) { $v = $v.Substring(0, 200) + '...' }
            $parts.Add($v)
        } catch { }
    }
    return ($parts -join ' | ')
}

function Add-Con($st, $text, $colorKey) {
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness(0)
    $lines = $text -split "`n"
    $n = [Math]::Min($lines.Count, 40)
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -gt 0) { $p.Inlines.Add((New-Object System.Windows.Documents.LineBreak)) }
        $r = New-Object System.Windows.Documents.Run($lines[$i].TrimEnd())
        $r.Foreground = $cbr[$colorKey]
        $p.Inlines.Add($r)
    }
    if ($lines.Count -gt 40) {
        $p.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
        $r2 = New-Object System.Windows.Documents.Run("      ... (+$($lines.Count - 40) more lines)")
        $r2.Foreground = $cbr.dim
        $p.Inlines.Add($r2)
    }
    $doc = $st.rtb.Document
    $doc.Blocks.Add($p)
    while ($doc.Blocks.Count -gt 350) { $doc.Blocks.Remove($doc.Blocks.FirstBlock) }
}

function Indent($s) {
    return '  ' + (($s -split "`n") -join "`n  ")
}

function Render-TLine($st, $ln) {
    $o = $null
    try { $o = ConvertFrom-Json $ln } catch { return }
    if ($null -eq $o -or -not $o.type) { return }
    $pref = ''
    if ($o.isSidechain) { $pref = '[agent] ' }
    if ($o.type -eq 'user') {
        $c = $o.message.content
        if ($c -is [string]) {
            if ($c.Trim()) { Add-Con $st ("you> " + (TruncD $c 800)) 'user' }
            return
        }
        foreach ($it in $c) {
            if ($it.type -eq 'tool_result') {
                $txt = ''
                if ($it.content -is [string]) { $txt = $it.content }
                else {
                    foreach ($cc in $it.content) { if ($cc.type -eq 'text') { $txt += $cc.text + "`n" } }
                }
                $ck = 'out'
                if ($it.is_error) { $ck = 'err' }
                if ($txt.Trim()) { Add-Con $st (Indent (TruncD $txt.Trim() 2000)) $ck }
            }
            elseif ($it.type -eq 'text') {
                if ($it.text.Trim()) { Add-Con $st ("you> " + (TruncD $it.text 800)) 'user' }
            }
        }
    }
    elseif ($o.type -eq 'assistant') {
        foreach ($it in $o.message.content) {
            if ($it.type -eq 'thinking') {
                if ($it.thinking) { Add-Con $st ($pref + 'thinking> ' + (TruncD $it.thinking 600)) 'dim' }
            }
            elseif ($it.type -eq 'text') {
                if ($it.text) { Add-Con $st ($pref + 'claude> ' + (TruncD $it.text 1500)) 'claude' }
            }
            elseif ($it.type -eq 'tool_use') {
                Add-Con $st ($pref + '[' + $it.name + '] ' + (Get-InputSummary $it.input)) 'tool'
            }
        }
    }
}

function Read-Transcript($st) {
    $chunk = Read-FileChunk $st.path ([ref]$st.pos)
    if (-not $chunk) { return }
    $any = $false
    foreach ($ln in ($chunk -split "`n")) {
        $ln = $ln.Trim()
        if (-not $ln) { continue }
        Render-TLine $st $ln
        $any = $true
    }
    if ($any -and -not $script:paused) { $st.rtb.ScrollToEnd() }
}

function New-SessionTab($sid, $path) {
    $rtb = New-Object System.Windows.Controls.RichTextBox
    $rtb.IsReadOnly = $true
    $rtb.IsUndoEnabled = $false
    $rtb.Background = New-Brush '#0B0D12'
    $rtb.Foreground = $cbr.claude
    $rtb.BorderThickness = New-Object System.Windows.Thickness(0)
    $rtb.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $rtb.FontSize = 11
    $rtb.VerticalScrollBarVisibility = 'Auto'
    $rtb.Document.Blocks.Clear()

    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = $sid
    $tab.ToolTip = $path
    $tab.Content = $rtb
    $Tabs.Items.Insert($Tabs.Items.Count - 1, $tab)

    $st = @{ rtb = $rtb; path = $path; pos = [long]0 }
    try {
        $fi = Get-Item -LiteralPath $path
        $st.pos = [Math]::Max(0, $fi.Length - 262144)
    } catch { }
    Add-Con $st ("=== tailing $path ===") 'dim'
    $chunk = Read-FileChunk $st.path ([ref]$st.pos)
    if ($chunk) {
        $lines = @(($chunk -split "`n") | Where-Object { $_.Trim() })
        $start = 0
        if ($st.pos -gt 262144) { $start = 1 }
        $from = [Math]::Max($start, $lines.Count - 80)
        for ($i = $from; $i -lt $lines.Count; $i++) { Render-TLine $st $lines[$i] }
    }
    $rtb.ScrollToEnd()
    $script:consoles[$sid] = $st
}

function Sync-SessionTabs {
    $cutT = (Get-Date).AddMinutes(-30)
    $files = Get-ChildItem -LiteralPath $projRoot -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cutT -and $_.FullName -notmatch '\\memory\\' }
    foreach ($f in $files) {
        $sid = [System.IO.Path]::GetFileNameWithoutExtension($f.FullName)
        if ($sid.Length -gt 8) { $sid = $sid.Substring(0, 8) }
        if (-not $script:consoles.ContainsKey($sid)) {
            New-SessionTab $sid $f.FullName
        }
    }
}

function Sync-Monitors {
    if (-not (Test-Path -LiteralPath $script:monDir)) { return }
    $entries = @()
    foreach ($f in (Get-ChildItem -LiteralPath $script:monDir -Filter *.monitor.json -File -ErrorAction SilentlyContinue)) {
        $m = $null
        try { $m = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $m -or -not $m.name) { continue }
        $status = 'no log'
        $mtime = [datetime]::MinValue
        if ($m.log -and (Test-Path -LiteralPath $m.log)) {
            $mtime = (Get-Item -LiteralPath $m.log).LastWriteTime
            $age = (Get-Date) - $mtime
            if ($age.TotalMinutes -le 2) { $status = 'RUNNING' }
            elseif ($age.TotalHours -ge 24) { $status = ('idle {0}d' -f [int]$age.TotalDays) }
            elseif ($age.TotalHours -ge 1) { $status = ('idle {0:N1}h' -f $age.TotalHours) }
            else { $status = ('idle {0}m' -f [int]$age.TotalMinutes) }
        }
        $desc = ''
        if ($m.description) { $desc = [string]$m.description }
        $entries += [pscustomobject]@{
            Name = [string]$m.name; Log = [string]$m.log; Mtime = $mtime; Running = ($status -eq 'RUNNING')
            Line = ('{0,-8} {1,-22} {2}' -f $status, $m.name, $desc)
        }
    }
    $entries = @($entries | Sort-Object @{e='Running';Descending=$true}, @{e='Mtime';Descending=$true})
    $lines = ($entries | ForEach-Object { $_.Line }) -join "`n"
    if ($lines -ne $script:monLines) {
        $script:monLines = $lines
        $selName = $null
        $i = $MonList.SelectedIndex
        if ($i -ge 0 -and $i -lt $script:monData.Count) { $selName = $script:monData[$i].Name }
        $script:monData = $entries
        $MonList.ItemsSource = @($entries | ForEach-Object { $_.Line })
        if ($selName) {
            for ($j = 0; $j -lt $entries.Count; $j++) {
                if ($entries[$j].Name -eq $selName) { $MonList.SelectedIndex = $j; break }
            }
        }
    }
    if (-not $script:monAutoSelected -and $script:monData.Count -gt 0 -and $MonList.SelectedIndex -lt 0) {
        $script:monAutoSelected = $true
        $MonList.SelectedIndex = 0
    }
}

$MonList.Add_SelectionChanged({
    $i = $MonList.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:monData.Count) {
        $e = $script:monData[$i]
        if ($script:monTailPath -ne $e.Log) {
            $script:monTailPath = $e.Log
            $script:monTailPos = [long]0
            try {
                $fi = Get-Item -LiteralPath $e.Log
                $script:monTailPos = [Math]::Max(0, $fi.Length - 102400)
            } catch { }
            $MonTail.Clear()
        }
    }
})

$FilterBox.Add_TextChanged({ Apply-Filter })
$CmbType.Add_SelectionChanged({ Apply-Filter })
$ChkTop.Add_Checked({ $win.Topmost = $true })
$ChkTop.Add_Unchecked({ $win.Topmost = $false })
$BtnPause.Add_Click({
    $script:paused = -not $script:paused
    if ($script:paused) { $BtnPause.Content = 'resume' } else { $BtnPause.Content = 'pause' }
})
$BtnClear.Add_Click({
    $items.Clear()
    $script:running = @{}
    Update-Chrome
})
$LogCombo.Add_SelectionChanged({
    $sel = $LogCombo.SelectedItem
    if ($sel) {
        $script:tailPath = [string]$sel
        $script:tailPos = 0
        try {
            $fi = Get-Item -LiteralPath $script:tailPath
            $script:tailPos = [Math]::Max(0, $fi.Length - 102400)
        } catch { }
        $TailBox.Clear()
    }
})

$syncTok = [hashtable]::Synchronized(@{ text = ''; tip = '' })
$syncDet = [hashtable]::Synchronized(@{ procs = @(); logs = @(); stamp = 0 })

$tokScript = {
    param($projRoot, $sync)
    function Fmt($n) {
        if ($n -ge 1e9) { return ('{0:N1}B' -f ($n / 1e9)) }
        if ($n -ge 1e6) { return ('{0:N1}M' -f ($n / 1e6)) }
        if ($n -ge 1e3) { return ('{0:N1}K' -f ($n / 1e3)) }
        return [string][long]$n
    }
    $offsets = @{}
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $day = @{}
    $sess = @{}
    $rxIn = [regex]'"input_tokens":(\d+)'
    $rxOut = [regex]'"output_tokens":(\d+)'
    $rxCC = [regex]'"cache_creation_input_tokens":(\d+)'
    $rxCR = [regex]'"cache_read_input_tokens":(\d+)'
    $rxId = [regex]'"id":"(msg_[^"]+)"'
    $rxReq = [regex]'"requestId":"([^"]+)"'
    $rxTs = [regex]'"timestamp":"([^"]+)"'
    while ($true) {
        try {
            $cut = (Get-Date).AddDays(-8)
            $files = Get-ChildItem -LiteralPath $projRoot -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cut -and $_.FullName -notmatch '\\memory\\' }
            foreach ($f in $files) {
                $path = $f.FullName
                $pos = [long]0
                if ($offsets.ContainsKey($path)) { $pos = $offsets[$path] }
                if ($f.Length -lt $pos) { $pos = 0 }
                if ($f.Length -eq $pos) { continue }
                $chunk = ''
                $newPos = $pos
                try {
                    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                    try {
                        $null = $fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
                        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                        $chunk = $sr.ReadToEnd()
                        $newPos = $fs.Length
                    }
                    finally { $fs.Dispose() }
                }
                catch { continue }
                $lastNl = $chunk.LastIndexOf("`n")
                if ($lastNl -lt 0) { continue }
                if ($lastNl -lt ($chunk.Length - 1)) {
                    $newPos -= [System.Text.Encoding]::UTF8.GetByteCount($chunk.Substring($lastNl + 1))
                    $chunk = $chunk.Substring(0, $lastNl + 1)
                }
                $offsets[$path] = $newPos
                $sid = [System.IO.Path]::GetFileNameWithoutExtension($path)
                if ($sid.Length -gt 8) { $sid = $sid.Substring(0, 8) }
                foreach ($ln in ($chunk -split "`n")) {
                    if ($ln.IndexOf('"input_tokens"') -lt 0) { continue }
                    $mi = $rxIn.Match($ln)
                    if (-not $mi.Success) { continue }
                    $key = ''
                    $mId = $rxId.Match($ln)
                    $mReq = $rxReq.Match($ln)
                    if ($mId.Success) {
                        $key = $mId.Groups[1].Value
                        if ($mReq.Success) { $key += '|' + $mReq.Groups[1].Value }
                    }
                    if ($key -and -not $seen.Add($key)) { continue }
                    $in = [long]$mi.Groups[1].Value
                    $out = [long]0; $cc = [long]0; $cr = [long]0
                    $m = $rxOut.Match($ln); if ($m.Success) { $out = [long]$m.Groups[1].Value }
                    $m = $rxCC.Match($ln); if ($m.Success) { $cc = [long]$m.Groups[1].Value }
                    $m = $rxCR.Match($ln); if ($m.Success) { $cr = [long]$m.Groups[1].Value }
                    $d = (Get-Date).ToString('yyyy-MM-dd')
                    $m = $rxTs.Match($ln)
                    if ($m.Success) { try { $d = [datetimeoffset]::Parse($m.Groups[1].Value).ToLocalTime().ToString('yyyy-MM-dd') } catch { } }
                    foreach ($pair in @(, @($day, $d)) + @(, @($sess, $sid))) {
                        $b = $pair[0]; $k = $pair[1]
                        if (-not $b.ContainsKey($k)) { $b[$k] = @{ in = [long]0; out = [long]0; cc = [long]0; cr = [long]0 } }
                        $b[$k].in += $in; $b[$k].out += $out; $b[$k].cc += $cc; $b[$k].cr += $cr
                    }
                }
            }
            $todayK = (Get-Date).ToString('yyyy-MM-dd')
            $weekKeys = @(0..6 | ForEach-Object { (Get-Date).AddDays(-$_).ToString('yyyy-MM-dd') })
            $t = @{ in = [long]0; out = [long]0; c = [long]0 }
            $w = @{ in = [long]0; out = [long]0; c = [long]0 }
            foreach ($k in $day.Keys) {
                $b = $day[$k]
                if ($k -eq $todayK) { $t.in += $b.in; $t.out += $b.out; $t.c += $b.cc + $b.cr }
                if ($weekKeys -contains $k) { $w.in += $b.in; $w.out += $b.out; $w.c += $b.cc + $b.cr }
            }
            $tTot = $t.in + $t.out + $t.c
            $wTot = $w.in + $w.out + $w.c
            $sync.text = "tokens   today $(Fmt $tTot)  (in $(Fmt $t.in) · out $(Fmt $t.out) · cache $(Fmt $t.c))     7d $(Fmt $wTot)  (in $(Fmt $w.in) · out $(Fmt $w.out) · cache $(Fmt $w.c))"
            $tip = New-Object System.Collections.Generic.List[string]
            $tip.Add('last 7 days:')
            foreach ($k in ($day.Keys | Where-Object { $weekKeys -contains $_ } | Sort-Object -Descending)) {
                $b = $day[$k]
                $tot = $b.in + $b.out + $b.cc + $b.cr
                $tip.Add(("  {0}   {1}   (in {2} · out {3} · cache {4})" -f $k, (Fmt $tot), (Fmt $b.in), (Fmt $b.out), (Fmt ($b.cc + $b.cr))))
            }
            $tip.Add('')
            $tip.Add('top sessions (8d):')
            foreach ($e in ($sess.GetEnumerator() | Sort-Object { $_.Value.in + $_.Value.out + $_.Value.cc + $_.Value.cr } -Descending | Select-Object -First 6)) {
                $b = $e.Value
                $tip.Add(("  {0}   {1}" -f $e.Key, (Fmt ($b.in + $b.out + $b.cc + $b.cr))))
            }
            $sync.tip = ($tip -join "`n")
        }
        catch { }
        Start-Sleep -Seconds 5
    }
}

$detScript = {
    param($sync, $log, $tempClaude, $projDir)
    $known = @{}
    $i = 0
    while ($true) {
        try {
            $procs = Get-WmiObject Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='cmd.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue
            $now = Get-Date
            $cur = @{}
            foreach ($p in $procs) {
                $cl = $p.CommandLine
                if (-not $cl) { continue }
                if ($cl -notmatch '(?i)(\\Temp\\claude\\|ClaudeProjects|scratchpad)') { continue }
                if ($cl -match '(?i)(hook-logger\.ps1|ClaudeActivityMonitor\.ps1)') { continue }
                $start = $now
                try { $start = [System.Management.ManagementDateTimeConverter]::ToDateTime($p.CreationDate) } catch { }
                if (($now - $start).TotalSeconds -lt 10) { continue }
                $name = $p.Name
                if ($cl -match '(?i)-File"?\s+"?([^"]+?\.(ps1|bat|cmd))') { $name = [System.IO.Path]::GetFileName($Matches[1]) }
                elseif ($cl -match '(?i)([\w\-\.]+\.(ps1|bat|cmd))') { $name = $Matches[1] }
                $cur[[string]$p.ProcessId] = @{ name = $name; start = $start; cl = $cl }
            }
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($k in $cur.Keys) {
                if (-not $known.ContainsKey($k)) {
                    $o = [ordered]@{ ts = (Get-Date).ToString('o'); ev = 'DetachedStart'; sid = ''; tool = 'Detached'; detail = "$($cur[$k].name) | pid $k"; cwd = '' }
                    $lines.Add(((ConvertTo-Json $o -Compress) + "`n"))
                }
            }
            foreach ($k in @($known.Keys)) {
                if (-not $cur.ContainsKey($k)) {
                    $mins = [int]((Get-Date) - $known[$k].start).TotalMinutes
                    $o = [ordered]@{ ts = (Get-Date).ToString('o'); ev = 'DetachedEnd'; sid = ''; tool = 'Detached'; detail = "$($known[$k].name) | pid $k | ran ${mins}m"; cwd = '' }
                    $lines.Add(((ConvertTo-Json $o -Compress) + "`n"))
                }
            }
            $known = $cur
            if ($lines.Count -gt 0) {
                $mtx = New-Object System.Threading.Mutex($false, 'ClaudeActivityMonitorLog')
                $got = $false
                try {
                    $got = $mtx.WaitOne(3000)
                    [System.IO.File]::AppendAllText($log, ($lines -join ''), (New-Object System.Text.UTF8Encoding($false)))
                }
                finally {
                    if ($got) { $mtx.ReleaseMutex() }
                    $mtx.Dispose()
                }
            }
            $chips = New-Object System.Collections.Generic.List[string]
            foreach ($k in ($cur.Keys | Sort-Object)) {
                $age = (Get-Date) - $cur[$k].start
                $ageS = ''
                if ($age.TotalHours -ge 1) { $ageS = ('{0:N1}h' -f $age.TotalHours) }
                elseif ($age.TotalMinutes -ge 1) { $ageS = ('{0}m' -f [int]$age.TotalMinutes) }
                else { $ageS = ('{0}s' -f [int]$age.TotalSeconds) }
                $chips.Add(("pid {0,-7} {1,-38} up {2}" -f $k, $cur[$k].name, $ageS))
            }
            $sync.procs = $chips.ToArray()
            if ($i % 5 -eq 0) {
                $logs = @()
                foreach ($root in @($tempClaude, $projDir)) {
                    if (Test-Path -LiteralPath $root) {
                        $logs += Get-ChildItem -LiteralPath $root -Recurse -Filter *.log -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-48) }
                    }
                }
                $sync.logs = @($logs | Sort-Object LastWriteTime -Descending | Select-Object -First 30 | ForEach-Object { $_.FullName })
            }
            $i++
            $sync.stamp = [int]$sync.stamp + 1
        }
        catch { }
        Start-Sleep -Seconds 3
    }
}

$rsA = [runspacefactory]::CreateRunspace(); $rsA.Open()
$psA = [powershell]::Create(); $psA.Runspace = $rsA
$null = $psA.AddScript($tokScript).AddArgument($projRoot).AddArgument($syncTok)
$null = $psA.BeginInvoke()

$rsB = [runspacefactory]::CreateRunspace(); $rsB.Open()
$psB = [powershell]::Create(); $psB.Runspace = $rsB
$null = $psB.AddScript($detScript).AddArgument($syncDet).AddArgument($log).AddArgument((Join-Path $env:TEMP 'claude')).AddArgument((Join-Path $env:USERPROFILE 'ClaudeProjects'))
$null = $psB.BeginInvoke()

$win.Add_Closed({
    try { $psA.Stop() } catch { }
    try { $psB.Stop() } catch { }
    try { $rsA.Close() } catch { }
    try { $rsB.Close() } catch { }
})

try {
    $fi = Get-Item -LiteralPath $log
    if ($fi.Length -gt 0 -and $fi.Length -lt 3MB) {
        $lines = [System.IO.File]::ReadAllLines($log, [System.Text.Encoding]::UTF8)
        $start = [Math]::Max(0, $lines.Count - 300)
        for ($i = $start; $i -lt $lines.Count; $i++) {
            $ln = $lines[$i].Trim()
            if (-not $ln) { continue }
            try { Add-Rec (ConvertFrom-Json $ln) } catch { }
        }
        $script:running = @{}
    }
    $script:pos = $fi.Length
}
catch { }
Sync-SessionTabs
Sync-Monitors
Update-Chrome
if ($items.Count -gt 0) { $Lv.ScrollIntoView($items[$items.Count - 1]) }

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
    $script:tick++
    Read-New
    foreach ($st in @($script:consoles.Values)) { Read-Transcript $st }
    if ($script:tailPath) {
        $chunk = Read-FileChunk $script:tailPath ([ref]$script:tailPos)
        if ($chunk) {
            $TailBox.AppendText($chunk)
            if ($TailBox.Text.Length -gt 400000) { $TailBox.Text = $TailBox.Text.Substring(200000) }
            if (-not $script:paused) { $TailBox.ScrollToEnd() }
        }
    }
    if ($script:monTailPath) {
        $chunk = Read-FileChunk $script:monTailPath ([ref]$script:monTailPos)
        if ($chunk) {
            $MonTail.AppendText($chunk)
            if ($MonTail.Text.Length -gt 400000) { $MonTail.Text = $MonTail.Text.Substring(200000) }
            if (-not $script:paused) { $MonTail.ScrollToEnd() }
        }
    }
    if (($script:tick % 8) -eq 0) {
        Sync-SessionTabs
        Sync-Monitors
        if ($syncTok.text -and $syncTok.text -ne $script:lastTok) {
            $script:lastTok = $syncTok.text
            $TokText.Text = $syncTok.text
            $TokBorder.ToolTip = $syncTok.tip
        }
        if ($syncDet.stamp -ne $script:lastDetStamp) {
            $script:lastDetStamp = $syncDet.stamp
            $ProcList.ItemsSource = $syncDet.procs
            $sel = $LogCombo.SelectedItem
            $LogCombo.ItemsSource = $syncDet.logs
            if ($sel -and ($syncDet.logs -contains $sel)) { $LogCombo.SelectedItem = $sel }
        }
        Update-Chrome
    }
})
$timer.Start()

$null = $win.ShowDialog()
