<#
  dsh-notify-yimit 常驻浮窗宿主(Windows PowerShell + WPF)。
  由 dsh-notify-yimit 宿主插件在加载时 spawn 一次并常驻:所有桌面浮窗都在本进程内创建,
  WPF 程序集只加载一次,通知创建延迟从 ~1s 冷启动降到 ~10ms(根治"总感觉慢")。

  协议(UTF-8,一行一个 JSON):
    stdin(入站命令):
      {"cmd":"show","key":"running:s1","instance":1,"title":"...","text":"...",
       "bg":"#286ebd","fg":"#e6edf3","durationSec":8,"sticky":true,"offsetY":0,
       "sessionId":"s1","baseUrl":"http://127.0.0.1:3080",
       "browserPath":"","winTitle":"dsh-notify-yimit-running:s1"}
      {"cmd":"text","key":...,"text":"..."}      # 原地更新内容(不重弹、零延迟)
      {"cmd":"move","key":...,"top":588}          # 平滑移动(220ms QuadraticEase)
      {"cmd":"close","key":...}                   # 160ms 淡出 + 20px 下坠后关闭
      {"cmd":"shutdown"}                          # 关闭全部窗口并退出
    stdout(出站报告):
      {"type":"pos","key":...,"instance":1,"left":...,"top":...,"height":...,
       "hwnd":...,"workBottom":...}
      {"type":"exit","key":...,"instance":...}
  说明:主线程(STA)跑 WPF Dispatcher;stdin 由独立 runspace 线程读取并放入
  ConcurrentQueue,命令在 Dispatcher 定时器(50ms)中处理——窗口操作线程安全。
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# WPF 必须运行在 STA 主线程(Windows PowerShell 5.1 控制台主线程为 STA)。
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
  [Console]::Error.WriteLine("dsh-notify-yimit: 宿主需要 STA 主线程(当前 $([System.Threading.Thread]::CurrentThread.ApartmentState))")
  exit 1
}

# ── 协议输出:UTF-8 无 BOM(管道传中文必须固定编码,否则乱码) ────────────────
$script:utf8 = New-Object System.Text.UTF8Encoding($false)
$script:stdout = New-Object System.IO.StreamWriter([System.Console]::OpenStandardOutput(), $script:utf8)
$script:stdout.AutoFlush = $true

function Send-Report([object]$obj) {
  try { $script:stdout.WriteLine(($obj | ConvertTo-Json -Compress)) } catch { }
}

# 浮窗注册表(key → @{ Win; Body; Timer; Instance }),只在 WPF 主线程访问。
$script:toasts = @{}
$script:exitRequested = $false

# 颜色解析:#RGB / #RRGGBB / #AARRGGBB → Windows.Media.Color
function Parse-Color([string]$hex, [string]$fallback) {
  $h = $hex.TrimStart('#')
  if ($h.Length -eq 3) { $h = ($h.ToCharArray() | ForEach-Object { "$_$_" }) -join '' }
  if ($h.Length -eq 6) { $h = "FF$h" }
  if ($h.Length -ne 8 -or $h -notmatch '^[0-9a-fA-F]{8}$') { $h = $fallback.TrimStart('#') }
  return [System.Windows.Media.Color]::FromArgb(
    [Convert]::ToInt32($h.Substring(0,2), 16),
    [Convert]::ToInt32($h.Substring(2,2), 16),
    [Convert]::ToInt32($h.Substring(4,2), 16),
    [Convert]::ToInt32($h.Substring(6,2), 16))
}

# 按钮用 Border 直接实现:标准圆角矩形(10px)。忽略 = 透明底 + 细边框(fg 色);
# 跳转 = 浅色实心底 + 主色文字。悬停/按压用不透明压暗色反馈(避免透明窗口闪烁)。
$downP = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(158,164,170))
$downI = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(30,36,44))
$hoverP = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(196,202,208))
$hoverI = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(44,52,62))

function New-ToastButton([string]$label, [scriptblock]$onClick, [bool]$primary,
  [System.Windows.Media.SolidColorBrush]$fg, [System.Windows.Media.SolidColorBrush]$bg) {
  $bd = New-Object System.Windows.Controls.Border
  $bd.CornerRadius = New-Object System.Windows.CornerRadius(10)
  $bd.Padding = New-Object System.Windows.Thickness(18,7,18,7)
  $bd.Margin = New-Object System.Windows.Thickness(0,0,8,0)
  $bd.Cursor = [System.Windows.Input.Cursors]::Hand
  $bd.Focusable = $false
  $txt = New-Object System.Windows.Controls.TextBlock
  $txt.Text = $label
  $txt.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI")
  $txt.FontSize = 12
  $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $txt.IsHitTestVisible = $false  # 点击穿透到 Border,确保命中与事件稳定
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
  # 事件回调在函数返回后触发,函数局部变量不可见:回调和主按钮标记存入 Tag(hashtable),
  # 回调统一从 $this(事件源)的 Tag 读取。
  $bd.Tag = @{ primary = $primary; onClick = $onClick }
  $bd.Add_MouseEnter({
    $info = $this.Tag
    $this.Background = if ($info.primary) { $hoverP } else { $hoverI }
  }) | Out-Null
  $bd.Add_MouseLeave({
    $info = $this.Tag
    $this.Background = if ($info.primary) { $fg } else { [System.Windows.Media.Brushes]::Transparent }
  }) | Out-Null
  $bd.Add_MouseLeftButtonDown({
    $info = $this.Tag
    $this.Background = if ($info.primary) { $downP } else { $downI }
  }) | Out-Null
  $bd.Add_MouseLeftButtonUp({
    $info = $this.Tag
    try { if ($info.onClick -ne $null) { & $info.onClick } } catch { }
    $this.Background = if ($info.primary) { $fg } else { [System.Windows.Media.Brushes]::Transparent }
  }) | Out-Null
  return $bd
}

