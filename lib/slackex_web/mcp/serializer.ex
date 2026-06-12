defmodule SlackexWeb.MCP.Serializer do
  @moduledoc """
  Transforms domain structs into JSON-safe maps for MCP responses.

  This is the boundary between Tenun's internal data model and what agents see.
  Explicit field selection per entity — no Jason.Encoder derivation on domain schemas.

  Messages loaded via Ecto queries are automatically decrypted by the Cloak field type.
  The serializer must only receive Ecto-loaded structs, never raw database rows.
  """

  alias Slackex.Accounts.User
  alias Slackex.Chat.Channel
  alias Slackex.Chat.Message

  def channel(%Channel{} = ch, member_count) do
    %{
      id: to_string(ch.id),
      name: ch.name,
      slug: ch.slug,
      description: ch.description,
      member_count: member_count,
      inserted_at: DateTime.to_iso8601(ch.inserted_at)
    }
  end

  def message(%Message{} = msg) do
    base = %{
      id: to_string(msg.id),
      channel_id: msg.channel_id && to_string(msg.channel_id),
      sender_id: to_string(msg.sender_id),
      content: msg.content,
      parent_message_id: msg.parent_message_id && to_string(msg.parent_message_id),
      reply_count: msg.reply_count,
      edited_at: msg.edited_at && DateTime.to_iso8601(msg.edited_at),
      inserted_at: DateTime.to_iso8601(msg.inserted_at)
    }

    # Denormalize channel human identity when the assoc is already preloaded
    # (from search queries or explicit preload in caller). Pattern match avoids
    # triggering lazy load (which would be hidden cost/N+1). Only for channel
    # messages; DM messages (no channel) and bare loads omit the keys (additive).
    case msg do
      %Message{channel: %Channel{name: name, slug: slug}} ->
        Map.merge(base, %{channel_name: name, channel_slug: slug})

      %Message{channel: %{name: name, slug: slug}} ->
        # Support attached map (e.g. from post-lookup in MCP server for reply)
        Map.merge(base, %{channel_name: name, channel_slug: slug})

      _ ->
        base
    end
  end

  @doc """
  Serializes a plain map from ChannelServer (not an Ecto struct).
  Used for send_message/reply_to_thread responses where the message
  hasn't been flushed to DB yet (batch writes).
  """
  def message_from_map(msg) when is_map(msg) do
    base = %{
      id: to_string(msg.id),
      channel_id: msg[:channel_id] && to_string(msg.channel_id),
      sender_id: to_string(msg.sender_id),
      content: msg.content,
      parent_message_id: msg[:parent_message_id] && to_string(msg.parent_message_id),
      reply_count: msg[:reply_count] || 0,
      edited_at: nil,
      inserted_at: DateTime.to_iso8601(msg.inserted_at)
    }

    # Support channel name/slug passed through from MCP server enrichment
    # (send_message path: lookup once using known channel_id, attach at top level
    # before calling from_map; keeps serializer cheap, no lookups here).
    # Omit if absent (backward compat for in-mem maps without).
    ch = msg[:channel]

    name =
      msg[:channel_name] ||
        if is_map(ch), do: ch[:name] || Map.get(ch, :name)

    slug =
      msg[:channel_slug] ||
        if is_map(ch), do: ch[:slug] || Map.get(ch, :slug)

    if name && slug do
      Map.merge(base, %{channel_name: name, channel_slug: slug})
    else
      base
    end
  end

  def messages(msgs) when is_list(msgs) do
    Enum.map(msgs, &message/1)
  end

  def user(%User{} = u) do
    %{
      id: to_string(u.id),
      username: u.username,
      display_name: u.display_name,
      avatar_url: u.avatar_url,
      is_bot: u.is_bot
    }
  end

  def ops_summary(%{
        "generated_at" => generated_at,
        "node" => node,
        "active_channel_servers" => active_channel_servers,
        "online_users_count" => online_users_count,
        "queue_running_counts" => queue_running_counts,
        "partial_failures" => partial_failures
      }) do
    %{
      generated_at: generated_at,
      node: node,
      active_channel_servers: active_channel_servers,
      online_users_count: online_users_count,
      queue_running_counts: queue_running_counts,
      partial_failures: partial_failures
    }
  end
end
