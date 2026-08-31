<# dsh-notify-yimit 常驻浮窗宿主(Windows PowerShell + WPF)。

倒计时即进度(本版核心变化):
- 非粘性通知整卡抽象为倒计时:强调色 @12% "液面层"锚定左缘,ScaleX 1→0,
  右缘向左退去 —— 时间从右向左流走,剩余时间 = 剩余液面面积;
- 独立 2.5px 强调色"进度指针"亮线贴液面右缘同步左移(不被 ScaleX 压扁,
  在 bg≈accent 相近配色下仍 100% 饱和可辨,是可见性兜底信号);
- 动画严格线性(无缓动),保证视觉时长与真实剩余时间一致;
- 粘性通知(运行中/待审批/待回答)无倒计时,左侧强调色条改为呼吸脉动,
  与"会消失的卡"一眼区分。

其余特性:
- 强调色(accent)体系:左侧类型色条 + 强调色描边 + 强调色主按钮 + 辉光阴影;
- 编辑模式样板窗:5 类型实时色卡预览 + 边缘圆点缩放把手 + 多语言提示;
- JSON 序列化深度增加、Tag 闭包变量传递、接收外部 Label 参数实现多语言。 #>

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
    try { $script:stdout.WriteLine(($obj | ConvertTo-Json -Compress -Depth 10)) } catch { }
}

# ───────────────────────── 颜色 / 效果工具 ─────────────────────────

function Convert-Hsl([System.Windows.Media.Color]$c, [double]$lightFactor) {
    # 简易亮度调整:lightFactor > 1 提亮, < 1 压暗(用于主按钮 hover/按压变体)。
    $f = [Math]::Max(0.0, $lightFactor)
    return [System.Windows.Media.Color]::FromRgb(
        [byte][Math]::Min(255, [int]($c.R * $f)),
        [byte][Math]::Min(255, [int]($c.G * $f)),
        [byte]([Math]::Min(255, [int]($c.B * $f))))
}

function New-GlowEffect([System.Windows.Media.Color]$c, [double]$opacity) {
    # 强调色辉光阴影:无位移、大模糊,营造"类型色悬浮"感。
    $effect = New-Object System.Windows.Media.Effects.DropShadowEffect
    $effect.Color = $c
    $effect.BlurRadius = 24
    $effect.ShadowDepth = 0
    $effect.Opacity = $opacity
    return $effect
}

