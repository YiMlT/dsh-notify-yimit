<# dsh-notify-yimit 常驻浮窗宿主(Windows PowerShell + WPF)。
 优化点：JSON序列化深度增加、Tag闭包变量传递优化、BeginInvoke资源回收、接收外部Label参数实现多语言。 #>
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    [Console]::Error.WriteLine("dsh-notify-yimit: Host requires STA main thread (current $([System.Threading.Thread]::CurrentThread.ApartmentState))")
    exit 1
}

$script:utf8 = New-Object System.Text.UTF8Encoding($false)
$script:stdout = New-Object System.IO.StreamWriter([System.Console]::OpenStandardOutput(), $script:utf8)
$script:stdout.AutoFlush = $true

function Send-Report([object]$obj) {
    try {
        $script:stdout.WriteLine(($obj | ConvertTo-Json -Compress -Depth 10))
    } catch { }
}

$script:toasts = @{}
$script:exitRequested = $false

function Parse-Color([string]$hex, [string]$fallback) {
    $h = $hex.TrimStart('#')
    if ($h.Length -eq 3) { $h = ($h.ToCharArray() | ForEach-Object { "$$_" }) -join '' }
    if ($h.Length -eq 6) { $h = "FF$h" }
    if ($h.Length -ne 8 -or $h -notmatch '^[0-9a-fA-F]{8}$') { $h = $fallback.TrimStart('#') }
    return [System.Windows.Media.Color]::FromArgb(
        [Convert]::ToInt32($h.Substring(0,2), 16),
        [Convert]::ToInt32($h.Substring(2,2), 16),
        [Convert]::ToInt32($h.Substring(4,2), 16),
        [Convert]::ToInt32($h.Substring(6,2), 16))
}

$downP = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(158,164,170))
$downI = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(30,36,44))
$hoverP = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(196,202,208))
$hoverI = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(44,52,62))

function New-ToastButton([string]$label, [scriptblock]$onClick, [bool]$primary, [System.Windows.Media.SolidColorBrush]$fg, [System.Windows.Media.SolidColorBrush]$bg) {
    $bd = New-Object System.Windows.Controls.Border
    $bd.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $bd.Padding = New-Object System.Windows.Thickness(18,7,18,7)
    $bd.Margin = New-Object System.Windows.Thickness(0,0,8,0)
    $bd.Cursor = [System.Windows.Input.Cursors]::Hand
    $bd.Focusable = $false
    
    $txt = New-Object System.Windows.Controls.TextBlock
    $txt.Text = $label
    $txt.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
    $txt.FontSize = 12
    $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $txt.IsHitTestVisible = $false
    
    if ($primary) {
        $bd.Background = $fg
        $txt.Foreground = $bg
        $bd.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        $bd.BorderThickness = New-Object System.Windows.Thickness(0)
    } else {
        $bd.Background = [System.Windows.Media.Brushes]::Transparent
        $txt.Foreground = $fg
        $bd.BorderBrush = $fg
        $bd.BorderThickness = New-Object System.Windows.Thickness(1)
    }
    $bd.Child = $txt
    
    $bd.Tag = @{ primary = $primary; onClick = $onClick; hoverP = $hoverP; hoverI = $hoverI; downP = $downP; downI = $downI; fg = $fg; bg = $bg }
    
    $bd.Add_MouseEnter({
        $info = $this.Tag
        $this.Background = if ($info.primary) { $info.hoverP } else { $info.hoverI }
    }) | Out-Null
    
    $bd.Add_MouseLeave({
        $info = $this.Tag
        $this.Background = if ($info.primary) { $info.fg } else { [System.Windows.Media.Brushes]::Transparent }
    }) | Out-Null
    
    $bd.Add_MouseLeftButtonDown({
        $info = $this.Tag
        $this.Background = if ($info.primary) { $info.downP } else { $info.downI }
    }) | Out-Null
    
    $bd.Add_MouseLeftButtonUp({
        $info = $this.Tag
        try { if ($info.onClick -ne $null) { & $info.onClick } } catch { }
        $this.Background = if ($info.primary) { $info.fg } else { [System.Windows.Media.Brushes]::Transparent }
    }) | Out-Null
    
    return $bd
}

