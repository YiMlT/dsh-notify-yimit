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
# 样板窗额外回传 baselineTop = 基准线(卡片可见底边)在窗口内的 Y 偏移,
# 供前端把它换算成屏幕坐标存进配置。
function Send-Geometry($w) {
    try {
        $work = [System.Windows.SystemParameters]::WorkArea
        $lineInWin = 0.0
        if ($w.Tag -is [hashtable] -and $null -ne $w.Tag.lineInWin) {
            $lineInWin = [double]$w.Tag.lineInWin
        }
        # ── 坐标口径必须与"重开时的定位口径"完全一致 ──
        # 定位时:$win.Top = $pos.top − lineInWin(即 $pos.top 是基准线的屏幕 Y)。
        # 因此这里回传的 top 也必须是**基准线的屏幕 Y**,而不是窗口顶边:
        #     top = 窗口顶边 + lineInWin
        # 若回传窗口顶边,index.js 再把它当基准线存下来,就会出现
        # "每进一次编辑模式基准线就往下漂一个带高"的问题(实测复现过)。
        # baselineTop 仍回传"基准线从窗口顶边算起的偏移",供前端换算/调试。
        $msg = @{
            type        = 'geometry'
            left        = [Math]::Round($w.Left - $work.Left)
            top         = [Math]::Round($w.Top - $work.Top + $lineInWin)
            width       = [Math]::Round($w.ActualWidth)
            height      = [Math]::Round($w.ActualHeight)
            baselineTop = [Math]::Round($lineInWin)
        }
        Send-Report $msg
    } catch { }
}

# ───────────────────────── 编辑模式样板窗 ─────────────────────────

# 基准线指示带固定高度(px):横线(2) + 3px 间距 + 箭头(19) + 2px 余量。
# 固定值而非 Auto:基准线到窗口底边的距离必须可预测,否则回传的基准线位置
# 会随字体度量浮动、与实际画的那条线对不上(编辑模式靠它反推窗口落点)。
$script:ANCHOR_BAND_H = 26

# 通知窗口内"可见卡片底边"到**窗口底边**的距离(px)。
# 实测地推:卡片底边 = 窗口顶边 + (窗口高 − 12);该 12 即 $border.Margin 的辉光边距。
# 注意它是"到窗口底边"的距离,不是"到窗口顶边"的偏移 —— 因此底部锚定的抬升量
# 必须写成 (窗口高 − TOAST_BOTTOM_GAP),随卡片高度自适应,绝不能写成固定值:
#     窗口顶边 = 锚点Y − (窗口高 − TOAST_BOTTOM_GAP) − offsetY
# 这样"卡片可见底边 = 锚点Y − offsetY",内容多长底边都钉在锚点上。
$script:TOAST_BOTTOM_GAP = 12

# 箭头用矢量多边形而非字体字形绘制:字形自带行距死区(上/下各数 px),
# 会把箭头推离横线、甚至溢出窗口被裁切;矢量图形能精确对齐到横线。
$script:ANCHOR_ARROW_W = 14
$script:ANCHOR_ARROW_H = 19
$script:ANCHOR_ARROW_GAP = 3

# 构造向上的空心箭头(chevron)多边形:顶点在正上方,两翼向下张开。
# 返回 PointCollection,坐标系原点在箭头外接框左上角。
function New-AnchorArrowPoints([double]$w, [double]$h) {
    $hw = $w / 2.0
    $th = [Math]::Max(2.0, $h * 0.45)          # 两翼的竖直厚度
    $tip = $hw * 0.62                           # 翼尖相对中轴的横向偏移
    $notch = $h * 0.42                          # 内凹点深度(形成空心)
    # 注意:PowerShell 中 `-` 与 `*` 的优先级容易误读,复合运算一律加括号。
    $pts = New-Object System.Windows.Media.PointCollection
    $pts.Add((New-Object System.Windows.Point($hw, 0)))                        # 顶点(贴住横线)
    $pts.Add((New-Object System.Windows.Point($w, $th)))                       # 右翼外侧
    $pts.Add((New-Object System.Windows.Point(($w - ($hw - $tip)), ($th + $tip))))  # 右翼尖端
    $pts.Add((New-Object System.Windows.Point($hw, $notch)))                   # 内凹点
    $pts.Add((New-Object System.Windows.Point(($hw - $tip), ($th + $tip))))    # 左翼尖端
    $pts.Add((New-Object System.Windows.Point(0, $th)))                        # 左翼外侧
    # 逗号运算符:PointCollection 实现了 IEnumerable,直接 return 会被 PowerShell
    # 展开成 Object[],导致赋值给 Polygon.Points 失败。
    return , $pts
}

