/**
 * dsh-notify 宿主插件。
 *
 * 单一 Loader 行(见 cordis.patch.yml)挂载本模块,职责:
 *  1. 持久化插件配置($DSH_HOME/storages/dsh-notify/config.json):总开关、通知方式
 *     (system 系统通知 / custom 自定义样式 / off 关闭,默认 off)、自定义通知的最大
 *     同时显示数、显示时长、背景色与文字色;
 *  2. 监听主机事件流,为每个会话维护轻量状态机并生成"通知事件":
 *     - session/event:turn/start、assistant/chunk、tool/call(含 ask_user_question
 *       的提问内容)、turn/end(completed/error)、session/title(对话标题);
 *     - agent/status:运行位边沿(运行中/空闲的兜底信号);
 *     - approval/request:等待审批时的具体审批内容;
 *  3. 维护未确认事件队列(客户端轮询 getState + ackEvents 消费,运行中事件按会话
 *     节流合并,完成/出错事件总是新增);
 *  4. 提供 notify 服务(手写 typertRemote 绑定,配合 ./typert 清单走 Typert 网关),
 *     客户端经 remote.notify.* 读取配置/事件并回执。
 *
 * 零构建、零 React 依赖;仅用 ctx API 与 Node 内建能力(配置路径经
 * @deepseek-ai/dsh-home-paths 解析,契约校验用 zod,与 dsh-cost-meter 同款姿势)。
 */

import { z } from 'zod'
import fs from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'

export const name = 'dsh-notify'

// ── 配置 ───────────────────────────────────────────────────────────────────

/** 通知类型清单(与事件 kind 一一对应)。 */
const KIND_KEYS = Object.freeze(['completed', 'error', 'running', 'approval', 'question'])

/** 默认配置(首次启动;之后持久化副本优先)。 */
const DEFAULT_CONFIG = Object.freeze({
  enabled: false,          // 插件总开关
  mode: 'off',             // 通知方式:system(Windows 系统通知)| custom(自定义样式)| off(关闭)
  maxVisible: 3,           // 自定义通知最大同时显示数量
  durationMs: 8000,        // 自定义通知显示时长(毫秒)
  browser: '',             // 跳转会话使用的浏览器可执行文件路径;空 = 系统默认浏览器
  bgColor: '#20272f',      // 自定义通知全局默认背景色(旧配置兼容/顶层默认)
  textColor: '#e6edf3',    // 自定义通知全局默认文字色(旧配置兼容/顶层默认)
  // 每种通知类型的背景/文字色;未显式配置时:旧配置(顶层 bgColor/textColor)迁移使用顶层值,
  // 全新默认则使用下方的类型区分色。
  colors: {
    completed: { bg: '#1f5138', fg: '#e6f4ec' },  // 绿:完成
    error:     { bg: '#5c1f24', fg: '#fbe9ea' },  // 红:出错
    running:   { bg: '#203a5c', fg: '#e8f0fb' },  // 蓝:运行中
    approval:  { bg: '#4a3a12', fg: '#f7efd8' },  // 黄:待审批
    question:  { bg: '#3d2a55', fg: '#f0e8fa' },  // 紫:待回答
  },
})

const HEX_RE = /^#[0-9a-fA-F]{3,8}$/
const isHex = (v) => typeof v === 'string' && HEX_RE.test(v)

/**
 * 配置合并校验:未知键忽略,非法值回退默认(设置页只发合法 patch)。
 * colors 采用"候选即结果"策略:输入中的 colors[kind].bg/fg 合法即采用;
 * 缺失时回退每类型默认色(旧配置的顶层色迁移在 openConfig 加载时一次性完成)。
 */