$easeMove = New-Object System.Windows.Media.Animation.QuadraticEase
$easeMove.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
$easeExit = New-Object System.Windows.Media.Animation.CubicEase
$easeExit.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn

function Close-WithFade($w) {
    try {
        if ($w.Tag -eq 'closing') { return }
        $w.Tag = 'closing'
        $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(1, 0, [TimeSpan]::FromMilliseconds(160))
        $fadeOut.EasingFunction = $easeExit
        $fadeOut.Add_Completed({ try { $w.Close() } catch { } }.GetNewClosure()) | Out-Null
        $w.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeOut)
        
        $dropAn = New-Object System.Windows.Media.Animation.DoubleAnimation($w.Top, ($w.Top + 20), [TimeSpan]::FromMilliseconds(160))
        $dropAn.EasingFunction = $easeExit
        $w.BeginAnimation([System.Windows.Window]::TopProperty, $dropAn)
        
        $backstop = New-Object System.Windows.Threading.DispatcherTimer
        $backstop.Interval = [TimeSpan]::FromMilliseconds(600)
        $backstop.Tag = $w
        $backstop.Add_Tick({
            $this.Stop()
            try { if ($this.Tag.IsVisible) { $this.Tag.Close() } } catch { }
        }) | Out-Null
        $backstop.Start()
    } catch {
        try { $w.Close() } catch { }
    }
}

