defmodule Slackex.Links.MetadataParserTest do
  use ExUnit.Case, async: true

  alias Slackex.Links.MetadataParser

  describe "parse_html/2" do
    test "extracts OpenGraph metadata" do
      html = """
      <html>
      <head>
        <meta property="og:title" content="Test Article" />
        <meta property="og:description" content="A description of the article" />
        <meta property="og:site_name" content="TestSite" />
        <meta property="og:image" content="https://example.com/image.jpg" />
        <link rel="icon" href="/favicon.ico" />
      </head>
      <body></body>
      </html>
      """

      result = MetadataParser.parse_html(html, "https://example.com/article")

      assert result.title == "Test Article"
      assert result.description == "A description of the article"
      assert result.site_name == "TestSite"
      assert result.image_url == "https://example.com/image.jpg"
      assert result.favicon_url == "https://example.com/favicon.ico"
    end

    test "falls back to <title> when og:title is missing" do
      html = """
      <html>
      <head><title>Fallback Title</title></head>
      <body></body>
      </html>
      """

      result = MetadataParser.parse_html(html, "https://example.com")
      assert result.title == "Fallback Title"
    end

    test "strips HTML tags from OG content" do
      html = """
      <html>
      <head>
        <meta property="og:title" content="&lt;b&gt;Bold&lt;/b&gt; Title" />
        <meta property="og:description" content="&lt;p&gt;Paragraph&lt;/p&gt; text" />
      </head>
      <body></body>
      </html>
      """

      result = MetadataParser.parse_html(html, "https://example.com")
      assert result.title == "Bold Title"
      assert result.description == "Paragraph text"
    end

    test "resolves relative favicon URLs" do
      html = """
      <html>
      <head>
        <link rel="icon" href="/assets/favicon.png" />
        <meta property="og:title" content="Test" />
      </head>
      <body></body>
      </html>
      """

      result = MetadataParser.parse_html(html, "https://example.com/page")
      assert result.favicon_url == "https://example.com/assets/favicon.png"
    end

    test "returns nil fields for minimal HTML" do
      result =
        MetadataParser.parse_html(
          "<html><head></head><body></body></html>",
          "https://example.com"
        )

      assert result.title == nil
      assert result.description == nil
      assert result.image_url == nil
    end

    test "handles shortcut icon rel attribute" do
      html = """
      <html>
      <head>
        <link rel="shortcut icon" href="https://example.com/fav.ico" />
      </head>
      <body></body>
      </html>
      """

      result = MetadataParser.parse_html(html, "https://example.com")
      assert result.favicon_url == "https://example.com/fav.ico"
    end
  end
end
