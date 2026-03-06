# Feature Flags

All features are controlled via [FunWithFlags](https://github.com/tompave/fun_with_flags). Flags default to **disabled** unless explicitly enabled.

Enable in production via remote console:

```elixir
FunWithFlags.enable(:flag_name)
```

## Flags

| Flag | Status | Description | What it controls |
|------|--------|-------------|------------------|
| `:message_search` | Disabled | Full-text and semantic search across messages | Search button in channel/DM headers, search panel, hybrid search (text + vector) |
| `:channel_summarization` | Disabled | AI-powered channel summarization | Summarize button in channel header, summary modal, LLM API calls |
| `:reactions` | Disabled | Emoji reactions on messages | Reaction bar under messages, emoji picker hover action, toggle reaction events |
| `:threads` | Disabled | Threaded replies on messages | Reply-in-thread hover action, reply count links, side thread panel |
| `:channel_management` | Disabled | Channel administration tools | Members modal (roles, kick), pinned messages modal, invite link generation/revocation, pin hover action |
| `:quick_switcher` | Disabled | Keyboard-driven channel/DM navigation | Ctrl+K / Cmd+K modal with fuzzy search across channels and DMs |
| `:link_previews` | Disabled | Rich inline link preview cards | URL extraction, OG metadata fetching, safety checking (blocklist + Safe Browsing), preview cards below messages |
| `:show_cluster_node` | Disabled | Show cluster node badge in sidebar | Per-user flag. Shows which BEAM node the user is connected to (useful for debugging distributed deployments) |

## Per-User Flags

`:show_cluster_node` supports per-user targeting:

```elixir
user = Slackex.Repo.get!(Slackex.Accounts.User, user_id)
FunWithFlags.enable(:show_cluster_node, for: user)
```

All other flags are global (on/off for everyone).

## Rollout Checklist

When enabling a flag in production:

1. Verify migrations have run (`mix ecto.migrate`)
2. Enable the flag: `FunWithFlags.enable(:flag_name)`
3. Verify in-app (flag takes effect on next page load / LiveView reconnect)
4. If issues arise, disable immediately: `FunWithFlags.disable(:flag_name)`
