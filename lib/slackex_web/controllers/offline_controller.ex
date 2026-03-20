defmodule SlackexWeb.OfflineController do
  use SlackexWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_content_type("text/html")
    |> send_resp(200, offline_html())
  end

  defp offline_html do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta http-equiv="refresh" content="5" />
      <title>Tenun</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          display: flex;
          align-items: center;
          justify-content: center;
          min-height: 100vh;
          background: #2A2640;
          color: #f5f5f5;
        }
        @media (prefers-color-scheme: light) {
          body { background: #FAFAFA; color: #1a1a1a; }
          .icon { background: #E8A835; }
        }
        .container { text-align: center; }
        .icon {
          width: 80px; height: 80px;
          background: #5D4D8F;
          border-radius: 20px;
          display: flex;
          align-items: center;
          justify-content: center;
          margin: 0 auto 24px;
          font-size: 40px;
          font-weight: 700;
          color: white;
        }
        .title { font-size: 20px; font-weight: 600; margin-bottom: 8px; }
        .subtitle { font-size: 14px; opacity: 0.6; }
        .dots::after {
          content: '';
          animation: dots 1.5s steps(4, end) infinite;
        }
        @keyframes dots {
          0% { content: ''; }
          25% { content: '.'; }
          50% { content: '..'; }
          75% { content: '...'; }
        }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="icon">T</div>
        <div class="title">Tenun</div>
        <div class="subtitle">Connecting<span class="dots"></span></div>
      </div>
    </body>
    </html>
    """
  end
end
