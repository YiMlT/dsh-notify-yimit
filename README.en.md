# dsh-notify-yimit

<p align="center">
  <a href="./README.md">简体中文</a>
    /
  <a href="./README.en.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/YiMlT/dsh-notify-yimit">
    <img alt="GitHub repository" src="https://img.shields.io/badge/GitHub-YiMlT%2Fdsh--notify--yimit-181717?logo=github&amp;logoColor=white">
  </a>
</p>

## Overview

A notification plugin for DeepSeek Harness: alerts you on **task completed / task failed / running (live activity) / awaiting approval / awaiting answer**.

- **Two notification styles**, switchable in Settings: **Windows system notifications** (native browser notifications) or **custom in-app notifications** (a toast at the bottom-right of the desktop, independent of the browser page); or turn everything **off** (default).
- **The notification title is the conversation title** (updated in place once the LLM generates it; the workspace directory name is never used). Toasts offer **Ignore**, and on the web also **Jump to session** (see below).
- **One codebase for desktop and web**: the host detects its platform from the runtime and hides only browser-facing entry points — notification behavior is identical.
- **Settings-page integration**: DSH Settings → "Notifications" section with a master switch, notification style, toast count/duration, and per-type background/text colors (done = green, failed = red, running = blue, approval = yellow, question = purple).

## Features

- **Trigger scenarios**:
  | Scenario | Notification content |
  |---|---|
  | Task completed | Task completed |
  | Task failed | Task failed (with error message) |
  | Running | Live activity (started / thinking… / generating reply… / executing \<tool\>; toast text updates in place) |
  | Awaiting approval | The concrete approval content (tool name / reason) |
  | Awaiting answer | The concrete question from ask_user_question |
- **Settings section**: DSH Settings → "Notifications" (native DSH styling, `--dsw-*` theme variables):
  - Plugin master switch (all other controls are disabled while off);
  - Notification style **segmented control** with three options: **Windows system notifications** / **custom in-app notifications** / **off** (default: off);
  - **Browser picker for jump-to-session** (**web only**; shown when the style is system or custom; auto-detects installed browsers — Chrome/Edge/Firefox etc.; empty = system default browser);
  - Custom notifications: **max simultaneously visible**, **display duration**, and a **per-type background/text color** list
    (done = green, failed = red, running = blue, approval = yellow, question = purple; each customizable);
  - The custom-settings block animates open/closed; system notifications offer one-click permission request.
- **Custom notification = desktop toast (independent of the browser)**: the host plugin spawns a **resident PowerShell + WPF host process** that pops borderless, always-on-top toasts at the **bottom-right** of the screen (multiple toasts stack upward without overlapping). Each toast has a title, body, and an **Ignore** button (**web only: plus a "Jump to session" button**; 10px rounded-rect buttons), colored per type from the config. Done/failed toasts auto-dismiss after the display duration; **running/approval/question toasts stay until their state ends** (turn end / decision made / answer given). Running content is **updated in place** (400ms throttle — no re-spawn, no flicker); approval/question are stateful and **not debounced** (multiple approvals/questions within 2s are never swallowed). Whether the browser page is open or minimized does not matter. Until the session title arrives (LLM-generated asynchronously — first-turn events precede the title event), toasts show a localized placeholder ("(Unnamed session)"); when the `session/title` event lands, **the titles of already-shown toasts are updated in place** — the workspace directory name is never used.
- **Resident host architecture**: the plugin starts one `powershell` host process (`toast-host.ps1`) on load; WPF is loaded only once and every toast is created inside that process — toast creation latency drops from ~1s cold start to ~10ms. The host receives one JSON command per line on **stdin** (`show`/`text`/`title`/`move`/`close`/`shutdown`) and reports `pos`/`exit` on **stdout**; no per-toast process spawn and no ctl/pos file polling.
- **Jump to session (web only)**: clicking a system notification or the toast's "Jump to session" button opens the browser and navigates to the session (via the URL hash convention `#dsh-notify-yimit/session=<id>`, listened to by the client; optionally with a specific browser). **The desktop app does not show that button** — opening a browser from inside the desktop app is redundant.
- **Runtime-aware UI**: the host detects its platform from the runtime (Electron runtime = desktop, plain Node = web) and adapts the UI:
  - desktop: toasts omit the "Jump to session" button; the settings page hides the jump browser picker and the "system notifications come from the browser / custom toasts sit at the bottom-right" explainer;
  - web: everything stays visible.
- **System notifications**: native browser notifications; clicking one focuses the window and opens the session.
- **Requirements**: Windows (PowerShell 5.1+, built-in); custom desktop toasts need no extra dependencies.

## Installation

1. **Command line** — run:

   ```sh
   dsh plugin --profile web add dsh-notify-yimit
   ```

   For the desktop profile, replace `web` with `desktop`:

   ```sh
   dsh plugin --profile desktop add dsh-notify-yimit
   ```

2. **Desktop GUI** — open **Settings → Plugins** (plugin manager), type `dsh-notify-yimit` into the add-plugin field, and click **Install**.

After installing, **restart dsh** (host-side plugins need a restart), then enable it in **Settings → Notifications**.

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
      approval/question: stateful, no debounce (replace = update, nothing swallowed);
      payload carries jumpEnabled (false on desktop) → the toast omits the "Jump to session" button
    - system / off: unacknowledged event queue → Typert service (client polls every 250ms)
  → getState() also reports a desktop flag (true on the Electron host) so the settings page can hide
    browser-only controls
client: settings config → dispatch:
  - system → Web Notification (tag replaced per session:type, onclick jumps to session)
  - custom → only acknowledges events (no in-page overlay; desktop toasts are handled by the host)
  - session deep link: listens to #dsh-notify-yimit/session=<id> (the toast "Jump to session" channel) → ctx.sessions.open
  - desktop=true: hides the jump browser picker and the notification-style explainer
```

## Config storage

`$DSH_HOME/storages/dsh-notify-yimit/config.json` (atomic write + debounce).

## Notes

- System notifications require browser notification permission; `127.0.0.1` is a secure context, so it can be requested directly.
- The plugin is off by default; enable it and pick a style to take effect.
- Running notifications update their content in real time as activity changes; completed/failed/approval/question are one-shot (stateful ones update in place).
- Platform detection looks only at the host runtime: Electron (the Electron runtime / `DeepSeek Harness.exe`) counts as desktop, plain Node counts as web. On desktop only the browser-facing entry points are hidden — notification behavior itself is identical.
