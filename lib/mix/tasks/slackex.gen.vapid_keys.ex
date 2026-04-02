defmodule Mix.Tasks.Slackex.Gen.VapidKeys do
  @moduledoc """
  Generates a VAPID key pair for Web Push notifications.

  Outputs URL-safe Base64-encoded public and private keys suitable for
  the `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` environment variables.

  ## Usage

      mix slackex.gen.vapid_keys
  """

  use Mix.Task

  @shortdoc "Generate VAPID key pair for Web Push notifications"
  def run(_args) do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

    encoded_public = Base.url_encode64(public, padding: false)
    encoded_private = Base.url_encode64(private, padding: false)

    Mix.shell().info("""

    VAPID Key Pair Generated
    ========================

    Add these to your production .env file:

      VAPID_PUBLIC_KEY=#{encoded_public}
      VAPID_PRIVATE_KEY=#{encoded_private}

    The public key is also used in the client-side service worker
    subscription call (applicationServerKey).
    """)
  end
end
