# dsh-notify-yimit

<p align="center">
  <a href="./README.md">简体中文</a>
    /
  <a href="./README.en.md">English</a>
</p>
DeepSeek Harness 通知插件:在 **任务完成 / 任务出错 / 运行中 / 等待审批 / 等待回答** 时提醒用户。
通知标题为对话标题;系统通知与自定义通知均支持**点击跳转到对应会话**。

## 功能

- **设置页集成**:DSH 设置 → 「通知」分节(符合 DSH 原生样式,`--dsw-*` 主题变量):
  
  - 插件总开关(关闭状态下其余设置项全部禁用);
  - 通知方式**分段控制器**三选一:**Windows 系统通知** / **插件自定义样式通知** / **关闭**(默认关闭);
  - **跳转浏览器选择器**(通知方式为系统通知/自定义通知时显示;自动探测本机浏览器,
    可指定 Chrome/Edge/Firefox 等;默认=系统默认浏览器;「跳转会话」始终打开浏览器);
  - 自定义通知:**同时最多显示数量**、**显示时长**,以及**每种通知类型的背景/文字颜色**列表
    (完成=绿、出错=红、运行中=蓝、待审批=黄、待回答=紫,可逐类定制);
  - 自定义设置区块显隐带过渡动画;系统通知可一键申请浏览器通知权限。
- **触发场景**:
  | 场景 | 通知内容 |
  |---|---|
  | 任务完成 | 任务已完成 |
  | 任务出错 | 任务出错(含错误信息) |
  | 运行中 | 实时活动(开始处理 / 正在思考… / 正在生成回复… / 正在执行 \<工具\>,浮窗内容实时更新) |
  | 等待审批 | 具体的审批内容(工具名 / 原因) |
  | 等待回答 | ask_user_question 的具体问题 |
- **自定义通知 = 桌面浮窗(不依赖浏览器)**:宿主插件通过**常驻 PowerShell + WPF 宿主进程**
  在屏幕**右下角**弹出无边框置顶浮窗(多浮窗自动向上堆叠不重叠),标题、内容、**忽略**、
  **跳转会话**按钮(按钮为圆角矩形 10px);按通知类型使用对应配置的背景/文字色。完成/出错
  按显示时长后自动消失;**运行中/待审批/待回答在状态结束前不会消失**(任务结束/审批决定/
  回答完成后自动关闭)。运行中内容**原地更新文本**(400ms 节流,不重弹、不闪烁);
  待审批/待回答为状态性通知,**不做防抖**(2s 内多条审批/提问不会被吞)。浏览器页面是否
  打开、是否最小化都不影响通知送达。标题未生成时(LLM 异步生成,首轮事件先于标题事件)
  浮窗用语言占位(「(未命名会话)」),`session/title` 事件到达后**原地更新已弹浮窗的标题**,
  不再显示工作区目录名。
- **常驻宿主架构**:插件加载时启动一个 powershell 宿主进程(toast-host.ps1),WPF 只加载
  一次,所有浮窗在该进程内创建——通知创建延迟从 ~1s 冷启动降到 ~10ms。宿主经 **stdin**
  收一行一个 JSON 命令(`show`/`text`/`title`/`move`/`close`/`shutdown`),经 **stdout** 回传
  `pos`/`exit` 报告;不再逐通知 spawn 进程,也没有 ctl/pos 文件轮询。
- **跳转会话**:系统通知点击 / 自定义浮窗「跳转会话」按钮 → **始终打开浏览器**并定位到该会话
  (通过 URL hash 约定 `#dsh-notify-yimit/session=<id>`,客户端监听后切换;可用所选浏览器打开)。
- **系统通知**:浏览器原生通知,点击通知即聚焦窗口并打开对应会话。
- **运行要求**:Windows(PowerShell 5.1+,系统自带);自定义桌面浮窗无需任何额外依赖。

## 安装

```sh
dsh plugin --profile web add dsh-notify-yimit
```

然后**重启 dsh web**(host 插件生效需重启),打开 设置 → 通知 开启即可。

> 也可以手动方式:在 `~/.dsh/profiles/web/package.json` 的 dependencies 中加入
> `"dsh-notify-yimit": "file:<本目录路径>"` 后 `pnpm install`,再重启。

## 结构

```
dsh-notify-yimit/
├── package.json         dsh.bundle.patch + dsh.client.platform: web(客户端 half 自动发现)
├── cordis.patch.yml     注册 host 行(id: dsh-notify-yimit)
├── lib/index.js         host half:配置存储 + 会话状态机 + 通知事件队列 + notify 服务 + 桌面浮窗调度
├── lib/toast-host.ps1   常驻 PowerShell + WPF 浮窗宿主(stdin 命令 / stdout 报告,所有浮窗一个进程)
├── lib/typert.host.js   Typert 宿主清单(getState / updateConfig / ackEvents)
└── lib/client.js        client half:设置页「通知」+ 系统通知调度 + 会话深链接(hash)跳转
```

## 数据流

```
host: session/event(turn/start|assistant/chunk|tool/call|turn/end|session/title)
      + agent/status + approval/request
  → 每会话状态机 → 分发:
    - custom(桌面浮窗):stdin 一行 JSON 命令 → 常驻宿主(show/text/move/close);
      宿主 stdout 回传 pos/exit → host 自适应堆叠(真实高度 + 12px 间距)并重排;
      运行中按 400ms 节流 + 活动文本变化原地 text 更新;最多 N 个同时显示;
      审批/问答状态性通知免防抖(替换即更新,不吞通知)
    - system / off:未确认事件队列 → Typert 服务(客户端 250ms 轮询)
client: 设置页「通知」配置 → 分发:
  - system → Web Notification(tag 按 会话:类型 替换,onclick 跳转会话)
  - custom → 只消费回执(不渲染页面内浮层;桌面浮窗由 host 负责)
  - 会话深链接:监听 #dsh-notify-yimit/session=<id>(桌面浮窗"跳转会话"通道)→ ctx.sessions.open
```

## 配置存储

`$DSH_HOME/storages/dsh-notify-yimit/config.json`(原子写 + 防抖)。

## 说明

- 系统通知依赖浏览器通知权限;`127.0.0.1` 属安全上下文,可直接申请。
- 插件默认关闭,不打扰;开启后选择通知方式生效。
- 运行中通知在活动变化时实时更新内容;完成/出错/审批/问答为一次性通知。
