# Phase 4 Remaining Criteria: Search Highlighting & Scroll-to-Message

**Research Date:** 2026-03-04
**Researcher:** Nova (nw-researcher)
**Status:** Complete
**Confidence:** High (3+ sources per major claim)

## Executive Summary

This document covers the two remaining Phase 4 acceptance criteria:

1. **Search UI shows results with highlighted matches** -- Use PostgreSQL `ts_headline()` for FTS snippets, server-side allowlist sanitization for XSS safety, and a contextual snippet approach for semantic results.
2. **"Jump to message" navigates to the correct channel and scrolls to the message** -- Use `push_event/3` to trigger a JS hook after loading messages around the target ID, with a `UNION ALL` bidirectional query pattern.

Both features are well-supported by Phoenix LiveView primitives and PostgreSQL built-ins. No new dependencies are required (HtmlSanitizeEx is optional; a Regex-based strip is sufficient given the controlled `ts_headline` output).

---

## Topic 1: Search Result Match Highlighting

### 1.1 PostgreSQL `ts_headline()` for FTS Snippets

**Confidence: High (4 sources)**

PostgreSQL provides a built-in `ts_headline()` function that generates text excerpts with matching terms wrapped in configurable HTML tags.

**Function signature:**
```sql
ts_headline([ config regconfig, ] document text, query tsquery [, options text ]) returns text
```

**Key options (all sourced from PostgreSQL 18 docs):**

| Option | Default | Purpose |
|--------|---------|---------|
| `StartSel` | `<b>` | Opening tag for matched terms |
| `StopSel` | `</b>` | Closing tag for matched terms |
| `MaxWords` | 35 | Maximum words in the excerpt |
| `MinWords` | 15 | Minimum words in the excerpt |
| `MaxFragments` | 0 | Number of fragments (0 = single excerpt) |
| `FragmentDelimiter` | ` ... ` | Separator between multiple fragments |
| `ShortWord` | 3 | Words this length or shorter dropped from excerpt edges |
| `HighlightAll` | false | If true, uses whole document (ignores word limits) |

**Recommended configuration for this codebase:**
```sql
ts_headline(
  'english',
  search_content,
  plainto_tsquery('english', $query),
  'StartSel=<mark>, StopSel=</mark>, MaxWords=40, MinWords=15, MaxFragments=1, FragmentDelimiter= ... '
)
```

Using `<mark>` instead of `<b>` is semantically correct for search highlighting and maps to a standard HTML element that can be styled with CSS (`mark { background: yellow; }`).

