defmodule Slackex.Markdown do
  @moduledoc """
  Converts markdown strings to sanitized HTML safe for rendering.

  Uses Earmark for parsing and a custom scrubber for XSS prevention.
  Returns `{:safe, html}` tuples for direct use in HEEx templates.

  ## Usage

      {Slackex.Markdown.to_html(@content)}
  """

  @doc """
  Converts a markdown string to sanitized HTML.

  Returns a Phoenix.HTML safe tuple `{:safe, html}` that can be
  directly interpolated in HEEx templates.
  """
  def to_html(nil), do: {:safe, ""}
  def to_html(""), do: {:safe, ""}

  def to_html(markdown) when is_binary(markdown) do
    markdown
    |> Earmark.as_html!(compact_output: true)
    |> HtmlSanitizeEx.Scrubber.scrub(Slackex.Markdown.Scrubber)
    |> add_link_attributes()
    |> Phoenix.HTML.raw()
  end

  defp add_link_attributes(html) do
    String.replace(html, "<a ", ~s(<a rel="noopener noreferrer" target="_blank" ))
  end
end