function normalizeConfig(input) {
  const src = input !== null && typeof input === 'object' && !Array.isArray(input) ? input : {}
  const out = { ...DEFAULT_CONFIG }
  if (typeof src.enabled === 'boolean') out.enabled = src.enabled
  if (src.mode === 'system' || src.mode === 'custom' || src.mode === 'off') out.mode = src.mode
  if (typeof src.maxVisible === 'number' && Number.isFinite(src.maxVisible)) out.maxVisible = Math.max(1, Math.min(20, Math.floor(src.maxVisible)))
  if (typeof src.durationMs === 'number' && Number.isFinite(src.durationMs)) out.durationMs = Math.max(1000, Math.min(300000, Math.floor(src.durationMs)))
  if (typeof src.browser === 'string') out.browser = src.browser
  if (isHex(src.bgColor)) out.bgColor = src.bgColor
  if (isHex(src.textColor)) out.textColor = src.textColor
  const srcColors = src.colors !== null && typeof src.colors === 'object' && !Array.isArray(src.colors) ? src.colors : {}
  out.colors = {}
  for (const kind of KIND_KEYS) {
    const entry = srcColors[kind]
    const def = DEFAULT_CONFIG.colors[kind]
    out.colors[kind] = {
      bg: isHex(entry?.bg) ? entry.bg : def.bg,
      fg: isHex(entry?.fg) ? entry.fg : def.fg,
    }
  }
  return out
}

/** 旧配置(仅有顶层 bgColor/textColor、无 colors)一次性迁移:colors 全用顶层色。 */
function migrateLegacyColors(input) {
  if (input === null || typeof input !== 'object' || Array.isArray(input)) return input
  if (input.colors !== null && typeof input.colors === 'object') return input
  if (!isHex(input.bgColor) && !isHex(input.textColor)) return input
  const colors = {}
  for (const kind of KIND_KEYS) colors[kind] = { bg: input.bgColor, fg: input.textColor }
  return { ...input, colors }
}

/** 深合并配置补丁:colors 按类型浅合并(只 patch 变更的 bg/fg,保留其余类型与字段)。 */
function mergeConfigPatch(base, patch) {
  const out = { ...base, ...patch }
  if (patch !== null && typeof patch === 'object' && patch.colors !== null && typeof patch.colors === 'object' && !Array.isArray(patch.colors)) {
    const baseColors = base.colors !== null && typeof base.colors === 'object' ? base.colors : {}
    const next = {}
    for (const kind of KIND_KEYS) next[kind] = { ...(baseColors[kind] ?? {}), ...(patch.colors[kind] ?? {}) }
    out.colors = next
  }
  return out
}

/** 配置存储:$DSH_HOME/storages/dsh-notify/config.json(临时文件 + 原子重命名,写防抖)。 */
function openConfig() {
  const home = resolveDshHome()
  const dir = path.join(home, 'storages', 'dsh-notify')
  const file = path.join(dir, 'config.json')
  let loaded = null
  try {
    loaded = JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    loaded = null
  }
  let config = normalizeConfig(migrateLegacyColors(loaded))
  let timer = null
  const persist = () => {
    if (timer !== null) return
    timer = setTimeout(() => {
      timer = null
      try {
        fs.mkdirSync(dir, { recursive: true })
        const tmp = `${file}.${process.pid}.tmp`
        fs.writeFileSync(tmp, JSON.stringify(config, null, 2), 'utf8')
        fs.renameSync(tmp, file)
      } catch (error) {
        // 配置写盘失败不应影响插件主流程,仅记录。
        console.warn(`[dsh-notify] 配置写盘失败: ${String(error)}`)
      }
    }, 200)
  }
  return {
    get: () => config,
    set(patch) {
      config = normalizeConfig(mergeConfigPatch(config, patch))
      persist()
      return config
    },
    close() {
      if (timer !== null) { clearTimeout(timer); timer = null }
      try {
        fs.mkdirSync(dir, { recursive: true })
        const tmp = `${file}.${process.pid}.tmp`
        fs.writeFileSync(tmp, JSON.stringify(config, null, 2), 'utf8')
        fs.renameSync(tmp, file)
      } catch {
        // 同上:关闭时尽力落盘。
      }
    },
  }
}

// ── 通知事件队列 ───────────────────────────────────────────────────────────

const MAX_QUEUE = 500          // 未确认事件上限(防堆积)
const RUNNING_THROTTLE_MS = 400  // 运行中事件按会话节流合并(更快响应,实时性优先)
const KIND_DEBOUNCE_MS = 2000   // 非运行中事件同会话同类型防抖窗口
const TOAST_GAP = 12            // 浮窗间距(像素);堆叠按各窗口回传的真实高度累加,自适应
const TEXT_MAX = 300            // 事件文本上限

function clip(text) {
  const s = String(text ?? '')
  return s.length > TEXT_MAX ? `${s.slice(0, TEXT_MAX)}…` : s
}

