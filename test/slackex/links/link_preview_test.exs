defmodule Slackex.Links.LinkPreviewTest do
  use Slackex.DataCase, async: true

  alias Slackex.Links.LinkPreview

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      attrs = %{
        message_id: 123_456_789,
        url: "https://example.com/article",
        title: "Example Article",
        description: "A great article about testing",
        site_name: "Example",
        image_url: "https://example.com/og.jpg",
        favicon_url: "https://example.com/favicon.ico",
        status: "fetched"
      }

      changeset = LinkPreview.changeset(%LinkPreview{}, attrs)
      assert changeset.valid?
    end

    test "requires message_id and url" do
      changeset = LinkPreview.changeset(%LinkPreview{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).message_id
      assert "can't be blank" in errors_on(changeset).url
    end

    test "validates status inclusion" do
      changeset =
        LinkPreview.changeset(%LinkPreview{}, %{
          message_id: 1,
          url: "https://example.com",
          status: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "truncates title to 200 chars" do
      long_title = String.duplicate("a", 250)

      changeset =
        LinkPreview.changeset(%LinkPreview{}, %{
          message_id: 1,
          url: "https://example.com",
          title: long_title,
          status: "fetched"
        })

      assert String.length(Ecto.Changeset.get_change(changeset, :title)) == 200
    end

    test "truncates description to 500 chars" do
      long_desc = String.duplicate("b", 600)

      changeset =
        LinkPreview.changeset(%LinkPreview{}, %{
          message_id: 1,
          url: "https://example.com",
          description: long_desc,
          status: "fetched"
        })

      assert String.length(Ecto.Changeset.get_change(changeset, :description)) == 500
    end

    test "truncates site_name to 100 chars" do
      long_name = String.duplicate("c", 150)

      changeset =
        LinkPreview.changeset(%LinkPreview{}, %{
          message_id: 1,
          url: "https://example.com",
          site_name: long_name,
          status: "fetched"
        })

      assert String.length(Ecto.Changeset.get_change(changeset, :site_name)) == 100
    end
  end
end