# 基准线指示带(仅编辑模式):一条横线 + 居中 ↑,紧贴在卡片"可见底边"正下方,
# 用来告诉用户"通知以该位置为基准,自定义通知均在此线上方"。
#
# 几何约定(方案 A,务必与 New-EditSample 的边距算式保持一致):
#   · 横线位于网格第 0 行,即带的顶边;↑ 叠放在同一格内(线画在箭头之上)。
#   · 带高固定(常量 $script:ANCHOR_BAND_H):固定值而非 Auto,基准线到窗口底边
#     的距离才可预测,回传的基准线位置才不会与实际画的线不一致。
function New-AnchorBand([System.Windows.Media.Color]$accent, [string]$label, [double]$maxLabelWidth) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Height = $script:ANCHOR_BAND_H
    $grid.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    # 必须 Top:若用 Center/Stretch 居中,线会被推到格子中间,离卡片底边多出一段距离。
    $grid.VerticalAlignment = [System.Windows.VerticalAlignment]::Top

    # ① 横线:强调色实线 + 辉光,两端小圆点形成"标尺"感
    $line = New-Object System.Windows.Controls.Grid
    $line.Height = 2
    $line.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $line.Background = New-Object System.Windows.Media.SolidColorBrush($accent)
    $line.Effect = New-GlowEffect $accent 0.55
    foreach ($side in @('Left', 'Right')) {
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 6
        $dot.Height = 6
        $dot.Fill = New-Object System.Windows.Media.SolidColorBrush($accent)
        # 竖直居中于 2px 线上,视觉上成为线段两端的端点。
        # 注意:枚举成员不能用 ::$side 这种写法展开(PowerShell 会当成属性访问而报错),
        # 必须显式分支赋值。
        if ($side -eq 'Left') {
            $dot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        } else {
            $dot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        }
        $dot.Margin = New-Object System.Windows.Thickness(0, -2, 0, -2)
        $line.Children.Add($dot) | Out-Null
    }
    $grid.Children.Add($line) | Out-Null

    # ② ↑ + 可选文字:叠放在线之下(同一格)。
    #    三列等分(各 1*):中列 = ↑,天然落在整条带的正中点;右列 = 文字。
    #    这样"文字不会把 ↑ 推偏",且文字过宽时由自身的 TextTrimming 处理。
    $cap = New-Object System.Windows.Controls.Grid
    $cap.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $cap.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $cap.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
    foreach ($i in 1..3) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $cap.ColumnDefinitions.Add($col) | Out-Null
    }

    $arrow = New-Object System.Windows.Shapes.Polygon
    $arrow.Points = New-AnchorArrowPoints $script:ANCHOR_ARROW_W $script:ANCHOR_ARROW_H
    $arrow.Fill = New-Object System.Windows.Media.SolidColorBrush($accent)
    $arrow.Width = $script:ANCHOR_ARROW_W
    $arrow.Height = $script:ANCHOR_ARROW_H
    $arrow.Stretch = [System.Windows.Media.Stretch]::Fill
    $arrow.Effect = New-GlowEffect $accent 0.45
    # 顶点贴住横线,只留 $script:ANCHOR_ARROW_GAP 的呼吸量(矢量图形无字形死区)。
    $arrow.Margin = New-Object System.Windows.Thickness(0, $script:ANCHOR_ARROW_GAP, 0, 0)
    $arrow.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    # 用一个撑满中列的容器来居中箭头:不依赖"列宽 = 箭头宽"这一巧合,
    # 否则同列的文字一变宽,箭头就会被带偏。
    $arrowBox = New-Object System.Windows.Controls.Border
    $arrowBox.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $arrowBox.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $arrowBox.Child = $arrow
    [System.Windows.Controls.Grid]::SetColumn($arrowBox, 1)
    $cap.Children.Add($arrowBox) | Out-Null

    if (-not [string]::IsNullOrEmpty($label)) {
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = $label
        $txt.Foreground = New-Object System.Windows.Media.SolidColorBrush($accent)
        $txt.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI")
        $txt.FontSize = 11
        $txt.Opacity = 0.92
        $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
        $txt.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $txt.Margin = New-Object System.Windows.Thickness(10, 1, 0, 0)
        # 限宽 + 省略号:文案过长时按字符截断,不挤压 ↑、也不超出窗口。
        $txt.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $txt.MaxWidth = [Math]::Max(80, $maxLabelWidth)
        [System.Windows.Controls.Grid]::SetColumn($txt, 2)
        $cap.Children.Add($txt) | Out-Null
    }

    $grid.Children.Add($cap) | Out-Null
    return $grid
}

