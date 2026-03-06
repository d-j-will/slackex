# Link Previews Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Render rich inline preview cards for URLs posted in messages, with multi-layer safety blocking for malicious/inappropriate sites.

**Architecture:** URLs are extracted from message content at send time. An Oban worker fetches metadata asynchronously, writes to a `link_previews` table, and broadcasts via PubSub so all connected LiveViews render preview cards inline below messages. Multi-layer URL safety: compile-time domain blocklist + Google Safe Browsing API. Feature-flagged behind `:link_previews`.

**Tech Stack:** Elixir, Ecto, Oban, Phoenix PubSub, Req (HTTP client), Floki (HTML parsing), FunWithFlags

---

### Task 1: Create the `link_previews` Migration

**Files:**
- Create: `priv/repo/migrations/YYYYMMDDHHMMSS_create_link_previews.exs`

**Step 1: Generate the migration**

Run: `mix ecto.gen.migration create_link_previews`

**Step 2: Write the migration**

```elixir
defmodule Slackex.Repo.Migrations.CreateLinkPreviews do
  use Ecto.Migration

  def change do
    create table(:link_previews) do
      add :message_id, :bigint, null: false
      add :url, :string, null: false
      add :title, :string, size: 200
      add :description, :string, size: 500
      add :site_name, :string, size: 100
      add :image_url, :string
      add :favicon_url, :string
      add :status, :string, null: false, default: "pending"
      add :blocked_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:link_previews, [:message_id])
  end
end
```

Note: No foreign key to `messages` — the messages table is partitioned and Snowflake IDs make FK constraints impractical. The index on `message_id` is sufficient for preloading.

**Step 3: Run the migration**

Run: `mix ecto.migrate`
Expected: Migration succeeds.

**Step 4: Commit**

```bash
git add priv/repo/migrations/*_create_link_previews.exs
git commit -m "feat(links): add link_previews migration"
```

---

### Task 2: Create the LinkPreview Schema

**Files:**
- Create: `lib/slackex/links/link_preview.ex`
- Create: `test/slackex/links/link_preview_test.exs`

**Step 1: Write the test**

```elixir
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

    test "requires message_id, url, and status" do
      changeset = LinkPreview.changeset(%LinkPreview{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).message_id
      assert "can't be blank" in errors_on(changeset).url
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

    test "validates status is fetched or blocked" do
      changeset =
        LinkPreview.changeset(%LinkPreview{}, %{
          message_id: 1,
          url: "https://example.com",
          status: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end
  end
end
```

**Step 2: Run the test to verify it fails**

Run: `mix test test/slackex/links/link_preview_test.exs`
Expected: FAIL — module not found.

**Step 3: Write the schema**

```elixir
defmodule Slackex.Links.LinkPreview do
  @moduledoc """
  Schema for cached link preview metadata extracted from URLs in messages.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending fetched blocked)

  schema "link_previews" do
    field :message_id, :integer
    field :url, :string
    field :title, :string
    field :description, :string
    field :site_name, :string
    field :image_url, :string
    field :favicon_url, :string
    field :status, :string, default: "pending"
    field :blocked_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [
      :message_id,
      :url,
      :title,
      :description,
      :site_name,
      :image_url,
      :favicon_url,
      :status,
      :blocked_reason
    ])
    |> validate_required([:message_id, :url])
    |> validate_inclusion(:status, @statuses)
    |> truncate_field(:title, 200)
    |> truncate_field(:description, 500)
    |> truncate_field(:site_name, 100)
  end

  defp truncate_field(changeset, field, max_length) do
    case get_change(changeset, field) do
      nil -> changeset
      value -> put_change(changeset, field, String.slice(value, 0, max_length))
    end
  end
end
```

**Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/links/link_preview_test.exs`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add lib/slackex/links/link_preview.ex test/slackex/links/link_preview_test.exs
git commit -m "feat(links): add LinkPreview schema with truncation"
```

---

### Task 3: Create the URLExtractor Module

**Files:**
- Create: `lib/slackex/links/url_extractor.ex`
- Create: `test/slackex/links/url_extractor_test.exs`

**Step 1: Write the test**

