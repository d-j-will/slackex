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

  # ── Helpers ────────────────────────────────────────────────────────────

  # Extract the class attribute from the top-level <a> link tag.
  # The avatar also uses font-semibold, so we must check only the link's class.
  defp link_class(html) do
    [_, class] = Regex.run(~r/<a [^>]*class="([^"]*)"/, html)
    class
  end

  # ── channel_list_item ─────────────────────────────────────────────────

  describe "channel_list_item bold styling" do
    test "applies font-semibold on link when unread_count > 0" do
      html =
        render_component(&ChatComponents.channel_list_item/1,
          channel: channel_fixture(),
          unread_count: 3,
          active: false
        )

      assert link_class(html) =~ "font-semibold"
    end

    test "does not apply font-semibold on link when unread_count is 0 and not active" do
      html =
        render_component(&ChatComponents.channel_list_item/1,
          channel: channel_fixture(),
          unread_count: 0,
          active: false
        )

      refute link_class(html) =~ "font-semibold"
    end

    test "applies font-semibold on link when active regardless of unread count" do
      html =
        render_component(&ChatComponents.channel_list_item/1,
          channel: channel_fixture(),
          unread_count: 0,
          active: true
        )

      assert link_class(html) =~ "font-semibold"
    end
  end

  # ── unread_badge ──────────────────────────────────────────────────────

  describe "unread_badge high count display" do
    test "renders 99+ when unread_count exceeds 99" do
      html =
        render_component(&ChatComponents.unread_badge/1,
          count: 150
        )

      assert html =~ "99+"
      refute html =~ "150"
    end
  end

  # ── link_preview_card ─────────────────────────────────────────────────

  describe "link_preview_card" do
    defp fetched_preview_fixture(overrides \\ %{}) do
      Map.merge(
        %{
          status: "fetched",
          url: "https://example.com/article",
          title: "Example Article",
          description: "A great article about testing",
          site_name: "Example",
          image_url: "https://example.com/og.jpg",
          favicon_url: "https://example.com/favicon.ico"
        },
        overrides
      )
    end

    test "renders fetched preview as a clickable link with title and description" do
      html =
        render_component(&ChatComponents.link_preview_card/1,
          preview: fetched_preview_fixture()
        )

      assert html =~ ~s(href="https://example.com/article")
      assert html =~ "Example Article"
      assert html =~ "A great article about testing"
      assert html =~ "Example"
    end

    test "renders pending preview as a skeleton placeholder without a link" do
      html =
        render_component(&ChatComponents.link_preview_card/1,
          preview: %{status: "pending", url: "https://example.com"}
        )

      assert html =~ "animate-pulse"
      assert html =~ "skeleton"
      refute html =~ ~s(href=)
    end

    test "renders nothing for blocked status" do
      html =
        render_component(&ChatComponents.link_preview_card/1,
          preview: %{status: "blocked", url: "https://example.com"}
        )

      refute html =~ "animate-pulse"
      refute html =~ ~s(href=)
    end
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
