defmodule Slackex.Links.MetadataParser do
  @moduledoc """
  Fetches a URL and extracts OpenGraph metadata for link previews.
  Sanitizes all extracted text (strips HTML, truncates, validates UTF-8).
  """

  require Logger

  @fetch_timeout 2_000

  @doc """
  Fetches a URL and returns parsed metadata.
  Returns `{:ok, metadata_map}` or `{:error, reason}`.
  """
  @spec fetch_and_parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch_and_parse(url) do
    extra_opts = Application.get_env(:slackex, :metadata_parser_req_options, [])

    case Req.get(
           url,
           [
             receive_timeout: @fetch_timeout,
             connect_options: [timeout: @fetch_timeout],
             max_redirects: 3,
             decode_body: false
           ] ++ extra_opts
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, parse_html(body, url)}

      {:ok, %{status: status}} ->
        Logger.warning("MetadataParser: HTTP #{status} for #{url}")
        {:error, "http_#{status}"}

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

  defp og_content(doc, property, opts \\ []) do
    case Floki.find(doc, "meta[property='#{property}']") do
      [{_, attrs, _} | _] ->
        value = attr_value(attrs, "content")

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
      [{_, _, _} | _] = nodes ->
        nodes |> hd() |> Floki.text() |> sanitize_text()

      _ ->
        nil
    end
  end

  defp extract_favicon(doc, base_url) do
    selectors = [
      "link[rel='icon']",
      "link[rel='shortcut icon']"
    ]

    Enum.find_value(selectors, fn selector ->
      case Floki.find(doc, selector) do
        [{_, attrs, _} | _] ->
          href = attr_value(attrs, "href")
          resolve_url(href, base_url)

        _ ->
          nil
      end
    end)
  end

  defp attr_value(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, v} -> v
      _ -> nil
    end)
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
    cleaned =
      text
      |> String.replace(~r/<[^>]+>/, "")
      |> String.trim()

    case cleaned do
      "" -> nil
      valid -> if String.valid?(valid), do: valid, else: nil
    end
  end
end
