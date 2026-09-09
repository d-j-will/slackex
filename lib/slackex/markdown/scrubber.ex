defmodule Slackex.Markdown.Scrubber do
  @moduledoc """
  HTML sanitization scrubber for markdown-rendered content.

  Allowlists safe block and inline elements while stripping
  dangerous tags, attributes, and URI schemes.

  To modify allowed tags, edit the `allow_tag_with_*` declarations below.
  """

  require HtmlSanitizeEx.Scrubber.Meta
  alias HtmlSanitizeEx.Scrubber.Meta

  Meta.remove_cdata_sections_before_scrub()
  Meta.strip_comments()

  # Block elements
  Meta.allow_tag_with_these_attributes("p", [])
  Meta.allow_tag_with_these_attributes("h1", [])
  Meta.allow_tag_with_these_attributes("h2", [])
  Meta.allow_tag_with_these_attributes("h3", [])
  Meta.allow_tag_with_these_attributes("h4", [])
  Meta.allow_tag_with_these_attributes("h5", [])
  Meta.allow_tag_with_these_attributes("h6", [])
  Meta.allow_tag_with_these_attributes("blockquote", [])
  Meta.allow_tag_with_these_attributes("pre", ["class"])
  Meta.allow_tag_with_these_attributes("code", ["class"])
  Meta.allow_tag_with_these_attributes("hr", [])
  Meta.allow_tag_with_these_attributes("br", [])
  Meta.allow_tag_with_these_attributes("ul", [])
  Meta.allow_tag_with_these_attributes("ol", [])
  Meta.allow_tag_with_these_attributes("li", [])

  # Table elements
  Meta.allow_tag_with_these_attributes("table", [])
  Meta.allow_tag_with_these_attributes("thead", [])
  Meta.allow_tag_with_these_attributes("tbody", [])
  Meta.allow_tag_with_these_attributes("tr", [])
  Meta.allow_tag_with_these_attributes("th", [])
  Meta.allow_tag_with_these_attributes("td", [])

  # Inline elements
  Meta.allow_tag_with_these_attributes("strong", [])
  Meta.allow_tag_with_these_attributes("em", [])
  Meta.allow_tag_with_these_attributes("del", [])

  # Links -- only safe URI schemes
  Meta.allow_tag_with_uri_attributes("a", ["href"], ["https", "http", "mailto"])
  Meta.allow_tag_with_these_attributes("a", ["rel", "target"])

  # Default-deny: anything not allowed above is stripped.
  #
  # This was `Meta.strip_everything_not_covered()`, which html_sanitize_ex 1.5
  # deprecated with the message "You can just remove it." Removing it here would
  # be a security regression. That macro's entire body is registering
  # `@before_compile HtmlSanitizeEx.ScrubberCompiler`, and the compiler is what
  # generates the allowed-tag scrubs, `scrub_attributes/2`, and the catch-all
  # that drops every other tag. The deprecation assumes the modern
  # `use HtmlSanitizeEx` idiom, which registers the compiler itself; this module
  # calls `Meta` macros directly (the "legacy support" path the macro's own
  # private helper is named for), so dropping the line would leave the scrubber
  # with no default-deny. Registering the attribute is exactly what the macro
  # expanded to, minus the deprecation warning.
  @before_compile HtmlSanitizeEx.ScrubberCompiler
end
