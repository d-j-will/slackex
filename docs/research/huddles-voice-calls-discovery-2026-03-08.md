# Huddles & Voice Calls: Feature Discovery

**Research Date:** 2026-03-08
**Method:** Architecture brainstorm, infrastructure constraint analysis, provider research
**Status:** Discovery / Pre-planning

---

## 1. Feature Vision

Slack-style "huddles" — lightweight, always-on audio rooms that users can drop in and out of within a channel. Not traditional phone calls with ring/accept/reject, but ambient voice presence.

### Huddle vs Call

| Aspect | Traditional Call | Huddle |
|--------|-----------------|--------|
| Initiation | Ring someone, they accept/reject | "Start huddle" — others join when ready |
| Presence | Binary (in call or not) | Ambient — you see who's in the huddle |
| Duration | Clear start/end | Can persist indefinitely |
| Mental model | Phone call | Open door / virtual room |
| Participants | Fixed at start | Drop in/drop out freely |

---

## 2. WebRTC Architecture Options

All browser-based real-time audio requires WebRTC. The question is how media streams are routed between participants.

### 2.1 Mesh (Pure P2P)

Each participant sends their stream directly to every other participant. N participants = N*(N-1) connections.

- **Pros:** No media server, zero server resource usage, simplest server-side code
- **Cons:** Scales terribly beyond 3-4 participants, every client uploads N-1 streams
- **Verdict:** Only viable for strict 1:1 calls

### 2.2 SFU (Selective Forwarding Unit)

Each participant sends one stream to a central server. The server forwards it to all others without decoding or mixing — just packet routing.

- **Pros:** Low server CPU (no transcoding), low latency, each client uploads only 1 stream, scales to 20+ participants
- **Cons:** Requires a server with UDP port access, clients download N-1 streams (fine for audio at ~50 kbps/stream)
- **Verdict:** Industry standard — used by Slack, Discord, Zoom, Google Meet

### 2.3 MCU (Multipoint Control Unit)

Server decodes all streams, mixes into a single composite, sends one stream to each client. Very CPU-intensive. Rarely used in modern applications.

- **Verdict:** Not considered

---

## 3. Infrastructure Constraints

Current production environment:

- **Unprivileged LXC** (CT 100) on Proxmox — not a VM, no kernel access
- **~20 GB memory** shared with host — already tight (Bumblebee/EXLA disabled due to OOM)
- **Docker inside LXC** with cgroup memory limits potentially unenforced
- **No GPU** (GPU access crashes the physical Proxmox host)
- **Networking:** Bridged on `vmbr0`, local IP `192.168.1.102/24`, Proxmox firewall enabled
- **Bandwidth:** 900 Gbps fiber to door — not a bottleneck

### UDP Port Access — The Key Question

WebRTC media requires UDP traffic on specific port ranges. Self-hosting an SFU inside the LXC requires:

1. Proxmox firewall rule: Allow inbound UDP on port range (e.g. 50000-60000) to CT 100
2. Router port forwarding: Forward same UDP range from public IP to 192.168.1.102

**Not yet tested.** If UDP is blocked or unreliable from the LXC, self-hosted SFU options are off the table.

---

## 4. Provider / Implementation Options

### 4.1 Cloudflare Realtime (Recommended)

Cloudflare's managed SFU + TURN service running on their anycast edge network.

| | Details |
|---|---|
| **Free tier** | 1,000 GB egress/month |
| **Paid** | $0.05/GB egress beyond free tier |
| **Inbound** | Free — pushing audio to Cloudflare is never charged |
| **Internal traffic** | Free — TURN-to-SFU doesn't count |
| **Includes** | Both SFU and TURN (shared 1 TB allowance) |

**Capacity estimate (audio-only):** Opus at ~50 kbps/stream, 3-person huddle = ~300 kbps total egress. **1 TB ~ 7,500 hours of 3-person huddles/month.**

**Pros:**
- Zero infrastructure on the LXC — no UDP ports, no firewall rules, no SFU process
- No self-hosted TURN server needed
- Anycast WebRTC — clients connect to nearest Cloudflare PoP
- Server only handles signaling (room management via REST API)
- Already using external providers (DeepInfra) so external dependency is acceptable

**Cons:**
- External dependency for media path
- API integration required

**Docs:** https://developers.cloudflare.com/realtime/

### 4.2 ex_webrtc (Elixir SFU)

Pure Elixir WebRTC implementation. Would run as a GenServer inside the existing BEAM VM.

- **Memory:** Near-zero additional (~1-2 MB per participant for buffers)
- **Blocker:** Requires UDP port access from the LXC (untested)
- **Pros:** No external dependency, fits OTP supervision naturally
- **Cons:** Newer library, requires solving UDP networking in LXC

### 4.3 LiveKit (Self-hosted Go binary)

Open-source SFU with Elixir SDK.

- **Memory:** ~50-100 MB idle, ~5-10 MB per participant
- **Blocker:** Same UDP networking question, plus additional service to manage
- **Verdict:** More proven than ex_webrtc but adds operational overhead on constrained LXC

### 4.4 Pure P2P Mesh (Fallback)

