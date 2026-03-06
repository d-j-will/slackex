defmodule Slackex.Links.SafetyChecker do
  @moduledoc """
  Multi-layer URL safety checking.

  Layer 1: Compile-time domain blocklist (adult, spam, gambling).
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

  @doc "Runs all safety checks in order. Short-circuits on first block."
  @spec check(String.t()) :: :ok | {:blocked, String.t()}
  def check(url) do
    with :ok <- check_domain(url) do
      check_safe_browsing(url)
    end
  end

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
  """
  @spec check_safe_browsing(String.t()) :: :ok | {:blocked, String.t()}
  def check_safe_browsing(url) do
    case Application.get_env(:slackex, :google_safe_browsing_key) do
      nil -> :ok
      "" -> :ok
      key -> do_safe_browsing_check(url, key)
    end
  end

  defp domain_blocked?(host) do
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

        :ok
    end
  end
end