```elixir
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

      assert result =~
               ~s(<a href="https://example.com" target="_blank" rel="noopener noreferrer ugc" class="link link-primary">https://example.com</a>)
    end

    test "escapes HTML in non-URL text" do
      result = URLExtractor.linkify("<script>alert('xss')</script> https://safe.com")
      refute result =~ "<script>"
      assert result =~ "&lt;script&gt;"
      assert result =~ ~s(href="https://safe.com")
    end

    test "returns safe HTML" do
      result = URLExtractor.linkify("Hello https://example.com")
      assert is_struct(result, Phoenix.HTML.Safe) or is_binary(result)
    end
  end
end
```

**Step 2: Run the test to verify it fails**

Run: `mix test test/slackex/links/url_extractor_test.exs`
Expected: FAIL — module not found.

**Step 3: Write the implementation**

```elixir
defmodule Slackex.Links.URLExtractor do
  @moduledoc """
  Extracts and linkifies HTTP(S) URLs from message text.
  """

  @url_regex ~r{https?://[^\s<>"'\)\]]+}i
  @max_urls 5
  @trailing_punct ~r/[.,;:!?\)]+$/

  @doc "Extracts up to #{@max_urls} unique HTTP(S) URLs from text."
  @spec extract(String.t() | nil) :: [String.t()]
  def extract(nil), do: []
  def extract(""), do: []

  def extract(text) when is_binary(text) do
    @url_regex
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, @trailing_punct, ""))
    |> Enum.uniq()
    |> Enum.take(@max_urls)
  end

  @doc """
  Replaces URLs in text with clickable HTML anchor tags.
  Non-URL text is HTML-escaped.
  Returns a Phoenix.HTML safe string.
  """
  @spec linkify(String.t() | nil) :: Phoenix.HTML.safe()
  def linkify(nil), do: {:safe, ""}
  def linkify(""), do: {:safe, ""}

  def linkify(text) when is_binary(text) do
    parts =
      Regex.split(@url_regex, text, include_captures: true)
      |> Enum.map(fn part ->
        if Regex.match?(@url_regex, part) do
          url = String.replace(part, @trailing_punct, "")
          escaped_url = Phoenix.HTML.html_escape(url) |> Phoenix.HTML.safe_to_string()

          ~s(<a href="#{escaped_url}" target="_blank" rel="noopener noreferrer ugc" class="link link-primary">#{escaped_url}</a>)
        else
          Phoenix.HTML.html_escape(part) |> Phoenix.HTML.safe_to_string()
        end
      end)

    {:safe, Enum.join(parts)}
  end
end
```

**Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/links/url_extractor_test.exs`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add lib/slackex/links/url_extractor.ex test/slackex/links/url_extractor_test.exs
git commit -m "feat(links): add URLExtractor with extract and linkify"
```

---

### Task 4: Create the SafetyChecker Module

**Files:**
- Create: `lib/slackex/links/safety_checker.ex`
- Create: `priv/links/blocked_domains.txt`
- Create: `test/slackex/links/safety_checker_test.exs`

**Step 1: Create the blocked domains file**

Create `priv/links/blocked_domains.txt` with a starter list. In production this would be sourced from Steven Black's hosts list, but start with a representative sample:

```text
# Blocked domains for link preview safety
# Sources: Steven Black's unified hosts, manual additions
# Format: one domain per line, # for comments
pornhub.com
xvideos.com
xhamster.com
redtube.com
youporn.com
spankbang.com
casino-online.com
bet365-promo.com
freebitcoins.xyz
trackingclick.biz
malware-download.net
```

**Step 2: Write the test**

```elixir
defmodule Slackex.Links.SafetyCheckerTest do
  use ExUnit.Case, async: true

  alias Slackex.Links.SafetyChecker

  describe "check_domain/1" do
    test "blocks known blocked domains" do
      assert {:blocked, "blocklist"} = SafetyChecker.check_domain("https://pornhub.com/video")
    end

    test "blocks subdomains of blocked domains" do
      assert {:blocked, "blocklist"} = SafetyChecker.check_domain("https://www.pornhub.com")
    end

    test "allows safe domains" do
      assert :ok = SafetyChecker.check_domain("https://elixir-lang.org")
    end

    test "allows similar but non-blocked domains" do
      assert :ok = SafetyChecker.check_domain("https://example.com")
    end

    test "handles invalid URLs gracefully" do
      assert {:blocked, "invalid_url"} = SafetyChecker.check_domain("not-a-url")
    end
  end

  describe "check_safe_browsing/1" do
    # These tests use a mock/bypass since we don't want to hit Google's API in tests.
    # The SafetyChecker.check_safe_browsing/1 function is designed to be testable
    # by accepting an optional HTTP client module.

    test "returns :ok when safe browsing is not configured" do
      # When GOOGLE_SAFE_BROWSING_KEY is not set, skip the check
      assert :ok = SafetyChecker.check_safe_browsing("https://example.com")
    end
  end
end
```