**Sources:**
- [PostgreSQL 18 Documentation: 12.3 Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html) -- canonical reference for `ts_headline` function, parameters, and behavior
- [Peter Ullrich: Complete Guide to Full-Text Search with Postgres and Ecto](https://peterullrich.com/complete-guide-to-full-text-search-with-postgres-and-ecto) -- Ecto fragment examples with `ts_headline`
- [Ruheni: Highlighting Results from a Full-Text Search Query with PostgreSQL](https://ruheni.dev/writing/fts-highlighting-search-results/) -- practical examples with custom StartSel/StopSel
- [Sling Academy: PostgreSQL Full-Text Search Using headline](https://www.slingacademy.com/article/postgresql-full-text-search-using-headline-for-search-result-highlights/) -- additional examples

### 1.2 Ecto Integration: `ts_headline` via Fragment

**Confidence: High (3 sources)**

The `ts_headline` call is added to the existing `build_search_query/3` via `select_merge` with a `fragment/1`, avoiding any schema changes. The headline becomes a virtual field on the returned Message struct.

**Pattern for this codebase:**
```elixir
# In MessageSearch.build_search_query/3, add to the existing query:
from(m in Message,
  where: ...,
  order_by: ...,
  select_merge: %{
    headline: fragment(
      """
      ts_headline(
        'english',
        coalesce(?, ''),
        plainto_tsquery('english', ?),
        'StartSel=<mark>, StopSel=</mark>, MaxWords=40, MinWords=15'
      )
      """,
      m.search_content,
      ^query
    )
  },
  ...
)
```

This requires adding a virtual field to the Message schema:
```elixir
field :headline, :string, virtual: true
```

**Critical note:** `ts_headline` operates on the original document text, not the tsvector. It re-parses the document for every row. PostgreSQL docs explicitly warn it "can be slow and should be used with care." Since the search query already limits results to 20 rows (the `@default_limit`), the performance impact is bounded and acceptable.

**Why `search_content`, not `content`:** The `content` field is stored as AES-GCM ciphertext (`encrypted_content` column). The `search_content` column is the plaintext companion specifically designed for FTS operations. `ts_headline` must operate on `search_content`.

**Sources:**
- [Peter Ullrich: Complete Guide to Full-Text Search with Postgres and Ecto](https://peterullrich.com/complete-guide-to-full-text-search-with-postgres-and-ecto) -- Ecto fragment pattern for ts_headline
- [Brightball: PostgreSQL Functions with Elixir Ecto Queries](https://www.brightball.com/articles/postgresql-functions-with-elixir-ecto) -- general Ecto fragment patterns with PostgreSQL functions
- [PostgreSQL 18 Documentation: 12.3 Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html) -- performance warning and functional behavior

### 1.3 XSS Safety: Sanitizing `ts_headline` Output

**Confidence: High (4 sources)**

The PostgreSQL documentation contains an explicit security warning:

> "The output from `ts_headline` is not guaranteed to be safe for direct inclusion in web pages. When `HighlightAll` is false (default), only simple XML tags are removed. This does not provide effective defense against XSS attacks with untrusted input."

Since message content is user-generated, the `ts_headline` output must be sanitized before rendering with `Phoenix.HTML.raw/1`.

**Three approaches, in order of recommendation:**

#### Approach A: Server-side strip-and-allow (Recommended)

Replace all HTML except `<mark>` and `</mark>` before sending to the template. This is the safest approach because it operates on a controlled allowlist.

```elixir
defp sanitize_headline(nil), do: nil
defp sanitize_headline(headline) do
  # 1. Escape all HTML entities in the full string
  escaped = Phoenix.HTML.html_escape(headline) |> Phoenix.HTML.safe_to_string()
  # 2. Restore only the <mark> tags that ts_headline inserted
  escaped
  |> String.replace("&lt;mark&gt;", "<mark>")
  |> String.replace("&lt;/mark&gt;", "</mark>")
end
```

Then in the template:
```heex
<p class="text-sm text-base-content/80 mt-0.5">
  {Phoenix.HTML.raw(sanitize_headline(result.headline))}
</p>
```

This works because:
1. `Phoenix.HTML.html_escape/1` escapes ALL HTML including any injected tags
2. We then restore only the exact `<mark>` and `</mark>` strings
3. Any malicious content like `<script>` remains escaped as `&lt;script&gt;`

#### Approach B: HtmlSanitizeEx with custom scrubber

If more complex HTML sanitization is needed in the future, use the `html_sanitize_ex` library with a custom scrubber that allows only `<mark>`:

```elixir
defmodule Slackex.Search.MarkScrubber do
  require HtmlSanitizeEx.Scrubber.Meta
  alias HtmlSanitizeEx.Scrubber.Meta

  Meta.remove_cdata_sections_before_scrub()
  Meta.strip_comments()
  Meta.allow_tag_with_these_attributes("mark", [])
  Meta.strip_everything_not_covered()
end
```

Usage: `HtmlSanitizeEx.Scrubber.scrub(headline, Slackex.Search.MarkScrubber)`

This adds a dependency. Not recommended unless the codebase already uses HtmlSanitizeEx or needs broader HTML sanitization.

#### Approach C: Use non-HTML delimiters

Avoid HTML in `ts_headline` output entirely by using non-HTML delimiters, then replace them in Elixir:

```sql
ts_headline('english', search_content, query,
  'StartSel=[[MARK]], StopSel=[[/MARK]]')
```

```elixir
headline
|> Phoenix.HTML.html_escape()
|> Phoenix.HTML.safe_to_string()
|> String.replace("[[MARK]]", "<mark>")
|> String.replace("[[/MARK]]", "</mark>")
```

This eliminates any risk of delimiter collision with user content. The tradeoff is slightly more unusual SQL output.

**Recommendation:** Approach A for simplicity with strong security. Approach C if the team prefers defense-in-depth against edge cases where user content literally contains the string `<mark>`.

**Sources:**
- [PostgreSQL 18 Documentation: 12.3 Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html) -- explicit XSS warning for ts_headline
- [Phoenix.HTML v4.3.0 Documentation](https://hexdocs.pm/phoenix_html/Phoenix.HTML.html) -- `raw/1` function, safety implications
- [HtmlSanitizeEx on GitHub](https://github.com/rrrene/html_sanitize_ex) -- custom scrubber pattern
- [Writing Custom Sanitization Rules with HtmlSanitizeEx](https://katafrakt.me/2016/09/03/custom-rules-in-htmlsanitizeex/) -- custom scrubber module pattern

### 1.4 Highlighting Semantic Search Results

**Confidence: Medium (2 sources + analysis)**

Semantic search finds messages by vector similarity, not keyword matching. There are no specific terms to highlight in the traditional FTS sense. This is an inherent limitation of embedding-based search.

**Three practical approaches:**

#### Approach 1: Use `ts_headline` opportunistically (Recommended)

Even though the match was semantic, the query text often shares words with the result. Apply `ts_headline` to semantic results as a best-effort highlight:

```elixir
# In build_semantic_query, add:
select_merge: %{
  headline: fragment(
    """
    ts_headline(
      'english',
      coalesce(?, ''),
      plainto_tsquery('english', ?),
      'StartSel=<mark>, StopSel=</mark>, MaxWords=40, MinWords=15, HighlightAll=true'
    )
    """,
    m.search_content,
    ^original_query_text
  )
}
```

Using `HighlightAll=true` returns the full content with any matching words highlighted. When no words match, the content is returned without highlights -- which is the correct behavior for pure semantic matches.

**Tradeoff:** Adds `ts_headline` processing overhead to semantic results. Bounded by the result limit (20 rows).

#### Approach 2: Client-side text matching

Pass the query terms to the template and use a helper to wrap exact substring matches:

```elixir
defp highlight_terms(content, query) do
  terms = query |> String.split(~r/\s+/) |> Enum.reject(&(String.length(&1) < 3))

  Enum.reduce(terms, Phoenix.HTML.html_escape(content) |> safe_to_string(), fn term, acc ->
    escaped_term = Regex.escape(term)
    String.replace(acc, ~r/#{escaped_term}/i, "<mark>\\0</mark>")
  end)
end
```

**Tradeoff:** Does not benefit from PostgreSQL's stemming (e.g., "running" won't match "run"). Simpler but less linguistically accurate.

#### Approach 3: No highlighting for semantic results

Display semantic results with the similarity score badge instead of text highlighting. The score itself communicates relevance:

```heex
<span class="badge badge-sm badge-info">{Float.round(result.similarity * 100, 0)}% match</span>
```

**Recommendation:** Approach 1 (opportunistic `ts_headline`) for hybrid search (which is the default mode). The hybrid RRF merge already combines FTS and semantic results, so applying `ts_headline` to all results is natural. For pure semantic mode, fall back to Approach 3 (similarity badge, no highlighting) since the query may have no lexical overlap with results.

**Sources:**
- [PostgreSQL 18 Documentation: 12.3 Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html) -- `HighlightAll` option behavior
- [Peter Ullrich: Complete Guide to Full-Text Search with Postgres and Ecto](https://peterullrich.com/complete-guide-to-full-text-search-with-postgres-and-ecto) -- general pattern

**Knowledge gap:** No authoritative source was found on best practices for highlighting semantic/embedding search results specifically. This is an open UX problem in the industry. Most production systems (Notion AI, ChatGPT search, Perplexity) show semantic results without per-word highlighting, relying on relevance scores and snippet context instead.

### 1.5 Rendering Highlighted Content in LiveView Templates

**Confidence: High (3 sources)**

The current template renders message content with automatic escaping:
```heex
<p class="text-sm text-base-content/80 truncate mt-0.5">
  {Map.get(result, :content, "")}
</p>
```

To render highlighted snippets, the template must use `Phoenix.HTML.raw/1` on the pre-sanitized headline:

```heex
<p class="text-sm text-base-content/80 mt-0.5">
  <%= if result.headline do %>
    {Phoenix.HTML.raw(sanitize_headline(result.headline))}
  <% else %>
    <span class="truncate">{Map.get(result, :content, "")}</span>
  <% end %>
</p>
```

**Important:** Remove the `truncate` class when displaying headlines. The `ts_headline` excerpt is already bounded by `MaxWords` and truncating it could cut off closing `</mark>` tags, producing broken HTML.

**CSS for `<mark>` styling:**
```css
/* In app.css or a component style */
mark {
  background-color: oklch(var(--wa) / 0.3); /* DaisyUI warning color at 30% opacity */
  border-radius: 2px;
  padding: 0 2px;
}
```

**Sources:**
- [Phoenix.HTML v4.3.0 Documentation](https://hexdocs.pm/phoenix_html/Phoenix.HTML.html) -- `raw/1` bypasses auto-escaping
- [HEEx Basics: Adopt LiveView](https://adopt-liveview.lubien.dev/guides/basics-of-heex/en) -- HEEx auto-escaping behavior
- [Phoenix.HTML.Safe Protocol](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Safe.html) -- Safe protocol contract

---

## Topic 2: Scroll-to-Message After Jump Navigation

### 2.1 Current State Analysis

The existing `jump_to_message` flow:

1. `SearchComponent` sends `{:jump_to_message, message_id, channel_id, dm_id}` to parent
2. Parent `handle_info` closes search panel, calls `push_patch/2` to the channel/DM URL
3. `handle_params/3` fires, calling `enter_channel/4` or `enter_dm/2`
4. These functions call `fetch_initial_messages/2` which loads the most recent N messages
5. Stream resets with `stream(:messages, messages, reset: true)`

**Problem:** The target message may not be in the most recent N messages. Even if it is, no scroll command is issued. The user lands at the bottom of the conversation with no visual indication of the target message.

### 2.2 The "Load Messages Around" Pattern

**Confidence: High (3 sources)**

Chat applications universally implement a "load around" query pattern: given a target message ID, load N messages before it, the message itself, and N messages after it. This centers the viewport on the target.

**PostgreSQL query pattern using UNION ALL:**

```sql
-- Messages before the target (older), ordered ascending
(SELECT * FROM messages WHERE channel_id = $1 AND id < $target_id
 ORDER BY id DESC LIMIT $half_page)
UNION ALL
-- The target message itself
(SELECT * FROM messages WHERE channel_id = $1 AND id = $target_id)
UNION ALL
-- Messages after the target (newer), ordered ascending
(SELECT * FROM messages WHERE channel_id = $1 AND id > $target_id
 ORDER BY id ASC LIMIT $half_page)
ORDER BY id ASC
```

**Ecto implementation pattern:**

```elixir
def list_messages_around(conversation_target, message_id, opts \\ []) do
  half_page = div(Keyword.get(opts, :limit, 50), 2)

  before_query =
    base_query(conversation_target)
    |> where([m], m.id < ^message_id)
    |> order_by([m], desc: m.id)
    |> limit(^half_page)

  after_query =
    base_query(conversation_target)
    |> where([m], m.id > ^message_id)
    |> order_by([m], asc: m.id)
    |> limit(^half_page)

  target_query =
    base_query(conversation_target)
    |> where([m], m.id == ^message_id)

  # Combine and re-order
  before_query
  |> union_all(^target_query)
  |> union_all(^after_query)
  |> subquery()
  |> order_by([m], asc: m.id)
  |> preload([:sender])
  |> Repo.all()
end
```

**Why Snowflake IDs make this clean:** Snowflake IDs embed timestamps and are monotonically increasing. Ordering by `id` is equivalent to ordering by `inserted_at`, which means the `id < target_id` / `id > target_id` comparisons naturally give us chronological before/after without needing a composite sort. The existing `oldest_message_id` pattern in the codebase already relies on this property.

**Partition considerations:** The messages table is partitioned. The `union_all` approach issues three separate index scans, each on a potentially different partition. This is actually better than a single range query because each sub-query can prune to the relevant partition independently.

**Sources:**
- [Ecto.Query Documentation: union_all/2](https://hexdocs.pm/ecto/Ecto.Query.html) -- union_all and subquery wrapping pattern
- [Chat Pagination with Infinite Scrolling (Vonage)](https://developer.vonage.com/en/blog/chat-pagination-with-infinite-scrolling-dr) -- "load around" pattern in chat applications
- [How Chat Apps Scroll to Messages Not in the DOM](https://medium.com/@chandrasekhar_82606/how-chat-apps-scroll-to-messages-not-in-the-dom-lazy-load-smooth-scroll-part-2-28663427e6c5) -- lazy load + scroll-to pattern

### 2.3 Integration with HistoryLoader

**Confidence: High (codebase analysis + 2 sources)**

The `HistoryLoader` module currently provides `recent/2` and `before/3`. A new `around/3` function fits naturally:

```elixir
# In Slackex.Search.HistoryLoader
@spec around(Cache.target(), integer(), pos_integer()) :: {:ok, list()}
def around(target, message_id, limit \\ 50) do
  messages = fetch_around_from_db(target, message_id, limit)
  {:ok, messages}
end
```

This bypasses the cache intentionally -- "load around" is a navigation operation, not a hot-path read. The cache stores only the most recent messages.

**Where this is called:** The `enter_channel/4` and `enter_dm/2` functions in `index.ex` need a variant that accepts an optional `target_message_id`. When present, they call `HistoryLoader.around/3` instead of `fetch_initial_messages/2`.

### 2.4 Server-Side: Coordinating Stream Reset with Scroll Event

**Confidence: High (3 sources)**

After loading messages around the target, the server must:
1. Reset the stream with the new message set
2. Push a client event to scroll to the target message

Phoenix LiveView's `push_event/3` is the correct mechanism for server-to-client communication outside the normal DOM diff cycle.

**Implementation pattern:**

```elixir
# In the parent LiveView (index.ex)
def handle_info({:jump_to_message, message_id, channel_id, nil}, socket)
    when is_integer(channel_id) do
  channel = Chat.get_channel!(channel_id)

  {:noreply,
   socket
   |> assign(:search_open, false)
   |> assign(:scroll_target, message_id)
   |> push_patch(to: ~p"/chat/#{channel.slug}?target=#{message_id}")}
end
```

Then in `handle_params`:
```elixir
def handle_params(%{"slug" => slug, "target" => target_id}, _uri, socket) do
  # ... authorize channel ...
  # Load messages around target
  messages = HistoryLoader.around({:channel, channel.id}, target_id)

  socket
  |> assign_conversation_state(messages)
  |> push_event("scroll_to_message", %{id: "messages-#{target_id}"})
  |> then(&{:noreply, &1})
end
```

**Why `push_event` not `phx-mounted`:** The `phx-mounted` binding executes a JS command when an element is added to the DOM. While it could work (add `phx-mounted={JS.dispatch("scroll-to-me")}` to the target message), it has a problem: on a stream reset, ALL messages are "mounted," making it hard to distinguish the scroll target. `push_event` is explicit and carries the target ID as payload.

**Sources:**
- [Phoenix LiveView JS Interoperability Guide](https://hexdocs.pm/phoenix_live_view/js-interop.html) -- `push_event/3` and `handleEvent` pattern
- [Phoenix.LiveView Documentation](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html) -- `push_event/3` signature and dispatch timing
- [Phoenix LiveView Bindings Guide](https://hexdocs.pm/phoenix_live_view/bindings.html) -- `phx-mounted` binding description

### 2.5 Client-Side: JS Hook for Scroll-to-Message

**Confidence: High (3 sources)**

The scroll behavior is handled by a JS hook on the message list container. Two approaches:

#### Approach A: handleEvent in existing MessageList hook (Recommended)

Extend the existing `MessageList` hook to handle a `scroll_to_message` event:

```javascript
const MessageList = {
  mounted() {
    this.scrollToBottom();
    this.pending = false;

    this.el.addEventListener("scroll", () => {
      if (this.el.scrollTop < 100 && !this.pending) {
        this.pending = true;
        this.pushEvent("load_more", {});
      }
    });

    // Handle scroll-to-message events from the server
    this.handleEvent("scroll_to_message", ({ id }) => {
      // Use requestAnimationFrame to ensure DOM has been patched
      requestAnimationFrame(() => {
        const target = document.getElementById(id);
        if (target) {
          target.scrollIntoView({ behavior: "smooth", block: "center" });
          // Add temporary highlight
          target.classList.add("highlight-flash");
          setTimeout(() => target.classList.remove("highlight-flash"), 2000);
        }
      });
    });
  },

  updated() {
    this.pending = false;
    if (this.isAtBottom()) {
      this.scrollToBottom();
    }
  },

  // ... existing methods ...
};
```

#### Approach B: Window event listener (Alternative)

If the hook approach has timing issues (the hook's `handleEvent` only works while the hook element is connected), use a window-level listener:

```javascript
// In app.js
window.addEventListener("phx:scroll_to_message", (e) => {
  requestAnimationFrame(() => {
    const target = document.getElementById(e.detail.id);
    if (target) {
      target.scrollIntoView({ behavior: "smooth", block: "center" });
      target.classList.add("highlight-flash");
      setTimeout(() => target.classList.remove("highlight-flash"), 2000);
    }
  });
});
```

Window-level listeners receive ALL `push_event` calls prefixed with `phx:`. This is simpler but less scoped.

**Recommendation:** Approach A (extend existing hook). The `MessageList` hook is already mounted on the message container and manages scroll behavior. Adding `handleEvent` there keeps scroll logic cohesive.

**Timing consideration:** `push_event` fires after the DOM patch by default. Wrapping in `requestAnimationFrame` adds one additional frame to ensure the browser has painted the new elements. This is a standard pattern for scroll-after-render.

**Sources:**
- [Phoenix LiveView JS Interoperability Guide](https://hexdocs.pm/phoenix_live_view/js-interop.html) -- `handleEvent` in hooks, window event listener pattern
- [DockYard: Implementing a Client Hook in LiveView](https://dockyard.com/blog/2025/03/11/implementing-a-client-hook-in-liveview) -- hook lifecycle and event handling
- [Phoenix LiveView Bindings Guide](https://hexdocs.pm/phoenix_live_view/bindings.html) -- `phx-mounted` binding as alternative

### 2.6 DOM ID Strategy for Message Elements

**Confidence: High (codebase analysis)**

The current stream renders messages with auto-generated DOM IDs from Phoenix streams:
```heex
<div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
```

Phoenix streams generate IDs like `messages-#{message.id}`. The scroll target ID must match this convention. Since Snowflake IDs are integers, the target DOM ID is predictable: `"messages-#{message_id}"`.

**Verification:** The `push_event` payload should use the same ID format:
```elixir
push_event(socket, "scroll_to_message", %{id: "messages-#{target_id}"})
```

### 2.7 Visual Highlight After Scroll

**Confidence: Medium (2 sources + standard practice)**

After scrolling to the target message, a temporary visual highlight helps the user identify it. This is standard UX in Slack, Discord, and GitHub.

**CSS animation approach:**
```css
@keyframes highlight-flash {
  0% { background-color: oklch(var(--wa) / 0.3); }
  100% { background-color: transparent; }
}

.highlight-flash {
  animation: highlight-flash 2s ease-out;
}
```

The JS hook adds `highlight-flash` class after scrolling, and the CSS animation automatically fades out. No cleanup timer needed because CSS animations are one-shot by default.

**Alternative: Tailwind animation:**
```css
.highlight-flash {
  @apply animate-pulse bg-warning/20;
  animation-duration: 2s;
  animation-iteration-count: 1;
}
```

**Sources:**
- [Top Ten Ways to Use Tailwind CSS Animations with Phoenix LiveView](https://medium.com/@hexshift/top-ten-ways-to-use-tailwind-css-animations-with-phoenix-liveview-b98281161139) -- Tailwind animation patterns with LiveView
- [Phoenix LiveView Bindings Guide](https://hexdocs.pm/phoenix_live_view/bindings.html) -- `phx-mounted` with `JS.transition` for mount animations

### 2.8 Handling Continued Pagination After Jump

**Confidence: Medium (2 sources + codebase analysis)**

After jumping to a message and loading the "around" window, the user may scroll up (load older) or down (load newer). The existing `load_more` event only loads older messages (upward scroll). Two gaps:

1. **`oldest_message_id` must be set correctly:** After `list_messages_around`, set `oldest_message_id` to the first message in the returned set (the oldest). The existing `assign_conversation_state/2` already does this via `oldest_message_id/1`.

2. **Loading newer messages (downward scroll):** If the user jumped to an old message, the "around" window may not extend to the present. Scrolling down should load newer messages. This requires:
   - A `newest_message_id` assign (or checking if the last message in the stream is the most recent)
   - A `phx-viewport-bottom` event or equivalent to trigger `load_newer`
   - A `list_messages_after(conversation_target, after_id, limit)` function

**Recommendation for initial implementation:** Skip downward pagination for now. The "around" window loads 50 messages (25 before + target + 25 after). This covers most "jump to recent search result" cases. Downward pagination can be added as a follow-up enhancement. The acceptance criteria only requires "navigates to the correct channel and scrolls to the message."

**Sources:**
- [Yellow Duck: Scroll Events and Infinite Pagination in Phoenix LiveView](https://www.yellowduck.be/posts/scroll-events-and-infinite-pagination-in-phoenix-liveview) -- bidirectional scroll with phx-viewport-top/bottom
- [Phoenix LiveView Bindings Guide](https://hexdocs.pm/phoenix_live_view/bindings.html) -- viewport event bindings

### 2.9 URL Query Parameter for Deep Linking

**Confidence: Medium (codebase analysis + 1 source)**

Passing the target message ID as a query parameter (`?target=123`) in the `push_patch` URL enables:
1. `handle_params` to detect when to load "around" vs "recent"
2. Deep-linkable URLs (share a link that jumps to a specific message)
3. Back-button support (browser history preserves the target)

```elixir
# Jump with target
push_patch(to: ~p"/chat/#{channel.slug}?target=#{message_id}")

# handle_params dispatches based on presence of "target"
def handle_params(%{"slug" => slug, "target" => target_id}, _uri, socket) do
  # Load around target
end

def handle_params(%{"slug" => slug}, _uri, socket) do
  # Load recent (existing behavior)
end
```

**Source:**
- [Phoenix LiveView Live Navigation Guide](https://hexdocs.pm/phoenix_live_view/live-navigation.html) -- push_patch preserves LiveView process, triggers handle_params

---

## Codebase-Specific Recommendations

### Recommendation 1: Add Virtual Fields to Message Schema

```elixir
# In lib/slackex/chat/message.ex
field :headline, :string, virtual: true   # ts_headline output
```

The `similarity` and `search_score` virtual fields already exist. Adding `headline` follows the same pattern.

### Recommendation 2: Modify MessageSearch to Return Headlines

Add `ts_headline` to `build_search_query/3` via `select_merge`. For `build_semantic_query/3`, pass the original query text through opts for opportunistic highlighting.

For hybrid search, the `merge_with_rrf/4` function should preserve the `headline` field from whichever source provided it (prefer the FTS result's headline since it will be more accurate).

### Recommendation 3: Add `list_messages_around` to Chat Context

Place the bidirectional query in `Slackex.Chat` alongside `list_messages/2` and `list_dm_messages/2`. Expose via `HistoryLoader.around/3` following the existing delegation pattern.

### Recommendation 4: Extend `handle_params` with Target Support

Add a new `handle_params` clause matching `%{"slug" => slug, "target" => target_id}` that loads messages around the target and pushes the scroll event. Keep existing clauses unchanged.

### Recommendation 5: Extend MessageList Hook, Not Create New One

The `MessageList` hook already manages scroll state for the message container. Adding `handleEvent("scroll_to_message", ...)` inside its `mounted()` callback keeps all scroll logic in one place.

---

## Knowledge Gaps

1. **No authoritative source for semantic search result highlighting best practices.** The industry has not converged on a standard approach. Most production systems avoid per-word highlighting for semantic results.

2. **`ts_headline` with partitioned tables.** No documentation was found confirming or denying any partition-specific behavior of `ts_headline`. Since it operates on the `text` value passed to it (not the table directly), partitioning should be transparent. However, this should be verified with an EXPLAIN ANALYZE test.

3. **LiveView stream reset + push_event ordering guarantee.** The documentation states push_event fires "after" the DOM patch, but does not specify whether this means after the browser has painted the new DOM. The `requestAnimationFrame` wrapper in the JS hook is a defensive measure against this ambiguity.

4. **Downward pagination after jump.** The existing codebase only supports upward scroll pagination. A complete "jump to message" experience would benefit from bidirectional pagination (phx-viewport-top + phx-viewport-bottom), but this is beyond the minimum acceptance criteria.

---

## Implementation Order

1. **Add `headline` virtual field** to `Message` schema
2. **Add `ts_headline` fragment** to `build_search_query` in `MessageSearch`
3. **Add `sanitize_headline/1`** helper in `SearchComponent`
4. **Update search result template** to render highlighted headline
5. **Add `list_messages_around`** to `Chat` context
6. **Add `around/3`** to `HistoryLoader`
7. **Add target query param** to `push_patch` in `jump_to_message` handlers
8. **Add `handle_params` clause** for target-based navigation
9. **Extend `MessageList` JS hook** with `handleEvent("scroll_to_message")`
10. **Add highlight-flash CSS** animation
11. **Write tests** for headline generation, sanitization, around-query, and scroll event

---

## Sources Summary

### PostgreSQL Documentation
- [12.3 Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html)

### Phoenix LiveView Documentation
- [JS Interoperability Guide](https://hexdocs.pm/phoenix_live_view/js-interop.html)
- [Phoenix.LiveView Module](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)
- [Phoenix.LiveView.JS Module](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.JS.html)
- [Bindings Guide](https://hexdocs.pm/phoenix_live_view/bindings.html)
- [Live Navigation Guide](https://hexdocs.pm/phoenix_live_view/live-navigation.html)

### Phoenix.HTML Documentation
- [Phoenix.HTML v4.3.0](https://hexdocs.pm/phoenix_html/Phoenix.HTML.html)
- [Phoenix.HTML.Safe Protocol](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Safe.html)

### Ecto Documentation
- [Ecto.Query - union_all/2](https://hexdocs.pm/ecto/Ecto.Query.html)

### Community Resources
- [Peter Ullrich: Complete Guide to Full-Text Search with Postgres and Ecto](https://peterullrich.com/complete-guide-to-full-text-search-with-postgres-and-ecto)
- [Brightball: PostgreSQL Functions with Elixir Ecto Queries](https://www.brightball.com/articles/postgresql-functions-with-elixir-ecto)
- [Ruheni: Highlighting Results from a Full-Text Search Query](https://ruheni.dev/writing/fts-highlighting-search-results/)
- [Yellow Duck: Scroll Events and Infinite Pagination in Phoenix LiveView](https://www.yellowduck.be/posts/scroll-events-and-infinite-pagination-in-phoenix-liveview)
- [DockYard: Implementing a Client Hook in LiveView](https://dockyard.com/blog/2025/03/11/implementing-a-client-hook-in-liveview)
- [HtmlSanitizeEx on GitHub](https://github.com/rrrene/html_sanitize_ex)
- [Custom Sanitization Rules with HtmlSanitizeEx](https://katafrakt.me/2016/09/03/custom-rules-in-htmlsanitizeex/)
- [Chat Pagination with Infinite Scrolling (Vonage)](https://developer.vonage.com/en/blog/chat-pagination-with-infinite-scrolling-dr)
- [How Chat Apps Scroll to Messages Not in the DOM](https://medium.com/@chandrasekhar_82606/how-chat-apps-scroll-to-messages-not-in-the-dom-lazy-load-smooth-scroll-part-2-28663427e6c5)
