/**
 * dsh-notify-yimit-yimit 宿主插件。
 * (优化点:内存LRU控制、队列头指针优化、浏览器探测缓存、宿主崩溃退避、agent/session id修正等)
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

// ── 配置 ───────────────────────────────────────────────────────────────────
const KIND_KEYS = Object.freeze(['completed', 'error', 'running', 'approval', 'question'])

const DEFAULT_CONFIG = Object.freeze({
	enabled: false,
	mode: 'off',
	maxVisible: 3,
	durationMs: 8000,
	browser: '',
	bgColor: '#20272f',
	textColor: '#e6edf3',
	colors: {
		completed: {
			bg: '#1f5138',
			fg: '#e6f4ec'
		},
		error: {
			bg: '#5c1f24',
			fg: '#fbe9ea'
		},
		running: {
			bg: '#203a5c',
			fg: '#e8f0fb'
		},
		approval: {
			bg: '#4a3a12',
			fg: '#f7efd8'
		},
		question: {
			bg: '#3d2a55',
			fg: '#f0e8fa'
		},
	},
})

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

	const srcColors = src.colors !== null && typeof src.colors === 'object' && !Array.isArray(src.colors) ? src.colors :
	{}
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

// 修复：增加 !Array.isArray 检查
function migrateLegacyColors(input) {
	if (input === null || typeof input !== 'object' || Array.isArray(input)) return input
	if (input.colors !== null && typeof input.colors === 'object' && !Array.isArray(input.colors)) return input
	if (!isHex(input.bgColor) && !isHex(input.textColor)) return input
	const colors = {}
	for (const kind of KIND_KEYS) colors[kind] = {
		bg: input.bgColor,
		fg: input.textColor
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
				console.warn(`[dsh-notify-yimit] 配置写盘失败: ${String(error)}`)
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
				/* 静默 */ }
		},
	}
}

// ── 通知事件队列 ───────────────────────────────────────────────────────────
const MAX_QUEUE = 500
const RUNNING_THROTTLE_MS = 400
const KIND_DEBOUNCE_MS = 2000
const TOAST_GAP = 12
const TEXT_MAX = 300

function clip(text) {
	const s = String(text ?? '')
	return s.length > TEXT_MAX ? `${s.slice(0, TEXT_MAX)}…` : s
}

