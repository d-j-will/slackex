# Remote Pair Programming: Feature Discovery

**Research Date:** 2026-03-08
**Method:** Architecture brainstorm, solution landscape analysis
**Status:** Discovery / Idea capture
**Related:** `docs/research/huddles-voice-calls-discovery-2026-03-08.md` (shared WebRTC foundation)

---

## 1. Feature Vision

Allow Slackex users to pair program remotely during a huddle or call. A host shares their screen and optionally grants a remote user control of their machine — mouse movement, clicks, and keyboard input.

Two distinct capabilities with very different technical requirements:

| Capability | Browser API Exists? | Native Install? |
|-----------|-------------------|-----------------|
| Screen sharing (view only) | Yes (`getDisplayMedia`) | No |
| Remote control (input injection) | No — deliberate browser security boundary | Yes (on host) |

---

## 2. Screen Sharing (View Only)

Solved by WebRTC. The browser's `getDisplayMedia()` API lets the user pick a screen, window, or tab, which becomes a video track sent over WebRTC.

If huddles are built with Cloudflare Realtime, screen sharing is a natural extension — just add a video track alongside the audio track. Cloudflare SFU forwards it to other participants.

**This is effectively free if huddles are implemented first.**

---

## 3. Remote Control — The Hard Problem

Browsers cannot inject mouse/keyboard events at the OS level. Any remote control solution requires either:

- A **native process** on the host machine that receives input events and injects them via OS APIs
- A **constrained shared environment** (terminal, editor) where control is mediated through the application layer

---

## 4. Approaches: No Native Install Required

These stay entirely in the browser but limit what can be controlled.

### 4.1 Shared Terminal (tmux + xterm.js)

Both users connect to the same tmux session rendered via xterm.js in the browser.

- **Host side:** tmux session exposed via websocket (using ttyd, or a custom Phoenix channel + Node PTY equivalent)
- **Viewer side:** xterm.js terminal component in Slackex, connected to the same session
- **Scope:** Terminal only — covers most CLI-based pair programming (vim, emacs, running tests, debugging)
- **Effort:** Low-medium
- **Prior art:** tmate (tmux fork with shareable SSH URLs), Teleconsole, Gotty

### 4.2 Shared Terminal via tmate

Even simpler variant — host runs `tmate` which generates a shareable SSH URL. Slackex just displays the connection info or embeds an xterm.js SSH client.

- **Host side:** `tmate` (one command)
- **Slackex side:** Display connection URL, optionally embed web terminal
- **Effort:** Very low (integration, not implementation)

### 4.3 Collaborative Code Editor (Monaco + CRDT)

