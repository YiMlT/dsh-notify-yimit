/**
 * dsh-notify-yimit-yimit 宿主插件。
 * 优化点：内存LRU控制、队列头指针优化、浏览器探测缓存、宿主崩溃退避、全面多语言支持。
 */
import {
	z
} from 'zod'
import fs from 'node:fs'
import path from 'node:path'
import {
	spawn
} from 'node:child_process'
import {
	fileURLToPath
} from 'node:url'
import {
	resolveDshHome
} from '@deepseek-ai/dsh-home-paths'

export const name = 'dsh-notify-yimit'

const KIND_KEYS = Object.freeze(['completed', 'error', 'running', 'approval', 'question'])

const DEFAULT_CONFIG = Object.freeze({
	enabled: false,
	mode: 'off',
	maxVisible: 3,
	durationMs: 8000,
	browser: '',
	bgColor: '#20272f',
	textColor: '#e6edf3',
	locale: 'en',
	toast: {
		width: 340,
		gap: 12,
		position: null
	},
	colors: {
		completed: {
			bg: '#1f5138',
			fg: '#e6f4ec',
			accent: '#34d399',
			enabled: true
		}, // 翠绿
		error: {
			bg: '#5c1f24',
			fg: '#fbe9ea',
			accent: '#f87171',
			enabled: true
		}, // 珊瑚红
		running: {
			bg: '#203a5c',
			fg: '#e8f0fb',
			accent: '#60a5fa',
			enabled: true
		}, // 天蓝
		approval: {
			bg: '#4a3a12',
			fg: '#f7efd8',
			accent: '#fbbf24',
			enabled: true
		}, // 琥珀
		question: {
			bg: '#3d2a55',
			fg: '#f0e8fa',
			accent: '#a78bfa',
			enabled: true
		}, // 雾紫
	},
})

const ACTIVITY_LABELS = {
	zh: {
		start: '开始处理',
		thinking: '正在思考…',
		generating: '正在生成回复…',
		executing: '正在执行',
		continuing: '继续处理…',
		processing: '正在处理…',
		completed: '任务已完成',
		errorPrefix: '任务出错:',
		errorFallback: '任务出错',
		approvalPrefix: '等待批准执行',
		approvalFallback: '等待批准',
	},
	en: {
		start: 'Started processing',
		thinking: 'Thinking…',
		generating: 'Generating response…',
		executing: 'Executing',
		continuing: 'Continuing…',
		processing: 'Processing...',
		completed: 'Task completed',
		errorPrefix: 'Task failed: ',
		errorFallback: 'Task failed',
		approvalPrefix: 'Awaiting approval to execute',
		approvalFallback: 'Awaiting approval',
	}
}

const TOAST_LABELS = {
	zh: {
		ignore: '忽略',
		jump: '跳转会话',
		unnamed: '(未命名会话)'
	},
	en: {
		ignore: 'Ignore',
		jump: 'Open',
		unnamed: '(Unnamed session)'
	}
}

/** 标题未生成时的占位文本(中/英):session/title 到达后原地替换。 */
const UNTITLED_NAMES = new Set([TOAST_LABELS.zh.unnamed, TOAST_LABELS.en.unnamed])

/** 编辑模式样板窗标题(中/英)。 */
const EDIT_TITLES = {
	zh: '通知样式预览',
	en: 'Notification preview'
}

const HEX_RE = /^#[0-9a-fA-F]{3,8}$/
const isHex = (v) => typeof v === 'string' && HEX_RE.test(v)

