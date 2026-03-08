# Tauri Desktop & Mobile App: Feature Discovery

**Research Date:** 2026-03-08
**Method:** Architecture brainstorm, framework analysis
**Status:** Discovery / Idea capture
**Related:**
- `docs/research/huddles-voice-calls-discovery-2026-03-08.md` (persistent audio layer)
- `docs/research/remote-pair-programming-discovery-2026-03-08.md` (native agent host)
- `docs/research/mcp-product-discovery-workflow-discovery-2026-03-08.md` (local MCP server)
**Reference implementation:** https://github.com/tidewave-ai/tidewave_app (Tauri + Elixir by Dashbit)

---

## 1. Feature Vision

Wrap Slackex in a Tauri v2 application to provide native desktop (macOS, Windows, Linux) and mobile (iOS, Android) apps alongside the existing web app. The LiveView UI remains server-rendered — Tauri provides a thin native shell with access to OS-level capabilities.

**Key principle:** Zero UI rewrite. Tauri's webview loads the existing LiveView app. Native features are added incrementally via Tauri's Rust backend and plugin system.

---

## 2. Why Tauri

### 2.1 vs Electron

| | Electron | Tauri |
|---|---|---|
| Binary size | ~150-300 MB | ~3-10 MB |
| Memory | Heavy (bundles Chromium) | Light (uses OS native webview) |
| Backend | Node.js | Rust |
| Mobile | No | Yes (Tauri v2) |
| Security | Full Node access from renderer | Explicit permission system |
| Auto-update | electron-updater | Built-in updater plugin |

Tauri's small footprint is especially relevant — users are installing a chat app, not an IDE. A 5 MB download vs 200 MB matters for adoption.

### 2.2 vs Progressive Web App (PWA)

| | PWA | Tauri |
|---|---|---|
| Install | "Add to home screen" | Real app install |
| System tray | No | Yes |
| Native notifications | Limited | Full control |
| File system access | Sandboxed | Full (with permissions) |
| Background audio | Unreliable | Reliable |
| Auto-launch | No | Yes |
| Global shortcuts | No | Yes |
| App store distribution | No | Yes |

PWA could be a lighter starting point, but it can't deliver the native features that make a chat app feel "real" (tray icon, badge counts, persistent audio).

### 2.3 vs React Native / Flutter

Those require a complete UI rewrite. Tauri reuses the existing LiveView UI as-is. Not a contest for this project.

---

## 3. Architecture

### 3.1 Core Model: Remote LiveView in Native Shell

```
+------------------------------------------+
| Tauri Native Shell                       |
| +--------------------------------------+ |
| | OS Webview (WebKit/WebView2/WebKitGTK)| |
| |                                      | |
| |   LiveView UI                        | |
| |   (loaded from https://slackex.app)  | |
| |                                      | |
| +--------------------------------------+ |
|                                          |
| Rust Backend                             |
| - System tray management                |
| - Native notifications                  |
| - Audio session persistence             |
| - Local storage / caching               |
| - IPC bridge to webview                 |
+------------------------------------------+
        |
        | WebSocket (LiveView)
        |
+------------------------------------------+
| Slackex Server (Phoenix)                 |
| - LiveView rendering                    |
| - PubSub                                |
| - Business logic                        |
+------------------------------------------+
```

The webview connects to the hosted Slackex server — same as a browser tab. The Rust backend handles OS-level features that the webview can't.

### 3.2 Local vs Remote Assets

**Option A: Fully remote (recommended to start)**
- Webview loads `https://your-slackex-instance.com`
- Zero client-side asset management
- Always up to date — no app update needed for UI changes
- Requires network connectivity

**Option B: Hybrid**
- Bundle static assets (CSS, JS) locally for faster cold start
- LiveView still connects to remote server for state
- App updates needed when assets change

**Option C: Offline-capable**
- Local asset bundle + service worker + local cache
- Significant complexity for a real-time chat app
- Diminishing returns — chat is inherently online

**Recommendation:** Start with Option A. It's the simplest and means UI updates deploy instantly without app updates. The only reason to bundle assets locally would be cold-start performance, which can be optimised later.

