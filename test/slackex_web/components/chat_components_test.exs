defmodule SlackexWeb.ChatComponentsTest do
  use SlackexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SlackexWeb.ChatComponents

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp channel_fixture(overrides \\ %{}) do
    Map.merge(%{id: 1, name: "general", slug: "general"}, overrides)
  end

  defp dm_fixture(overrides \\ %{}) do
    other_user = %{id: 2, username: "bob", display_name: "Bob Smith"}

    Map.merge(
      %{id: 1, other_user: other_user},
      overrides
    )
  end

  # ── channel_list_item ─────────────────────────────────────────────────

  describe "channel_list_item bold styling" do
    test "applies font-semibold when unread_count > 0" do
      html =
        render_component(&ChatComponents.channel_list_item/1,
          channel: channel_fixture(),
          unread_count: 3,
          active: false
        )

      assert html =~ "font-semibold"
    end

    test "does not apply font-semibold when unread_count is 0 and not active" do
      html =
        render_component(&ChatComponents.channel_list_item/1,
          channel: channel_fixture(),
          unread_count: 0,
          active: false
        )

      refute html =~ "font-semibold"
    end

    test "applies font-semibold when active regardless of unread count" do
      html =
        render_component(&ChatComponents.channel_list_item/1,
          channel: channel_fixture(),
          unread_count: 0,
          active: true
        )

      assert html =~ "font-semibold"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  # Extract the class attribute from the top-level <a> link tag.
  # The avatar also uses font-semibold, so we must check only the link's class.
  defp link_class(html) do
    [_, class] = Regex.run(~r/<a [^>]*class="([^"]*)"/, html)
    class
  end

  # ── dm_list_item ──────────────────────────────────────────────────────

  describe "dm_list_item bold styling" do
    test "applies font-semibold on link when unread_count > 0" do
      html =
        render_component(&ChatComponents.dm_list_item/1,
          dm: dm_fixture(),
          unread_count: 5,
          active: false,
          online: false
        )

      assert link_class(html) =~ "font-semibold"
    end

    test "does not apply font-semibold on link when unread_count is 0 and not active" do
      html =
        render_component(&ChatComponents.dm_list_item/1,
          dm: dm_fixture(),
          unread_count: 0,
          active: false,
          online: false
        )

      refute link_class(html) =~ "font-semibold"
    end

    test "applies font-semibold on link when active regardless of unread count" do
      html =
        render_component(&ChatComponents.dm_list_item/1,
          dm: dm_fixture(),
          unread_count: 0,
          active: true,
          online: false
        )

      assert link_class(html) =~ "font-semibold"
    end
  end
end