# 编辑模式样板窗:拖拽移动 + 左右边缘圆点把手缩放;拖拽/缩放结束后回传 geometry。
# 强调色描边 + 辉光;内嵌 5 类型实时色卡预览(chips);多语言提示;
# 卡片下方带"基准线 + ↑"指示带(方案 A)。
function New-EditSample($cmd) {
    $bg = Parse-Color ([string]$cmd.bg) "#203a5c"
    $fg = Parse-Color ([string]$cmd.fg) "#e8f0fb"
    $accent = Parse-Color ([string]$cmd.accent) "#60a5fa"
    $bgBrush = New-Object System.Windows.Media.SolidColorBrush($bg)
    $fgBrush = New-Object System.Windows.Media.SolidColorBrush($fg)
    $accentBrush = New-Object System.Windows.Media.SolidColorBrush($accent)

    # ── 几何总纲(务必与手柄、带行的算式保持一致) ──
    # $glowMargin 同时是:左右辉光呼吸量、卡片左/右/上边距、左右缩放把手的边距。
    #   · 卡片:左/右边距相等 → 始终居中;卡宽 = 窗口宽 − 2×$glowMargin。
    #   · 手柄:左右边距同样为 $glowMargin(宽 8px)→ 左右手柄"内沿"之间
    #     = 窗口宽 − 2×$glowMargin = 卡宽,即手柄与卡片严格等宽、等左右沿。
    #   · 下边距必须为 0:卡片因此一直铺到第 0 行的底边,而第 1 行(带行)紧随其后,
    #     所以横线正好压在卡片可见底边上;卡片高度 = 行高 = 手柄高度。
    #     若在这里留边距,卡片会在自己所在行内被顶上去,横线就会离开卡片底边。
    #   · 底部呼吸量由带行自身(透明)提供,无需再留边距。
    $glowMargin = 8
    $bandHeight = [double]$script:ANCHOR_BAND_H
    $bottomMargin = 0
    # 基准线(卡片可见底边)到**窗口底边**的距离 = 卡片下边距 + 带高。
    # 实测:带(含自身下边距)紧贴第 0 行底部,故卡片可见底边 = 窗口高 − 该值,
    # 也就是横线自身的 Y。这是"从底部算"的量。
    # 注意:真正用于定位/回传的是"从窗口顶边算"的 lineInWin(在 Loaded 里实测),
    # 两者基准不同,不可混用 —— 混用会导致每次重开编辑模式基准线漂移一个带高。
    $baselineFromBottom = $bottomMargin + $bandHeight

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
    $border.Margin = New-Object System.Windows.Thickness($glowMargin, $glowMargin, $glowMargin, $bottomMargin)

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
    # 把手竖直范围 = 卡片可见上下沿(下边距用带高,故把手不会压到基准线指示带上)。
    $leftStrip.Margin = New-Object System.Windows.Thickness(0, $glowMargin, 0, $bottomMargin)
    $leftStrip.Background = $edgeBrush
    $leftStrip.CornerRadius = New-Object System.Windows.CornerRadius(14, 0, 0, 14)
    $rightStrip = New-Object System.Windows.Controls.Border
    $rightStrip.Width = 8
    $rightStrip.Cursor = [System.Windows.Input.Cursors]::SizeWE
    $rightStrip.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $rightStrip.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    $rightStrip.Margin = New-Object System.Windows.Thickness(0, $glowMargin, 0, $bottomMargin)
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

    # 外层 Grid:边框 + 基准线指示带 + 左右缩放把手叠放(把手覆盖窗口左右边缘)
    $outer = New-Object System.Windows.Controls.Grid
    # 两条等分行:第 0 行卡片(占满剩余高度),第 1 行 = 基准线指示带。
    $rowCard = New-Object System.Windows.Controls.RowDefinition
    $rowCard.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $rowBand = New-Object System.Windows.Controls.RowDefinition
    $rowBand.Height = [System.Windows.GridLength]::Auto
    $outer.RowDefinitions.Add($rowCard) | Out-Null
    $outer.RowDefinitions.Add($rowBand) | Out-Null

    # 文案限宽:窗口宽度的一半多一点,过长按字符省略。
    $band = New-AnchorBand $accent ([string]$cmd.anchorLabel) ([Math]::Max(80, $win.Width * 0.55))
    [System.Windows.Controls.Grid]::SetRow($band, 1)
    $outer.Children.Add($border) | Out-Null
    $outer.Children.Add($band) | Out-Null
    $outer.Children.Add($leftStrip) | Out-Null
    $outer.Children.Add($rightStrip) | Out-Null

    # 共享拖拽/缩放状态(事件回调看不到函数局部变量,放 Tag)
    # lineInWin:基准线(卡片可见底边)从**窗口顶边**量起的 Y 偏移。
    #   定位与回传都用它,保证"存下的坐标"与"重开时的落点"是同一个量。
    $win.Tag = @{
        resizing = $false
        startX = 0.0
        startWidth = 0.0
        startLeft = 0.0
        edge = 'right'
        lineInWin = 0.0
    }

    $win.Add_Loaded({
        $work = [System.Windows.SystemParameters]::WorkArea
        $pos = $cmd.position
        # ── 基准线自测(消除"从顶部算/从底部算"的混用) ──
        # 先把窗口顶边临时归零,等布局落定后量出基准线在窗口内的真实 Y(从窗口顶边算起)。
        # 之后定位与 Send-Geometry 回传都用这同一个量,于是"存下的坐标"与"重开的落点"
        # 必然一致,不会再出现每进一次编辑模式就漂移一截的问题。
        $win.Top = 0
        $win.UpdateLayout()
        $lineInWin = $border.TranslatePoint(
            (New-Object System.Windows.Point(0, $border.ActualHeight)), $win).Y
        if ($lineInWin -le 0) {
            # 兜底:布局尚未就绪时用"窗口高 − 从底部算的距离"估算。
            $lineInWin = $win.ActualHeight - $bottomMargin - $bandHeight
        }
        $win.Tag.lineInWin = $lineInWin
        if ($null -ne $pos -and $null -ne $pos.left -and $null -ne $pos.top) {
            $win.Left = [double]$pos.left + $work.Left
            $win.Top = [double]$pos.top + $work.Top - $lineInWin
        } else {
            # 编辑模式的样板窗贴住工作区右下角:窗口底边 = 工作区底边。
            # (此处不加 20px 呼吸量 —— 用户明确要求样板窗能贴到屏幕最底部;
            #  窗口底边即"基准线 + ↑"指示带所在行,基准线因此落在离屏幕底
            #  一个带高的位置,通知向上堆叠时正好从屏幕底部往上排。)
            $win.Left = $work.Right - $win.ActualWidth
            $win.Top = $work.Bottom - $win.ActualHeight
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

# 「返回应用」:把已在运行的 DeepSeek Harness 桌面窗口切到前台。
#
# 为什么不能靠 dsh://open:应用只在 macOS 的 `open-url` 事件里处理 `dsh://open`
# (Windows 上协议 URL 是作为 argv 交给新进程的,而它的 `second-instance` 处理器
# 不读 argv、也不校验 URL),所以那条路在 Windows 上是死代码。
#
# 因此改为直接枚举窗口并激活。合法性:用户点按钮的那一刻,前台窗口就是这个 WPF
# 浮窗(属于本宿主进程),所以宿主调用 SetForegroundWindow 不会被
# "只有前台进程才能抢占前台"的系统限制挡住。
$script:ToastWin32Ready = $false
try {
    if (-not ('ToastWin32' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class ToastWin32 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT wp);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT {
        public int length;
        public int flags;
        public int showCmd;
        public POINT ptMinPosition;
        public POINT ptMaxPosition;
        public RECT rcNormalPosition;
    }

    private const uint GW_OWNER = 4;
    private const int SW_SHOWNORMAL = 1;
    private const int SW_SHOWMINIMIZED = 2;
    private const int SW_SHOWMAXIMIZED = 3;
    private const int SW_SHOW = 5;
    private const int SW_RESTORE = 9;
    /// WPF_RESTORETOMAXIMIZED:最小化前是最大化状态
    private const int WPF_RESTORETOMAXIMIZED = 0x0002;

    /// 找出 pid 名下最可能是"主窗口"的顶层窗口。
    ///
    /// 实测要点(这台机器上枚举到 280 个窗口、其中 20 个可见):
    /// 应用最小化到托盘 / 被隐藏时,它的主窗口会变成 **不可见**,甚至带上 owner
    /// 关系。若像最初那样要求"可见 + 非 owner",这两条会把主窗口全部滤掉,
    /// 结果就是"点了返回应用没反应"。因此这里分级挑选:
    ///   1) 可见 + 有标题 + 非 owner(正常情况,最可靠)
    ///   2) 有标题 + 非 owner(隐藏/托盘态)
    ///   3) 有标题(连 owner 关系都能容忍)
    /// 每级内部取面积最大者,Electron 的辅助窗口通常面积很小或没有标题。
    public static IntPtr FindMainWindow(uint pid) {
        IntPtr shell = GetShellWindow();
        IntPtr[] best = new IntPtr[3];
        long[] bestArea = new long[3] { -1, -1, -1 };
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint wpid = 0;
            GetWindowThreadProcessId(h, out wpid);
            if (wpid != pid) return true;
            if (h == shell) return true;
            if (GetWindowTextLength(h) <= 0) return true;

            bool visible = IsWindowVisible(h);
            bool owned = GetWindow(h, GW_OWNER) != IntPtr.Zero;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            long area = (long)(r.Right - r.Left) * (long)(r.Bottom - r.Top);

            int tier;
            if (visible && !owned) tier = 0;
            else if (!owned) tier = 1;
            else tier = 2;

            if (area > bestArea[tier]) { bestArea[tier] = area; best[tier] = h; }
            return true;
        }, IntPtr.Zero);

        for (int i = 0; i < 3; i++) { if (best[i] != IntPtr.Zero) return best[i]; }
        return IntPtr.Zero;
    }

    /// 把 hWnd 提到前台,并**保持窗口原有的尺寸/最大化状态**。
    ///
    /// 关键:`ShowWindow(h, SW_RESTORE)` 会把"最小化**或**最大化"的窗口还原成
    /// 原始(默认)尺寸 —— 这正是"窗口本来最大化、只是不在最上层,点返回应用后
    /// 变成默认大小"的原因。所以这里必须先查询显示状态:
    ///   · 最小化 → SW_RESTORE(恢复原尺寸,若原先最大化会恢复成最大化)
    ///   · 最大化 → SW_SHOWMAXIMIZED
    ///   · 普通   → SW_SHOW(只显示/置顶,**不改尺寸**)
    /// SetForegroundWindow 受"仅前台进程可抢占前台"限制,失败时按通行做法
    /// 附加到当前前台线程的输入队列后重试一次。
    public static bool Activate(IntPtr h) {
        if (h == IntPtr.Zero) return false;

        WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
        wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        int show = SW_SHOW;
        if (GetWindowPlacement(h, ref wp)) {
            int cur = wp.showCmd;
            if (cur == SW_SHOWMINIMIZED) {
                show = (wp.flags & WPF_RESTORETOMAXIMIZED) != 0 ? SW_SHOWMAXIMIZED : SW_RESTORE;
            } else if (cur == SW_SHOWMAXIMIZED) {
                show = SW_SHOWMAXIMIZED;
            }
        }
        ShowWindow(h, show);

        if (SetForegroundWindow(h)) return true;
        IntPtr fg = GetForegroundWindow();
        uint dummy = 0;
        uint tidFg = fg == IntPtr.Zero ? 0u : GetWindowThreadProcessId(fg, out dummy);
        uint tidMe = GetWindowThreadProcessId(GetShellWindow(), out dummy);
        if (tidFg != 0u && tidFg != tidMe) {
            if (AttachThreadInput(tidMe, tidFg, true)) {
                bool ok = SetForegroundWindow(h);
                AttachThreadInput(tidMe, tidFg, false);
                if (ok) return true;
            }
        }
        return SetForegroundWindow(h);
    }
}
'@ -ErrorAction Stop
    }
    $script:ToastWin32Ready = $true
} catch {
    # Win32 互操作不可用(极少见):activateLabel 会因此不下发,按钮不出现。
    $script:ToastWin32Ready = $false
}

function Write-ActLog([string]$msg) {
    # 诊断日志:激活这一步涉及"按 exe 路径找进程 + 枚举窗口"两处环境相关行为,
    # 出问题时按钮只会静默无反应,没有日志无法定位。
    # 落点优先级:脚本所在目录(真实宿主 = lib/)→ DSH_HOME。
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg`r`n"
        $enc = New-Object System.Text.UTF8Encoding($false)
        $dirs = @()
        if (-not [string]::IsNullOrEmpty($PSScriptRoot)) { $dirs += $PSScriptRoot }
        if (-not [string]::IsNullOrEmpty($env:DSH_HOME)) { $dirs += $env:DSH_HOME }
        foreach ($d in $dirs) {
            try {
                [System.IO.File]::AppendAllText((Join-Path $d 'activate-debug.log'), $line, $enc)
                return
            } catch { }
        }
    } catch { }
}