function normalizeConfig(input) {
	const src = input !== null && typeof input === 'object' && !Array.isArray(input) ? input : {}
	const out = {
		...DEFAULT_CONFIG
	}
	if (typeof src.enabled === 'boolean') out.enabled = src.enabled
	if (src.mode === 'system' || src.mode === 'custom' || src.mode === 'off') out.mode = src.mode
	if (typeof src.maxVisible === 'number' && Number.isFinite(src.maxVisible)) out.maxVisible = Math.max(1, Math.min(20,
		Math.floor(src.maxVisible)))
	if (typeof src.durationMs === 'number' && Number.isFinite(src.durationMs)) out.durationMs = Math.max(1000, Math.min(
		300000, Math.floor(src.durationMs)))
	if (typeof src.browser === 'string') out.browser = src.browser
	if (isHex(src.bgColor)) out.bgColor = src.bgColor
	if (isHex(src.textColor)) out.textColor = src.textColor
	if (src.locale === 'zh' || src.locale === 'en') out.locale = src.locale

	// 通知窗口样式:width 260–520;gap 0–60;position 缺省 null(默认右下贴边),合法 {left,top} 才采纳。
	out.toast = {
		width: 340,
		gap: 12,
		position: null
	}
	const srcToast = src.toast !== null && typeof src.toast === 'object' && !Array.isArray(src.toast) ? src.toast : {}
	if (typeof srcToast.width === 'number' && Number.isFinite(srcToast.width)) {
		out.toast.width = Math.max(260, Math.min(520, Math.round(srcToast.width)))
	}
	if (typeof srcToast.gap === 'number' && Number.isFinite(srcToast.gap)) {
		out.toast.gap = Math.max(0, Math.min(60, Math.round(srcToast.gap)))
	}
	const pos = srcToast.position
	if (pos !== null && typeof pos === 'object' && !Array.isArray(pos) &&
		typeof pos.left === 'number' && Number.isFinite(pos.left) &&
		typeof pos.top === 'number' && Number.isFinite(pos.top)) {
		out.toast.position = {
			left: Math.round(pos.left),
			top: Math.round(pos.top)
		}
	}

	const srcColors = src.colors !== null && typeof src.colors === 'object' && !Array.isArray(src.colors) ? src.colors :
	{}
	out.colors = {}
	for (const kind of KIND_KEYS) {
		const entry = srcColors[kind]
		const def = DEFAULT_CONFIG.colors[kind]
		out.colors[kind] = {
			bg: isHex(entry?.bg) ? entry.bg : def.bg,
			fg: isHex(entry?.fg) ? entry.fg : def.fg,
			accent: isHex(entry?.accent) ? entry.accent : def.accent, // 新增
			enabled: entry?.enabled !== false,
		}
	}
	return out
}

function migrateLegacyColors(input) {
	if (input === null || typeof input !== 'object' || Array.isArray(input)) return input
	if (input.colors !== null && typeof input.colors === 'object' && !Array.isArray(input.colors)) return input
	if (!isHex(input.bgColor) && !isHex(input.textColor)) return input
	const colors = {}
	for (const kind of KIND_KEYS) colors[kind] = {
		bg: input.bgColor,
		fg: input.textColor,
		enabled: true
	}
	return {
		...input,
		colors
	}
}

function mergeConfigPatch(base, patch) {
	const out = {
		...base,
		...patch
	}
	if (patch !== null && typeof patch === 'object' && patch.colors !== null && typeof patch.colors === 'object' && !
		Array.isArray(patch.colors)) {
		const baseColors = base.colors !== null && typeof base.colors === 'object' ? base.colors : {}
		const next = {}
		for (const kind of KIND_KEYS) next[kind] = {
			...(baseColors[kind] ?? {}),
			...(patch.colors[kind] ?? {})
		}
		out.colors = next
	}
	if (patch !== null && typeof patch === 'object' && patch.toast !== null && typeof patch.toast === 'object' && !
		Array.isArray(patch.toast)) {
		out.toast = {
			...(base.toast !== null && typeof base.toast === 'object' && !Array.isArray(base.toast) ? base.toast :
				{}),
			...patch.toast
		}
	}
	return out
}

function openConfig() {
	const home = resolveDshHome()
	const dir = path.join(home, 'storages', 'dsh-notify-yimit')
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
				fs.mkdirSync(dir, {
					recursive: true
				})
				const tmp = `${file}.${process.pid}.tmp`
				fs.writeFileSync(tmp, JSON.stringify(config, null, 2), 'utf8')
				fs.renameSync(tmp, file)
			} catch (error) {
				console.warn(`[dsh-notify-yimit] Failed to persist config: ${String(error)}`)
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
			if (timer !== null) {
				clearTimeout(timer);
				timer = null
			}
			try {
				fs.mkdirSync(dir, {
					recursive: true
				})
				const tmp = `${file}.${process.pid}.tmp`
				fs.writeFileSync(tmp, JSON.stringify(config, null, 2), 'utf8')
				fs.renameSync(tmp, file)
			} catch {
				/* 静默 */
			}
		},
	}
}

const MAX_QUEUE = 500
const RUNNING_THROTTLE_MS = 400
const KIND_DEBOUNCE_MS = 2000
/** 通知间距默认值(px);实际使用 config.toast.gap(0–60,可调)。 */
const TOAST_GAP = 12
const TEXT_MAX = 300

function clip(text) {
	const s = String(text ?? '')
	return s.length > TEXT_MAX ? `${s.slice(0, TEXT_MAX)}…` : s
}