Embed Monaco (VS Code's editor engine) with real-time collaboration via Yjs or Automerge CRDT.

- **Scope:** Shared text editing only — no terminal, no file tree, no language server
- **Could evolve into:** A lightweight in-browser code editor for Slackex (code snippets, shared scratch pads)
- **Effort:** Medium (Monaco integration + CRDT sync over Phoenix channels)
- **Prior art:** VS Code Live Share (not embeddable), CodeSandbox, Replit

### 4.4 Web App Control via Click Forwarding

If the "app" being shared is a web app, the viewer's click coordinates can be forwarded to the host's browser via WebRTC data channel, and the host replays them via JavaScript.

- **Scope:** Web apps only, fragile (DOM must match between users)
- **Effort:** Medium, but brittle
- **Verdict:** Novelty, not production-viable

---

## 5. Approaches: Native Install on Host

These provide full GUI remote control but require the host to run a native process.

### 5.1 VNC + noVNC (Browser Client)

Classic remote desktop. VNC server captures the screen and accepts input events. noVNC renders the session in the browser via websocket.

- **Host side:** VNC server (built into macOS as Screen Sharing, TigerVNC/x11vnc on Linux, TightVNC on Windows)
- **Relay:** Websocket proxy (websockify) or route through Phoenix
- **Viewer side:** noVNC JavaScript client embedded in Slackex
- **Pros:** Mature protocol, works on any OS, browser-based viewer
- **Cons:** Image quality can be poor (no hardware acceleration), latency, VNC server setup varies by OS
- **Effort:** Medium (integration + websocket proxying)

### 5.2 Apache Guacamole

Web gateway that speaks VNC, RDP, and SSH on the backend and HTML5/websocket to the browser.

- **Architecture:** Guacamole server (Java) acts as protocol translator
- **Pros:** Supports VNC + RDP + SSH through one web interface, well-maintained
- **Cons:** Another Java service to host, heavyweight for the use case
- **Effort:** Medium (deployment + Slackex integration)

### 5.3 RustDesk (Self-Hosted)

Open-source remote desktop (Rust). Self-hostable relay server. Native clients for all platforms.

- **Architecture:** RustDesk client on both machines, relay server for NAT traversal
- **Self-hosted relay:** Lightweight Rust binary, can run alongside Slackex
- **Slackex integration:** Generate/display session IDs, deep-link to RustDesk client
- **Pros:** High quality (hardware-accelerated capture), open source (AGPLv3), self-hosted
- **Cons:** Requires RustDesk client install on both sides (no pure browser viewer), AGPLv3 license
- **Effort:** Low (integration only — link to sessions from Slackex)

### 5.4 Custom Lightweight Native Agent

Build a small native binary (Rust or Go) that:
1. Registers with Slackex via websocket
2. Captures screen via WebRTC (`getDisplayMedia` if Electron-style, or native capture APIs)
3. Receives input events from viewer via WebRTC data channel or websocket
4. Injects mouse/keyboard events via OS APIs

OS input injection APIs:
- **macOS:** `CGEvent` (Core Graphics)
- **Linux:** `xdotool` (X11) or `uinput` / `libei` (Wayland)
- **Windows:** `SendInput` Win32 API

**Pros:** Fully integrated experience inside Slackex, no third-party branding
**Cons:** Significant effort, cross-platform input injection is fiddly, distribution/auto-update story needed
**Effort:** High

---

## 6. Hybrid Approaches

### 6.1 WebRTC Screen Share + Data Channel Control

Combine browser-native screen sharing with a native agent for input only:

- **Video:** Host uses `getDisplayMedia()` — high quality, hardware-accelerated, routed via Cloudflare SFU
- **Control:** Lightweight native agent on host listens for input events sent via WebRTC data channel
- **Advantage:** The viewer needs nothing installed. Only the host needs the agent, and only when granting control (screen share works without it)

```
Host Browser                Host Agent              Cloudflare        Viewer Browser
+-----------+              +------------+           +--------+        +------------+
|getDisplay |--video------>| (not       |           |  SFU   |------->| Video      |
|Media()    |              |  involved) |           |        |        |            |
+-----------+              +------------+           +--------+        +------------+
                           | Injects    |<--data channel (P2P)--------|  Sends     |
                           | mouse/keys |           or via relay      |  clicks/   |
                           | via OS API |                             |  keystrokes|
                           +------------+                             +------------+
```

### 6.2 Tiered Experience

Offer different levels depending on what's installed:

| Tier | Host Setup | Capability |
|------|-----------|------------|
| 1 | Nothing | View-only screen share (WebRTC) |
| 2 | Nothing | Shared terminal (tmux/xterm.js) |
| 3 | Lightweight agent (~5 MB) | Full remote control |

Users get value at every tier without forcing a native install.

---

## 7. Comparison Matrix

| Approach | Install | Control Scope | Quality | Effort | Reuses Huddle Infra |
|----------|---------|--------------|---------|--------|-------------------|
| Screen share (view only) | None | View only | Excellent | Low | Yes |
| Shared tmux terminal | None | Terminal | N/A | Low-Med | No (websocket) |
| tmate integration | tmate on host | Terminal | N/A | Very Low | No |
| Monaco + CRDT editor | None | Editor | N/A | Medium | No (Phoenix channels) |
| VNC + noVNC | VNC server on host | Full GUI | Moderate | Medium | No |
| Apache Guacamole | Guac server | Full GUI | Moderate | Medium | No |
| RustDesk integration | RustDesk on both | Full GUI | Excellent | Low | No |
| WebRTC + native agent | Agent on host | Full GUI | Excellent | High | Yes (video path) |
| Tiered hybrid | Progressive | Progressive | Varies | Med-High | Partially |

---

## 8. Recommendations

### For Pair Programming Specifically

Most pair programming is **editing code and running commands in a terminal**, not clicking around a GUI. The highest-value, lowest-effort path:

1. **Shared terminal (tmux + xterm.js)** — Covers 80% of pair programming with zero native install
2. **WebRTC screen share** — "Show me what you're looking at" — comes free with huddles
3. **RustDesk for full control** — When someone genuinely needs to click around a GUI, link to a self-hosted RustDesk session

### For a Fully Integrated Product

The tiered hybrid (Section 6.2) offers the best UX progression — every user gets value, power users get more with a lightweight agent install.

---

## 9. Open Questions

1. **Elixir PTY support** — Is there an Elixir/Erlang equivalent to Node's node-pty for hosting terminal sessions? Or proxy through a small Go/Rust sidecar?
2. **tmux session security** — How to scope terminal access (read-only vs read-write) and isolate sessions per pairing?
3. **Cloudflare Realtime data channels** — Does the SFU support WebRTC data channels for forwarding input events, or only media tracks?
4. **RustDesk licensing** — AGPLv3 implications if integrating the relay server alongside Slackex
5. **Latency requirements** — What's acceptable for remote control? Screen share tolerates 100-200ms; input injection feels sluggish above ~50ms
6. **Wayland compatibility** — Screen capture and input injection on Wayland is still evolving (portals, libei). How many target users are on Wayland vs X11?
7. **Audio integration** — If someone is pair programming, they're also talking. Shared terminal + huddle audio should feel like one feature, not two