function Add-GridRow($grid) {
    $row = New-Object System.Windows.Controls.RowDefinition
    $row.Height = [System.Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($row) | Out-Null
}

# 编辑模式几何回传:样板窗当前 left/top/width/height(工作区相对坐标)。
function Send-Geometry($w) {
    try {
        $work = [System.Windows.SystemParameters]::WorkArea
        Send-Report @{
            type   = 'geometry'
            left   = [Math]::Round($w.Left - $work.Left)
            top    = [Math]::Round($w.Top - $work.Top)
            width  = [Math]::Round($w.ActualWidth)
            height = [Math]::Round($w.ActualHeight)
        }
    } catch { }
}

# ───────────────────────── 编辑模式样板窗 ─────────────────────────

# 编辑模式样板窗:拖拽移动 + 左右边缘圆点把手缩放;拖拽/缩放结束后回传 geometry。
# 强调色描边 + 辉光;内嵌 5 类型实时色卡预览(chips);多语言提示。
function New-EditSample($cmd) {
    $bg = Parse-Color ([string]$cmd.bg) "#203a5c"
    $fg = Parse-Color ([string]$cmd.fg) "#e8f0fb"
    $accent = Parse-Color ([string]$cmd.accent) "#60a5fa"
    $bgBrush = New-Object System.Windows.Media.SolidColorBrush($bg)
    $fgBrush = New-Object System.Windows.Media.SolidColorBrush($fg)
    $accentBrush = New-Object System.Windows.Media.SolidColorBrush($accent)

    $win = New-Object System.Windows.Window
    $win.WindowStyle = [System.Windows.WindowStyle]::None
    $win.AllowsTransparency = $true
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $win.Topmost = $true
    $win.ShowInTaskbar = $false
    if ($null -ne $cmd.width) { $win.Width = [double]$cmd.width } else { $win.Width = 340 }
    $win.SizeToContent = [System.Windows.SizeToContent]::Height
    $win.Effect = New-GlowEffect $accent 0.25

    $border = New-Object System.Windows.Controls.Border
    $border.Background = $bgBrush
    $border.BorderBrush = $accentBrush
    $border.BorderThickness = New-Object System.Windows.Thickness(1)
    $border.CornerRadius = New-Object System.Windows.CornerRadius(14)
    $border.Margin = New-Object System.Windows.Thickness(12)

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(16, 14, 16, 14)
    $border.Child = $root

    # 标题(带强调色小色块前缀)
    $titleRow = New-Object System.Windows.Controls.StackPanel
    $titleRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $titleRow.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $titleDot = New-Object System.Windows.Controls.Border
    $titleDot.Width = 4
    $titleDot.Height = 14
    $titleDot.CornerRadius = New-Object System.Windows.CornerRadius(2)
    $titleDot.Background = $accentBrush
    $titleDot.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $titleDot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $titleRow.Children.Add($titleDot) | Out-Null
    $titleText = New-Object System.Windows.Controls.TextBlock
    $titleText.Text = if ([string]::IsNullOrEmpty([string]$cmd.title)) { "Notification preview" } else { [string]$cmd.title }
    $titleText.Foreground = $fgBrush
    $titleText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
    $titleText.FontSize = 13
    $titleText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $titleText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $titleRow.Children.Add($titleText) | Out-Null
    $root.Children.Add($titleRow) | Out-Null

    # 5 类型实时色卡预览:浮窗色条/描边/主按钮所见即所得
    $chips = @($cmd.chips)
    if ($chips.Count -gt 0) {
        $chipRow = New-Object System.Windows.Controls.WrapPanel
        $chipRow.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        foreach ($c in $chips) {
            if ($c -eq $null) { continue }
            $chipAccent = Parse-Color ([string]$c.accent) "#60a5fa"
            $chipBg = Parse-Color ([string]$c.bg) "#20272f"
            $chip = New-Object System.Windows.Controls.Border
            $chip.CornerRadius = New-Object System.Windows.CornerRadius(8)
            $chip.Padding = New-Object System.Windows.Thickness(8, 3, 8, 4)
            $chip.Margin = New-Object System.Windows.Thickness(0, 0, 6, 4)
            $chip.Background = New-Object System.Windows.Media.SolidColorBrush($chipBg)
            $chip.BorderBrush = New-Object System.Windows.Media.SolidColorBrush($chipAccent)
            $chip.BorderThickness = New-Object System.Windows.Thickness(1)
            $chipText = New-Object System.Windows.Controls.TextBlock
            $chipText.Text = [string]$c.label
            $chipText.Foreground = New-Object System.Windows.Media.SolidColorBrush($chipAccent)
            $chipText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
            $chipText.FontSize = 11
            $chipText.FontWeight = [System.Windows.FontWeights]::SemiBold
            $chip.Child = $chipText
            $chipRow.Children.Add($chip) | Out-Null
        }
        $root.Children.Add($chipRow) | Out-Null
    }

    # 提示文案(多语言,由 startEditMode 传入 hint)
    $bodyText = New-Object System.Windows.Controls.TextBlock
    $bodyText.Text = if ([string]::IsNullOrEmpty([string]$cmd.hint)) {
        "Drag to move · Drag window edges to resize width · Click 'Finish editing' when done"
    } else { [string]$cmd.hint }
    $bodyText.Foreground = $fgBrush
    $bodyText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
    $bodyText.FontSize = 12
    $bodyText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $root.Children.Add($bodyText) | Out-Null

    # 左右边缘缩放把手:8px 通高,强调色半透明填充 + 三圆点把手,
    # 悬停时完全不透明提示可拖拽区域,光标为左右双向箭头。
    $edgeBrush = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.Color]::FromArgb(115, $accent.R, $accent.G, $accent.B))
    $leftStrip = New-Object System.Windows.Controls.Border
    $leftStrip.Width = 8
    $leftStrip.Cursor = [System.Windows.Input.Cursors]::SizeWE
    $leftStrip.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $leftStrip.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    $leftStrip.Background = $edgeBrush
    $leftStrip.CornerRadius = New-Object System.Windows.CornerRadius(14, 0, 0, 14)
    $rightStrip = New-Object System.Windows.Controls.Border
    $rightStrip.Width = 8
    $rightStrip.Cursor = [System.Windows.Input.Cursors]::SizeWE
    $rightStrip.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $rightStrip.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    $rightStrip.Background = $edgeBrush
    $rightStrip.CornerRadius = New-Object System.Windows.CornerRadius(0, 14, 14, 0)

    function Add-GripDots($strip, $dotColor) {
        $dots = New-Object System.Windows.Controls.StackPanel
        $dots.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $dots.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $dots.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        foreach ($i in 1..3) {
            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 3; $dot.Height = 3
            $dot.Margin = New-Object System.Windows.Thickness(1, 0, 1, 0)
            $dot.Fill = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.Color]::FromArgb(170, $dotColor.R, $dotColor.G, $dotColor.B))
            $dots.Children.Add($dot) | Out-Null
        }
        $strip.Child = $dots
        $strip.Opacity = 0.75
        $strip.Add_MouseEnter({ $this.Opacity = 1.0 }) | Out-Null
        $strip.Add_MouseLeave({ $this.Opacity = 0.75 }) | Out-Null
    }
    Add-GripDots $leftStrip $fg
    Add-GripDots $rightStrip $fg

    # 外层 Grid:边框 + 左右缩放把手叠放(把手覆盖窗口左右边缘)
    $outer = New-Object System.Windows.Controls.Grid
    $outer.Children.Add($border) | Out-Null
    $outer.Children.Add($leftStrip) | Out-Null
    $outer.Children.Add($rightStrip) | Out-Null

    # 共享拖拽/缩放状态(事件回调看不到函数局部变量,放 Tag)
    $win.Tag = @{ resizing = $false; startX = 0.0; startWidth = 0.0; startLeft = 0.0; edge = 'right' }

    $win.Add_Loaded({
        $work = [System.Windows.SystemParameters]::WorkArea
        $pos = $cmd.position
        if ($null -ne $pos -and $null -ne $pos.left -and $null -ne $pos.top) {
            $win.Left = [double]$pos.left + $work.Left
            $win.Top = [double]$pos.top + $work.Top
        } else {
            $win.Left = $work.Right - $win.ActualWidth - 20
            $win.Top = $work.Bottom - $win.ActualHeight - 20
        }
        Send-Geometry $win
    }.GetNewClosure()) | Out-Null

    # 拖拽移动(缩放把手区域除外):DragMove 阻塞至松开,结束后收敛到工作区内并回传几何。
    $win.Add_MouseLeftButtonDown({
        if ($win.Tag.resizing) { $win.Tag.resizing = $false; return }
        try { $win.DragMove() } catch { }
        try {
            $work = [System.Windows.SystemParameters]::WorkArea
            $win.Left = [Math]::Max($work.Left, [Math]::Min($win.Left, $work.Right - $win.ActualWidth))
            $win.Top = [Math]::Max($work.Top, [Math]::Min($win.Top, $work.Bottom - $win.ActualHeight))
        } catch { }
        Send-Geometry $win
    }.GetNewClosure()) | Out-Null

    # 拖拽边缘缩放宽度(260–520):右缘拖右变宽;左缘拖左变宽且右缘固定(窗口左移)。
    # 注意:$strip/$edge/$win 都作为函数参数,闭包才能可靠捕获。
    function Add-EdgeResize($strip, [string]$edge, $w) {
        $strip.Add_MouseLeftButtonDown({
            $w.Tag.resizing = $true
            $w.Tag.edge = $edge
            $w.Tag.startX = $_.GetPosition($w).X
            $w.Tag.startWidth = $w.ActualWidth
            $w.Tag.startLeft = $w.Left
            $strip.CaptureMouse()
            $_.Handled = $true
        }.GetNewClosure()) | Out-Null
        $strip.Add_MouseMove({
            if ($w.Tag.resizing) {
                $dx = $_.GetPosition($w).X - $w.Tag.startX
                if ($w.Tag.edge -eq 'left') {
                    $nw = [Math]::Max(260, [Math]::Min(520, [Math]::Round($w.Tag.startWidth - $dx)))
                    $w.Width = $nw
                    $w.Left = $w.Tag.startLeft + ($w.Tag.startWidth - $w.Width)
                } else {
                    $nw = [Math]::Max(260, [Math]::Min(520, [Math]::Round($w.Tag.startWidth + $dx)))
                    $w.Width = $nw
                }
                $_.Handled = $true
            }
        }.GetNewClosure()) | Out-Null
        $strip.Add_MouseLeftButtonUp({
            if ($w.Tag.resizing) {
                $w.Tag.resizing = $false
                if ($strip.IsMouseCaptured) { $strip.ReleaseMouseCapture() }
                Send-Geometry $w
                $_.Handled = $true
            }
        }.GetNewClosure()) | Out-Null
    }
    Add-EdgeResize $leftStrip 'left' $win
    Add-EdgeResize $rightStrip 'right' $win

    $win.Add_Closed({
        if ($script:editSample -eq $win) { $script:editSample = $null }
    }.GetNewClosure()) | Out-Null

    $win.Content = $outer
    return $win
}