---

## 4. Native Capabilities Unlocked

### 4.1 System Tray

- Tray icon with unread count badge
- Quick actions: open app, mute notifications, set status
- Keeps app "running" when window is closed
- **Tauri plugin:** `tauri-plugin-positioner` for tray window positioning

### 4.2 Native Notifications

- OS-level notifications with channel/user context
- Click notification → opens app to the right channel/thread
- Notification grouping (per channel)
- Do Not Disturb awareness
- Sound customisation
- **Tauri plugin:** `tauri-plugin-notification`

### 4.3 Persistent Audio (Huddles)

This solves the hardest problem from the huddles discovery doc. In a browser, navigating away can kill the WebRTC connection. In Tauri:

- WebRTC audio connection managed by the Rust backend, independent of webview navigation
- Or: audio lives in a persistent webview layer that doesn't unmount during LiveView navigation
- Huddle survives window minimise, channel switching, even webview reload
- **This alone might justify the Tauri app**

### 4.4 Global Keyboard Shortcuts

- `Cmd+Shift+S` → Open Slackex from anywhere
- `Cmd+Shift+M` → Mute/unmute huddle
- Customisable per user
- **Tauri plugin:** `tauri-plugin-global-shortcut`

### 4.5 Auto-Launch & Background

- Start on login
- Run in background (tray only, no dock icon)
- **Tauri plugin:** `tauri-plugin-autostart`

### 4.6 File Handling

- Native file drag-and-drop for uploads
- "Open with Slackex" for sharing files
- Download management
- **Tauri plugin:** `tauri-plugin-dialog`, `tauri-plugin-fs`

### 4.7 Deep Links

- `slackex://channel/general` opens the app to that channel
- Click a link in email/browser → opens in the Tauri app
- **Tauri plugin:** `tauri-plugin-deep-link`

### 4.8 Auto-Update

- Background update checks
- Download and install updates silently or with user prompt
- No app store review cycle for updates (if distributing directly)
- **Tauri plugin:** `tauri-plugin-updater`

---

## 5. Cross-Feature Synergies

### 5.1 Huddles (Voice Calls)

Tauri solves the "persistent audio across navigation" problem. The Rust backend can manage the WebRTC connection lifecycle independently of the webview. When the user navigates channels in LiveView, the audio connection is unaffected.

Additionally, Tauri can handle:
- Microphone permission management at the OS level
- Audio device selection via native APIs
- Push-to-talk via global keyboard shortcut

### 5.2 Pair Programming

Tauri's Rust backend is the natural home for the lightweight native agent from the pair programming discovery:

- Screen capture via native APIs
- Input injection (`CGEvent` on macOS, etc.) for remote control
- No separate agent install — it's built into the Slackex app
- Activated only when the user explicitly grants control

### 5.3 MCP Server

Tauri's Rust backend could host a local MCP server:

- Exposes local Slackex context to AI agents running on the user's machine
- Claude Desktop / Claude Code connects to the local MCP server
- The MCP server proxies to the remote Slackex MCP server with the user's auth
- Could also expose local capabilities (file system, terminal) for the pair programming use case

### 5.4 Notifications

