/**
 * dsh-notify-yimit 浏览器端 bundle(单文件,经 __ModuleLoader__ 加载，零构建)。
 * 优化点：设置保存防抖、不可见时暂停轮询、降级备份机制、CSS兼容性补丁、语言自动同步。
 */
window.__ModuleLoader__.load({
	id: 'dsh-notify-yimit',
	factory: (require) => {
		var module = {
			exports: {}
		}
		var exports = module.exports
		Object.defineProperty(exports, Symbol.toStringTag, {
			value: 'Module'
		})
		const React = require('react')

		const css = [
			'/* dsh-notify-yimit: 设置页与自定义通知浮层 */',
			'.dn-root{display:flex;flex-direction:column;gap:20px;padding:4px 2px 24px;font-size:13px;color:var(--dsw-alias-label-primary)}',
			'.dn-block{display:flex;flex-direction:column;gap:10px}',
			'.dn-title{font-size:13px;font-weight:600;margin:0}',
			'.dn-note{font-size:12px;line-height:20px;color:var(--dsw-alias-label-tertiary);margin:0}',
			'.dn-row{display:flex;align-items:center;gap:10px}',
			'.dn-label{font-size:13px;color:var(--dsw-alias-label-secondary);flex:none}',
			'.dn-switch{position:relative;width:38px;height:22px;border-radius:999px;background:var(--dsw-alias-bg-layer-3);border:1px solid var(--dsw-alias-border-l2);cursor:pointer;padding:0;flex:none;transition:background .15s ease,border-color .15s ease}',
			'.dn-switch[data-on="true"]{background:var(--dsw-alias-state-business-primary);border-color:transparent}',
			'.dn-switch::after{content:"";position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:var(--dsw-alias-label-secondary);transition:transform .15s ease,background .15s ease}',
			'.dn-switch[data-on="true"]::after{transform:translateX(16px);background:var(--dsw-alias-label-primary-inverted)}',
			'.dn-seg{display:flex;gap:2px;padding:2px;border-radius:10px;background:var(--dsw-alias-bg-layer-2);border:1px solid var(--dsw-alias-border-l1);max-width:520px}',
			'.dn-seg-btn{flex:1;font:inherit;font-size:13px;color:var(--dsw-alias-label-secondary);border:0;border-radius:8px;padding:6px 10px;cursor:pointer;background:transparent;transition:background .15s ease,color .15s ease;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
			'.dn-seg-btn:hover{color:var(--dsw-alias-label-primary);background:var(--dsw-alias-interactive-bg-hover)}',
			'.dn-seg-btn[data-on="true"]{background:var(--dsw-alias-bg-base);color:var(--dsw-alias-label-primary);box-shadow:var(--dsw-shadow-lv1)}',
			'.dn-seg-btn:disabled{opacity:.45;cursor:not-allowed}',
			'.dn-seg-btn:disabled:hover{background:transparent;color:var(--dsw-alias-label-secondary)}',
			'.dn-collapse{display:grid;grid-template-rows:1fr;opacity:1;transition:grid-template-rows .24s ease,opacity .2s ease}',
			'.dn-collapse[data-open="false"]{grid-template-rows:0fr;opacity:0}',
			'.dn-collapse>.dn-collapse-body{overflow:hidden;min-height:0}',
			'.dn-collapse>.dn-collapse-body>.dn-block{min-width:0}',
			'.dn-kind-list{display:flex;flex-direction:column;gap:8px}',
			'.dn-kind-row{display:flex;align-items:center;gap:12px;padding:8px 12px;border:1px solid var(--dsw-alias-border-l1);border-radius:10px;background:var(--dsw-alias-bg-layer-1)}',
			'.dn-kind-swatch{flex:none;width:20px;height:20px;border-radius:6px;border:1px solid var(--dsw-alias-border-l2);box-shadow:inset 0 0 0 1px rgba(0,0,0,.12)}',
			'.dn-kind-name{flex:1;font-size:13px;font-weight:600;min-width:0}',
			'.dn-kind-field{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--dsw-alias-label-tertiary);flex:none}',
			'.dn-input{font:inherit;font-size:13px;color:var(--dsw-alias-label-primary);background:var(--dsw-alias-bg-base);border:1px solid var(--dsw-alias-border-l1);border-radius:8px;padding:5px 10px;outline:none;max-width:120px}',
			'.dn-input:focus{border-color:var(--dsw-alias-state-business-primary)}',
			'.dn-input[type=color]{padding:2px 4px;width:48px;height:28px;cursor:pointer;max-width:none}',
			'.dn-input:disabled{opacity:.45;cursor:not-allowed}',
			'.dn-select{max-width:260px;cursor:pointer}',
			'.dn-color-preview{font-size:12px;color:var(--dsw-alias-label-tertiary);font-family:var(--dsw-font-mono)}',
			'.dn-btn{font:inherit;font-size:13px;color:var(--dsw-alias-label-primary);background:var(--dsw-alias-button-elevated-fill);border:1px solid var(--dsw-alias-border-l1);border-radius:8px;padding:6px 14px;cursor:pointer}',
			'.dn-btn:hover{background:var(--dsw-alias-interactive-bg-hover)}',
			'.dn-btn.primary{background:var(--dsw-alias-state-business-primary);border-color:transparent;color:var(--dsw-alias-label-primary-inverted)}',
			'.dn-btn.primary:hover{opacity:0.88}',
			'.dn-btn:disabled{opacity:.5;cursor:not-allowed}',
			'.dn-msg{font-size:12px;line-height:18px;padding:8px 12px;border-radius:8px;border:1px solid var(--dsw-alias-border-l1)}',
			'.dn-msg.ok{color:var(--dsw-alias-state-success-primary)}',
			'.dn-msg.err{color:var(--dsw-alias-state-error-primary)}',
			'.dn-divider{height:1px;background:var(--dsw-alias-border-l1)}',
			'.dn-layer{position:fixed;top:16px;right:16px;z-index:9999;display:flex;flex-direction:column;align-items:flex-end;gap:10px;pointer-events:none}',
			'.dn-card{pointer-events:auto;width:320px;max-width:calc(100vw - 32px);border-radius:12px;box-shadow:var(--dsw-shadow-lv3);border:1px solid var(--dsw-alias-border-l2);background:var(--dn-bg,#20272f);color:var(--dn-fg,#e6edf3);overflow:hidden;animation:dn-in .18s ease}',
			'@keyframes dn-in{from{opacity:0;transform:translateX(24px)}to{opacity:1;transform:translateX(0)}}',
			'.dn-card-head{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:10px 12px 6px}',
			'.dn-card-title{font-size:13px;font-weight:600;line-height:20px;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
			'.dn-card-kind{flex:none;font-size:11px;line-height:18px;border-radius:999px;padding:0 8px;border:1px solid currentColor;opacity:.85}',
			'.dn-card-body{padding:0 12px 8px;font-size:13px;line-height:20px;word-break:break-word;max-height:120px;overflow:hidden;display:-webkit-box;-webkit-line-clamp:4;-webkit-box-orient:vertical}',
			'.dn-card-actions{display:flex;align-items:center;gap:6px;padding:6px 12px 10px}',
			'.dn-card-btn{font:inherit;font-size:12px;line-height:18px;border-radius:6px;padding:4px 10px;cursor:pointer;border:1px solid rgba(128,128,128,0.35);border:1px solid color-mix(in srgb,currentColor 35%,transparent);background:transparent;background:color-mix(in srgb,currentColor 12%,transparent);color:inherit}',
			'.dn-card-btn:hover{background:rgba(128,128,128,0.12);background:color-mix(in srgb,currentColor 12%,transparent)}',
			'.dn-card-btn.primary{background:rgba(128,128,128,0.18);background:color-mix(in srgb,currentColor 18%,transparent)}',
			'.dn-card-bar{height:2px;background:rgba(128,128,128,0.25);background:color-mix(in srgb,currentColor 25%,transparent);transform-origin:left}',
			'@media (prefers-reduced-motion: reduce){.dn-card{animation:none}}',
		].join('\n')

		const cssTagId = 'dsh-notify-yimit/client.css'
		if (typeof document !== 'undefined' && document.querySelector('style[data-plugin-css=' + JSON
				.stringify(cssTagId) + ']') === null) {
			const tag = document.createElement('style')
			tag.dataset.plugin = 'dsh-notify-yimit'
			tag.dataset.pluginCss = cssTagId
			tag.textContent = css
			document.head.appendChild(tag)
		}

		const MESSAGES = {
			zh: {
				sectionLabel: '通知',
				enabledLabel: '启用通知插件',
				enabledNote: '关闭后不产生任何通知(设置仍会保存)。',
				modeLabel: '通知方式',
				modeSystem: 'Windows 系统通知',
				modeCustom: '插件自定义样式通知',
				modeOff: '关闭',
				modeNote: '系统通知由浏览器弹出、可在系统通知中心查看;自定义通知为桌面右下角浮窗(不依赖浏览器页面)。',
				browserLabel: '跳转会话浏览器',
				browserDefault: '默认浏览器(系统)',
				browserNote: '「跳转会话」始终打开浏览器并定位到该会话;可选指定浏览器打开(默认=系统默认浏览器)。',
				customTitle: '自定义通知设置',
				colorsTitle: '每种通知的样式',
				colorBg: '背景',
				colorFg: '文字',
				maxVisibleLabel: '同时最多显示数量',
				durationLabel: '通知显示时长(秒)',
				bgColorLabel: '背景颜色',
				textColorLabel: '文字颜色',
				systemTitle: '系统通知',
				permissionGranted: '已获得系统通知权限',
				permissionDenied: '系统通知权限被拒绝,请在浏览器设置中允许本页面通知',
				permissionDefault: '系统通知需要浏览器通知权限',
				requestPermission: '申请通知权限',
				triggerNote: '触发场景:任务完成、任务出错、运行中(实时内容)、等待审批、等待回答。通知标题为对话标题;点击通知或跳转按钮可打开对应会话。',
				saveHint: '所有设置修改后自动保存。',
				saved: '已保存',
				saveFailed: '保存失败:{message}',
				loading: '正在读取配置…',
				rpcFailed: '读取配置失败:{message}',
				kindCompleted: '已完成',
				kindError: '出错',
				kindRunning: '运行中',
				kindApproval: '待审批',
				kindQuestion: '待回答',
				ignore: '忽略',
				jump: '跳转会话',
			},
			en: {
				sectionLabel: 'Notifications',
				enabledLabel: 'Enable notification plugin',
				enabledNote: 'When disabled, no notifications are produced (settings are still saved).',
				modeLabel: 'Notification style',
				modeSystem: 'Windows system notifications',
				modeCustom: 'Custom in-app notifications',
				modeOff: 'Off',
				modeNote: 'System notifications are shown by the browser and live in the system notification center; custom notifications are desktop toasts at the bottom-right (independent of the browser page).',
				browserLabel: 'Browser for jumping to a session',
				browserDefault: 'Default browser (system)',
				browserNote: '"Jump to session" always opens the browser and navigates to the session; optionally pick a specific browser (default = system default).',
				customTitle: 'Custom notification settings',
				colorsTitle: 'Style per notification type',
				colorBg: 'BG',
				colorFg: 'FG',
				maxVisibleLabel: 'Max simultaneously visible',
				durationLabel: 'Display duration (seconds)',
				bgColorLabel: 'Background color',
				textColorLabel: 'Text color',
				systemTitle: 'System notifications',
				permissionGranted: 'System notification permission granted',
				permissionDenied: 'System notification permission denied — allow notifications for this site in your browser settings',
				permissionDefault: 'System notifications need browser notification permission',
				requestPermission: 'Request permission',
				triggerNote: 'Triggers: task completed, task failed, running (live activity), awaiting approval, awaiting answer. The title is the conversation title; clicking the notification or the jump button opens the session.',
				saveHint: 'All settings changes are auto-saved.',
				saved: 'Saved',
				saveFailed: 'Save failed: {message}',
				loading: 'Loading config…',
				rpcFailed: 'Failed to load config: {message}',
				kindCompleted: 'Done',
				kindError: 'Failed',
				kindRunning: 'Running',
				kindApproval: 'Approval',
				kindQuestion: 'Question',
				ignore: 'Ignore',
				jump: 'Open',
			},
		}

		// 优化：尝试从 DSH 的 localStorage 获取语言设置，后备 navigator.language
		function detectBrowserLocale() {
			try {
				const dshLang = typeof localStorage !== 'undefined' ? (localStorage.getItem(
					'dsh-language') || localStorage.getItem('language') || localStorage.getItem(
						'locale')) : null
				if (dshLang) return dshLang.toLowerCase().startsWith('zh') ? 'zh' : 'en'
			} catch {}
			const lang = typeof navigator !== 'undefined' && typeof navigator.language === 'string' ?
				navigator.language : ''
			return lang.toLowerCase().startsWith('zh') ? 'zh' : 'en'
		}

		function makeT(locale) {
			const dict = locale === 'zh' ? MESSAGES.zh : MESSAGES.en
			return (key, vars) => {
				let text = dict[key] ?? MESSAGES.en[key] ?? key
				if (vars)
					for (const name of Object.keys(vars)) text = text.split('{' + name + '}').join(
						String(vars[name]))
				return text
			}
		}

		function fail(path) {
			throw new Error('dsh-notify-yimit: Invalid server data (' + path + ')')
		}

		function needStr(v, path) {
			if (typeof v !== 'string') fail(path);
			return v
		}

		function needNum(v, path) {
			if (typeof v !== 'number' || !Number.isFinite(v)) fail(path);
			return v
		}

		function needBool(v, path) {
			if (typeof v !== 'boolean') fail(path);
			return v
		}

		function parseConfig(v, path) {
			if (v === null || typeof v !== 'object' || Array.isArray(v)) fail(path)
			const kindColors = (key, fallbackBg, fallbackFg) => {
				const entry = v.colors !== null && typeof v.colors === 'object' && !Array.isArray(v
					.colors) ? v.colors[key] : undefined
				return {
					bg: typeof entry?.bg === 'string' ? entry.bg : fallbackBg,
					fg: typeof entry?.fg === 'string' ? entry.fg : fallbackFg
				}
			}
			const topBg = typeof v.bgColor === 'string' ? v.bgColor : '#20272f'
			const topFg = typeof v.textColor === 'string' ? v.textColor : '#e6edf3'
			return {
				enabled: v.enabled === true,
				mode: v.mode === 'system' || v.mode === 'custom' || v.mode === 'off' ? v.mode : 'off',
				maxVisible: typeof v.maxVisible === 'number' ? v.maxVisible : 3,
				durationMs: typeof v.durationMs === 'number' ? v.durationMs : 8000,
				browser: typeof v.browser === 'string' ? v.browser : '',
				bgColor: topBg,
				textColor: topFg,
				locale: v.locale === 'zh' || v.locale === 'en' ? v.locale : 'en',
				colors: {
					completed: kindColors('completed', topBg, topFg),
					error: kindColors('error', topBg, topFg),
					running: kindColors('running', topBg, topFg),
					approval: kindColors('approval', topBg, topFg),
					question: kindColors('question', topBg, topFg),
				},
			}
		}

		function parseEvent(v, path) {
			if (v === null || typeof v !== 'object' || Array.isArray(v)) fail(path)
			return {
				id: needStr(v.id, path + '.id'),
				sessionId: needStr(v.sessionId, path + '.sessionId'),
				title: typeof v.title === 'string' ? v.title : '',
				kind: v.kind === 'completed' || v.kind === 'error' || v.kind === 'running' || v.kind ===
					'approval' || v.kind === 'question' ? v.kind : 'running',
				text: needStr(v.text, path + '.text'),
				activity: typeof v.activity === 'string' ? v.activity : '',
				at: needNum(v.at, path + '.at'),
			}
		}

		function parseState(v, path) {
			if (v === null || typeof v !== 'object' || Array.isArray(v)) fail(path)
			return {
				config: parseConfig(v.config, path + '.config'),
				events: Array.isArray(v.events) ? v.events.map((e, i) => parseEvent(e, path + '.events[' +
					i + ']')) : []
			}
		}

		const codecOf = (parse) => ({
			parse
		})
		const stateCodec = codecOf((v) => parseState(v, 'state'))
		const configCodec = codecOf((v) => parseConfig(v, 'config'))
		const ackCodec = codecOf((v) => {
			if (v === null || typeof v !== 'object') fail('ack');
			return {
				ok: v.ok === true
			}
		})
		const patchCodec = codecOf((v) => {
			if (v === null || typeof v !== 'object' || Array.isArray(v)) fail('patch');
			return v
		})
		const browsersCodec = codecOf((v) => {
			if (v === null || typeof v !== 'object' || !Array.isArray(v.browsers)) fail('browsers')
			return {
				browsers: v.browsers.map((b, i) => ({
					id: typeof b?.id === 'string' ? b.id : String(i),
					name: typeof b?.name === 'string' ? b.name : '',
					path: typeof b?.path === 'string' ? b.path : ''
				}))
			}
		})

		const CONTRIBUTION = {
			package: 'dsh-notify-yimit',
			descriptors: [{
					id: 'dsh-notify-yimit#notify/getState',
					service: 'notify',
					namespace: 'notify',
					method: 'getState',
					invocation: {
						kind: 'direct'
					},
					parameters: [],
					result: {
						mode: 'strict',
						typeSymbol: 'dsh-notify-yimit#NotifyState',
						schema: stateCodec
					}
				},
				{
					id: 'dsh-notify-yimit#notify/updateConfig',
					service: 'notify',
					namespace: 'notify',
					method: 'updateConfig',
					invocation: {
						kind: 'direct'
					},
					parameters: [{
						name: 'patch',
						wire: 'patch',
						source: 'json',
						codec: {
							mode: 'strict',
							typeSymbol: 'dsh-notify-yimit#NotifyConfigPatch',
							schema: patchCodec
						}
					}],
					result: {
						mode: 'strict',
						typeSymbol: 'dsh-notify-yimit#NotifyConfig',
						schema: configCodec
					}
				},
				{
					id: 'dsh-notify-yimit#notify/ackEvents',
					service: 'notify',
					namespace: 'notify',
					method: 'ackEvents',
					invocation: {
						kind: 'direct'
					},
					parameters: [{
						name: 'ids',
						wire: 'ids',
						source: 'json',
						codec: {
							mode: 'strict',
							typeSymbol: 'dsh-notify-yimit#EventIds',
							schema: codecOf((v) => Array.isArray(v) ? v.map((x) => String(
								x)) : [])
						}
					}],
					result: {
						mode: 'strict',
						typeSymbol: 'dsh-notify-yimit#AckResult',
						schema: ackCodec
					}
				},
				{
					id: 'dsh-notify-yimit#notify/listBrowsers',
					service: 'notify',
					namespace: 'notify',
					method: 'listBrowsers',
					invocation: {
						kind: 'direct'
					},
					parameters: [],
					result: {
						mode: 'strict',
						typeSymbol: 'dsh-notify-yimit#BrowserList',
						schema: browsersCodec
					}
				},
			],
		}

		function makeStore(initial) {
			let snapshot = initial
			const listeners = new Set()
			return {
				getSnapshot: () => snapshot,
				subscribe: (fn) => {
					listeners.add(fn);
					return () => {
						listeners.delete(fn)
					}
				},
				set: (next) => {
					if (next === snapshot) return;
					snapshot = next;
					for (const fn of [...listeners]) fn()
				},
			}
		}

		const {
			createElement: el,
			Fragment,
			useState,
			useEffect,
			useRef,
			useCallback
		} = React

		function kindLabel(kind, t) {
			switch (kind) {
				case 'completed':
					return t('kindCompleted')
				case 'error':
					return t('kindError')
				case 'approval':
					return t('kindApproval')
				case 'question':
					return t('kindQuestion')
				default:
					return t('kindRunning')
			}
		}

		function NotifyOverlay(props) {
			const notifyStore = props.useNotify ? props.useNotify((s) => s) : undefined
			const api = props.api
			const sessions = props.sessions
			const seenRef = useRef(new Set())
			const config = notifyStore?.config
			const events = notifyStore?.events
			const openSession = useCallback((sessionId) => {
				try {
					if (typeof sessions?.open === 'function') sessions.open(sessionId)
				} catch {
					/* 静默 */ }
			}, [sessions])

			useEffect(() => {
				const cleanup = setInterval(() => {
					if (seenRef.current.size > 1000) seenRef.current.clear()
				}, 60000)
				return () => clearInterval(cleanup)
			}, [])

			useEffect(() => {
				if (!config || !Array.isArray(events)) return
				const fresh = events.filter((e) => !seenRef.current.has(e.id))
				if (fresh.length === 0) return
				for (const e of fresh) seenRef.current.add(e.id)

				const ack = () => {
					try {
						api?.ackEvents(fresh.map((e) => e.id))
					} catch {
						/* 静默 */ }
				}

				if (config.enabled !== true || config.mode === 'off') {
					ack();
					return
				}

				if (config.mode === 'custom') {
					if (typeof Notification === 'undefined' || Notification.permission !==
						'granted') {
						ack();
						return
					}
				} else if (config.mode === 'system') {
					if (typeof Notification === 'undefined' || Notification.permission ===
						'denied') {
						ack();
						return
					}
				}

				const request = Notification.permission === 'granted' ? Promise.resolve('granted') :
					Notification.requestPermission()
				request.then((permission) => {
					if (permission !== 'granted') {
						ack();
						return
					}
					for (const e of fresh) {
						let n
						try {
							n = new Notification(e.title && e.title.length > 0 ? e.title : e
								.sessionId, {
									body: e.text,
									tag: e.kind === 'running' ?
										`${e.sessionId}:${e.kind}` :
										`${e.sessionId}:${e.kind}:${e.at}`,
									silent: false,
								})
						} catch {
							continue
						}
						n.onclick = () => {
							try {
								window.focus();
								openSession(e.sessionId);
								n.close()
							} catch {
								/* 静默 */ }
						}
					}
					ack()
				}).catch(() => ack())
			}, [events, config, api, openSession])

			return null
		}

		function Segmented(props) {
			const {
				value,
				options,
				onChange,
				disabled
			} = props
			return el('div', {
					className: 'dn-seg',
					role: 'tablist'
				},
				options.map((entry) => el('button', {
					key: entry[0],
					type: 'button',
					role: 'tab',
					'aria-selected': String(value === entry[0]),
					className: 'dn-seg-btn',
					'data-on': String(value === entry[0]),
					disabled: disabled === true,
					onClick: () => {
						if (value !== entry[0]) onChange(entry[0])
					},
				}, entry[1])))
		}

		const KIND_ORDER = ['completed', 'error', 'running', 'approval', 'question']

		function NotifySection(props) {
			const notifyStore = props.useNotify ? props.useNotify((s) => s) : undefined
			const api = props.api
			const t = makeT(detectBrowserLocale())
			const state = notifyStore
			const config = state?.config
			const [msg, setMsg] = useState(null)
			const [saving, setSaving] = useState(false)
			const [permission, setPermission] = useState(typeof Notification !== 'undefined' ? Notification
				.permission : 'unsupported')

			const saveTimerRef = useRef(null)
			const save = useCallback((patch) => {
				if (saveTimerRef.current) clearTimeout(saveTimerRef.current)
				saveTimerRef.current = setTimeout(async () => {
					if (!api?.updateConfig) return
					setSaving(true)
					setMsg(null)
					try {
						await api.updateConfig(patch)
						setMsg({
							kind: 'ok',
							text: t('saved')
						})
					} catch (error) {
						setMsg({
							kind: 'err',
							text: t('saveFailed', {
								message: error?.message ?? String(error)
							})
						})
					} finally {
						setSaving(false)
					}
				}, 300)
			}, [api, t])

			const requestPerm = useCallback(async () => {
				if (typeof Notification === 'undefined' || Notification.permission ===
					'granted') {
					setPermission(typeof Notification !== 'undefined' ? Notification
						.permission : 'unsupported')
					return
				}
				try {
					const result = await Notification.requestPermission();
					setPermission(result)
				} catch {
					setPermission('denied')
				}
			}, [])

			if (!config) return el('div', {
				className: 'dn-root'
			}, el('div', {
				className: 'dn-note'
			}, t('loading')))

			const locale = detectBrowserLocale()
			const tt = makeT(locale)
			const controlsDisabled = !config.enabled

			const kindRows = KIND_ORDER.map((kind) => {
				const entry = config.colors?. [kind] ?? {}
				const bg = entry.bg || config.bgColor || '#20272f'
				const fg = entry.fg || config.textColor || '#e6edf3'
				return el('div', {
						key: kind,
						className: 'dn-kind-row'
					},
					el('span', {
						className: 'dn-kind-swatch',
						style: {
							background: bg
						}
					}),
					el('span', {
						className: 'dn-kind-name'
					}, kindLabel(kind, t)),
					el('label', {
							className: 'dn-kind-field'
						},
						el('input', {
							type: 'color',
							className: 'dn-input',
							title: tt('colorBg'),
							value: /^#[0-9a-fA-F]{6}$/.test(bg) ? bg : '#20272f',
							disabled: controlsDisabled,
							onChange: (e) => save({
								colors: {
									[kind]: {
										...entry,
										bg: e.target.value
									}
								}
							})
						}), tt('colorBg')),
					el('label', {
							className: 'dn-kind-field'
						},
						el('input', {
							type: 'color',
							className: 'dn-input',
							title: tt('colorFg'),
							value: /^#[0-9a-fA-F]{6}$/.test(fg) ? fg : '#e6edf3',
							disabled: controlsDisabled,
							onChange: (e) => save({
								colors: {
									[kind]: {
										...entry,
										fg: e.target.value
									}
								}
							})
						}), tt('colorFg')))
			})

			const customOpen = config.mode === 'custom'

			return el('div', {
					className: 'dn-root'
				},
				el('div', {
						className: 'dn-block'
					},
					el('div', {
							className: 'dn-row'
						},
						el('button', {
							type: 'button',
							role: 'switch',
							'aria-checked': config.enabled,
							className: 'dn-switch',
							'data-on': String(config.enabled),
							onClick: () => save({
								enabled: !config.enabled
							})
						}),
						el('span', {
							className: 'dn-label'
						}, t('enabledLabel'))),
					el('p', {
						className: 'dn-note'
					}, t('enabledNote'))),
				el('div', {
					className: 'dn-divider'
				}),
				el('div', {
						className: 'dn-block'
					},
					el('p', {
						className: 'dn-title'
					}, t('modeLabel')),
					el(Segmented, {
						value: config.mode,
						disabled: controlsDisabled,
						onChange: (mode) => save({
							mode
						}),
						options: [
							['system', t('modeSystem')],
							['custom', t('modeCustom')],
							['off', t('modeOff')]
						]
					}),
					el('p', {
						className: 'dn-note'
					}, t('modeNote'))),
				config.mode === 'system' || config.mode === 'custom' ? el('div', {
						className: 'dn-block'
					},
					el('div', {
							className: 'dn-row'
						},
						el('span', {
							className: 'dn-label'
						}, t('browserLabel')),
						el('select', {
								className: 'dn-input dn-select',
								value: config.browser || '',
								disabled: controlsDisabled,
								onChange: (e) => save({
									browser: e.target.value
								})
							},
							el('option', {
								value: ''
							}, t('browserDefault')),
							(state?.browsers ?? []).map((b) => el('option', {
								key: b.id,
								value: b.path
							}, b.name)))),
					el('p', {
						className: 'dn-note'
					}, t('browserNote'))) : null,
				el('div', {
					className: 'dn-divider'
				}),
				config.mode === 'system' ? el('div', {
						className: 'dn-block'
					},
					el('p', {
						className: 'dn-title'
					}, t('systemTitle')),
					permission === 'granted' ? el('div', {
						className: 'dn-msg ok'
					}, t('permissionGranted')) :
					permission === 'denied' ? el('div', {
						className: 'dn-msg err'
					}, t('permissionDenied')) :
					el(Fragment, null,
						el('p', {
							className: 'dn-note'
						}, t('permissionDefault')),
						el('button', {
							className: 'dn-btn primary',
							disabled: controlsDisabled,
							onClick: requestPerm
						}, t('requestPermission')))) : null,
				el('div', {
						className: 'dn-collapse',
						'data-open': String(customOpen)
					},
					el('div', {
							className: 'dn-collapse-body'
						},
						el('div', {
								className: 'dn-block'
							},
							el('p', {
								className: 'dn-title'
							}, t('customTitle')),
							el('div', {
									className: 'dn-row'
								},
								el('span', {
									className: 'dn-label'
								}, t('maxVisibleLabel')),
								el('input', {
									type: 'number',
									min: 1,
									max: 20,
									className: 'dn-input',
									value: config.maxVisible,
									disabled: controlsDisabled,
									onChange: (e) => {
										const n = Math.max(1, Math.min(20, Math.floor(Number(e
											.target.value) || 1)));
										save({
											maxVisible: n
										})
									}
								})),
							el('div', {
									className: 'dn-row'
								},
								el('span', {
									className: 'dn-label'
								}, t('durationLabel')),
								el('input', {
									type: 'number',
									min: 1,
									max: 300,
									className: 'dn-input',
									value: Math.round(config.durationMs / 1000),
									disabled: controlsDisabled,
									onChange: (e) => {
										const s = Math.max(1, Math.min(300, Math.floor(Number(e
											.target.value) || 1)));
										save({
											durationMs: s * 1000
										})
									}
								})),
							el('p', {
								className: 'dn-title'
							}, t('colorsTitle')),
							el('div', {
								className: 'dn-kind-list'
							}, kindRows)))),
				el('div', {
					className: 'dn-divider'
				}),
				el('p', {
					className: 'dn-note'
				}, t('triggerNote')),
				el('p', {
					className: 'dn-note'
				}, t('saveHint')),
				msg !== null ? el('div', {
					className: 'dn-msg ' + msg.kind
				}, msg.text) : null,
				saving ? el('div', {
					className: 'dn-note'
				}, '…') : null,
			)
		}

		const inject = ['remote']

		async function apply(ctx) {
			const remote = ctx.remote
			if (remote === undefined || typeof remote.$mount !== 'function') return
			const unmount = await remote.$mount(CONTRIBUTION)
			ctx.effect(() => () => {
				unmount()
			}, 'dsh-notify-yimit: remote contribution')

			const notify = ctx.get('remote.notify')
			if (notify === undefined) return

			const store = makeStore({
				config: null,
				events: [],
				browsers: []
			})

			const loadBrowsers = async () => {
				try {
					const result = await notify.listBrowsers()
					if (result !== null && typeof result === 'object' && result.ok === true) {
						const parsed = browsersCodec.parse(result.value)
						const state = store.getSnapshot()
						store.set({
							config: state.config,
							events: state.events,
							browsers: parsed.browsers
						})
					}
				} catch {
					/* 探测失败 */ }
			}

			let reloading = false
			const reload = async () => {
				if (reloading) return
				reloading = true
				try {
					const result = await notify.getState()
					if (result !== null && typeof result === 'object' && result.ok === true) {
						const prev = store.getSnapshot()
						store.set({
							...parseState(result.value, 'state'),
							browsers: prev.browsers
						})

						// 优化：自动同步客户端语言到宿主端
						const currentLocale = detectBrowserLocale()
						if (store.getSnapshot().config?.locale !== currentLocale) {
							void api.updateConfig({
								locale: currentLocale
							})
						}
					}
				} catch {
					/* 传输失败 */ } finally {
					reloading = false
				}
			}

			const api = {
				reload,
				updateConfig: async (patch) => {
					const result = await notify.updateConfig(patch)
					if (result !== null && typeof result === 'object' && result.ok === true) {
						const state = store.getSnapshot()
						store.set({
							config: parseConfig(result.value, 'config'),
							events: state.events,
							browsers: state.browsers
						})
					}
					return result?.value
				},
				ackEvents: async (ids) => {
					try {
						await notify.ackEvents(ids)
					} catch {
						/* 静默 */ }
				},
			}

			void reload()
			void loadBrowsers()

			ctx.effect(() => ctx.on('connection/reset', () => {
				void reload();
				void loadBrowsers()
			}), 'dsh-notify-yimit: reconnect reload')

			const pollTimer = setInterval(() => {
				if (document.visibilityState === 'hidden') return
				void reload()
			}, 250)
			ctx.effect(() => () => {
				clearInterval(pollTimer)
			}, 'dsh-notify-yimit: poll timer')

			const onVisible = () => {
				if (document.visibilityState === 'visible') void reload()
			}
			document.addEventListener('visibilitychange', onVisible)
			ctx.effect(() => () => {
				document.removeEventListener('visibilitychange', onVisible)
			}, 'dsh-notify-yimit: visibility reload')

			const sessions = ctx.get('sessions')
			const slots = ctx.get('slots')
			if (slots === undefined) return

			const openFromHash = () => {
				try {
					const m = /#dsh-notify-yimit\/session=([^&]+)/.exec(window.location.hash)
					if (m !== null && typeof sessions?.open === 'function') {
						sessions.open(decodeURIComponent(m[1]))
						const clean = window.location.href.split('#')[0]
						window.history.replaceState(null, '', clean)
					}
				} catch {
					/* 静默 */ }
			}
			window.addEventListener('hashchange', openFromHash)
			openFromHash()
			ctx.effect(() => () => window.removeEventListener('hashchange', openFromHash),
				'dsh-notify-yimit: hash listener')

			const injected = () => ({
				hooks: {
					notify: store
				},
				api,
				sessions
			})
			const sectionInjected = () => ({
				hooks: {
					notify: store
				},
				api
			})

			const sectionActive = {
				gen: 0,
				dispose: null
			}
			const registerSection = () => {
				if (sectionActive.dispose !== null) {
					sectionActive.dispose();
					sectionActive.dispose = null
				}
				sectionActive.gen += 1
				const gen = sectionActive.gen
				slots.inject('settings.section', () => {
					if (sectionActive.gen !== gen) return
					const dispose = slots.register({
						name: 'settings.section',
						id: 'dsh-notify-yimit',
						order: 60,
						label: () => makeT(detectBrowserLocale())('sectionLabel'),
						inject: sectionInjected
					}, NotifySection)
					if (sectionActive.gen !== gen) {
						dispose();
						return
					}
					sectionActive.dispose = dispose
					return () => {
						if (sectionActive.dispose === dispose) sectionActive.dispose =
							null;
						dispose()
					}
				})
			}
			registerSection()

			const overlayActive = {
				gen: 0,
				dispose: null
			}
			const registerOverlay = () => {
				if (overlayActive.dispose !== null) {
					overlayActive.dispose();
					overlayActive.dispose = null
				}
				overlayActive.gen += 1
				const gen = overlayActive.gen
				slots.inject('shell.overlay', () => {
					if (overlayActive.gen !== gen) return
					const dispose = slots.register({
						name: 'shell.overlay',
						id: 'dsh-notify-yimit',
						order: 10,
						inject: injected
					}, NotifyOverlay)
					if (overlayActive.gen !== gen) {
						dispose();
						return
					}
					overlayActive.dispose = dispose
					return () => {
						if (overlayActive.dispose === dispose) overlayActive.dispose =
							null;
						dispose()
					}
				})
			}
			registerOverlay()

			return () => {}
		}

		exports.apply = apply
		exports.inject = inject
		return module.exports
	},
})