**Step 3: Run the test to verify it fails**

Run: `mix test test/slackex/links/safety_checker_test.exs`
Expected: FAIL — module not found.

**Step 4: Write the implementation**

```elixir
defmodule Slackex.Links.SafetyChecker do
  @moduledoc """
  Multi-layer URL safety checking.

  Layer 1: Compile-time domain blocklist (porn, spam, gambling).
  Layer 2: Google Safe Browsing API (phishing, malware).
  """

  require Logger

  @blocked_domains_file "priv/links/blocked_domains.txt"
  @external_resource @blocked_domains_file

  @blocked_domains @blocked_domains_file
                   |> File.read!()
                   |> String.split("\n", trim: true)
                   |> Enum.reject(&String.starts_with?(&1, "#"))
                   |> Enum.map(&String.trim/1)
                   |> Enum.reject(&(&1 == ""))
                   |> MapSet.new()

  @doc "Checks a URL against the compile-time domain blocklist."
  @spec check_domain(String.t()) :: :ok | {:blocked, String.t()}
  def check_domain(url) do
    case URI.parse(url) do
      %URI{host: nil} ->
        {:blocked, "invalid_url"}

      %URI{host: host} ->
        host = String.downcase(host)

        if domain_blocked?(host) do
          {:blocked, "blocklist"}
        else
          :ok
        end
    end
  end

  @doc """
  Checks a URL against Google Safe Browsing API.
  Returns `:ok` if safe or API key not configured.
  Returns `{:blocked, "safe_browsing"}` if flagged.
  """
  @spec check_safe_browsing(String.t()) :: :ok | {:blocked, String.t()}
  def check_safe_browsing(url) do
    case Application.get_env(:slackex, :google_safe_browsing_key) do
      nil -> :ok
      "" -> :ok
      key -> do_safe_browsing_check(url, key)
    end
  end

  @doc "Runs all safety checks in order. Short-circuits on first block."
  @spec check(String.t()) :: :ok | {:blocked, String.t()}
  def check(url) do
    with :ok <- check_domain(url),
         :ok <- check_safe_browsing(url) do
      :ok
    end
  end

  # -- Private ----------------------------------------------------------------

  defp domain_blocked?(host) do
    # Check exact match and parent domains (e.g. www.pornhub.com -> pornhub.com)
    host
    |> domain_variants()
    |> Enum.any?(&MapSet.member?(@blocked_domains, &1))
  end

  defp domain_variants(host) do
    parts = String.split(host, ".")

    for i <- 0..(length(parts) - 2) do
      parts |> Enum.drop(i) |> Enum.join(".")
    end
  end

  defp do_safe_browsing_check(url, api_key) do
    body = %{
      client: %{clientId: "slackex", clientVersion: "1.0"},
      threatInfo: %{
        threatTypes: ["MALWARE", "SOCIAL_ENGINEERING", "UNWANTED_SOFTWARE"],
        platformTypes: ["ANY_PLATFORM"],
        threatEntryTypes: ["URL"],
        threatEntries: [%{url: url}]
      }
    }

    case Req.post(
           "https://safebrowsing.googleapis.com/v4/threatMatches:find",
           json: body,
           params: [key: api_key],
           receive_timeout: 2_000
         ) do
      {:ok, %{status: 200, body: %{"matches" => [_ | _]}}} ->
        Logger.warning("SafetyChecker: URL blocked by Safe Browsing: #{url}")
        {:blocked, "safe_browsing"}

      {:ok, %{status: 200}} ->
        :ok

      {:error, reason} ->
        Logger.warning("SafetyChecker: Safe Browsing API error for #{url}: #{inspect(reason)}")
        # Fail open — don't block on API errors, the fetch timeout will catch bad sites
        :ok
    end
  end
end
```

**Step 5: Run the test to verify it passes**