Native notifications are significantly better than browser notifications:
- Persistent (don't disappear when browser closes)
- Grouped and actionable
- Respect OS Do Not Disturb
- Badge count on dock/taskbar icon

---

## 6. Mobile (Tauri v2)

Tauri v2 supports iOS and Android. The same webview approach applies — your LiveView UI loads in a native mobile shell.

### 6.1 What Mobile Adds

- Push notifications (APNs / FCM) — not possible from a mobile browser reliably
- Background audio for huddles
- Share sheet integration ("Share to Slackex")
- Biometric auth (Face ID / fingerprint)
- App icon with unread badge

### 6.2 Mobile Considerations

- **Viewport/responsive design** — LiveView UI needs to work at mobile widths (may already if you have responsive CSS)
- **Touch interactions** — Hover states, right-click menus need touch alternatives
- **App store distribution** — Apple/Google review process, guidelines compliance
- **Offline handling** — Mobile loses connectivity more often; need graceful degradation
- **Battery** — WebSocket keepalive and background audio impact battery life

### 6.3 Mobile vs Just Using the Browser

The main advantages of a Tauri mobile app over mobile Safari/Chrome:

| Feature | Mobile Browser | Tauri Mobile |
|---------|---------------|--------------|
| Push notifications | Unreliable / limited | Native (APNs/FCM) |
| Background audio | Killed by OS | Managed via native APIs |
| App icon + badge | Add to home screen (limited) | Real app with badge |
| Share sheet | No | Yes |
| Biometric auth | Limited | Full |
| Performance | Good | Similar (same webview engine) |

The notification story alone probably justifies a mobile app. Mobile browsers are terrible at reliable push notifications.

---

## 7. Build & Distribution

### 7.1 Desktop

| Method | Pros | Cons |
|--------|------|------|
| Direct download (website) | No review process, instant updates | Users must trust the source |
| macOS App Store | Trusted, discoverable | Review process, Apple guidelines, 30% cut |
| Windows Store | Trusted, auto-update | Review process, Microsoft guidelines |
| Homebrew / winget / snap | Developer-friendly | Niche audience |

**Recommendation:** Direct download with auto-update for v1. App store later if adoption warrants it.

### 7.2 Mobile

- **iOS:** App Store required (TestFlight for beta)
- **Android:** Play Store or direct APK download
- Apple review is the main friction — plan for it

### 7.3 Signing & Notarisation

- **macOS:** Code signing certificate + Apple notarisation required for Gatekeeper
- **Windows:** Code signing certificate (EV cert for SmartScreen trust)
- **Linux:** AppImage or .deb, no signing required (but AppImage supports it)
- **Tauri handles** the signing/notarisation workflow in its build pipeline

### 7.4 CI/CD

Tauri apps can be built in GitHub Actions:
- Matrix build: macOS (ARM + Intel), Windows, Linux
- Produces signed/notarised binaries
- Auto-update server serves the latest version
- Separate release cadence from server deploys (UI changes deploy server-side instantly; native feature changes require app update)

---

## 8. Implementation Phases

### Phase 1: Desktop Shell (MVP)

- Tauri app that loads the remote LiveView URL
- System tray with basic status
- Native notifications (forward from server via websocket)
- Auto-launch on login
- Deep links (`slackex://channel/...`)
- macOS + Linux builds (matches current user base)

### Phase 2: Enhanced Desktop

- Global keyboard shortcuts
- Unread badge count on tray/dock icon
- Auto-update mechanism
- Persistent audio layer for huddles (if huddles are implemented)
- File drag-and-drop handling

### Phase 3: Mobile

- Tauri v2 iOS + Android builds
- Push notifications (APNs/FCM integration on server side)
- Responsive LiveView UI adjustments
- Share sheet integration
- Biometric auth

### Phase 4: Native Integration Features

- Pair programming native agent (screen capture + input injection)
- Local MCP server in Rust backend
- Offline message cache / optimistic UI

---

## 9. Technical Considerations

### 9.1 LiveView + Webview Compatibility

- Tauri uses the OS webview (WebKit on macOS, WebView2 on Windows, WebKitGTK on Linux)
- LiveView's websocket transport should work identically to a browser
- Test for: WebSocket reconnection behaviour, `pushState` navigation, file upload via webview
- Potential issue: WebKitGTK on Linux may lag behind Safari WebKit — test features against it

### 9.2 IPC Bridge

Communication between the Rust backend and LiveView in the webview:

```
LiveView (in webview) ←→ JavaScript IPC ←→ Tauri Rust Backend
                          (invoke/listen)
```

- `invoke()` — Webview calls Rust function, gets a response
- `listen()` / `emit()` — Event-based communication (e.g., Rust notifies webview of tray click)
- LiveView hooks can call `invoke()` to trigger native actions (e.g., "show native notification")

### 9.3 Auth Persistence

- Store auth token in OS keychain via Tauri's secure storage
- Auto-login on app launch
- Handle token refresh / session expiry gracefully

### 9.4 Multi-Instance Prevention

- Only one instance of the app should run at a time
- Second launch should focus the existing window
- Tauri supports single-instance plugin

---

## 10. Reference: Tidewave App (Tauri + Elixir)

**Source:** https://github.com/tidewave-ai/tidewave_app (by Dashbit, Apache 2.0)

Tidewave is a real-world example of Tauri wrapping an Elixir application. Key observations:

### Architecture Differences from Our Approach

Tidewave takes a **different approach** to what we've outlined. It's worth understanding both models:

| | Tidewave Model | Slackex Model (Proposed) |
|---|---|---|
| **Where Elixir runs** | Bundled — Rust backend spawns a local HTTP server | Remote — LiveView served from hosted server |
| **Webview loads** | `http://localhost:{port}` | `https://slackex.example.com` |
| **Offline capable** | Yes (local server) | No (requires server connection) |
| **Distribution** | Self-contained binary | Thin client + hosted server |
| **Updates** | App update for any change | UI updates deploy server-side; app update only for native features |

Tidewave bundles the backend into the desktop app — more like a local-first tool. Slackex is a multi-user real-time chat app, so the server must be remote. The Slackex model is closer to how Slack's desktop app works (Electron shell loading a remote webapp).

### What We Can Learn From Tidewave

**Tauri plugins used (confirmed working together):**
- `tauri-plugin-single-instance` — Prevents multiple app instances
- `tauri-plugin-cli` — CLI argument parsing (port, debug flags)
- `tauri-plugin-updater` — Auto-update via GitHub releases with signed artifacts
- `tauri-plugin-autostart` — Launch at login
- `tauri-plugin-opener` — Cross-platform URL/file opening
- `tauri-plugin-dialog` — Native dialog boxes

**Tray menu pattern:**
- Open in Browser / Settings / View Logs / Launch at Login (toggle) / Check for Updates / Restart / Quit
- Clean, minimal — good template for Slackex tray menu

**Build targets:** `app`, `dmg`, `nsis` (Windows installer), `appimage` (Linux) — covers all three desktop platforms.

**Auto-update flow:** Tauri's built-in updater plugin checks a JSON endpoint on GitHub releases. Signed with minisign. This is exactly the pattern we'd use for Slackex direct-download distribution.

**Configuration pattern:** TOML config file in platform-specific data directory, created with commented defaults on first run. Relevant for Slackex's configurable server URL.

**`frontendDist: null`:** Tidewave sets this to null because it doesn't bundle frontend assets — it serves them from the local HTTP server. For Slackex, we'd also set this to null (or minimal) since the webview loads from the remote server.

**Graceful shutdown:** Uses a `tokio::sync::watch` channel to signal the server to shut down before the app exits. We'd use a similar pattern for cleaning up WebRTC connections on quit.

---

## 11. Open Questions

1. **WebView2 on Windows** — Does it ship with Windows 10+, or do users need to install it? (It's included in Windows 11, optional on Windows 10)
2. **WebKitGTK version** — Which Linux distros ship a recent enough version for LiveView compatibility?
3. **Push notification server-side** — Need APNs/FCM integration in Phoenix for mobile push. What's the Elixir library story? (Pigeon, web_push?)
4. **App identity** — Name, icon, branding for the native app. "Slackex" or something else?
5. **Self-hosted vs cloud** — If users self-host Slackex, the Tauri app needs to point at their instance. Configurable server URL on first launch?
6. **Tauri v2 mobile maturity** — How production-ready is Tauri mobile? What are the rough edges?
7. **WebRTC in webview** — Does the OS webview support `getDisplayMedia()` and `getUserMedia()` for huddles/screen share? Safari WebKit does; WebKitGTK support may vary.
8. **App store review** — Would Apple approve a webview-only app? They have rules against "thin client" apps. The native features (notifications, tray, audio) help justify it.
9. **Update decoupling** — Server-side LiveView changes deploy instantly. Rust backend changes require an app update. How to manage feature flags across these two release channels?
