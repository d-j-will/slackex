defmodule SlackexWeb.ChatLive.SummaryModal do
  @moduledoc """
  LiveComponent for the channel summarization modal.

  Displays time range selection and streams AI-generated summary text.
  Three dismiss mechanisms: backdrop click, Escape key, close button.
  """
  use SlackexWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("close_summary", _params, socket) do
    send(self(), :close_summary_modal)
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_time_range", %{"range" => range}, socket) do
    send(self(), {:start_summary, range})
    {:noreply, socket}
  end

  attr :loom, :boolean, default: false

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="summary-modal"
      data-role="summary-modal"
      phx-window-keydown="close_summary"
      phx-key="Escape"
      phx-target={@myself}
      class="fixed inset-0 z-50 flex items-center justify-center"
    >
      <%!-- Backdrop --%>
      <div class="absolute inset-0 bg-black/50" phx-click="close_summary" phx-target={@myself} />
      <%!-- Modal card --%>
      <div class="relative bg-base-100 rounded-lg shadow-xl w-full max-w-lg mx-4 max-h-[80vh] flex flex-col">
        <%!-- Header --%>
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="loom-sum-title text-lg font-semibold">Channel Summary</h3>
          <button
            data-role="close-summary"
            phx-click="close_summary"
            phx-target={@myself}
            class="btn btn-ghost btn-sm btn-square"
          >
            <span class="hero-x-mark size-5" />
          </button>
        </div>
        <%!-- Content --%>
        <div class="p-4 overflow-y-auto flex-1">
          <%= if @summary_state == :idle do %>
            <p class="text-sm text-base-content/70 mb-4">Choose a time range to summarize:</p>
            <div class="flex flex-wrap gap-2">
              <button
                data-role="time-range-24h"
                phx-click="select_time_range"
                phx-value-range="24h"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                Last 24 hours
              </button>
              <button
                data-role="time-range-7d"
                phx-click="select_time_range"
                phx-value-range="7d"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                Last 7 days
              </button>
              <button
                data-role="time-range-30d"
                phx-click="select_time_range"
                phx-value-range="30d"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                Last 30 days
              </button>
            </div>
          <% end %>

          <%= if @summary_state == :loading do %>
            <div class="flex items-center gap-2 mb-2">
              <.loom_loader :if={@loom} />
              <span :if={!@loom} class="loading loading-spinner loading-sm" />
              <span class="text-sm text-base-content/70">Generating summary...</span>
            </div>
            <div class="prose prose-sm max-w-none">{Slackex.Markdown.to_html(@summary_text)}</div>
          <% end %>

          <%= if @summary_state == :complete do %>
            <div class="prose prose-sm max-w-none">{Slackex.Markdown.to_html(@summary_text)}</div>
          <% end %>

          <%= if @summary_state == :error do %>
            <div class="alert alert-error">
              <span>{error_message(@summary_error)}</span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp loom_loader(assigns) do
    ~H"""
    <svg class="loom-loader" width="40" height="40" viewBox="0 0 24 24" aria-label="loading">
      <g stroke="currentColor" stroke-width="1.5" stroke-linecap="round" fill="none">
        <path d="M4 4 V20" opacity="0.7" />
        <path d="M9 4 V20" opacity="0.5" />
        <path d="M14 4 V20" opacity="0.5" />
        <path d="M19 4 V20" opacity="0.7" />
        <path d="M2 8 H22" stroke-dasharray="4 6">
          <animate
            attributeName="stroke-dashoffset"
            from="0"
            to="-20"
            dur="1.6s"
            repeatCount="indefinite"
          />
        </path>
        <path d="M2 12 H22" stroke-dasharray="4 6" stroke-dashoffset="3">
          <animate
            attributeName="stroke-dashoffset"
            from="3"
            to="-17"
            dur="1.6s"
            repeatCount="indefinite"
          />
        </path>
        <path d="M2 16 H22" stroke-dasharray="4 6">
          <animate
            attributeName="stroke-dashoffset"
            from="0"
            to="-20"
            dur="1.6s"
            repeatCount="indefinite"
          />
        </path>
      </g>
    </svg>
    """
  end

  defp error_message(:no_messages), do: "No messages found in this time range."
  defp error_message(:not_configured), do: "AI features are not configured."
  defp error_message(:unauthorized), do: "You don't have access to this channel."

  defp error_message(:empty_response),
    do: "The AI service returned an empty response. Check API key configuration."

  defp error_message(:task_crashed),
    do: "The summary task crashed unexpectedly. Check server logs."

  defp error_message({:api_error, status, _}), do: "API returned error (HTTP #{status})."
  defp error_message({:api_error, status}), do: "API returned error (HTTP #{status})."
  defp error_message({:network_error, _}), do: "Could not reach the AI service. Network error."
  defp error_message({:stream_error, msg}), do: "Stream error: #{msg}"
  defp error_message(other), do: "Something went wrong: #{inspect(other)}"
end