# 动画缓动(脚本级,供各处复用)。
# 注意:PS 5.1 的 New-Object 无法用枚举参数调构造器(会报 "overload ... argument count: 1"),
# 必须默认构造后设置 EasingMode 属性。
$easeMove = New-Object System.Windows.Media.Animation.QuadraticEase
$easeMove.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
$easeExit = New-Object System.Windows.Media.Animation.CubicEase
$easeExit.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn

# 淡出关闭:160ms EaseIn 淡出 + 20px 下坠,动画完成后 Close(Closed 事件上报 exit)。
# 防重入:$w.Tag='closing' 只执行一次(忽略按钮 + close 命令 + 定时器可能先后触发);
# 600ms 硬性兜底,确保即使动画/定时器异常也强制关闭(绝不挂起)。
function Close-WithFade($w) {
  try {
    if ($w.Tag -eq 'closing') { return }
    $w.Tag = 'closing'
    $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(1, 0, [TimeSpan]::FromMilliseconds(160))
    $fadeOut.EasingFunction = $easeExit
    # 事件回调延迟触发,看不到函数局部变量:GetNewClosure() 捕获 $w。
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

# 建窗:按 show 命令参数创建窗口;返回 Window(由调用方 Show() 显示)。
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

  # 圆角卡片容器(窗口圆角 12;按钮为圆角矩形 10px)。
  $cornerRadius = 12
  $border = New-Object System.Windows.Controls.Border
  $border.Background = $bgBrush
  $border.BorderBrush = $fgBrush
  $border.BorderThickness = New-Object System.Windows.Thickness(1)
  $border.CornerRadius = New-Object System.Windows.CornerRadius($cornerRadius)
  $border.Margin = New-Object System.Windows.Thickness(12)

  $root = New-Object System.Windows.Controls.StackPanel
  $root.Margin = New-Object System.Windows.Thickness(14,12,14,12)
  $border.Child = $root

  # 标题行
  $titleText = New-Object System.Windows.Controls.TextBlock
  $titleText.Text = if ([string]::IsNullOrEmpty([string]$cmd.title)) { "(未命名会话)" } else { [string]$cmd.title }
  $titleText.Foreground = $fgBrush
  $titleText.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI")
  $titleText.FontSize = 13
  $titleText.FontWeight = [System.Windows.FontWeights]::SemiBold
  $titleText.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $titleText.Margin = New-Object System.Windows.Thickness(0,0,0,6)
  $root.Children.Add($titleText) | Out-Null

  # 内容(保留引用:text 命令原地更新,零延迟不重弹)
  $bodyText = New-Object System.Windows.Controls.TextBlock
  $bodyText.Text = [string]$cmd.text
  $bodyText.Foreground = $fgBrush
  $bodyText.FontFamily = New-Object System.Windows.Media.FontFamily("Microsoft YaHei UI")
  $bodyText.FontSize = 13
  $bodyText.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $bodyText.Margin = New-Object System.Windows.Thickness(0,0,0,10)
  $root.Children.Add($bodyText) | Out-Null

  # 按钮行
  $btnRow = New-Object System.Windows.Controls.StackPanel
  $btnRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $btnRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

  $ignoreBtn = New-ToastButton "忽略" ({ Close-WithFade $win }.GetNewClosure()) $false $fgBrush $bgBrush
  $btnRow.Children.Add($ignoreBtn) | Out-Null

  if (-not [string]::IsNullOrEmpty([string]$cmd.sessionId)) {
    # 跳转会始终打开浏览器(功能恒开启):用指定浏览器(空 = 系统默认)打开 DSH 并定位会话。
    $jumpBtn = New-ToastButton "跳转会话" ({
      $url = "$($cmd.baseUrl)/#dsh-notify-yimit/session=$($cmd.sessionId)"
      try {
        if (-not [string]::IsNullOrEmpty([string]$cmd.browserPath)) {
          Start-Process -FilePath ([string]$cmd.browserPath) -ArgumentList $url
        } else {
          Start-Process $url
        }
      } catch { }
      Close-WithFade $win
    }.GetNewClosure()) $true $fgBrush $bgBrush
    $btnRow.Children.Add($jumpBtn) | Out-Null
  }
  $root.Children.Add($btnRow) | Out-Null

  $win.Content = $border

  # 右下角定位 + 滑入动画 + 淡入 + pos 回传(单 Loaded 处理器)。
  # 关键顺序:先把窗口放到"起始位置"(目标下方 32px)且透明度 0,
  # 再启动动画滑向目标并淡入——窗口从起始位置可见地滑入,而不是瞬间显示在终点。
  $win.Add_Loaded({
    $work = [System.Windows.SystemParameters]::WorkArea
    $targetLeft = $work.Right - $win.ActualWidth - 20
    $targetTop = $work.Bottom - $win.ActualHeight - 20 - [int]$cmd.offsetY
    $win.Left = $targetLeft
    $win.Top = $targetTop + 32
    $win.Opacity = 0
    try {
      # 滑入 + 淡入(QuadraticEase EaseOut,260ms 快出缓停;淡入 180ms 先于位移结束)。
      $easingIn = New-Object System.Windows.Media.Animation.QuadraticEase
      $easingIn.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
      $slideIn = New-Object System.Windows.Media.Animation.DoubleAnimation($targetTop + 32, $targetTop, [TimeSpan]::FromMilliseconds(260))
      $slideIn.EasingFunction = $easingIn
      $win.BeginAnimation([System.Windows.Window]::TopProperty, $slideIn)
      $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(180))
      $fadeIn.EasingFunction = $easingIn
      $win.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeIn)
      # 保险:400ms 后若动画异常导致不可见/未到位,强制恢复(窗口绝不能隐形挂起)。
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
    # 位置与句柄回传(workBottom 为准确屏幕底部基准,宿主用它做自适应堆叠)。
    try {
      $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
      Send-Report @{
        type = 'pos'; key = [string]$cmd.key; instance = [int]$cmd.instance
        left = [Math]::Round($targetLeft); top = [Math]::Round($targetTop)
        height = [Math]::Round($win.ActualHeight); hwnd = $hwnd.ToInt64()
        workBottom = [Math]::Round($work.Bottom)
      }
    } catch { }
  }.GetNewClosure()) | Out-Null

  # 关闭(任何途径)即注销并上报 exit(宿主侧唯一出口;宿主据此重排上方浮窗)。
  # 注意:GetNewClosure 闭包里 $script: 解析不到原脚本作用域(为 $null),必须经
  # 闭包捕获的函数局部引用访问注册表($toastsRef)。
  $toastsRef = $script:toasts
  $win.Add_Closed({
    if ($toastsRef.ContainsKey([string]$cmd.key)) {
      $rec = $toastsRef[[string]$cmd.key]
      if ($rec.Timer -ne $null) { try { $rec.Timer.Stop() } catch { } }
      $toastsRef.Remove([string]$cmd.key) | Out-Null
    }
    Send-Report @{ type = 'exit'; key = [string]$cmd.key; instance = [int]$cmd.instance }
  }.GetNewClosure()) | Out-Null

  # 注册
  $rec = @{ Win = $win; Body = $bodyText; Timer = $null; Instance = [int]$cmd.instance }
  $script:toasts[[string]$cmd.key] = $rec

  # 非 sticky:定时自动消失(先淡出再关闭)。
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

# ── 命令处理(WPF 主线程 Dispatcher 上执行,窗口操作线程安全) ───────────────
function Invoke-Command([string]$line) {
  $line = $line.Trim()
  if ([string]::IsNullOrEmpty($line)) { return }
  $cmd = $null
  try { $cmd = $line | ConvertFrom-Json } catch { return }
  if ($cmd -eq $null -or [string]::IsNullOrEmpty([string]$cmd.cmd)) { return }
  switch ([string]$cmd.cmd) {
    'show' {
      # 防御:同 key 已存在(极端时序,如旧窗淡出中又来新 show)→ 立即关闭旧窗再建新窗。
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

# ── stdin 读取:独立 runspace 线程(阻塞 ReadLine 不卡 WPF 主线程) ───────────
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
  # stdin 关闭 → 通知主线程优雅退出。
  $q.Enqueue('{"cmd":"shutdown"}')
}
$readerRs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$readerRs.Open()
$readerPs = [System.Management.Automation.PowerShell]::Create()
$readerPs.Runspace = $readerRs
$readerPs.AddScript($readerScript).AddArgument($script:cmdQueue) | Out-Null
$readerPs.BeginInvoke() | Out-Null

# ── 主循环:50ms 排空命令队列;收到 shutdown 后关闭全部窗口并退出 ─────────────
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
try { $readerPs.Dispose() } catch { }
try { $readerRs.Dispose() } catch { }