function titleOf(session) {
	const events = session?.events
	if (Array.isArray(events)) {
		// 全量扫描:标题事件通常在会话早期(seq 小)生成,长会话/恢复会话里它可能在
		// 最后 50 条之外——只扫尾部会漏掉,导致回退到占位/目录名(恢复会话不会重放
		// 种子事件,event 流也补不上)。
		for (let i = events.length - 1; i >= 0; i -= 1) {
			const event = events[i]
			if (event?.type === 'session/title' && typeof event.data?.title === 'string' && event.data.title.length > 0)
				return event.data.title
		}
	}
	// 标题尚未生成(异步 LLM/摘录,首轮事件都先于 session/title 到达):
	// 不回退到 cwd 目录名(工作区名),返回空由调用方按语言显示占位;
	// session/title 事件到达后,已弹浮窗标题经 title: 命令原地更新。
	return ''
}

let cachedBrowsers = null

function browserCandidates() {
	const pf = process.env.ProgramFiles ?? 'C:\\Program Files'
	const pfx86 = process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)'
	const local = process.env.LOCALAPPDATA ?? ''
	return [{
			id: 'edge',
			name: 'Microsoft Edge',
			paths: [`${pfx86}\\Microsoft\\Edge\\Application\\msedge.exe`,
				`${pf}\\Microsoft\\Edge\\Application\\msedge.exe`
			]
		},
		{
			id: 'chrome',
			name: 'Google Chrome',
			paths: [`${pf}\\Google\\Chrome\\Application\\chrome.exe`,
				`${pfx86}\\Google\\Chrome\\Application\\chrome.exe`, local ?
				`${local}\\Google\\Chrome\\Application\\chrome.exe` : ''
			]
		},
		{
			id: 'firefox',
			name: 'Mozilla Firefox',
			paths: [`${pf}\\Mozilla Firefox\\firefox.exe`, `${pfx86}\\Mozilla Firefox\\firefox.exe`]
		},
		{
			id: 'brave',
			name: 'Brave',
			paths: [`${pf}\\BraveSoftware\\Brave-Browser\\Application\\brave.exe`, local ?
				`${local}\\BraveSoftware\\Brave-Browser\\Application\\brave.exe` : ''
			]
		},
		{
			id: 'opera',
			name: 'Opera',
			paths: [local ? `${local}\\Programs\\Opera\\opera.exe` : '', `${pf}\\Opera\\launcher.exe`]
		},
		{
			id: 'vivaldi',
			name: 'Vivaldi',
			paths: [local ? `${local}\\Vivaldi\\Application\\vivaldi.exe` : '',
				`${pf}\\Vivaldi\\Application\\vivaldi.exe`
			]
		},
		{
			id: '360se',
			name: '360 Safe Browser',
			paths: [`${pfx86}\\360\\360se6\\Application\\360se.exe`]
		},
		{
			id: '360chrome',
			name: 'Chrome Browser',
			paths: [`${pfx86}\\360\\360Chrome\\Chrome\\Application\\360chrome.exe`]
		},
		{
			id: 'qqbrowser',
			name: 'QQ Browser',
			paths: [`${pfx86}\\Tencent\\QQBrowser\\QQBrowser.exe`, `${pf}\\Tencent\\QQBrowser\\QQBrowser.exe`]
		},
		{
			id: 'sogou',
			name: 'Sogou Browser',
			paths: [`${pfx86}\\SogouExplorer\\SogouExplorer.exe`]
		},
		{
			id: 'liebao',
			name: 'Cheetah Browser',
			paths: [`${pfx86}\\liebao\\liebao.exe`]
		},
	]
}

function detectBrowsers() {
	if (cachedBrowsers !== null) return cachedBrowsers
	const found = []
	for (const candidate of browserCandidates()) {
		const path = (candidate.paths ?? []).find((p) => typeof p === 'string' && p.length > 0 && fs.existsSync(p))
		if (path !== undefined) found.push({
			id: candidate.id,
			name: candidate.name,
			path
		})
	}
	cachedBrowsers = found
	return found
}