$script:toasts = @{}
$script:exitRequested = $false
# 编辑模式样板窗(不进入 toasts 注册表,不参与堆叠;edit-end 时关闭)。
$script:editSample = $null

function Parse-Color([string]$hex, [string]$fallback) {
    $h = $hex.TrimStart('#')
    if ($h.Length -eq 3) { $h = ($h.ToCharArray() | ForEach-Object { "$_$_" }) -join '' }
    if ($h.Length -eq 6) { $h = "FF$h" }
    if ($h.Length -ne 8 -or $h -notmatch '^[0-9a-fA-F]{8}$') {
        # 非法/缺失输入:改用回退色并同样做 3/6 位展开 + 补 FF。
        $h = $fallback.TrimStart('#')
        if ($h.Length -eq 3) { $h = ($h.ToCharArray() | ForEach-Object { "$_$_" }) -join '' }
        if ($h.Length -eq 6) { $h = "FF$h" }
    }
    return [System.Windows.Media.Color]::FromArgb(
        [Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16),
        [Convert]::ToInt32($h.Substring(6, 2), 16))
}

$downP = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(158, 164, 170))
$downI = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(30, 36, 44))
$hoverP = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(196, 202, 208))
$hoverI = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(44, 52, 62))

# 浮窗按钮:primary 时传入强调色画刷,hover/按压基于该色自动提亮/压暗;
# secondary 保持描边透明底样式。
function New-ToastButton([string]$label, [scriptblock]$onClick, [bool]$primary, [System.Windows.Media.SolidColorBrush]$fg, [System.Windows.Media.SolidColorBrush]$bg) {
    $bd = New-Object System.Windows.Controls.Border
    $bd.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $bd.Padding = New-Object System.Windows.Thickness(18, 7, 18, 7)
    $bd.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
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
    # hover/down 变体:primary 基于传入的强调色提亮/压暗;secondary 用全局灰蓝变体。
    $bd.Tag = @{
        primary = $primary; onClick = $onClick
        hoverP  = (Convert-Hsl $fg.Color 1.15); downP = (Convert-Hsl $fg.Color 0.85)
        hoverI  = $hoverI; downI = $downI
        fg      = $fg; bg = $bg
    }
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
        # closing 标记改为 Tag 哈希表(同时携带卡片缩放变换供退场动画用)。
        if ($w.Tag -is [hashtable]) {
            if ($w.Tag.closing) { return }
            $w.Tag.closing =$true
        } else {
            if ($w.Tag -eq 'closing') { return }
            $w.Tag = @{ closing =$true; scale = $null }
        }
        # 淡出 + 下坠 + 轻微收缩(0.98):三者同步 200ms,"沉落"退场。
        $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(1, 0, [TimeSpan]::FromMilliseconds(200))
        $fadeOut.EasingFunction =$easeExit
        $fadeOut.Add_Completed({
            try { $w.Close() } catch { }
        }.GetNewClosure()) | Out-Null
        $w.BeginAnimation([System.Windows.Window]::OpacityProperty,$fadeOut)
        $dropAn = New-Object System.Windows.Media.Animation.DoubleAnimation($w.Top, ($w.Top + 16), [TimeSpan]::FromMilliseconds(200))
        $dropAn.EasingFunction =$easeExit
        $w.BeginAnimation([System.Windows.Window]::TopProperty,$dropAn)
        try {
            $sc =$w.Tag.scale
            if ($sc -ne$null) {
                $sx = New-Object System.Windows.Media.Animation.DoubleAnimation(1, 0.98, [TimeSpan]::FromMilliseconds(200))
                $sx.EasingFunction =$easeExit
                $sy = New-Object System.Windows.Media.Animation.DoubleAnimation(1, 0.98, [TimeSpan]::FromMilliseconds(200))
                $sy.EasingFunction =$easeExit
                $sc.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty,$sx)
                $sc.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty,$sy)
            }
        } catch { }
        $backstop = New-Object System.Windows.Threading.DispatcherTimer
        $backstop.Interval = [TimeSpan]::FromMilliseconds(600)
        $backstop.Tag =$w
        $backstop.Add_Tick({
            $this.Stop()
            try { if ($this.Tag.IsVisible) {$this.Tag.Close() } } catch { }
        }) | Out-Null
        $backstop.Start()
    } catch {
        try { $w.Close() } catch { }
    }
}

