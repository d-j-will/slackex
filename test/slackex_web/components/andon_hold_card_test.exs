defmodule SlackexWeb.AndonHoldCardTest do
  @moduledoc """
  What the hold card must state, asserted against the rendered output — the
  channel's answer to "what is held, who has it, and is anyone on it" without
  opening another tool.
  """
  use SlackexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SlackexWeb.ChatComponents

  defp hold(overrides) do
    Map.merge(
      %{
        "pull_id" => "p-1",
        "class" => "defect",
        "thread" => "4242",
        "subject" => %{"adapter" => "linear", "external_id" => "ENG-9"},
        "held_since" => "2026-07-25T09:00:00Z",
        "escalated" => false,
        "holder" => %{"relay" => "slackex", "token" => "77"},
        "holder_source" => "dri",
        "acked_at" => nil,
        "ack_due_at" => "2026-07-25T09:20:00Z",
        "epoch" => 0,
        "actions" => []
      },
      overrides
    )
  end

  defp render_card(holds, viewer_id) do
    render_component(&ChatComponents.andon_hold_card/1,
      mirror: %{"active_holds" => holds},
      current_user_id: viewer_id
    )
  end

  test "each hold names its subject, its class and whoever is holding it" do
    html = render_card([hold(%{})], 1)

    assert html =~ "ENG-9"
    assert html =~ "defect"
    assert html =~ "@77"
  end

  test "the deadline travels as an absolute time for the client to count from" do
    html = render_card([hold(%{})], 1)

    assert html =~ ~s(data-due="2026-07-25T09:20:00Z")
    assert html =~ ~s(data-since="2026-07-25T09:00:00Z")
  end

  test "after an escalation the row says who carries it now, and that it moved" do
    html =
      render_card(
        [
          hold(%{
            "holder" => %{"relay" => "slackex", "token" => "88"},
            "holder_source" => "escalated_to"
          })
        ],
        1
      )

    assert html =~ "@88"
    assert html =~ "escalated"
  end

  test "rows render in payload order — the card never reorders by how overdue something is" do
    html =
      render_card(
        [
          hold(%{"pull_id" => "p-1", "subject" => %{"external_id" => "ENG-1"}}),
          hold(%{"pull_id" => "p-2", "subject" => %{"external_id" => "ENG-2"}}),
          hold(%{"pull_id" => "p-3", "subject" => %{"external_id" => "ENG-3"}})
        ],
        1
      )

    assert [_, one, two, three] = String.split(html, ~r/ENG-/)
    assert String.starts_with?(one, "1")
    assert String.starts_with?(two, "2")
    assert String.starts_with?(three, "3")
  end

  test "a viewer is offered only what the service authorized them to do" do
    holds = [
      hold(%{
        "actions" => [
          %{"action" => "release", "authorized" => %{"relay" => "slackex", "token" => "5"}},
          %{"action" => "ack", "authorized" => %{"relay" => "slackex", "token" => "77"}}
        ]
      })
    ]

    puller_view = render_card(holds, 5)
    assert puller_view =~ "resolved"
    refute puller_view =~ "heard"

    holder_view = render_card(holds, 77)
    assert holder_view =~ "heard"
    refute holder_view =~ "resolved"

    bystander_view = render_card(holds, 999)
    refute bystander_view =~ "resolved"
    refute bystander_view =~ "heard"
  end

  test "a deep board stays bounded, and says how much is below the fold" do
    holds =
      for n <- 1..12,
          do: hold(%{"pull_id" => "p-#{n}", "subject" => %{"external_id" => "ENG-#{n}"}})

    html = render_card(holds, 1)

    assert html =~ "ENG-8"
    refute html =~ "ENG-9\""
    assert html =~ "+ 4 more held"
  end

  test "no holds, no card" do
    assert render_card([], 1) == ""
  end
end