No SFU. Signaling only via existing LiveView websocket. Needs a TURN server for ~10-15% of clients behind restrictive NATs.

- **Verdict:** Viable as a first milestone for 1:1 calls only

---

## 5. Recommended Architecture (Cloudflare Realtime)

```
Phoenix/LiveView (LXC)                Cloudflare Edge
+-------------------------+           +------------------+
| Huddle GenServer        |--REST--->| Realtime SFU     |
| (room state, presence)  |          | (media routing)  |
|                         |           |                  |
| LiveView / PubSub       |           | TURN service     |
| (signaling, UI state)   |           | (NAT traversal)  |
+-------------------------+           +------------------+
       | WebSocket                        | WebRTC (UDP)
+-------------------------+
| Browser                 |--- audio --> Cloudflare --> other participants
| (JS WebRTC hook)        |<-- audio --
+-------------------------+
```

### Server-Side Responsibilities (Phoenix)

- **Huddle lifecycle:** Start, join, leave, end — GenServer per active huddle under DynamicSupervisor
- **Participant presence:** `Phoenix.Presence` for real-time join/leave/mute state
- **Cloudflare integration:** REST API calls to create/destroy rooms, generate participant tokens
- **UI state:** PubSub broadcasts for huddle bar, channel indicators, mute state
- **Feature flag:** `FunWithFlags.enabled?(:huddles)`

### Client-Side Responsibilities (Browser JS)

- **LiveView hook:** Wraps browser `RTCPeerConnection` API, connects to Cloudflare SFU
- **Audio controls:** Mute/unmute, speaker/mic selection, volume
- **Connection management:** ICE restart on disconnect, reconnection with backoff
- **Persistent across navigation:** WebRTC connection must survive LiveView patch/navigation

### Data Model (Ephemeral)

Huddles are transient — live state in GenServer/ETS, not persisted to Postgres:

```elixir
%Huddle{
  channel_id: snowflake,
  started_by: user_id,
  started_at: DateTime.t(),
  participants: MapSet.t(user_id),
  muted: MapSet.t(user_id),
  cloudflare_room_id: String.t()
}
```

Optional: persist `huddle_sessions` table for history/analytics after the core feature works.

---

## 6. UI Components

```
+-----------------------------------+
| #general                     [H] 3|  <-- Huddle indicator in channel header
+-----------------------------------+
|  ...messages...                    |
|                                    |
+-----------------------------------+
| [green] Alice  [muted] Bob  Carol |  <-- Huddle bar (bottom of channel)
| [Mute] [Leave]                    |
+-----------------------------------+
```

- **Huddle bar** (LiveComponent) — Shows participants, mute states, join/leave buttons
- **Channel header indicator** — Active huddle with participant count
- **Sidebar indicator** — Channels with active huddles get visual marker
- **Audio controls** — Mute/unmute, device selection
- **Three dismiss mechanisms** (per UI conventions) — for any huddle-related modals

---

## 7. Hard Problems

### 7.1 Persistent Audio Across Navigation

In Slack, switching channels doesn't disconnect your huddle. In LiveView, navigation typically unmounts/remounts components.

**Options:**
- JS hook that survives `live_navigation` patches (works if hook element stays in the DOM — e.g., in a root layout component)
- Dedicated persistent element outside the LiveView container

### 7.2 Multi-Node Considerations

Slackex already runs multi-node. Huddle GenServer state needs to be accessible from any node:

- Use `Phoenix.PubSub` (already cross-node) for presence and events
- Huddle GenServer could use a registry (e.g., `:global`, Horde) or just PubSub-based coordination
- Cloudflare handles the actual media, so node affinity for the GenServer is less critical

### 7.3 Browser Audio Permissions

- Microphone permission prompt on first use
- Handle permission denied gracefully
- Remember device selection across sessions (localStorage)

---

## 8. Implementation Phases (Rough)

### Phase 1: Foundation & 1:1 Calls
- Cloudflare Realtime account setup and API integration module
- Huddle GenServer + DynamicSupervisor
- Basic JS WebRTC hook connecting to Cloudflare
- Join/leave a huddle in a channel
- Feature flag: `:huddles`

### Phase 2: Core Huddle UX
- Huddle bar LiveComponent with participant list
- Mute/unmute with state broadcast
- Channel header and sidebar indicators
- Audio device selection
- Persistent audio across navigation

### Phase 3: Polish & Resilience
- Connection quality indicators
- Reconnection logic with backoff
- Multi-node huddle state coordination
- Huddle session history (optional persistence)
- Screen share (if Cloudflare supports video tracks)

---

## 9. Open Questions

1. **Cloudflare Realtime API specifics** — Room creation flow, token format, client SDK or raw WebRTC?
2. **ex_webrtc as future fallback** — Worth keeping as option if Cloudflare changes pricing/terms?
3. **Video support** — Audio-only initially, but should the architecture accommodate video later?
4. **Screen sharing** — Slack huddles support screen share. Include in scope?
5. **UDP from LXC** — Still worth testing even if going Cloudflare route, for future flexibility
6. **Mobile support** — WebRTC works in mobile browsers, but UX considerations differ
