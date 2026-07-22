defmodule Slackex.Andon.HTTPServiceClientTest do
  @moduledoc """
  The relay→service HTTP seam at its own wire boundary (Req.Test stubs the
  wire): a bearer-authed JSON POST to `/relay/v1/events`, `retry: false`, and
  the full response (status + decoded body) handed back so the caller can
  branch on 201/200/4xx. Missing config degrades, never raises.
  """
  use ExUnit.Case, async: false

  alias Slackex.Andon.HTTPServiceClient

  @event %{
    "event" => "pull_created",
    "event_id" => "slackex-123",
    "occurred_at" => "2026-07-22T10:00:00Z",
    "puller" => %{"relay" => "slackex", "token" => "42"},
    "class" => "defect",
    "sentence" => "the build is red on main",
    "origin" => %{
      "relay" => "slackex",
      "channel" => "7",
      "thread" => "123",
      "message" => "123"
    }
  }

  setup do
    original = Application.get_env(:slackex, :andon_service)
    on_exit(fn -> Application.put_env(:slackex, :andon_service, original) end)
    :ok
  end

  defp configure(plug_name) do
    Application.put_env(:slackex, :andon_service,
      url: "http://andon.test",
      token: "the-relay-token",
      req_options: [plug: {Req.Test, plug_name}]
    )
  end

  test "POSTs the event as bearer-authed JSON to /relay/v1/events and returns status+body" do
    configure(__MODULE__)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/relay/v1/events"
      assert ["Bearer the-relay-token"] = Plug.Conn.get_req_header(conn, "authorization")

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["event"] == "pull_created"
      assert decoded["event_id"] == "slackex-123"
      assert decoded["origin"]["channel"] == "7"

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "data" => %{"pull_id" => "p-1", "log_position" => 1},
        "commands" => [%{"command" => "request_subject", "thread" => "123"}]
      })
    end)

    assert {:ok, %{status: 201, body: body}} = HTTPServiceClient.post_event(@event)
    assert body["data"]["pull_id"] == "p-1"
    assert [%{"command" => "request_subject"}] = body["commands"]
  end

  test "a 4xx is returned (not raised) so the caller can surface the error" do
    configure(__MODULE__)

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{"errors" => %{"puller" => ["only the puller may withdraw"]}})
    end)

    assert {:ok, %{status: 403, body: body}} = HTTPServiceClient.post_event(@event)
    assert body["errors"]["puller"] == ["only the puller may withdraw"]
  end

  test "a network failure degrades to an error, never a raise" do
    configure(__MODULE__)
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, _reason} = HTTPServiceClient.post_event(@event)
  end

  test "no configured url degrades to :not_configured" do
    Application.put_env(:slackex, :andon_service, token: "x")
    assert {:error, :not_configured} = HTTPServiceClient.post_event(@event)
  end
end