/** 会话标题:优先会话日志里的 session/title,其次 cwd 目录名,最后会话 id。 */
function titleOf(session) {
  const events = session?.events
  if (Array.isArray(events)) {
    for (let i = events.length - 1; i >= 0; i -= 1) {
      const event = events[i]
      if (event?.type === 'session/title' && typeof event.data?.title === 'string' && event.data.title.length > 0) {
        return event.data.title
      }
    }
  }
  const cwd = session?.header?.cwd
  if (typeof cwd === 'string' && cwd.length > 0) {
    const base = cwd.replace(/[\\/]+$/, '').split(/[\\/]/).pop()
    if (typeof base === 'string' && base.length > 0) return base
  }
  return session?.id ?? ''
}

// ── 浏览器探测(跳转会话时选择用哪个浏览器打开) ─────────────────────────────

/** 常见 Windows 浏览器安装候选路径(按 64/32 位与用户级安装展开)。 */
function browserCandidates() {
  const pf = process.env.ProgramFiles ?? 'C:\\Program Files'
  const pfx86 = process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)'
  const local = process.env.LOCALAPPDATA ?? ''
  return [
    { id: 'edge', name: 'Microsoft Edge', paths: [`${pfx86}\\Microsoft\\Edge\\Application\\msedge.exe`, `${pf}\\Microsoft\\Edge\\Application\\msedge.exe`] },
    { id: 'chrome', name: 'Google Chrome', paths: [`${pf}\\Google\\Chrome\\Application\\chrome.exe`, `${pfx86}\\Google\\Chrome\\Application\\chrome.exe`, local ? `${local}\\Google\\Chrome\\Application\\chrome.exe` : ''] },
    { id: 'firefox', name: 'Mozilla Firefox', paths: [`${pf}\\Mozilla Firefox\\firefox.exe`, `${pfx86}\\Mozilla Firefox\\firefox.exe`] },
    { id: 'brave', name: 'Brave', paths: [`${pf}\\BraveSoftware\\Brave-Browser\\Application\\brave.exe`, local ? `${local}\\BraveSoftware\\Brave-Browser\\Application\\brave.exe` : ''] },
    { id: 'opera', name: 'Opera', paths: [local ? `${local}\\Programs\\Opera\\opera.exe` : '', `${pf}\\Opera\\launcher.exe`] },
    { id: 'vivaldi', name: 'Vivaldi', paths: [local ? `${local}\\Vivaldi\\Application\\vivaldi.exe` : '', `${pf}\\Vivaldi\\Application\\vivaldi.exe`] },
    { id: '360se', name: '360 安全浏览器', paths: [`${pfx86}\\360\\360se6\\Application\\360se.exe`] },
    { id: '360chrome', name: '360 极速浏览器', paths: [`${pfx86}\\360\\360Chrome\\Chrome\\Application\\360chrome.exe`] },
    { id: 'qqbrowser', name: 'QQ 浏览器', paths: [`${pfx86}\\Tencent\\QQBrowser\\QQBrowser.exe`, `${pf}\\Tencent\\QQBrowser\\QQBrowser.exe`] },
    { id: 'sogou', name: '搜狗浏览器', paths: [`${pfx86}\\SogouExplorer\\SogouExplorer.exe`] },
    { id: 'liebao', name: '猎豹浏览器', paths: [`${pfx86}\\liebao\\liebao.exe`] },
  ]
}

/** 探测本机已安装浏览器:返回 [{ id, name, path }](按候选顺序,路径存在即收录)。 */
function detectBrowsers() {
  const found = []
  for (const candidate of browserCandidates()) {
    const path = (candidate.paths ?? []).find((p) => typeof p === 'string' && p.length > 0 && fs.existsSync(p))
    if (path !== undefined) found.push({ id: candidate.id, name: candidate.name, path })
  }
  return found
}

// ── 插件主体 ───────────────────────────────────────────────────────────────