function New-ToastWindow($cmd) {
    $bg = Parse-Color ([string]$cmd.bg) "#20272f"
    $fg = Parse-Color ([string]$cmd.fg) "#e6edf3"
    $bgBrush = New-Object System.Windows.Media.SolidColorBrush($bg)
    $fgBrush = New-Object System.Windows.Media.SolidColorBrush($fg)
    
    $win = New-Object System.Windows.Window
    $win.WindowStyle = [System.Windows.WindowStyle]::None
    $win.AllowsTransparency = $true
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $win.Topmost = $true
    $win.ShowInTaskbar = $false
    $win.Width = 340
    $win.SizeToContent = [System.Windows.SizeToContent]::Height
    if (-not [string]::IsNullOrEmpty([string]$cmd.winTitle)) { $win.Title = [string]$cmd.winTitle }
    
    $border = New-Object System.Windows.Controls.Border
    $border.Background = $bgBrush
    $border.BorderBrush = $fgBrush
    $border.BorderThickness = New-Object System.Windows.Thickness(1)
    $border.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $border.Margin = New-Object System.Windows.Thickness(12)
    
    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(14,12,14,12)
    $border.Child = $root
    
    # 优化：支持多语言，接收传入的 label，如果没有则使用后备英文
    $unnamedLabel = if ([string]::IsNullOrEmpty([string]$cmd.unnamedLabel)) { "(Unnamed session)" } else { [string]$cmd.unnamedLabel }
    
    $titleText = New-Object System.Windows.Controls.TextBlock
    $titleText.Text = if ([string]::IsNullOrEmpty([string]$cmd.title)) { $unnamedLabel } else { [string]$cmd.title }
    $titleText.Foreground = $fgBrush
    $titleText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
    $titleText.FontSize = 13
    $titleText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $titleText.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $titleText.Margin = New-Object System.Windows.Thickness(0,0,0,6)
    $root.Children.Add($titleText) | Out-Null
    
    $bodyText = New-Object System.Windows.Controls.TextBlock
    $bodyText.Text = [string]$cmd.text
    $bodyText.Foreground = $fgBrush
    $bodyText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
    $bodyText.FontSize = 13
    $bodyText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $bodyText.Margin = New-Object System.Windows.Thickness(0,0,0,10)
    $root.Children.Add($bodyText) | Out-Null
    
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btnRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    
    $ignoreLabel = if ([string]::IsNullOrEmpty([string]$cmd.ignoreLabel)) { "Ignore" } else { [string]$cmd.ignoreLabel }
    $ignoreBtn = New-ToastButton $ignoreLabel ({ Close-WithFade $win }.GetNewClosure()) $false $fgBrush $bgBrush
    $btnRow.Children.Add($ignoreBtn) | Out-Null
    
    if (-not [string]::IsNullOrEmpty([string]$cmd.sessionId)) {
        $jumpLabel = if ([string]::IsNullOrEmpty([string]$cmd.jumpLabel)) { "Open" } else { [string]$cmd.jumpLabel }
        $jumpBtn = New-ToastButton $jumpLabel ({
            $url = "$($cmd.baseUrl)/#dsh-notify-yimit/session=$($cmd.sessionId)"
            try {
                if (-not [string]::IsNullOrEmpty([string]$cmd.browserPath)) {
                    Start-Process -FilePath ([string]$cmd.browserPath) -ArgumentList $url
                } else { Start-Process $url }
            } catch { }
            Close-WithFade $win
        }.GetNewClosure()) $true $fgBrush $bgBrush
        $btnRow.Children.Add($jumpBtn) | Out-Null
    }
    $root.Children.Add($btnRow) | Out-Null
    $win.Content = $border
    
    $win.Add_Loaded({
        $work = [System.Windows.SystemParameters]::WorkArea
        $targetLeft = $work.Right - $win.ActualWidth - 20
        $targetTop = $work.Bottom - $win.ActualHeight - 20 - [int]$cmd.offsetY
        $win.Left = $targetLeft
        $win.Top = $targetTop + 32
        $win.Opacity = 0
        try {
            $easingIn = New-Object System.Windows.Media.Animation.QuadraticEase
            $easingIn.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
            $slideIn = New-Object System.Windows.Media.Animation.DoubleAnimation($targetTop + 32, $targetTop, [TimeSpan]::FromMilliseconds(260))
            $slideIn.EasingFunction = $easingIn
            $win.BeginAnimation([System.Windows.Window]::TopProperty, $slideIn)
            $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(180))
            $fadeIn.EasingFunction = $easingIn
            $win.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeIn)
            
            $guard = New-Object System.Windows.Threading.DispatcherTimer
            $guard.Interval = [TimeSpan]::FromMilliseconds(400)
            $guard.Tag = @{ w = $win; top = $targetTop }
            $guard.Add_Tick({
                $this.Stop()
                $g = $this.Tag
                try {
                    if ($g.w.Opacity -lt 0.9) { $g.w.Opacity = 1 }
                    if ($g.w.Top -ne $g.top) { $g.w.Top = $g.top }
                } catch { }
            }) | Out-Null
            $guard.Start()
        } catch {
            $win.Opacity = 1
            $win.Top = $targetTop
        }
        try {
            $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
            Send-Report @{ type = 'pos'; key = [string]$cmd.key; instance = [int]$cmd.instance
                          left = [Math]::Round($targetLeft); top = [Math]::Round($targetTop)
                          height = [Math]::Round($win.ActualHeight); hwnd = $hwnd.ToInt64()
                          workBottom = [Math]::Round($work.Bottom) }
        } catch { }
    }.GetNewClosure()) | Out-Null
    
    $toastsRef = $script:toasts
    $win.Add_Closed({
        if ($toastsRef.ContainsKey([string]$cmd.key)) {
            $rec = $toastsRef[[string]$cmd.key]
            if ($rec.Timer -ne $null) { try { $rec.Timer.Stop() } catch { } }
            $toastsRef.Remove([string]$cmd.key) | Out-Null
        }
        Send-Report @{ type = 'exit'; key = [string]$cmd.key; instance = [int]$cmd.instance }
    }.GetNewClosure()) | Out-Null
    
    $rec = @{ Win = $win; Body = $bodyText; Title = $titleText; Timer = $null; Instance = [int]$cmd.instance }
    $script:toasts[[string]$cmd.key] = $rec
    
    if (-not ($cmd.sticky -eq $true)) {
        $dur = [Math]::Max(1, [int]$cmd.durationSec)
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds($dur)
        $timer.Add_Tick({ $this.Stop(); Close-WithFade $win }.GetNewClosure()) | Out-Null
        $timer.Start()
        $rec.Timer = $timer
    }
    return $win
}