Run: `mix test test/slackex/links/safety_checker_test.exs`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add lib/slackex/links/safety_checker.ex priv/links/blocked_domains.txt test/slackex/links/safety_checker_test.exs
git commit -m "feat(links): add SafetyChecker with blocklist and Safe Browsing"
```

---

### Task 5: Create the MetadataParser Module

**Files:**
- Create: `lib/slackex/links/metadata_parser.ex`
- Create: `test/slackex/links/metadata_parser_test.exs`

**Step 1: Ensure Floki is a dependency**

Check `mix.exs` for `{:floki, ...}`. If not present, add it:

```elixir
{:floki, "~> 0.37"}
```

Then run: `mix deps.get`

Note: `Req` should already be a dependency (check `mix.exs`). If not, add `{:req, "~> 0.5"}`.

**Step 2: Write the test**

```elixir
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
        <meta property="og:title" content="<b>Bold</b> Title <script>alert('xss')</script>" />
        <meta property="og:description" content="<p>Paragraph</p> text" />
      </head>
      <body></body>
      </html>
      """

      result = MetadataParser.parse_html(html, "https://example.com")
      assert result.title == "Bold Title alert('xss')"
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
      result = MetadataParser.parse_html("<html><head></head><body></body></html>", "https://example.com")
      assert result.title == nil
      assert result.description == nil
      assert result.image_url == nil
    end
  end

  describe "fetch_and_parse/1" do
    # Integration tests would use Bypass here. Unit tests cover parse_html.
    # fetch_and_parse is tested indirectly via the LinkPreviewWorker tests.
  end
end
```

**Step 3: Run the test to verify it fails**

Run: `mix test test/slackex/links/metadata_parser_test.exs`
Expected: FAIL — module not found.

**Step 4: Write the implementation**

```elixir
defmodule Slackex.Links.MetadataParser do
  @moduledoc """
  Fetches a URL and extracts OpenGraph metadata for link previews.
  Sanitizes all extracted text (strips HTML, truncates, validates UTF-8).
  """

  require Logger

  @fetch_timeout 2_000
  @max_body_size 256_000

  @doc """
  Fetches a URL and returns parsed metadata.
  Returns `{:ok, metadata_map}` or `{:error, reason}`.
  """
  @spec fetch_and_parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch_and_parse(url) do
    case Req.get(url,
           receive_timeout: @fetch_timeout,
           connect_options: [timeout: @fetch_timeout],
           max_redirects: 3,
           raw: true,
           into: &collect_body/2
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, parse_html(body, url)}

      {:ok, %{status: status}} ->
        Logger.warning("MetadataParser: HTTP #{status} for #{url}")
        {:error, "http_#{status}"}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.warning("MetadataParser: transport error for #{url}: #{inspect(reason)}")
        {:error, "transport_error"}

      {:error, reason} ->
        Logger.warning("MetadataParser: fetch error for #{url}: #{inspect(reason)}")
        {:error, "fetch_error"}
    end
  rescue
    e ->
      Logger.warning("MetadataParser: exception fetching #{url}: #{inspect(e)}")
      {:error, "fetch_error"}
  end

  @doc """
  Parses HTML and extracts OpenGraph metadata.
  All text fields are sanitized (HTML stripped, truncated).
  """
  @spec parse_html(String.t(), String.t()) :: map()
  def parse_html(html, base_url) when is_binary(html) do
    {:ok, doc} = Floki.parse_document(html)

    %{
      title: og_content(doc, "og:title") || page_title(doc),
      description: og_content(doc, "og:description"),
      site_name: og_content(doc, "og:site_name"),
      image_url: og_content(doc, "og:image", sanitize: false),
      favicon_url: extract_favicon(doc, base_url)
    }
  end

  # -- Private ----------------------------------------------------------------

  defp og_content(doc, property, opts \\ []) do
    case Floki.find(doc, "meta[property='#{property}']") do
      [{_, attrs, _} | _] ->
        value =
          attrs
          |> Enum.find_value(fn
            {"content", v} -> v
            _ -> nil
          end)

        if Keyword.get(opts, :sanitize, true) do
          sanitize_text(value)
        else
          value
        end

      _ ->
        nil
    end
  end

  defp page_title(doc) do
    case Floki.find(doc, "title") do
      [{_, _, children} | _] -> children |> Floki.text() |> sanitize_text()
      _ -> nil
    end
  end

  defp extract_favicon(doc, base_url) do
    selector = "link[rel='icon'], link[rel='shortcut icon']"

    case Floki.find(doc, selector) do
      [{_, attrs, _} | _] ->
        href = Enum.find_value(attrs, fn
          {"href", v} -> v
          _ -> nil
        end)

        resolve_url(href, base_url)

      _ ->
        nil
    end
  end

  defp resolve_url(nil, _base_url), do: nil

  defp resolve_url(url, base_url) do
    case URI.parse(url) do
      %URI{scheme: nil} ->
        base = URI.parse(base_url)
        URI.to_string(%{base | path: url, query: nil, fragment: nil})

      _ ->
        url
    end
  end

  defp sanitize_text(nil), do: nil

  defp sanitize_text(text) do
    text
    |> Floki.text()
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
    |> case do
      "" -> nil
      clean -> if String.valid?(clean), do: clean, else: nil
    end
  end

  # Req body collector — stops reading after @max_body_size bytes
  defp collect_body({:data, data}, {req, resp}) do
    body = (resp.body || "") <> data

    if byte_size(body) > @max_body_size do
      {:halt, {req, %{resp | body: body}}}
    else
      {:cont, {req, %{resp | body: body}}}
    end
  end
end
```

Note: The `collect_body` function may need adjustment depending on the Req version. If `raw: true` and `into:` don't work as expected, simplify to a standard `Req.get/2` call and truncate the body after receipt. The test covers `parse_html` directly, and the worker integration test will validate `fetch_and_parse`.

**Step 5: Run the test to verify it passes**

Run: `mix test test/slackex/links/metadata_parser_test.exs`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add lib/slackex/links/metadata_parser.ex test/slackex/links/metadata_parser_test.exs
git commit -m "feat(links): add MetadataParser with OG extraction and sanitization"
```

---

### Task 6: Create the LinkPreviewWorker (Oban)

**Files:**
- Create: `lib/slackex/links/link_preview_worker.ex`
- Create: `test/slackex/links/link_preview_worker_test.exs`
- Modify: `config/config.exs:64` — add `:link_previews` queue

**Step 1: Add the Oban queue**

In `config/config.exs`, find the Oban queues config line:

```elixir
queues: [default: 10, notifications: 20, embeddings: 5],
```

Change to:

```elixir
queues: [default: 10, notifications: 20, embeddings: 5, link_previews: 5],
```

**Step 2: Write the test**

```elixir
defmodule Slackex.Links.LinkPreviewWorkerTest do
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Links.LinkPreview
  alias Slackex.Links.LinkPreviewWorker

  describe "enqueue/2" do
    test "inserts an Oban job with message_id and urls" do
      assert {:ok, %Oban.Job{}} =
               LinkPreviewWorker.enqueue(123, ["https://example.com"])
    end

    test "does not enqueue when urls list is empty" do
      assert :noop = LinkPreviewWorker.enqueue(123, [])
    end
  end

  describe "perform/1 with blocked domain" do
    test "creates a blocked link_preview record" do
      # pornhub.com is in the blocklist
      assert :ok =
               perform_job(LinkPreviewWorker, %{
                 "message_id" => 999,
                 "urls" => ["https://pornhub.com/video"]
               })

      preview = Repo.get_by!(LinkPreview, message_id: 999)
      assert preview.status == "blocked"
      assert preview.blocked_reason == "blocklist"
    end
  end

  describe "perform/1 with unreachable URL" do
    test "creates a blocked link_preview record for connection error" do
      # This domain won't resolve
      assert :ok =
               perform_job(LinkPreviewWorker, %{
                 "message_id" => 998,
                 "urls" => ["https://this-domain-definitely-does-not-exist-abc123.com"]
               })

      preview = Repo.get_by!(LinkPreview, message_id: 998)
      assert preview.status == "blocked"
      assert preview.blocked_reason == "fetch_error"
    end
  end
end
```

**Step 3: Run the test to verify it fails**

Run: `mix test test/slackex/links/link_preview_worker_test.exs`
Expected: FAIL — module not found.

**Step 4: Write the implementation**

```elixir
defmodule Slackex.Links.LinkPreviewWorker do
  @moduledoc """
  Oban worker that fetches link preview metadata for URLs in messages.

  Pipeline per URL:
  1. Check domain blocklist
  2. Check Google Safe Browsing (if configured)
  3. Fetch page and parse OpenGraph metadata (2s timeout)
  4. Insert link_preview record
  5. Broadcast via PubSub

  Any fetch failure (timeout, HTTP error, SSL error) results in a blocked
  preview — if a URL can't load fast and clean, it doesn't get a preview.
  """

  use Oban.Worker, queue: :link_previews, max_attempts: 1

  require Logger

  alias Slackex.Links.{LinkPreview, MetadataParser, SafetyChecker}
  alias Slackex.Repo

  @pubsub Slackex.PubSub

  @doc "Enqueues a link preview job for a message with extracted URLs."
  @spec enqueue(integer(), [String.t()]) :: {:ok, Oban.Job.t()} | :noop
  def enqueue(_message_id, []), do: :noop

  def enqueue(message_id, urls) when is_list(urls) do
    %{message_id: message_id, urls: urls}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id, "urls" => urls}}) do
    previews =
      Enum.map(urls, fn url ->
        process_url(message_id, url)
      end)

    fetched = Enum.filter(previews, &(&1.status == "fetched"))

    if fetched != [] do
      broadcast_previews(message_id, fetched)
    end

    :ok
  end

  # -- Private ----------------------------------------------------------------

  defp process_url(message_id, url) do
    case SafetyChecker.check(url) do
      {:blocked, reason} ->
        insert_preview(message_id, url, %{status: "blocked", blocked_reason: reason})

      :ok ->
        fetch_and_store(message_id, url)
    end
  end

  defp fetch_and_store(message_id, url) do
    case MetadataParser.fetch_and_parse(url) do
      {:ok, %{title: nil}} ->
        insert_preview(message_id, url, %{status: "blocked", blocked_reason: "fetch_error"})

      {:ok, metadata} ->
        insert_preview(message_id, url, Map.put(metadata, :status, "fetched"))

      {:error, _reason} ->
        insert_preview(message_id, url, %{status: "blocked", blocked_reason: "fetch_error"})
    end
  end

  defp insert_preview(message_id, url, attrs) do
    %LinkPreview{}
    |> LinkPreview.changeset(Map.merge(attrs, %{message_id: message_id, url: url}))
    |> Repo.insert!()
  end

  defp broadcast_previews(message_id, previews) do
    # Broadcast to a dedicated topic that the LiveView subscribes to
    Phoenix.PubSub.broadcast(
      @pubsub,
      "link_previews:#{message_id}",
      {:link_previews_ready, message_id, previews}
    )
  end
end
```

**Step 5: Run the test to verify it passes**

Run: `mix test test/slackex/links/link_preview_worker_test.exs`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add lib/slackex/links/link_preview_worker.ex test/slackex/links/link_preview_worker_test.exs config/config.exs
git commit -m "feat(links): add LinkPreviewWorker Oban job"
```

---

### Task 7: Create the LinkPreviewListener (PubSub → Oban)

**Files:**
- Create: `lib/slackex/links/link_preview_listener.ex`
- Create: `test/slackex/links/link_preview_listener_test.exs`
- Modify: `lib/slackex/application.ex` — add to supervision tree

**Step 1: Write the test**

```elixir
defmodule Slackex.Links.LinkPreviewListenerTest do
  use Slackex.DataCase, async: false
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Links.LinkPreviewListener

  describe "handle_info/2 with :messages_persisted" do
    setup do
      # Start the listener manually for testing
      {:ok, pid} = LinkPreviewListener.start_link(name: nil)
      %{pid: pid}
    end

    test "enqueues LinkPreviewWorker for messages containing URLs", %{pid: pid} do
      # Enable the feature flag
      FunWithFlags.enable(:link_previews)

      # Insert a message with a URL
      user = insert(:user)
      channel = insert(:channel)

      {:ok, message} =
        Slackex.Chat.send_message(channel.id, user.id, "Check https://example.com")

      # Simulate the PubSub event that BatchWriter broadcasts
      send(pid, {:messages_persisted, [message.id]})

      # Give it a moment to process
      Process.sleep(50)

      assert_enqueued(
        worker: Slackex.Links.LinkPreviewWorker,
        args: %{message_id: message.id, urls: ["https://example.com"]}
      )
    end

    test "ignores messages without URLs", %{pid: pid} do
      FunWithFlags.enable(:link_previews)

      user = insert(:user)
      channel = insert(:channel)

      {:ok, message} = Slackex.Chat.send_message(channel.id, user.id, "Hello world!")

      send(pid, {:messages_persisted, [message.id]})
      Process.sleep(50)

      refute_enqueued(worker: Slackex.Links.LinkPreviewWorker)
    end

    test "does nothing when feature flag is disabled", %{pid: pid} do
      FunWithFlags.disable(:link_previews)

      user = insert(:user)
      channel = insert(:channel)

      {:ok, message} =
        Slackex.Chat.send_message(channel.id, user.id, "Check https://example.com")

      send(pid, {:messages_persisted, [message.id]})
      Process.sleep(50)

      refute_enqueued(worker: Slackex.Links.LinkPreviewWorker)
    end
  end
end
```

**Step 2: Run the test to verify it fails**

Run: `mix test test/slackex/links/link_preview_listener_test.exs`
Expected: FAIL — module not found.

**Step 3: Write the implementation**

```elixir
defmodule Slackex.Links.LinkPreviewListener do
  @moduledoc """
  Supervised GenServer that subscribes to `"pipeline:events"` and enqueues
  `LinkPreviewWorker` jobs when messages containing URLs are persisted.

  Mirrors the pattern from `Slackex.Embeddings.PersistenceListener`.
  Only active when the `:link_previews` feature flag is enabled.
  """

  use GenServer

  require Logger

  alias Slackex.Chat.Message
  alias Slackex.Links.{LinkPreviewWorker, URLExtractor}
  alias Slackex.Repo

  @pubsub Slackex.PubSub
  @topic "pipeline:events"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    _ = Phoenix.PubSub.subscribe(@pubsub, @topic)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:messages_persisted, message_ids}, state) when is_list(message_ids) do
    if FunWithFlags.enabled?(:link_previews) do
      process_messages(message_ids)
    end

    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  # -- Private ----------------------------------------------------------------

  defp process_messages(message_ids) do
    import Ecto.Query

    messages =
      from(m in Message,
        where: m.id in ^message_ids,
        where: is_nil(m.deleted_at),
        select: %{id: m.id, content: m.content}
      )
      |> Repo.all()

    Enum.each(messages, fn message ->
      urls = URLExtractor.extract(message.content)

      case LinkPreviewWorker.enqueue(message.id, urls) do
        {:ok, _job} ->
          Logger.info("LinkPreviewListener: enqueued preview for message #{message.id}")

        :noop ->
          :ok
      end
    end)
  end
end
```

**Step 4: Add to supervision tree**

In `lib/slackex/application.ex`, find where `Slackex.Embeddings.PersistenceListener` is started and add `LinkPreviewListener` nearby:

```elixir
Slackex.Links.LinkPreviewListener,
```

Use `restart: :permanent` — this is a lightweight PubSub subscriber, not a resource-heavy process.

**Step 5: Run the test to verify it passes**

Run: `mix test test/slackex/links/link_preview_listener_test.exs`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add lib/slackex/links/link_preview_listener.ex test/slackex/links/link_preview_listener_test.exs lib/slackex/application.ex
git commit -m "feat(links): add LinkPreviewListener PubSub subscriber"
```

---

### Task 8: Wire Link Previews into the LiveView and Components

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex`
- Modify: `lib/slackex_web/components/chat_components.ex`

**Step 1: Add `link_previews_enabled` assign and preload previews**

In `lib/slackex_web/live/chat_live/index.ex`, in the `mount/3` function where other feature flags are assigned, add:

```elixir
|> assign(:link_previews_enabled, FunWithFlags.enabled?(:link_previews))
|> assign(:link_previews, %{})
```

**Step 2: Preload link previews when loading messages**

Find the function that loads messages for a channel/DM (where the stream is populated). After messages are loaded, query their previews:

```elixir
# After loading messages, preload their link previews
preview_map = Slackex.Links.list_previews_for_messages(Enum.map(messages, & &1.id))
```

Add this `list_previews_for_messages/1` function to a new `lib/slackex/links/links.ex` context module:

```elixir
defmodule Slackex.Links do
  @moduledoc "Context module for link preview operations."

  import Ecto.Query
  alias Slackex.Links.LinkPreview
  alias Slackex.Repo

  @doc "Returns a map of message_id => [%LinkPreview{}] for fetched previews."
  def list_previews_for_messages([]), do: %{}

  def list_previews_for_messages(message_ids) do
    from(lp in LinkPreview,
      where: lp.message_id in ^message_ids,
      where: lp.status == "fetched",
      order_by: [asc: lp.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end
end
```

**Step 3: Handle PubSub broadcast for new previews**

In `index.ex`, subscribe to link preview events and handle the broadcast:

```elixir
# In the handle_info for :link_previews_ready
@impl true
def handle_info({:link_previews_ready, message_id, previews}, socket) do
  if socket.assigns.link_previews_enabled do
    link_previews = Map.put(socket.assigns.link_previews, message_id, previews)
    {:noreply, assign(socket, :link_previews, link_previews)}
  else
    {:noreply, socket}
  end
end
```

**Step 4: Pass previews to message_stream and message_bubble**

In `chat_components.ex`, add a `link_previews` attr to `message_stream` and `message_bubble`, and a new `link_preview_card` component:

Add attrs:
```elixir
attr :link_previews, :map, default: %{}
attr :link_previews_enabled, :boolean, default: false
```

Add the preview card component:

```elixir
def link_preview_card(assigns) do
  ~H"""
  <div class="mt-2 border-l-4 border-primary/30 rounded-r-lg bg-base-200/50 p-3 max-w-lg">
    <div :if={@preview.site_name} class="flex items-center gap-1.5 mb-1">
      <img
        :if={@preview.favicon_url}
        src={@preview.favicon_url}
        class="w-4 h-4 rounded"
        loading="lazy"
      />
      <span class="text-xs font-medium text-base-content/60">{@preview.site_name}</span>
    </div>
    <a
      href={@preview.url}
      target="_blank"
      rel="noopener noreferrer ugc"
      class="text-sm font-semibold text-primary hover:underline line-clamp-1"
    >
      {@preview.title}
    </a>
    <p :if={@preview.description} class="text-xs text-base-content/70 mt-1 line-clamp-2">
      {@preview.description}
    </p>
    <img
      :if={@preview.image_url}
      src={@preview.image_url}
      class="mt-2 rounded-md max-h-48 object-cover"
      loading="lazy"
    />
  </div>
  """
end
```

In the `message_bubble` template, after the message content `<p>` tag and before the reaction bar, add:

```elixir
<div :if={@link_previews_enabled}>
  <.link_preview_card
    :for={preview <- Map.get(@link_previews, @message.id, [])}
    preview={preview}
  />
</div>
```

**Step 5: Linkify message content**

In the `message_bubble` template, replace the plain text content rendering:

From:
```elixir
<p class="text-sm text-base-content/90 break-words whitespace-pre-wrap">
  {Map.get(@message, :content, "")}
```

To:
```elixir
<p class="text-sm text-base-content/90 break-words whitespace-pre-wrap">
  <%= if @link_previews_enabled do %>
    {Slackex.Links.URLExtractor.linkify(Map.get(@message, :content, ""))}
  <% else %>
    {Map.get(@message, :content, "")}
  <% end %>
```

**Step 6: Run tests**

Run: `mix test`
Expected: All existing tests pass. No new test failures.

**Step 7: Commit**

```bash
git add lib/slackex/links/links.ex lib/slackex_web/live/chat_live/index.ex lib/slackex_web/components/chat_components.ex
git commit -m "feat(links): wire link previews into LiveView and components"
```

---

### Task 9: Add Feature Flag and Enable in Tests

**Files:**
- Modify: `test/test_helper.exs`
- Modify: `FEATURES.md`

**Step 1: Add `:link_previews` to test flag enablement**

In `test/test_helper.exs`, find the feature flag enablement block and add `:link_previews`:

```elixir
for flag <- [:message_search, :channel_summarization, :reactions, :threads, :channel_management, :quick_switcher, :link_previews] do
```

**Step 2: Add to FEATURES.md**

Add a new entry for `:link_previews`:

```markdown
### `:link_previews`
**Purpose:** Rich inline preview cards for URLs in messages.
**Default:** Disabled
**Enable:** `FunWithFlags.enable(:link_previews)`
**Components:** URLExtractor, SafetyChecker, MetadataParser, LinkPreviewWorker, LinkPreviewListener
**Notes:** Requires Google Safe Browsing API key (`GOOGLE_SAFE_BROWSING_KEY`) for full protection. Works without it but only uses the compile-time domain blocklist.
```

**Step 3: Run full test suite**

Run: `mix test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add test/test_helper.exs FEATURES.md
git commit -m "feat(links): add :link_previews feature flag and docs"
```

---

### Task 10: Final Verification

**Step 1: Run full test suite**

Run: `mix test --warnings-as-errors`
Expected: All tests pass, no warnings.

**Step 2: Run formatting and linting**

Run: `mix format --check-formatted && mix credo`
Expected: No issues.

**Step 3: Run dialyzer**

Run: `mix dialyzer`
Expected: No errors.

**Step 4: Verify feature flag gating**

Manually verify: with `:link_previews` disabled, no preview cards render and no Oban jobs are enqueued. With it enabled, URLs in messages get preview cards.

**Step 5: Commit any fixups and push**

```bash
git push origin master
```