# 启动探针:宿主每次加载(含插件重载)都记一行门控状态。
# 必须放在 Write-ActLog 定义之后,否则这个调用会因函数未定义而静默失效。
try {
    $probe = "boot: Win32Ready=$script:ToastWin32Ready"
    try { $probe += " selfExe='$((Get-Process -Id $PID).Path)'" } catch { $probe += " selfExe=<取不到>" }
    try { $probe += " DSH_HOME='$env:DSH_HOME'" } catch { }
    try { $probe += " PSScriptRoot='$PSScriptRoot'" } catch { }
    Write-ActLog $probe
} catch { }

function Invoke-ToastActivateApp([string]$appPath) {
    try {
        Write-ActLog "--- click ---"
        Write-ActLog "Win32Ready=$script:ToastWin32Ready appPath='$appPath'"
        if (-not $script:ToastWin32Ready) { Write-ActLog "中止: Win32 助手不可用"; return }
        if ([string]::IsNullOrEmpty($appPath)) { Write-ActLog "中止: appPath 为空"; return }
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath($appPath) } catch { Write-ActLog "中止: GetFullPath 失败"; return }
        Write-ActLog "full='$full' exists=$(Test-Path -LiteralPath $full)"
        if (-not (Test-Path -LiteralPath $full)) { Write-ActLog "中止: exe 路径不存在"; return }

        # Electron 的主进程与各渲染进程都是同一个 exe,窗口可能挂在其中任意一个 PID 上,
        # 所以把全部同 exe 的进程当作一组来挑窗口,而不是"谁先回答就用谁"。
        $procs = @()
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            try { if ($p.Path -eq $full) { $procs += $p } } catch { }
        }
        Write-ActLog "按 exe 匹配=$($procs.Count) pids=$(($procs | ForEach-Object { $_.Id }) -join ',')"
        if ($procs.Count -eq 0) {
            # 兜底:按进程名匹配(某些情况下 Path 取不到)。
            $nm = [System.IO.Path]::GetFileNameWithoutExtension($full)
            $procs = @(Get-Process -Name $nm -ErrorAction SilentlyContinue)
            Write-ActLog "按名 '$nm' 兜底=$($procs.Count) pids=$(($procs | ForEach-Object { $_.Id }) -join ',')"
        }
        foreach ($p in $procs) {
            $h = [ToastWin32]::FindMainWindow([uint32]$p.Id)
            Write-ActLog "  pid=$($p.Id) hwnd=$h"
            if ($h -ne [IntPtr]::Zero) {
                $ok = [ToastWin32]::Activate($h)
                Write-ActLog "  Activate=$ok fg=$([ToastWin32]::GetForegroundWindow())"
                if ($ok) { return }
            }
        }
        Write-ActLog "结束: 未找到可激活窗口"
    } catch {
        Write-ActLog "异常: $($_.Exception.GetType().Name) :: $($_.Exception.Message)"
    }
}

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
    # 「返回应用」:位于「忽略」右侧;仅桌面端出现(由 index.js 按 isDesktopRuntime 下发
    # activateLabel)。点击后把应用窗口切到前台,但**不**关闭本条通知。
    # 另外要求 Win32 互操作可用(否则无法激活窗口,宁可不显示这个按钮)。
    $activateLabel = [string]$cmd.activateLabel
    $appPath = [string]$cmd.appPath
    if ($script:ToastWin32Ready -and -not [string]::IsNullOrEmpty($activateLabel) -and
        -not [string]::IsNullOrEmpty($appPath)) {
        $activateBtn = New-ToastButton $activateLabel ({
            Invoke-ToastActivateApp $appPath
            # 按要求保留通知,不做 Close-WithFade。
        }.GetNewClosure()) $false $fgBrush $bgBrush
        $btnRow.Children.Add($activateBtn) | Out-Null
    }
    # 缺省 true = 保留「跳转会话」;桌面端宿主会显式传 jumpEnabled=false 来隐藏它。
    $jumpEnabled = $true
    if ($cmd.PSObject.Properties.Name -contains 'jumpEnabled') { $jumpEnabled = [bool]$cmd.jumpEnabled }
    if ($jumpEnabled -and -not [string]::IsNullOrEmpty([string]$cmd.sessionId)) {
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
        # ── 底部锚定定位 ──
        # 目标:本条通知"可见卡片底边"落在锚点上(卡片多高都只影响顶边)。
        #
        # 抬升量由布局实测得出,而不是靠写死的常量:
        #   $border 就是那张可见卡片,先把窗口顶边临时放到 0,量出它相对窗口的下边缘
        #   ($borderBottomInWin),于是
        #       窗口顶边 = 锚点Y − $borderBottomInWin − offsetY
        #   其中 offsetY = 该条之上已叠的高度(首条为 0)。
        # 先前用固定常量推算,卡片高度随内容变化时底边会偏离锚点(实测可差 12px 以上),
        # 所以这里改成"用布局真实值",与卡片高度彻底解耦。
        # 另:也不能写成 "$pos.top − offsetY"(那是把 pos.top 当窗口顶边的顶边锚定)。
        $win.Top = 0
        $win.UpdateLayout()
        $borderBottomInWin = $border.TranslatePoint(
            (New-Object System.Windows.Point(0, $border.ActualHeight)), $win).Y
        if ($borderBottomInWin -le 0) {
            # 兜底:布局尚未就绪时退回到"窗口高 − 常量"的估算。
            $borderBottomInWin = $win.ActualHeight - $script:TOAST_BOTTOM_GAP
        }
        if ($null -ne$pos -and $null -ne$pos.left -and $null -ne$pos.top) {
            $targetLeft = [double]$pos.left + $work.Left
            $targetTop = [double]$pos.top + $work.Top - $borderBottomInWin - [int]$cmd.offsetY
        } else {
            # 默认右下:可见卡片底边距工作区底边 20px(与 index.js 的 TOAST_EDGE_PAD 一致)。
            $targetLeft =$work.Right - $win.ActualWidth - 20
            $targetTop =$work.Bottom - 20 - $borderBottomInWin - [int]$cmd.offsetY
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
