# Slackex

Slackex is a real-time messaging context built around channels, DMs, unread state, and live presence. This glossary names the user-facing concepts that shape the chat experience.

## Language

**Chat Shell**:
The persistent frame of chat: sidebar, unread state, feature-gated controls, and the default state that surrounds every channel or DM view.
_Avoid_: Boot, layout, chrome

**Catchup**:
The reconstruction of unread state and missed-message context after a reconnect.
_Avoid_: Replay, resync, backlog

**Reconnect**:
A chat session re-establishing after it was already mounted once. It is not a first visit or a fresh page load.
_Avoid_: First load, initial mount
