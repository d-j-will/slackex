defmodule Slackex.Chat do
  @moduledoc """
  The Chat context. Manages channels, messages, DM conversations, and read cursors.
  """

  use Boundary,
    deps: [Slackex.Accounts, Slackex.Infrastructure, Slackex.Encrypted],
    exports: [
      Channel,
      Message,
      MessageReaction,
      PinnedMessage,
      Members,
      Pins,
      InviteLink,
      Invites,
      DMConversation,
      DMRequest,
      ReadCursor,
      Subscription,
      UserBlock,
      UserTrustScore,
      AbuseReport,
      Permissions,
      DMRateLimiter
    ]

  # ---------------------------------------------------------------------------
  # Channels (delegated to Chat.Channels)
  # ---------------------------------------------------------------------------

  defdelegate create_channel(user_id, attrs), to: Slackex.Chat.Channels
  defdelegate count_members(channel_id), to: Slackex.Chat.Channels
  def list_public_channels(opts \\ []), do: Slackex.Chat.Channels.list_public_channels(opts)
  def list_active_channels(opts \\ []), do: Slackex.Chat.Channels.list_active_channels(opts)
  defdelegate list_user_channels(user_id), to: Slackex.Chat.Channels
  defdelegate list_user_channel_ids(user_id), to: Slackex.Chat.Channels
  defdelegate get_channel!(id), to: Slackex.Chat.Channels
  defdelegate get_channel_by_slug!(slug), to: Slackex.Chat.Channels
  defdelegate join_channel(user_id, channel_id), to: Slackex.Chat.Channels
  defdelegate leave_channel(user_id, channel_id), to: Slackex.Chat.Channels
  defdelegate get_role(user_id, channel_id), to: Slackex.Chat.Channels

  # ---------------------------------------------------------------------------
  # Messages (delegated to Chat.Messages)
  # ---------------------------------------------------------------------------

  defdelegate get_message!(id), to: Slackex.Chat.Messages
  defdelegate get_message(id), to: Slackex.Chat.Messages
  defdelegate edit_message(message_id, user_id, new_content), to: Slackex.Chat.Messages

  def delete_message(message_id, user_id, opts \\ []),
    do: Slackex.Chat.Messages.delete_message(message_id, user_id, opts)

  defdelegate send_message(channel_id, sender_id, content), to: Slackex.Chat.Messages

  def list_messages(channel_id, opts \\ []),
    do: Slackex.Chat.Messages.list_messages(channel_id, opts)

  def list_dm_messages(dm_id, opts \\ []),
    do: Slackex.Chat.Messages.list_dm_messages(dm_id, opts)

  def list_messages_around(target, message_id, opts \\ []),
    do: Slackex.Chat.Messages.list_messages_around(target, message_id, opts)

  # ---------------------------------------------------------------------------
  # Reactions (delegated to Chat.Reactions)
  # ---------------------------------------------------------------------------

  defdelegate toggle_reaction(message_id, user_id, emoji), to: Slackex.Chat.Reactions
  def list_reactions(message_ids), do: Slackex.Chat.Reactions.list_reactions(message_ids)

  # ---------------------------------------------------------------------------
  # Threads (delegated to Chat.Messages)
  # ---------------------------------------------------------------------------

  defdelegate send_reply(channel_id, sender_id, parent_message_id, content),
    to: Slackex.Chat.Messages

  def list_thread(parent_message_id, opts \\ []),
    do: Slackex.Chat.Messages.list_thread(parent_message_id, opts)

  # ---------------------------------------------------------------------------
  # DMs (delegated to Chat.DMs)
  # ---------------------------------------------------------------------------

  defdelegate get_dm(id), to: Slackex.Chat.DMs
  defdelegate find_or_create_dm(user_a_id, user_b_id), to: Slackex.Chat.DMs
  defdelegate create_dm_request(sender_id, recipient_id, preview_text), to: Slackex.Chat.DMs
  defdelegate accept_dm_request(request_id, recipient_id), to: Slackex.Chat.DMs
  defdelegate decline_dm_request(request_id, recipient_id), to: Slackex.Chat.DMs
  defdelegate list_pending_requests_for_user(user_id), to: Slackex.Chat.DMs
  defdelegate send_dm(dm_id, sender_id, content), to: Slackex.Chat.DMs
  defdelegate list_dms(user_id), to: Slackex.Chat.DMs
  defdelegate list_user_dm_conversations(user_id), to: Slackex.Chat.DMs
  defdelegate get_dm_conversation!(id), to: Slackex.Chat.DMs

  # ---------------------------------------------------------------------------
  # Read state (delegated to Chat.ReadState)
  # ---------------------------------------------------------------------------

  defdelegate mark_as_read(user_id, channel_id), to: Slackex.Chat.ReadState
  defdelegate unread_count(user_id, channel_id), to: Slackex.Chat.ReadState
  defdelegate mark_dm_as_read(user_id, dm_conversation_id), to: Slackex.Chat.ReadState
  defdelegate batch_unread_counts(user_id), to: Slackex.Chat.ReadState

  # ---------------------------------------------------------------------------
  # Moderation (delegated to Chat.Moderation)
  # ---------------------------------------------------------------------------

  defdelegate block_user(blocker_id, blocked_id), to: Slackex.Chat.Moderation
  defdelegate unblock_user(blocker_id, blocked_id), to: Slackex.Chat.Moderation
  defdelegate blocked?(blocker_id, blocked_id), to: Slackex.Chat.Moderation
  defdelegate list_blocked_user_ids(user_id), to: Slackex.Chat.Moderation
  defdelegate list_blocked_users(user_id), to: Slackex.Chat.Moderation

  defdelegate create_abuse_report(reporter_id, reported_user_id, attrs),
    to: Slackex.Chat.Moderation
end