export function apply(ctx) {
  const store = openConfig()
  ctx.effect(() => () => store.close(), 'dsh-notify: config close')

  /** 每会话状态:标题、状态位、最近一次运行中事件(用于节流合并)、等待类型、防抖时间戳。 */
  const states = new Map()
  const stateOf = (sessionId) => {
    let st = states.get(sessionId)
    if (st === undefined) {
      st = { title: '', status: 'idle', lastRunningId: null, lastRunningAt: 0, lastRunningText: null, waitingKind: null, lastFired: {} }
      states.set(sessionId, st)
    }
    return st
  }

  /** 未确认事件队列(升序 id)。 */
  const queue = []
  let nextId = 1

  // ── 桌面自定义通知浮窗(常驻 PowerShell 宿主 + WPF,不依赖浏览器) ──────────
  // custom 模式下通知直接弹桌面上浮窗(显示即消费,不入队);system 模式走浏览器
  // Web Notification(事件入队由客户端消费)。
  // 架构:插件加载时启动一个常驻 powershell 宿主进程(toast-host.ps1),所有浮窗都在
  // 该进程内创建(WPF 只加载一次)。宿主经 stdin 收一行一个 JSON 命令、经 stdout 回传
  // pos/exit 报告——通知创建从 ~1s 冷启动降到 ~10ms,并消灭 ctl/pos 文件轮询。

  const TOAST_HOST_SCRIPT = fileURLToPath(new URL('./toast-host.ps1', import.meta.url))
  const activeToasts = new Map() // 键 → { key, instance, meta: {left,top,height,hwnd,workBottom} | null, offsetY }
  const toastOrder = []          // 浮窗键序(弹出顺序 = 从底到顶堆叠)
  const pendingClose = new Set() // 已发 close 命令、等待淡出退出的浮窗键
  /** 屏幕底部基准线(工作区底边):由浮窗回传的准确 workBottom 更新,供自适应堆叠。 */
  let globalWorkBottom = null
  /** 浮窗实例序号:同 key 的新旧窗口用 instance 区分(旧窗 exit 回传不会误删新窗)。 */
  let toastSeq = 1

  // ── 常驻宿主进程 ─────────────────────────────────────────────────────────
  let host = null
  let hostAlive = false
  function spawnHost() {
    try {
      // 测试钩子:单测通过 globalThis.__DSH_NOTIFY_TEST_SPAWN__ 注入假的 spawn,避免真实进程。
      const spawnFn = typeof globalThis.__DSH_NOTIFY_TEST_SPAWN__ === 'function'
        ? globalThis.__DSH_NOTIFY_TEST_SPAWN__
        : spawn
      host = spawnFn('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', TOAST_HOST_SCRIPT], {
        windowsHide: true,
        stdio: ['pipe', 'pipe', 'pipe'],
      })
    } catch (error) {
      console.warn(`[dsh-notify] 浮窗宿主启动失败: ${String(error)}`)
      host = null
      hostAlive = false
      return
    }
    hostAlive = true
    // 宿主死亡/管道破裂时静默,避免未捕获的 error 事件击穿插件。
    host.stdin.on('error', () => {})
    host.stdout.on('error', () => {})
    host.on('error', () => { hostAlive = false })
    host.stdout.setEncoding('utf8')
    let buf = ''
    host.stdout.on('data', (d) => {
      buf += String(d)
      let nl
      while ((nl = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, nl).trim()
        buf = buf.slice(nl + 1)
        if (line.length === 0) continue
        let msg
        try { msg = JSON.parse(line) } catch { console.warn(`[dsh-notify] 浮窗回传解析失败: ${line}`); continue }
        if (msg === null || typeof msg !== 'object') continue
        if (msg.type === 'pos' && typeof msg.key === 'string') {
          const rec = activeToasts.get(msg.key)
          if (rec !== undefined && rec.instance === msg.instance) {
            setToastMeta(rec, { left: msg.left, top: msg.top, height: msg.height, hwnd: msg.hwnd, workBottom: msg.workBottom })
            reflowToasts()
          }
        } else if (msg.type === 'exit' && typeof msg.key === 'string') {
          const rec = activeToasts.get(msg.key)
          if (rec !== undefined && rec.instance === msg.instance) {
            pendingClose.delete(msg.key)
            activeToasts.delete(msg.key)
            const idx = toastOrder.indexOf(msg.key)
            if (idx !== -1) toastOrder.splice(idx, 1)
            reflowToasts() // 窗口真正退出后才重排,上方通知收到 move 命令曲线下落
          }
        }
      }
    })
    host.on('exit', () => {
      hostAlive = false
      // 宿主退出:全部浮窗随之消失,清理状态(下次 show 时按需重新拉起)。
      activeToasts.clear()
      toastOrder.length = 0
      pendingClose.clear()
    })
  }

  /** 下发一条命令到常驻宿主(stdin,一行 JSON)。 */
  function sendCmd(payload) {
    if (host === null || !hostAlive) return false
    try {
      host.stdin.write(`${JSON.stringify(payload)}\n`)
      return true
    } catch { return false }
  }

  /** 宿主不在时重新拉起(插件加载时已预热一次;意外退出后按需恢复)。 */
  function ensureHost() {
    if (host !== null && hostAlive) return true
    spawnHost()
    return host !== null && hostAlive
  }

  /** 优雅关闭:发 close 命令让窗口淡出;窗口退出后由 exit 回传触发带动画的重排。
   *  附带 1.5s 兜底(重发 close + 强制清理),确保堆叠序列绝不泄漏。 */
  function dismissToast(key) {
    if (pendingClose.has(key)) return
    const rec = activeToasts.get(key)
    if (rec === undefined) return
    pendingClose.add(key)
    sendCmd({ cmd: 'close', key })
    setTimeout(() => {
      if (activeToasts.get(key) === rec) {
        sendCmd({ cmd: 'close', key })
        pendingClose.delete(key)
        activeToasts.delete(key)
        const idx = toastOrder.indexOf(key)
        if (idx !== -1) toastOrder.splice(idx, 1)
        reflowToasts()
      } else {
        pendingClose.delete(key)
      }
    }, 1500).unref?.()
  }

  /** 重排浮窗:从底部按各窗口回传的真实高度逐个向上累加(12px 间距),
   *  下发 move 命令让窗口自带曲线移动。 */
  function reflowToasts() {
    if (globalWorkBottom === null) return
    let anchor = globalWorkBottom - 20 // 底部留边
    for (let i = 0; i < toastOrder.length; i += 1) {
      const rec = activeToasts.get(toastOrder[i])
      if (rec === undefined) continue
      // meta 未回传的窗口用默认高度 130 占位推进(不下发命令,避免基于估算高度的错误移动;
      // 其初始位置由 offsetY 估算保证);meta 到达后 reflow 精修。
      const height = rec.meta?.height ?? 130
      const newTop = Math.round(anchor - height)
      if (rec.meta !== null && newTop !== rec.meta.top) {
        rec.meta.top = newTop
        sendCmd({ cmd: 'move', key: rec.key, top: newTop }) // 窗口以曲线自行移动
      }
      anchor = newTop - TOAST_GAP
    }
  }

  /** 设置一个浮窗的 meta;用浮窗回传的准确 workBottom 更新全局基准线。 */
  function setToastMeta(rec, meta) {
    rec.meta = meta
    if (Number.isFinite(meta.workBottom)) globalWorkBottom = meta.workBottom
  }

  const baseUrlOf = () => {
    const ws = ctx.get('webServer')
    return `http://127.0.0.1:${ws !== null && ws !== undefined && typeof ws.port === 'number' ? ws.port : 3080}`
  }

  function showDesktopToast(cfg, ev) {
    const maxVisible = Math.max(1, Math.min(20, Math.floor(Number(cfg.maxVisible) || 3)))
    // 状态性浮窗键(运行中/待审批/待回答):同会话同类型只有一个,刷新内容实现实时更新。
    const stickyKind = ev.kind === 'running' || ev.kind === 'approval' || ev.kind === 'question'
    const key = stickyKind ? `${ev.kind}:${ev.sessionId}` : `${ev.kind}:${ev.sessionId}:${ev.at}`
    // 状态性浮窗已在屏且未在淡出:原地更新文本(text 命令)——不 kill、不重弹,
    // 消灭运行中通知的闪烁与二次延迟;正在淡出的旧窗除外(直接走重弹路径替换)。
    let replaceIndex = -1
    if (stickyKind) {
      const prev = activeToasts.get(key)
      if (prev !== undefined && !pendingClose.has(key)) {
        sendCmd({ cmd: 'text', key, text: clip(ev.text) })
        return
      }
      if (prev !== undefined) {
        // 旧窗正在淡出:从堆叠序列移除;exit 回传时 instance 不匹配,不会误删新窗。
        replaceIndex = toastOrder.indexOf(key)
        if (replaceIndex !== -1) toastOrder.splice(replaceIndex, 1)
        activeToasts.delete(key)
        pendingClose.delete(key)
      }
    }
    // 并发上限:超出时对最先弹出的窗口发 close 优雅淡出(不立即删除,由 exit 回传收尾;
    // 计算活跃数时排除已在淡出中的窗口)。
    let guard = 0
    while (activeToasts.size - pendingClose.size >= maxVisible && guard++ < 64) {
      let first = null
      for (const k of activeToasts.keys()) {
        if (pendingClose.has(k)) continue
        if (stickyKind && !/^(running|approval|question):/.test(k)) { first = k; break }
        if (first === null) first = k
      }
      if (first === null) break
      dismissToast(first)
    }
    const colors = cfg.colors !== null && typeof cfg.colors === 'object' ? cfg.colors[ev.kind] : undefined
    // 堆叠位置:全新通知插到底部(最新在底);替换场景插回原槽位(保持原生成时间顺序)。
    // 弹窗偏移按 insertIndex 之前窗口的真实高度估算(meta 回传后由 reflowToasts 精确校正)。
    if (replaceIndex === -1) {
      toastOrder.unshift(key)
    } else {
      toastOrder.splice(replaceIndex, 0, key)
    }
    const insertIndex = replaceIndex !== -1 ? replaceIndex : 0
    let offsetY = 0
    for (let i = 0; i < insertIndex; i += 1) {
      const r = activeToasts.get(toastOrder[i])
      offsetY += (r?.meta?.height ?? 130) + TOAST_GAP
    }
    const payload = {
      cmd: 'show',
      key,
      instance: toastSeq++,
      title: String(ev.title || ev.sessionId),
      text: clip(ev.text),
      bg: colors?.bg ?? cfg.bgColor ?? '#20272f',
      fg: colors?.fg ?? cfg.textColor ?? '#e6edf3',
      durationSec: Math.max(1, Math.round((Number(cfg.durationMs) || 8000) / 1000)),
      sticky: stickyKind,
      offsetY,
      sessionId: String(ev.sessionId),
      baseUrl: baseUrlOf(),
      winTitle: `dsh-notify-${key}`,
    }
    if (typeof cfg.browser === 'string' && cfg.browser.length > 0) payload.browserPath = cfg.browser
    if (!ensureHost()) return
    if (!sendCmd(payload)) return
    activeToasts.set(key, { key, instance: payload.instance, meta: null, offsetY })
  }

  /** 关闭一个状态性浮窗(状态结束时优雅淡出;不存在的键为 no-op)。 */
  function closeToast(kind, sessionId) {
    dismissToast(`${kind}:${sessionId}`)
  }

  // 卸载/退出时关闭常驻宿主与全部浮窗。
  ctx.effect(() => () => {
    if (host !== null) {
      try { sendCmd({ cmd: 'shutdown' }) } catch { /* 忽略 */ }
      try { host.kill() } catch { /* 已退出 */ }
    }
    activeToasts.clear()
    toastOrder.length = 0
    pendingClose.clear()
  }, 'dsh-notify: toast cleanup')

  // 插件加载时预热一次宿主:把 ~1s 的 WPF 冷启动变成一次性成本,之后每个通知近实时。
  spawnHost()

  const push = (sessionId, kind, text) => {
    const st = states.get(sessionId)
    if (st === undefined) return
    const at = Date.now()
    const cfg = store.get()
    const desktop = cfg.enabled === true && cfg.mode === 'custom'
    if (kind === 'running') {
      // 运行中事件节流合并:同会话 RUNNING_THROTTLE_MS 内已有运行中事件。
      if (st.lastRunningAt !== 0 && at - st.lastRunningAt < RUNNING_THROTTLE_MS && st.lastRunningId !== null) {
        if (desktop) {
          // 桌面模式:仅当活动文本变化时替换浮窗(实时内容更新);相同文本忽略防刷屏。
          if (st.lastRunningText !== clip(text)) {
            st.lastRunningText = clip(text)
            showDesktopToast(cfg, { sessionId, title: st.title, kind, text: clip(text), at })
          }
          return
        }
        const entry = queue.find((item) => item.id === st.lastRunningId)
        if (entry !== undefined) {
          entry.text = clip(text)
          entry.at = at
        }
        return
      }
      st.lastRunningAt = at
      st.lastRunningText = clip(text)
      if (desktop) {
        // 桌面模式:替换同会话运行中浮窗,实现实时内容更新。
        showDesktopToast(cfg, { sessionId, title: st.title, kind, text: clip(text), at })
        st.lastRunningId = `desktop:${at}`
        return
      }
      const entry = { id: String(nextId++), sessionId, title: st.title, kind, text: clip(text), activity: clip(text), at }
      st.lastRunningId = entry.id
      queue.push(entry)
      trim()
      return
    }
    // 完成 / 出错 / 审批 / 问答:同会话同类型防抖(KIND_DEBOUNCE_MS 内不重复)。
    // 审批/问答是状态性通知(sticky,在屏即原地更新文本):不做防抖,防止 2s 内多条
    // 审批/提问事件被静默吞掉——等待状态必须让用户看得到(替换即更新)。
    if (st.lastFired === undefined) st.lastFired = {}
    const isSticky = kind === 'approval' || kind === 'question'
    if (!isSticky && at - (st.lastFired[kind] ?? 0) < KIND_DEBOUNCE_MS) return
    st.lastFired[kind] = at
    if (desktop) {
      showDesktopToast(cfg, { sessionId, title: st.title, kind, text: clip(text), at })
      return
    }
    const stale = queue.findIndex((item) => item.sessionId === sessionId && item.kind === kind)
    if (stale !== -1) queue.splice(stale, 1)
    const entry = { id: String(nextId++), sessionId, title: st.title, kind, text: clip(text), at }
    queue.push(entry)
    trim()
  }

  function trim() {
    while (queue.length > MAX_QUEUE) queue.shift()
  }

  // ── 会话事件流:状态机与通知事件 ─────────────────────────────────────────

  ctx.on('session/event', (session, event) => {
    if (session === undefined || session === null || event === undefined || event === null) return
    const id = session.id
    const st = stateOf(id)
    // 首次接触该会话时回退标题(会话日志中可能尚无 session/title 事件)。
    if (st.title.length === 0) st.title = titleOf(session)
    switch (event.type) {
      case 'session/title': {
        if (typeof event.data?.title === 'string' && event.data.title.length > 0) {
          st.title = event.data.title
          // 已入队事件补标题(通常未入队,防御)。
          for (const item of queue) if (item.sessionId === id && item.title.length === 0) item.title = st.title
        }
        return
      }
      case 'turn/start':
        st.status = 'running'
        st.activity = '开始处理'
        push(id, 'running', st.activity)
        return
      case 'step/start':
        st.status = 'running'
        st.activity = '正在思考…'
        push(id, 'running', st.activity)
        return
      case 'assistant/chunk': {
        const chunk = event.data?.chunk
        if (chunk === null || typeof chunk !== 'object') return
        if (chunk.type === 'reasoning' && typeof chunk.text === 'string' && chunk.text.length > 0) {
          st.activity = '正在思考…'
          push(id, 'running', st.activity)
        } else if (chunk.type === 'text' && typeof chunk.text === 'string' && chunk.text.length > 0) {
          st.activity = '正在生成回复…'
          push(id, 'running', st.activity)
        }
        return
      }
      case 'tool/call': {
        const data = event.data
        if (data === null || typeof data !== 'object') return
        const toolName = typeof data.name === 'string' ? data.name : ''
        st.activity = `正在执行 ${toolName}`
        push(id, 'running', st.activity)
        // ask_user_question 工具:提问内容即"等待回答"通知文本(状态性浮窗,回答前不消失)。
        if (toolName === 'ask_user_question' && typeof data.arguments === 'string') {
          try {
            const args = JSON.parse(data.arguments)
            const questions = Array.isArray(args?.questions) ? args.questions : []
            const first = questions.find((q) => q !== null && typeof q === 'object' && typeof q.question === 'string')
            if (first !== undefined) {
              st.status = 'waiting'
              st.waitingKind = 'question'
              push(id, 'question', first.question)
            }
          } catch {
            // arguments 非 JSON:跳过问答解析。
          }
        }
        return
      }
      case 'tool/result':
        // 工具结果返回:问答/审批结束,关闭对应状态性浮窗并恢复运行中。
        if (st.waitingKind === 'question') {
          closeToast('question', id)
          st.waitingKind = null
          st.status = 'running'
          st.activity = '继续处理…'
          push(id, 'running', st.activity)
        } else if (st.status === 'waiting') {
          st.status = 'running'
          st.activity = '继续处理…'
          push(id, 'running', st.activity)
        }
        return
      case 'approval/decided':
        // 审批已决定:关闭待审批状态性浮窗。
        closeToast('approval', id)
        if (st.waitingKind === 'approval') st.waitingKind = null
        return
      case 'turn/end': {
        const reason = event.data?.reason
        const kind = reason !== null && typeof reason === 'object' ? reason.kind : undefined
        st.status = 'idle'
        st.activity = ''
        st.lastRunningAt = 0
        st.lastRunningId = null
        st.lastRunningText = null
        st.waitingKind = null
        // 任务结束:关闭运行中状态性浮窗。
        closeToast('running', id)
        if (kind === 'completed') {
          push(id, 'completed', '任务已完成')
        } else if (kind === 'error') {
          const message = reason !== null && typeof reason === 'object' && reason.error !== null && typeof reason.error === 'object'
            ? (typeof reason.error.message === 'string' ? reason.error.message : '')
            : ''
          push(id, 'error', message.length > 0 ? `任务出错:${message}` : '任务出错')
        }
        // aborted / interrupted / max-tokens:不打扰用户,不通知。
        return
      }
      default:
        return
    }
  })

  // ── 运行位兜底:turn/end 事件可能缺失时的运行中信号 ──────────────────────

  ctx.on('agent/status', ({ agent, status }) => {
    if (agent === undefined || agent === null || typeof agent.id !== 'string') return
    const st = stateOf(agent.id)
    if (status === 'running' && st.status !== 'running') {
      st.status = 'running'
      st.activity = '正在处理…'
      push(agent.id, 'running', st.activity)
    } else if (status === 'idle' && st.status === 'running') {
      st.status = 'idle'
      st.lastRunningAt = 0
      st.lastRunningId = null
    }
  })

  // ── 等待审批:具体审批内容(approval/request 为 waterfall,观察后放行) ─────

  ctx.on('approval/request', (req, next) => {
    try {
      const sessionId = req?.agent?.session?.id ?? req?.agent?.id
      if (typeof sessionId === 'string' && req !== null && typeof req === 'object') {
        const st = stateOf(sessionId)
        st.status = 'waiting'
        st.waitingKind = 'approval'
        const toolName = typeof req.toolName === 'string' ? req.toolName : ''
        const reason = typeof req.reason === 'string' && req.reason.length > 0 ? req.reason : ''
        push(sessionId, 'approval', reason.length > 0 ? reason : (toolName.length > 0 ? `等待批准执行 ${toolName}` : '等待批准'))
      }
    } catch {
      // 观察失败不影响审批链路。
    }
    return next()
  })

  // ── typert 服务 ──────────────────────────────────────────────────────────

  const service = {
    /** 读取当前配置与全部未确认事件(客户端轮询消费)。 */
    getState() {
      return { config: store.get(), events: queue.map((item) => ({ ...item })) }
    },
    /** 深合并一份配置补丁并持久化(返回值与 ./typert 清单的纯 config codec 一致)。 */
    updateConfig(patch) {
      return store.set(patch)
    },
    /** 回执已消费的事件 id(从队列移除,防止重复提醒)。 */
    ackEvents(ids) {
      if (Array.isArray(ids)) {
        const acked = new Set(ids.map((x) => String(x)))
        for (let i = queue.length - 1; i >= 0; i -= 1) if (acked.has(queue[i].id)) queue.splice(i, 1)
      }
      return { ok: true }
    },
    /** 探测本机已安装浏览器(设置页"跳转会话浏览器"选择器数据源)。 */
    listBrowsers() {
      return { browsers: detectBrowsers() }
    },
  }
  Object.defineProperty(service, 'typertRemote', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: { service, serviceKey: 'notify', namespace: 'notify' },
  })
  ctx.provide('notify', service)

  console.log('[dsh-notify] 已加载(默认关闭;请在 设置 → 通知 中开启)')
}