export function apply(ctx) {
	const store = openConfig()
	ctx.effect(() => () => store.close(), 'dsh-notify-yimit: config close')

	const MAX_SESSIONS = 200
	const states = new Map()
	const stateOf = (sessionId) => {
		let st = states.get(sessionId)
		if (st === undefined) {
			st = {
				title: '',
				status: 'idle',
				lastRunningId: null,
				lastRunningAt: 0,
				lastRunningText: null,
				waitingKind: null,
				lastFired: {}
			}
			states.set(sessionId, st)
			if (states.size > MAX_SESSIONS) states.delete(states.keys().next().value)
		}
		return st
	}

	let queue = []
	let queueHead = 0

	function trim() {
		while (queue.length - queueHead > MAX_QUEUE) queueHead++
		if (queueHead > MAX_QUEUE) {
			queue = queue.slice(queueHead);
			queueHead = 0
		}
	}

	const TOAST_HOST_SCRIPT = fileURLToPath(new URL('./toast-host.ps1',
		import.meta.url))
	const activeToasts = new Map()
	const toastOrder = []
	const pendingClose = new Set()

	let globalWorkBottom = null
	let toastSeq = 1
	let host = null
	let hostAlive = false
	let hostRestartAttempts = 0
	let hostRestartUntil = 0

	function spawnHost() {
		try {
			const spawnFn = typeof globalThis.__DSH_NOTIFY_TEST_SPAWN__ === 'function' ? globalThis
				.__DSH_NOTIFY_TEST_SPAWN__ : spawn
			host = spawnFn('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', TOAST_HOST_SCRIPT], {
				windowsHide: true,
				stdio: ['pipe', 'pipe', 'pipe'],
			})
		} catch (error) {
			console.warn(`[dsh-notify-yimit] Toast host spawn failed: ${String(error)}`)
			host = null;
			hostAlive = false;
			return
		}
		hostAlive = true
		host.stdin.on('error', (err) => {
			if (process.env.DSH_DEBUG) console.warn(`[dsh-notify-yimit] stdin error: ${err}`)
		})
		host.stdout.on('error', () => {})
		host.on('error', () => {
			hostAlive = false
		})
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
				try {
					msg = JSON.parse(line)
				} catch {
					continue
				}
				if (msg === null || typeof msg !== 'object') continue
				if (msg.type === 'pos' && typeof msg.key === 'string') {
					const rec = activeToasts.get(msg.key)
					if (rec !== undefined && rec.instance === msg.instance) {
						setToastMeta(rec, {
							left: msg.left,
							top: msg.top,
							height: msg.height,
							hwnd: msg.hwnd,
							workBottom: msg.workBottom
						})
						reflowToasts()
					}
				} else if (msg.type === 'exit' && typeof msg.key === 'string') {
					const rec = activeToasts.get(msg.key)
					if (rec !== undefined && rec.instance === msg.instance) {
						pendingClose.delete(msg.key)
						activeToasts.delete(msg.key)
						const idx = toastOrder.indexOf(msg.key)
						if (idx !== -1) toastOrder.splice(idx, 1)
						reflowToasts()
					}
				} else if (msg.type === 'geometry' && typeof msg.left === 'number' && typeof msg.top ===
					'number') {
					// 编辑模式:样板窗拖拽/缩放结束 → 写回配置,并应用到在屏浮窗。
					const width = Math.max(260, Math.min(520, Math.round(Number(msg.width) || 340)))
					const left = Math.round(Number(msg.left))
					const top = Math.round(Number(msg.top))
					store.set({
						toast: {
							width,
							position: {
								left,
								top
							}
						}
					})
					for (const rec of activeToasts.values()) {
						sendCmd({
							cmd: 'size',
							key: rec.key,
							width
						})
					}
					reflowToasts()
				}
			}
		})

		host.on('exit', () => {
			hostAlive = false
			activeToasts.clear()
			toastOrder.length = 0
			pendingClose.clear()
		})
	}

	function sendCmd(payload) {
		if (host === null || !hostAlive) return false
		try {
			host.stdin.write(`${JSON.stringify(payload)}\n`);
			return true
		} catch {
			return false
		}
	}

	function ensureHost() {
		if (host !== null && hostAlive) return true
		if (Date.now() < hostRestartUntil) return false
		spawnHost()
		if (!hostAlive) {
			hostRestartAttempts++
			hostRestartUntil = Date.now() + Math.min(30000, 1000 * (2 ** hostRestartAttempts))
		} else {
			hostRestartAttempts = 0
		}
		return host !== null && hostAlive
	}

	function dismissToast(key) {
		if (pendingClose.has(key)) return
		const rec = activeToasts.get(key)
		if (rec === undefined) return
		pendingClose.add(key)
		sendCmd({
			cmd: 'close',
			key
		})
		setTimeout(() => {
			if (activeToasts.get(key) === rec) {
				sendCmd({
					cmd: 'close',
					key
				})
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

	function reflowToasts() {
		const cfg = store.get()
		const pos = cfg.toast?.position ?? null
		const gap = typeof cfg.toast?.gap === 'number' ? cfg.toast.gap : TOAST_GAP
		if (pos !== null) {
			// 自定义位置:position.top 是"第一个(最新,最底部)浮窗的顶边",向上堆叠。
			// 与宿主 Loaded 的 targetTop = pos.top - offsetY 语义一致,否则重排会把
			// 浮窗再上移一个自身高度(先正确、随即上移的 bug)。横向同步 position.left,
			// 编辑调整位置后,在屏浮窗立即左右移动到位。
			let prevTop = pos.top
			let first = true
			for (let i = 0; i < toastOrder.length; i += 1) {
				const rec = activeToasts.get(toastOrder[i])
				if (rec === undefined) continue
				const height = rec.meta?.height ?? 130
				const newTop = first ? prevTop : Math.round(prevTop - gap - height)
				first = false
				const needsTop = rec.meta !== null && newTop !== rec.meta.top
				const needsLeft = rec.meta !== null && rec.meta.left !== pos.left
				if (needsTop || needsLeft) {
					const move = {
						cmd: 'move',
						key: rec.key,
						top: newTop
					}
					if (needsTop) rec.meta.top = newTop
					if (needsLeft) {
						move.left = pos.left;
						rec.meta.left = pos.left
					}
					sendCmd(move)
				}
				prevTop = newTop
			}
			return
		}
		// 默认右下:底边对齐(工作区底边 - 20),向上堆叠;横向回默认贴边(left 'default'),
		// 覆盖"恢复默认位置/改宽度后需回到右下角"的场景。
		if (globalWorkBottom === null) return
		let cursor = globalWorkBottom - 20
		for (let i = 0; i < toastOrder.length; i += 1) {
			const rec = activeToasts.get(toastOrder[i])
			if (rec === undefined) continue
			const height = rec.meta?.height ?? 130
			const newTop = Math.round(cursor - height)
			if (rec.meta !== null && newTop !== rec.meta.top) {
				rec.meta.top = newTop
				sendCmd({
					cmd: 'move',
					key: rec.key,
					top: newTop,
					left: 'default'
				})
			}
			cursor = newTop - gap
		}
	}

	function setToastMeta(rec, meta) {
		rec.meta = meta
		if (Number.isFinite(meta.workBottom)) globalWorkBottom = meta.workBottom
	}

	const baseUrlOf = () => {
		const ws = ctx.get('webServer')
		return `http://127.0.0.1:${ws !== null && ws !== undefined && typeof ws.port === 'number' ? ws.port : 3080}`
	}

	const KIND_BADGES = {
		zh: {
			completed: '完成',
			error: '出错',
			running: '运行中',
			approval: '待审批',
			question: '待回答'
		},
		en: {
			completed: 'Done',
			error: 'Failed',
			running: 'Running',
			approval: 'Approval',
			question: 'Question'
		},
	}

	function showDesktopToast(cfg, ev) {
		const maxVisible = Math.max(1, Math.min(20, Math.floor(Number(cfg.maxVisible) || 3)))
		const stickyKind = ev.kind === 'running' || ev.kind === 'approval' || ev.kind === 'question'
		const key = stickyKind ? `${ev.kind}:${ev.sessionId}` : `${ev.kind}:${ev.sessionId}:${ev.at}`

		let replaceIndex = -1
		if (stickyKind) {
			const prev = activeToasts.get(key)
			if (prev !== undefined && !pendingClose.has(key)) {
				sendCmd({
					cmd: 'text',
					key,
					text: clip(ev.text)
				})
				return
			}
			if (prev !== undefined) {
				replaceIndex = toastOrder.indexOf(key)
				if (replaceIndex !== -1) toastOrder.splice(replaceIndex, 1)
				activeToasts.delete(key)
				pendingClose.delete(key)
			}
		}

		let guard = 0
		while (activeToasts.size - pendingClose.size >= maxVisible && guard++ < 64) {
			let first = null
			for (const k of activeToasts.keys()) {
				if (pendingClose.has(k)) continue
				if (stickyKind && !/^(running|approval|question):/.test(k)) {
					first = k;
					break
				}
				if (first === null) first = k
			}
			if (first === null) break
			dismissToast(first)
		}

		const colors = cfg.colors !== null && typeof cfg.colors === 'object' ? cfg.colors[ev.kind] : undefined
		if (replaceIndex === -1) {
			toastOrder.unshift(key)
		} else {
			toastOrder.splice(replaceIndex, 0, key)
		}
		const insertIndex = replaceIndex !== -1 ? replaceIndex : 0
		const gap = typeof cfg.toast?.gap === 'number' ? cfg.toast.gap : TOAST_GAP
		let offsetY = 0
		for (let i = 0; i < insertIndex; i += 1) {
			const r = activeToasts.get(toastOrder[i])
			offsetY += (r?.meta?.height ?? 130) + gap
		}

		const lang = cfg.locale === 'zh' ? 'zh' : 'en'
		const l = TOAST_LABELS[lang]

		const payload = {
			cmd: 'show',
			key,
			instance: toastSeq++,
			title: typeof ev.title === 'string' && ev.title.length > 0 ? ev.title : l.unnamed,
			text: clip(ev.text),
			bg: colors?.bg ?? cfg.bgColor ?? '#20272f',
			fg: colors?.fg ?? cfg.textColor ?? '#e6edf3',
			durationSec: Math.max(1, Math.round((Number(cfg.durationMs) || 8000) / 1000)),
			accent: colors?.accent ?? '#60a5fa', // 强调色
			durationSec: Math.max(1, Math.round((Number(cfg.durationMs) || 8000) / 1000)),
			sticky: stickyKind,
			offsetY,
			sessionId: String(ev.sessionId),
			baseUrl: baseUrlOf(),
			winTitle: `dsh-notify-yimit-${key}`,
			ignoreLabel: l.ignore,
			jumpLabel: l.jump,
			unnamedLabel: l.unnamed,
			// 通知窗口样式:宽度 + 自定义位置(null = 默认右下贴边)
			width: cfg.toast?.width ?? 340,
			position: cfg.toast?.position ?? null,
		}
		if (typeof cfg.browser === 'string' && cfg.browser.length > 0) payload.browserPath = cfg.browser

		if (!ensureHost() || !sendCmd(payload)) {
			const entry = {
				id: String(nextId++),
				sessionId: String(ev.sessionId),
				title: typeof ev.title === 'string' && ev.title.length > 0 ? ev.title : l.unnamed,
				kind: ev.kind,
				text: clip(ev.text),
				at: ev.at
			}
			queue.push(entry)
			trim()
			return
		}
		activeToasts.set(key, {
			key,
			instance: payload.instance,
			meta: null,
			offsetY,
			sessionId: String(ev.sessionId)
		})
	}

	function closeToast(kind, sessionId) {
		dismissToast(`${kind}:${sessionId}`)
	}

	/** 会话标题到达后原地更新已弹浮窗的标题(宿主 title: 命令,不重弹、不闪烁)。 */
	function updateToastTitle(sessionId, title) {
		if (typeof title !== 'string' || title.length === 0) return
		for (const rec of activeToasts.values()) {
			if (rec.sessionId === sessionId) {
				sendCmd({
					cmd: 'title',
					key: rec.key,
					title
				})
			}
		}
	}

	ctx.effect(() => () => {
		if (host !== null) {
			try {
				sendCmd({
					cmd: 'shutdown'
				})
			} catch {
				/* 忽略 */
			}
			try {
				host.kill()
			} catch {
				/* 已退出 */
			}
		}
		activeToasts.clear()
		toastOrder.length = 0
		pendingClose.clear()
	}, 'dsh-notify-yimit: toast cleanup')

	spawnHost()
	let nextId = 1

	const push = (sessionId, kind, text) => {
		const st = states.get(sessionId)
		if (st === undefined) return
		const at = Date.now()
		const cfg = store.get()
		// 每类型开关:该类型被关闭时完全不产生通知(桌面浮窗与系统通知都不发)。
		if (cfg.colors?. [kind]?.enabled === false) return
		const desktop = cfg.enabled === true && cfg.mode === 'custom'
		const lang = cfg.locale === 'zh' ? 'zh' : 'en'
		const l = TOAST_LABELS[lang]
		const entryTitle = typeof st.title === 'string' && st.title.length > 0 ? st.title : l.unnamed

		if (kind === 'running') {
			if (st.lastRunningAt !== 0 && at - st.lastRunningAt < RUNNING_THROTTLE_MS && st.lastRunningId !==
				null) {
				if (desktop) {
					if (st.lastRunningText !== clip(text)) {
						st.lastRunningText = clip(text)
						showDesktopToast(cfg, {
							sessionId,
							title: st.title,
							kind,
							text: clip(text),
							at
						})
					}
					return
				}
				for (let i = queueHead; i < queue.length; i++) {
					if (queue[i].id === st.lastRunningId) {
						queue[i].text = clip(text);
						queue[i].at = at;
						break
					}
				}
				return
			}
			st.lastRunningAt = at
			st.lastRunningText = clip(text)
			if (desktop) {
				showDesktopToast(cfg, {
					sessionId,
					title: st.title,
					kind,
					text: clip(text),
					at
				})
				st.lastRunningId = `desktop:${at}`
				return
			}
			const entry = {
				id: String(nextId++),
				sessionId,
				title: entryTitle,
				kind,
				text: clip(text),
				activity: clip(text),
				at
			}
			st.lastRunningId = entry.id
			queue.push(entry)
			trim()
			return
		}

		if (st.lastFired === undefined) st.lastFired = {}
		const isSticky = kind === 'approval' || kind === 'question'
		if (!isSticky && at - (st.lastFired[kind] ?? 0) < KIND_DEBOUNCE_MS) return
		st.lastFired[kind] = at

		if (desktop) {
			showDesktopToast(cfg, {
				sessionId,
				title: st.title,
				kind,
				text: clip(text),
				at
			})
			return
		}

		let stale = -1
		for (let i = queueHead; i < queue.length; i++) {
			if (queue[i].sessionId === sessionId && queue[i].kind === kind) {
				stale = i;
				break
			}
		}
		if (stale !== -1) queue.splice(stale, 1)

		const entry = {
			id: String(nextId++),
			sessionId,
			title: entryTitle,
			kind,
			text: clip(text),
			at
		}
		queue.push(entry)
		trim()
	}

	ctx.on('session/event', (session, event) => {
		if (session === undefined || session === null || event === undefined || event === null) return
		const id = session.id
		const st = stateOf(id)
		if (st.title.length === 0) st.title = titleOf(session)

		const lang = store.get().locale === 'zh' ? 'zh' : 'en'
		const L = ACTIVITY_LABELS[lang]

		switch (event.type) {
			case 'session/title': {
				if (typeof event.data?.title === 'string' && event.data.title.length > 0) {
					st.title = event.data.title
					for (let i = queueHead; i < queue.length; i++) {
						if (queue[i].sessionId === id && (queue[i].title.length === 0 || UNTITLED_NAMES.has(
								queue[i].title)))
							queue[i].title = st.title
					}
					// 已弹浮窗(运行中/待审批/待回答等)标题原地更新,不再一直顶着占位/旧标题。
					updateToastTitle(id, st.title)
				}
				return
			}
			case 'turn/start': {
				st.status = 'running'
				st.activity = L.start
				push(id, 'running', st.activity)
				return
			}
			case 'step/start': {
				st.status = 'running'
				st.activity = L.thinking
				push(id, 'running', st.activity)
				return
			}
			case 'assistant/chunk': {
				const chunk = event.data?.chunk
				if (chunk === null || typeof chunk !== 'object') return
				if (chunk.type === 'reasoning' && typeof chunk.text === 'string' && chunk.text.length > 0) {
					st.activity = L.thinking
					push(id, 'running', st.activity)
				} else if (chunk.type === 'text' && typeof chunk.text === 'string' && chunk.text.length > 0) {
					st.activity = L.generating
					push(id, 'running', st.activity)
				}
				return
			}
			case 'tool/call': {
				const data = event.data
				if (data === null || typeof data !== 'object') return
				const toolName = typeof data.name === 'string' ? data.name : ''
				st.activity = `${L.executing} ${toolName}`
				push(id, 'running', st.activity)
				if (toolName === 'ask_user_question' && typeof data.arguments === 'string') {
					try {
						const args = JSON.parse(data.arguments)
						const questions = Array.isArray(args?.questions) ? args.questions : []
						const first = questions.find((q) => q !== null && typeof q === 'object' && typeof q
							.question === 'string')
						if (first !== undefined) {
							st.status = 'waiting'
							st.waitingKind = 'question'
							push(id, 'question', first.question)
						}
					} catch {
						/* arguments 非 JSON */
					}
				}
				return
			}
			case 'tool/result': {
				if (st.waitingKind === 'question') {
					closeToast('question', id)
					st.waitingKind = null
					st.status = 'running'
					st.activity = L.continuing
					push(id, 'running', st.activity)
				} else if (st.status === 'waiting') {
					st.status = 'running'
					st.activity = L.continuing
					push(id, 'running', st.activity)
				}
				return
			}
			case 'approval/decided': {
				closeToast('approval', id)
				if (st.waitingKind === 'approval') st.waitingKind = null
				return
			}
			case 'turn/end': {
				const reason = event.data?.reason
				const kind = reason !== null && typeof reason === 'object' ? reason.kind : undefined
				st.status = 'idle'
				st.activity = ''
				st.lastRunningAt = 0
				st.lastRunningId = null
				st.lastRunningText = null
				st.waitingKind = null
				closeToast('running', id)
				if (kind === 'completed') {
					push(id, 'completed', L.completed)
				} else if (kind === 'error') {
					const message = reason !== null && typeof reason === 'object' && reason.error !== null &&
						typeof reason.error === 'object' ? (typeof reason.error.message === 'string' ? reason
							.error.message : '') : ''
					push(id, 'error', message.length > 0 ? `${L.errorPrefix}${message}` : L.errorFallback)
				}
				return
			}
			default:
				return
		}
	})

	ctx.on('agent/status', ({
		agent,
		status
	}) => {
		if (agent === undefined || agent === null) return
		const sessionId = agent.session?.id ?? agent.id
		if (typeof sessionId !== 'string' || sessionId.length === 0) return
		const st = stateOf(sessionId)
		const lang = store.get().locale === 'zh' ? 'zh' : 'en'
		const L = ACTIVITY_LABELS[lang]
		if (status === 'running' && st.status !== 'running') {
			st.status = 'running'
			st.activity = L.processing
			push(sessionId, 'running', st.activity)
		} else if (status === 'idle' && st.status === 'running') {
			st.status = 'idle'
			st.lastRunningAt = 0
			st.lastRunningId = null
		}
	})

	ctx.on('approval/request', (req, next) => {
		try {
			const sid = req?.agent?.session?.id
			const sessionId = (typeof sid === 'string' && sid.length > 0) ? sid : req?.agent?.id
			if (typeof sessionId === 'string' && sessionId.length > 0 && req !== null && typeof req ===
				'object') {
				const st = stateOf(sessionId)
				st.status = 'waiting'
				st.waitingKind = 'approval'
				const toolName = typeof req.toolName === 'string' ? req.toolName : ''
				const reason = typeof req.reason === 'string' && req.reason.length > 0 ? req.reason : ''

				const lang = store.get().locale === 'zh' ? 'zh' : 'en'
				const L = ACTIVITY_LABELS[lang]
				push(sessionId, 'approval', reason.length > 0 ? reason : (toolName.length > 0 ?
					`${L.approvalPrefix} ${toolName}` : L.approvalFallback))
			}
		} catch {
			/* 观察失败不影响审批链路 */
		}
		return next()
	})

	const service = {
		getState() {
			return {
				config: store.get(),
				events: queue.slice(queueHead).map((item) => ({
					...item
				}))
			}
		},
		updateConfig(patch) {
			const prev = store.get()
			const next = store.set(patch)
			// toast 几何(位置/宽度/间距)变更:立即应用到在屏浮窗,无需等待下一个浮窗。
			const pToast = patch !== null && typeof patch === 'object' && !Array.isArray(patch) ? patch.toast :
				undefined
			if (pToast !== null && typeof pToast === 'object' && !Array.isArray(pToast)) {
				if (typeof pToast.width === 'number' && pToast.width !== prev.toast?.width) {
					for (const rec of activeToasts.values()) {
						sendCmd({
							cmd: 'size',
							key: rec.key,
							width: next.toast.width
						})
					}
				}
				reflowToasts()
			}
			return next
		},
		ackEvents(ids) {
			if (Array.isArray(ids)) {
				const acked = new Set(ids.map((x) => String(x)))
				for (let i = queue.length - 1; i >= queueHead; i -= 1) {
					if (acked.has(queue[i].id)) queue.splice(i, 1)
				}
				if (queueHead > MAX_QUEUE / 2) {
					queue = queue.slice(queueHead);
					queueHead = 0
				}
			}
			return {
				ok: true
			}
		},
		listBrowsers() {
			return {
				browsers: detectBrowsers()
			}
		},
		/** 进入通知窗口编辑模式:宿主弹样板窗(可拖拽/缩放),几何回传后写回配置。 */
		startEditMode() {
			const cfg = store.get()
			const lang = cfg.locale === 'zh' ? 'zh' : 'en'
			sendCmd({
				cmd: 'edit',
				title: EDIT_TITLES[lang],
				width: cfg.toast?.width ?? 340,
				position: cfg.toast?.position ?? null,
				// 新增：类型色卡数组，样板窗内做预览
				chips: KIND_KEYS.map((k) => ({
					label: (KIND_BADGES[lang] ?? KIND_BADGES.en)[k],
					accent: cfg.colors[k].accent,
					bg: cfg.colors[k].bg,
					fg: cfg.colors[k].fg,
				})),
			})
			return {
				ok: true
			}
		},
		/** 退出编辑模式:样板窗淡出消失。 */
		endEditMode() {
			sendCmd({
				cmd: 'edit-end'
			})
			return {
				ok: true
			}
		},
	}

	Object.defineProperty(service, 'typertRemote', {
		configurable: false,
		enumerable: false,
		writable: false,
		value: {
			service,
			serviceKey: 'notify',
			namespace: 'notify'
		},
	})

	ctx.provide('notify', service)
	console.log('[dsh-notify-yimit] Loaded (disabled by default; please enable in Settings -> Notifications)')
}