# ───────────────────────── 通知浮窗 ─────────────────────────

function New-ToastWindow($cmd) {
    $bg = Parse-Color ([string]$cmd.bg) "#20272f"
    $fg = Parse-Color ([string]$cmd.fg) "#e6edf3"
    $accent = Parse-Color ([string]$cmd.accent) "#60a5fa"
    $bgBrush = New-Object System.Windows.Media.SolidColorBrush($bg)
    $fgBrush = New-Object System.Windows.Media.SolidColorBrush($fg)
    $accentBrush = New-Object System.Windows.Media.SolidColorBrush($accent)

    # 提前计算:粘性判定与倒计时时长(Loaded 闭包与计时器共用)。
    $isSticky = ($cmd.sticky -eq $true)
    $dur = [Math]::Max(1, [int]$cmd.durationSec)

    $win = New-Object System.Windows.Window
    $win.WindowStyle = [System.Windows.WindowStyle]::None
    $win.AllowsTransparency =$true
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $win.Topmost =$true
    $win.ShowInTaskbar =$false
    if ($null -ne$cmd.width) { $win.Width = [double]$cmd.width } else { $win.Width = 340 }
    $win.SizeToContent = [System.Windows.SizeToContent]::Height
    if (-not [string]::IsNullOrEmpty([string]$cmd.winTitle)) {$win.Title = [string]$cmd.winTitle }
    $win.Effect = New-GlowEffect $accent 0.28

    $border = New-Object System.Windows.Controls.Border
    $border.Background =$bgBrush
    $border.BorderBrush =$accentBrush
    $border.BorderThickness = New-Object System.Windows.Thickness(1)
    $border.CornerRadius = New-Object System.Windows.CornerRadius(14)
    $border.Margin = New-Object System.Windows.Thickness(12)

    # 卡片缩放变换:入场 0.96→1(底部锚点,"浮现"),退场 1→0.98("沉落")。
    # 经 $win.Tag 传给 Close-WithFade,同时 Tag.closing 作防重入标记。
    $cardT = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $border.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 1)
    $border.RenderTransform =$cardT

    # 内容 Grid:3 行 = 头部(标题) / 正文 / 按钮行
    $root = New-Object System.Windows.Controls.Grid
    $root.Margin = New-Object System.Windows.Thickness(26, 12, 14, 12)
    Add-GridRow $root
    Add-GridRow $root
    Add-GridRow $root

    # ── 头部:仅标题 ──
    $head = New-Object System.Windows.Controls.StackPanel
    $head.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $head.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    $unnamedLabel = if ([string]::IsNullOrEmpty([string]$cmd.unnamedLabel)) { "(Unnamed session)" } else { [string]$cmd.unnamedLabel }
    $titleText = New-Object System.Windows.Controls.TextBlock
    $titleText.Text = if ([string]::IsNullOrEmpty([string]$cmd.title)) { $unnamedLabel } else { [string]$cmd.title }
    $titleText.Foreground =$fgBrush
    $titleText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
    $titleText.FontSize = 13
    $titleText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $titleText.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $titleText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $head.Children.Add($titleText) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($head, 0)
    $root.Children.Add($head) | Out-Null

    # ── 正文 ──
    $bodyText = New-Object System.Windows.Controls.TextBlock
    $bodyText.Text = [string]$cmd.text
    $bodyText.Foreground =$fgBrush
    $bodyText.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
    $bodyText.FontSize = 13
    $bodyText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $bodyText.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
    [System.Windows.Controls.Grid]::SetRow($bodyText, 1)
    $root.Children.Add($bodyText) | Out-Null

    # ── 按钮行 ──
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btnRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $btnRow.Margin = New-Object System.Windows.Thickness(0, 0, 0, 2)
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
        }.GetNewClosure()) $true $accentBrush $bgBrush
        $btnRow.Children.Add($jumpBtn) | Out-Null
    }
    [System.Windows.Controls.Grid]::SetRow($btnRow, 2)
    $root.Children.Add($btnRow) | Out-Null

    # ── 倒计时液面层(唯一的倒计时视觉,无任何线条元素) ──
    $inner = New-Object System.Windows.Controls.Grid
    $tintLayer = New-Object System.Windows.Controls.Border
    $tintLayer.CornerRadius = New-Object System.Windows.CornerRadius(13, 0, 0, 13)
    $tintLayer.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    $tintLayer.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $tintBrush = New-Object System.Windows.Media.SolidColorBrush($accent)
    $tintBrush.Opacity = 0.12
    $tintLayer.Background =$tintBrush
    $tintT = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $tintLayer.RenderTransformOrigin = New-Object System.Windows.Point(0, 0.5)
    $tintLayer.RenderTransform =$tintT
    $inner.Children.Add($tintLayer) | Out-Null
    $inner.Children.Add($root) | Out-Null
    $border.Child =$inner

    # ── 左侧强调色条(粘性通知做呼吸脉动) ──
    $accentStrip = New-Object System.Windows.Controls.Border
    $accentStrip.Width = 4
    $accentStrip.CornerRadius = New-Object System.Windows.CornerRadius(2)
    $accentStrip.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    $accentStrip.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $accentStrip.Margin = New-Object System.Windows.Thickness(22, 26, 0, 26)
    $accentStrip.Background =$accentBrush

    # 外层只有:卡片 + 色条。进度指针已彻底移除 —— 任何通知都不再出现那根线。
    $outer = New-Object System.Windows.Controls.Grid
    $outer.Children.Add($border) | Out-Null
    $outer.Children.Add($accentStrip) | Out-Null
    $win.Content =$outer

    $win.Tag = @{ closing =$false; scale = $cardT }

    $win.Add_Loaded({
        $work = [System.Windows.SystemParameters]::WorkArea
        $pos =$cmd.position
        if ($null -ne$pos -and $null -ne$pos.left -and $null -ne$pos.top) {
            $targetLeft = [double]$pos.left + $work.Left
            $targetTop = [double]$pos.top + $work.Top - [int]$cmd.offsetY
        } else {
            $targetLeft =$work.Right - $win.ActualWidth - 20
            $targetTop =$work.Bottom - $win.ActualHeight - 20 - [int]$cmd.offsetY
        }
        $win.Left =$targetLeft
        $win.Top =$targetTop + 36
        $win.Opacity = 0
        try {
            $easingIn = New-Object System.Windows.Media.Animation.QuadraticEase
            $easingIn.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
            # 入场三连:上滑 36px + 淡入 + 卡片 0.96→1 缩放(底部锚点),260ms 同步完成。
            $slideIn = New-Object System.Windows.Media.Animation.DoubleAnimation($targetTop + 36, $targetTop, [TimeSpan]::FromMilliseconds(260))
            $slideIn.EasingFunction =$easingIn
            $win.BeginAnimation([System.Windows.Window]::TopProperty,$slideIn)
            $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(200))
            $fadeIn.EasingFunction =$easingIn
            $win.BeginAnimation([System.Windows.Window]::OpacityProperty,$fadeIn)
            $scInX = New-Object System.Windows.Media.Animation.DoubleAnimation(0.96, 1, [TimeSpan]::FromMilliseconds(260))
            $scInX.EasingFunction =$easingIn
            $scInY = New-Object System.Windows.Media.Animation.DoubleAnimation(0.96, 1, [TimeSpan]::FromMilliseconds(260))
            $scInY.EasingFunction =$easingIn
            $cardT.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty,$scInX)
            $cardT.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty,$scInY)
            $guard = New-Object System.Windows.Threading.DispatcherTimer
            $guard.Interval = [TimeSpan]::FromMilliseconds(400)
            $guard.Tag = @{ w =$win; top = $targetTop }
            $guard.Add_Tick({
                $this.Stop()
                $g =$this.Tag
                try {
                    if ($g.w.Opacity -lt 0.9) {$g.w.Opacity = 1 }
                    if ($g.w.Top -ne$g.top) { $g.w.Top =$g.top }
                } catch { }
            }) | Out-Null
            $guard.Start()
        } catch {
            $win.Opacity = 1
            $win.Top =$targetTop
        }
        try {
            $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
            Send-Report @{
                type       = 'pos'; key = [string]$cmd.key; instance = [int]$cmd.instance
                left       = [Math]::Round($targetLeft); top = [Math]::Round($targetTop)
                height     = [Math]::Round($win.ActualHeight); hwnd =$hwnd.ToInt64()
                workBottom = [Math]::Round($work.Bottom)
            }
        } catch { }

        # ── 停留阶段:非粘性 = 液面匀速右→左;粘性 = 色条呼吸 ──
        if (-not $isSticky) {
            try {
                $shrink = New-Object System.Windows.Media.Animation.DoubleAnimation(
                    1, 0, [TimeSpan]::FromSeconds($dur))
                # 无缓动:视觉时长 = 真实剩余时间。
                $tintT.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty,$shrink)
            } catch { }
        } else {
            try {
                $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation(0.55, 1.0,
                    [TimeSpan]::FromMilliseconds(1100))
                $pulse.AutoReverse =$true
                $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                $pulse.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
                $accentStrip.BeginAnimation([System.Windows.UIElement]::OpacityProperty,$pulse)
            } catch { }
        }
    }.GetNewClosure()) | Out-Null

    $toastsRef =$script:toasts
    $win.Add_Closed({
        if ($toastsRef.ContainsKey([string]$cmd.key)) {
            $rec =$toastsRef[[string]$cmd.key]
            if ($rec.Timer -ne$null) {
                try { $rec.Timer.Stop() } catch { }
            }
            $toastsRef.Remove([string]$cmd.key) | Out-Null
        }
        Send-Report @{ type = 'exit'; key = [string]$cmd.key; instance = [int]$cmd.instance }
    }.GetNewClosure()) | Out-Null

    $rec = @{ Win =$win; Body = $bodyText; Title =$titleText; Timer = $null; Instance = [int]$cmd.instance }
    $script:toasts[[string]$cmd.key] = $rec

    if (-not $isSticky) {
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds($dur)
        $timer.Add_Tick({$this.Stop(); Close-WithFade $win }.GetNewClosure()) | Out-Null
        $timer.Start()
        $rec.Timer =$timer
    }

    return $win
}

