defmodule Slackex.Integrations do
  @moduledoc """
  The Integrations context. Manages incoming webhooks and
  external service integrations.
  """

  use Boundary,
    deps: [Slackex.Accounts, Slackex.Chat],
    exports: [Webhook, Webhooks, McpToken, McpTokens]
end
