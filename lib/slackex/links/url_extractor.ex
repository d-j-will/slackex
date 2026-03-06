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
  Non-URL text is HTML-escaped. Returns a Phoenix.HTML safe tuple.
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
          escaped = html_escape(url)

          ~s(<a href="#{escaped}" target="_blank" rel="noopener noreferrer ugc" class="link link-primary">#{escaped}</a>)
        else
          html_escape(part)
        end
      end)

    {:safe, Enum.join(parts)}
  end

  defp html_escape(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