function titleOf(session) {
	const events = session?.events
	if (Array.isArray(events)) {
		// 限制扫描深度以避免极大数组时的性能损耗
		for (let i = events.length - 1; i >= 0 && i > events.length - 50; i -= 1) {
			const event = events[i]
			if (event?.type === 'session/title' && typeof event.data?.title === 'string' && event.data.title.length >
				0) {
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

// ── 浏览器探测 (优化：增加缓存) ─────────────────────────────────────────────
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
			name: '360 安全浏览器',
			paths: [`${pfx86}\\360\\360se6\\Application\\360se.exe`]
		},
		{
			id: '360chrome',
			name: '360 极速浏览器',
			paths: [`${pfx86}\\360\\360Chrome\\Chrome\\Application\\360chrome.exe`]
		},
		{
			id: 'qqbrowser',
			name: 'QQ 浏览器',
			paths: [`${pfx86}\\Tencent\\QQBrowser\\QQBrowser.exe`, `${pf}\\Tencent\\QQBrowser\\QQBrowser.exe`]
		},
		{
			id: 'sogou',
			name: '搜狗浏览器',
			paths: [`${pfx86}\\SogouExplorer\\SogouExplorer.exe`]
		},
		{
			id: 'liebao',
			name: '猎豹浏览器',
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

// ── 插件主体 ───────────────────────────────────────────────────────────────
export function apply(ctx) {
	const store = openConfig()
	ctx.effect(() => () => store.close(), 'dsh-notify-yimit: config close')

	// 优化：限制 states Map 大小防止内存泄漏
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
			if (states.size > MAX_SESSIONS) {
				const oldestKey = states.keys().next().value
				states.delete(oldestKey)
			}
		}
		return st
	}

	// 优化：使用头指针代替 shift，提升出队性能
	let queue = []
	let queueHead = 0

	function trim() {
		while (queue.length - queueHead > MAX_QUEUE) queueHead++
		if (queueHead > MAX_QUEUE) {
			queue = queue.slice(queueHead)
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
			console.warn(`[dsh-notify-yimit] 浮窗宿主启动失败: ${String(error)}`)
			host = null
			hostAlive = false
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
			host.stdin.write(`${JSON.stringify(payload)}\n`)
			return true
		} catch {
			return false
		}
	}

	// 优化：宿主崩溃指数退避
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
		if (globalWorkBottom === null) return
		let anchor = globalWorkBottom - 20
		for (let i = 0; i < toastOrder.length; i += 1) {
			const rec = activeToasts.get(toastOrder[i])
			if (rec === undefined) continue
			const height = rec.meta?.height ?? 130
			const newTop = Math.round(anchor - height)
			if (rec.meta !== null && newTop !== rec.meta.top) {
				rec.meta.top = newTop
				sendCmd({
					cmd: 'move',
					key: rec.key,
					top: newTop
				})
			}
			anchor = newTop - TOAST_GAP
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
			winTitle: `dsh-notify-yimit-${key}`,
		}
		if (typeof cfg.browser === 'string' && cfg.browser.length > 0) payload.browserPath = cfg.browser

		// 优化：sendCmd 失败时降级入队
		if (!ensureHost() || !sendCmd(payload)) {
			const entry = {
				id: String(nextId++),
				sessionId: String(ev.sessionId),
				title: String(ev.title || ev.sessionId),
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
			offsetY
		})
	}

	function closeToast(kind, sessionId) {
		dismissToast(`${kind}:${sessionId}`)
	}

	ctx.effect(() => () => {
		if (host !== null) {
			try {
				sendCmd({
					cmd: 'shutdown'
				})
			} catch {
				/* 忽略 */ }
			try {
				host.kill()
			} catch {
				/* 已退出 */ }
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
		const desktop = cfg.enabled === true && cfg.mode === 'custom'

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
				// 优化：使用循环代替 find 以适配头指针
				for (let i = queueHead; i < queue.length; i++) {
					if (queue[i].id === st.lastRunningId) {
						queue[i].text = clip(text)
						queue[i].at = at
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
				title: st.title,
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
			title: st.title,
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

		switch (event.type) {
			case 'session/title': {
				if (typeof event.data?.title === 'string' && event.data.title.length > 0) {
					st.title = event.data.title
					for (let i = queueHead; i < queue.length; i++) {
						if (queue[i].sessionId === id && queue[i].title.length === 0) queue[i].title = st.title
					}
				}
				return
			}
			case 'turn/start': {
				st.status = 'running'
				st.activity = '开始处理'
				push(id, 'running', st.activity)
				return
			}
			case 'step/start': {
				st.status = 'running'
				st.activity = '正在思考…'
				push(id, 'running', st.activity)
				return
			}
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
						/* arguments 非 JSON */ }
				}
				return
			}
			case 'tool/result': {
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
					push(id, 'completed', '任务已完成')
				} else if (kind === 'error') {
					const message = reason !== null && typeof reason === 'object' && reason.error !== null &&
						typeof reason.error === 'object' ? (typeof reason.error.message === 'string' ? reason
							.error.message : '') : ''
					push(id, 'error', message.length > 0 ? `任务出错:${message}` : '任务出错')
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
		// 优化：优先使用 session.id
		const sessionId = agent.session?.id ?? agent.id
		if (typeof sessionId !== 'string' || sessionId.length === 0) return
		const st = stateOf(sessionId)
		if (status === 'running' && st.status !== 'running') {
			st.status = 'running'
			st.activity = '正在处理…'
			push(sessionId, 'running', st.activity)
		} else if (status === 'idle' && st.status === 'running') {
			st.status = 'idle'
			st.lastRunningAt = 0
			st.lastRunningId = null
		}
	})

	ctx.on('approval/request', (req, next) => {
		try {
			// 优化：空字符串回退逻辑
			const sid = req?.agent?.session?.id
			const sessionId = (typeof sid === 'string' && sid.length > 0) ? sid : req?.agent?.id
			if (typeof sessionId === 'string' && sessionId.length > 0 && req !== null && typeof req ===
				'object') {
				const st = stateOf(sessionId)
				st.status = 'waiting'
				st.waitingKind = 'approval'
				const toolName = typeof req.toolName === 'string' ? req.toolName : ''
				const reason = typeof req.reason === 'string' && req.reason.length > 0 ? req.reason : ''
				push(sessionId, 'approval', reason.length > 0 ? reason : (toolName.length > 0 ?
					`等待批准执行 ${toolName}` : '等待批准'))
			}
		} catch {
			/* 观察失败不影响审批链路 */ }
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
			return store.set(patch)
		},
		ackEvents(ids) {
			if (Array.isArray(ids)) {
				const acked = new Set(ids.map((x) => String(x)))
				for (let i = queue.length - 1; i >= queueHead; i -= 1) {
					if (acked.has(queue[i].id)) queue.splice(i, 1)
				}
				if (queueHead > MAX_QUEUE / 2) {
					queue = queue.slice(queueHead)
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
	console.log('[dsh-notify-yimit] 已加载(默认关闭;请在 设置 → 通知 中开启)')
}
