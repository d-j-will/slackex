defmodule Slackex.Links.URLExtractorTest do
  use ExUnit.Case, async: true

  alias Slackex.Links.URLExtractor

  describe "extract/1" do
    test "extracts a single URL" do
      assert URLExtractor.extract("Check out https://example.com") == ["https://example.com"]
    end

    test "extracts multiple URLs" do
      text = "See https://foo.com and http://bar.org/page"
      assert URLExtractor.extract(text) == ["https://foo.com", "http://bar.org/page"]
    end

    test "handles URLs with paths, query strings, and fragments" do
      url = "https://example.com/path/to/page?q=test&lang=en#section"
      assert URLExtractor.extract("Visit #{url}") == [url]
    end

    test "ignores non-http URLs" do
      assert URLExtractor.extract("ftp://files.example.com") == []
      assert URLExtractor.extract("mailto:user@example.com") == []
    end

    test "returns empty list for text without URLs" do
      assert URLExtractor.extract("No links here!") == []
    end

    test "handles nil content" do
      assert URLExtractor.extract(nil) == []
    end

    test "deduplicates URLs" do
      text = "https://example.com is at https://example.com"
      assert URLExtractor.extract(text) == ["https://example.com"]
    end

    test "strips trailing punctuation" do
      assert URLExtractor.extract("Go to https://example.com.") == ["https://example.com"]
      assert URLExtractor.extract("See https://example.com, ok?") == ["https://example.com"]
    end

    test "limits to 5 URLs per message" do
      urls = for i <- 1..8, do: "https://example#{i}.com"
      text = Enum.join(urls, " ")
      assert length(URLExtractor.extract(text)) == 5
    end
  end

  describe "linkify/1" do
    test "wraps URLs in anchor tags" do
      result = URLExtractor.linkify("Visit https://example.com today")
      html = safe_to_string(result)

      assert html =~ ~s(href="https://example.com")
      assert html =~ ~s(rel="noopener noreferrer ugc")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(class="link link-primary")
    end

    test "escapes HTML in non-URL text" do
      result = URLExtractor.linkify("<script>alert('xss')</script> https://safe.com")
      html = safe_to_string(result)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ ~s(href="https://safe.com")
    end

    test "handles nil" do
      assert {:safe, ""} = URLExtractor.linkify(nil)
    end

    test "handles empty string" do
      assert {:safe, ""} = URLExtractor.linkify("")
    end

    test "returns text unchanged when no URLs" do
      result = URLExtractor.linkify("Hello world")
      html = safe_to_string(result)
      assert html == "Hello world"
    end
  end

  defp safe_to_string({:safe, str}), do: str
  defp safe_to_string(str) when is_binary(str), do: str
end
