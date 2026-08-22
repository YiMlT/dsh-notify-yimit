# dsh-notify-yimit

<p align="center">
  <a href="./README.md">简体中文</a>
    /
  <a href="./README.en.md">English</a>
</p>

A notification plugin for DeepSeek Harness: alerts you on **task completed / task failed / running (live activity) / awaiting approval / awaiting answer**.
The notification title is the conversation title; both system and custom notifications support **click-to-jump to the corresponding session**.

## Features

- **Settings-page integration**: DSH Settings → "Notifications" section (native DSH styling, `--dsw-*` theme variables):
  - Plugin master switch (all other controls are disabled while off);
  - Notification style **segmented control** with three options: **Windows system notifications** / **custom in-app notifications** / **off** (default: off);
  - **Browser picker for jump-to-session** (shown when the style is system or custom; auto-detects installed browsers — Chrome/Edge/Firefox etc.; empty = system default browser; "Jump to session" always opens the browser);
  - Custom notifications: **max simultaneously visible**, **display duration**, and a **per-type background/text color** list
    (done = green, failed = red, running = blue, approval = yellow, question = purple; each customizable);
  - The custom-settings block animates open/closed; system notifications offer one-click permission request.
- **Trigger scenarios**:
  | Scenario | Notification content |
  |---|---|
  | Task completed | Task completed |
  | Task failed | Task failed (with error message) |
  | Running | Live activity (started / thinking… / generating reply… / executing \<tool\>; toast text updates in place) |
  | Awaiting approval | The concrete approval content (tool name / reason) |
  | Awaiting answer | The concrete question from ask_user_question |
- **Custom notification = desktop toast (independent of the browser)**: the host plugin spawns a **resident PowerShell + WPF host process** that pops borderless, always-on-top toasts at the **bottom-right** of the screen (multiple toasts stack upward without overlapping). Each toast has a title, body, and **Ignore** / **Jump to session** buttons (10px rounded-rect buttons), colored per type from the config. Done/failed toasts auto-dismiss after the display duration; **running/approval/question toasts stay until their state ends** (turn end / decision made / answer given). Running content is **updated in place** (400ms throttle — no re-spawn, no flicker); approval/question are stateful and **not debounced** (multiple approvals/questions within 2s are never swallowed). Whether the browser page is open or minimized does not matter.
- **Resident host architecture**: the plugin starts one `powershell` host process (`toast-host.ps1`) on load; WPF is loaded only once and every toast is created inside that process — toast creation latency drops from ~1s cold start to ~10ms. The host receives one JSON command per line on **stdin** (`show`/`text`/`move`/`close`/`shutdown`) and reports `pos`/`exit` on **stdout**; no per-toast process spawn and no ctl/pos file polling.
- **Jump to session**: clicking a system notification or the toast's "Jump to session" button → **always opens the browser** and navigates to the session (via the URL hash convention `#dsh-notify-yimit/session=<id>`, listened to by the client; optionally with a specific browser).
- **System notifications**: native browser notifications; clicking one focuses the window and opens the session.
- **Requirements**: Windows (PowerShell 5.1+, built-in); custom desktop toasts need no extra dependencies.

## Installation

```sh
dsh plugin --profile web add <path-to-this-directory>
```

Then **restart dsh web** (host-side plugins need a restart) and enable it in Settings → Notifications.

> Manual alternative: add `"dsh-notify-yimit": "file:<path-to-this-directory>"` to the `dependencies` of
> `~/.dsh/profiles/web/package.json`, run `pnpm install`, then restart.

### Installing from npm (published package)

```sh
dsh plugin --profile web add dsh-notify-yimit
# or manually:
#   ~/.dsh/profiles/web/package.json → dependencies: "dsh-notify": "^0.1.0"
#   ~/.dsh/profiles/web/package.json → dsh.profile.bundles: add "dsh-notify"
pnpm install   # inside the profile
```

Then restart `dsh web`.

## Structure

```
dsh-notify-yimit/
├── package.json         dsh.bundle.patch + dsh.client.platform: web (client half auto-discovered)
├── cordis.patch.yml     registers the host row (id: dsh-notify-yimit)
├── lib/index.js         host half: config storage + session state machine + event queue + notify service + toast scheduling
├── lib/toast-host.ps1   resident PowerShell + WPF toast host (stdin commands / stdout reports; all toasts in one process)
├── lib/typert.host.js   Typert host manifest (getState / updateConfig / ackEvents)
├── lib/client.js        client half: "Notifications" settings section + system-notification dispatch + session deep link (hash)
├── README.md            documentation (Chinese)
└── README.en.md         documentation (English)
```

## Data flow

```
host: session/event(turn/start|assistant/chunk|tool/call|turn/end|session/title)
      + agent/status + approval/request
  → per-session state machine → dispatch:
    - custom (desktop toasts): one JSON command per line on stdin → resident host (show/text/move/close);
      host reports pos/exit on stdout → host-side adaptive stacking (real heights + 12px gap) and reflow;
      running: 400ms throttle + in-place text updates on activity change; at most N toasts at once;
      approval/question: stateful, no debounce (replace = update, nothing swallowed)
    - system / off: unacknowledged event queue → Typert service (client polls every 250ms)
client: settings config → dispatch:
  - system → Web Notification (tag replaced per session:type, onclick jumps to session)
  - custom → only acknowledges events (no in-page overlay; desktop toasts are handled by the host)
  - session deep link: listens to #dsh-notify/session=<id> (the toast "Jump to session" channel) → ctx.sessions.open
```

## Config storage

`$DSH_HOME/storages/dsh-notify-yimit/config.json` (atomic write + debounce).

## Notes

- System notifications require browser notification permission; `127.0.0.1` is a secure context, so it can be requested directly.
- The plugin is off by default; enable it and pick a style to take effect.
- Running notifications update their content in real time as activity changes; completed/failed/approval/question are one-shot (stateful ones update in place).