# ───────────────────────── 命令处理 ─────────────────────────

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
                # 可选横向定位:left 数字 = 绝对 X(工作区相对);left 'default' = 默认右下贴边
                # (工作区右缘 - 宽度 - 20)。用于编辑调整位置/恢复默认后,在屏浮窗立即到位。
                if ($null -ne $cmd.left) {
                    $newLeft = 0.0
                    if ($cmd.left -eq 'default') {
                        $work = [System.Windows.SystemParameters]::WorkArea
                        $newLeft = $work.Right - $rec.Win.ActualWidth - 20
                    } else {
                        $newLeft = [double]$cmd.left
                    }
                    $slideL = New-Object System.Windows.Media.Animation.DoubleAnimation($rec.Win.Left, $newLeft, [TimeSpan]::FromMilliseconds(220))
                    $slideL.EasingFunction = $easeMove
                    $rec.Win.BeginAnimation([System.Windows.Window]::LeftProperty, $slideL)
                }
            }
        }
        'close' {
            $rec = $script:toasts[[string]$cmd.key]
            if ($rec -ne $null) { Close-WithFade $rec.Win }
        }
        'size' {
            $rec = $script:toasts[[string]$cmd.key]
            if ($rec -ne $null -and $null -ne $cmd.width) { $rec.Win.Width = [double]$cmd.width }
        }
        'edit' {
            # 编辑模式:关闭旧样板(如有),弹新样板窗(可拖拽/缩放,内嵌类型色卡预览)。
            if ($script:editSample -ne $null) {
                try { $script:editSample.Close() } catch { }
                $script:editSample = $null
            }
            $w = New-EditSample $cmd
            if ($w -ne $null) { $w.Show(); $script:editSample = $w }
        }
        'edit-end' {
            if ($script:editSample -ne $null) {
                try { $script:editSample.Close() } catch { }
                $script:editSample = $null
            }
        }
        'shutdown' { $script:exitRequested = $true }
    }
}

# ───────────────────────── 主循环 ─────────────────────────

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
            if ($script:editSample -ne $null) {
                try { $script:editSample.Close() } catch { }
                $script:editSample = $null
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