function Invoke-Command([string]$line) {
    $line = $line.Trim()
    if ([string]::IsNullOrEmpty($line)) { return }
    $cmd = $null
    try { $cmd = $line | ConvertFrom-Json } catch { return }
    if ($cmd -eq $null -or [string]::IsNullOrEmpty([string]$cmd.cmd)) { return }
    
    switch ([string]$cmd.cmd) {
        'show' {
            if ($script:toasts.ContainsKey([string]$cmd.key)) {
                $old = $script:toasts[[string]$cmd.key]
                try { $old.Win.Close() } catch { }
                $script:toasts.Remove([string]$cmd.key) | Out-Null
            }
            $w = New-ToastWindow $cmd
            if ($w -ne $null) { $w.Show() }
        }
        'text' {
            $rec = $script:toasts[[string]$cmd.key]
            if ($rec -ne $null -and $rec.Body -ne $null) { $rec.Body.Text = [string]$cmd.text }
        }
        'title' {
            $rec = $script:toasts[[string]$cmd.key]
            if ($rec -ne $null -and $rec.Title -ne $null) { $rec.Title.Text = [string]$cmd.title }
        }
        'move' {
            $rec = $script:toasts[[string]$cmd.key]
            if ($rec -ne $null) {
                $top = [int]$cmd.top
                $slide = New-Object System.Windows.Media.Animation.DoubleAnimation($rec.Win.Top, $top, [TimeSpan]::FromMilliseconds(220))
                $slide.EasingFunction = $easeMove
                $rec.Win.BeginAnimation([System.Windows.Window]::TopProperty, $slide)
            }
        }
        'close' {
            $rec = $script:toasts[[string]$cmd.key]
            if ($rec -ne $null) { Close-WithFade $rec.Win }
        }
        'shutdown' { $script:exitRequested = $true }
    }
}

$script:cmdQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$readerScript = {
    param($q)
    try {
        $reader = New-Object System.IO.StreamReader([System.Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $q.Enqueue($line)
        }
    } catch { }
    $q.Enqueue('{"cmd":"shutdown"}')
}

$readerRs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$readerRs.Open()
$readerPs = [System.Management.Automation.PowerShell]::Create()
$readerPs.Runspace = $readerRs
$readerPs.AddScript($readerScript).AddArgument($script:cmdQueue) | Out-Null
$readerAsyncResult = $readerPs.BeginInvoke()

$cmdTimer = New-Object System.Windows.Threading.DispatcherTimer
$cmdTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$cmdTimer.Add_Tick({
    try {
        $line = $null
        while ($script:cmdQueue.TryDequeue([ref]$line)) {
            if (-not [string]::IsNullOrEmpty($line)) { Invoke-Command $line }
            if ($script:exitRequested) { break }
        }
        if ($script:exitRequested) {
            $this.Stop()
            foreach ($key in @($script:toasts.Keys)) {
                try { $script:toasts[$key].Win.Close() } catch { }
            }
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        }
    } catch { }
}) | Out-Null
$cmdTimer.Start()
[System.Windows.Threading.Dispatcher]::Run()

try { if ($readerAsyncResult -ne $null) { $readerPs.EndInvoke($readerAsyncResult) } } catch { }
try { $readerPs.Dispose() } catch { }
try { $readerRs.Dispose() } catch { }
