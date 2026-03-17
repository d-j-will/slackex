defmodule Slackex.Test.MetadataParserStub do
  @moduledoc """
  A simple Plug used as the Req adapter for MetadataParser in tests.

  Configured via `config :slackex, :metadata_parser_req_options, plug: __MODULE__`
  in `config/test.exs`. This avoids real HTTP in all tests without relying on
  Req.Test's process-ownership model (which doesn't reach globally supervised
  GenServers like LinkPreviewListener).

  Returns a minimal HTML page with OpenGraph tags so MetadataParser produces
  a `status: "fetched"` LinkPreview record.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    html = """
    <html>
    <head>
      <title>Test Page</title>
      <meta property="og:title" content="Test Page Title" />
      <meta property="og:description" content="A stub page for link preview tests." />
      <meta property="og:site_name" content="Test Site" />
    </head>
    <body>Hello from stub</body>
    </html>
    """

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, html)
  end
end
