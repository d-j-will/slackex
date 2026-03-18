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
    |> chat_preprocess()
    |> Earmark.as_html!(compact_output: true)
    |> HtmlSanitizeEx.Scrubber.scrub(Slackex.Markdown.Scrubber)
    |> add_link_attributes()
    |> Phoenix.HTML.raw()
  end

  # Chat users type single newlines, but markdown block elements need
  # blank lines before them. This inserts blank lines at block transitions
  # (e.g. paragraph → list, paragraph → heading) but NOT between items
  # of the same block type (e.g. consecutive list items or table rows).
  defp chat_preprocess(text) do
    text
    |> String.split("\n")
    |> insert_blank_lines([])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp block_type(""), do: :blank

  defp block_type(line) do
    cond do
      Regex.match?(~r/^\#{1,6}\s/, line) -> :heading
      Regex.match?(~r/^[-*+]\s/, line) -> :list
      Regex.match?(~r/^\d+\.\s/, line) -> :list
      Regex.match?(~r/^>\s?/, line) -> :blockquote
      Regex.match?(~r/^```/, line) -> :code_fence
      Regex.match?(~r/^(---+|\*\*\*+|___+)$/, line) -> :rule
      Regex.match?(~r/^\|.+\|$/, line) -> :table
      true -> :text
    end
  end

  defp insert_blank_lines([], acc), do: acc
  defp insert_blank_lines([line | rest], []), do: insert_blank_lines(rest, [line])

  defp insert_blank_lines([line | rest], [prev | _] = acc) do
    prev_type = block_type(prev)
    curr_type = block_type(line)

    needs_blank =
      prev_type != :blank and curr_type != :blank and
        prev_type != curr_type and
        (prev_type != :text or curr_type != :text)

    if needs_blank do
      insert_blank_lines(rest, [line, "" | acc])
    else
      insert_blank_lines(rest, [line | acc])
    end
  end

  defp add_link_attributes(html) do
    String.replace(html, "<a ", ~s(<a rel="noopener noreferrer" target="_blank" ))
  end
end
