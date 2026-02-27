defmodule SlackexWeb.MockupLive.Index do
  @moduledoc """
  LiveView for cycling through 10 distinct chat UI mockup designs.
  Each mockup showcases a unique visual style for inspiration.
  Mockups 1-5 are modern Western styles; 6-10 draw from global cultural traditions.
  """
  use SlackexWeb, :live_view

  @mockups [
    %{
      id: 1,
      name: "Aurora Borealis",
      tagline: "Ethereal gradients that shift like the northern lights"
    },
    %{
      id: 2,
      name: "Synthwave",
      tagline: "Neon-soaked retro vibes from a digital sunset"
    },
    %{
      id: 3,
      name: "Glass Garden",
      tagline: "Translucent panels floating over a lush backdrop"
    },
    %{
      id: 4,
      name: "Candy Pop",
      tagline: "Playful colors and bubbly shapes that spark delight"
    },
    %{
      id: 5,
      name: "Cosmic Void",
      tagline: "Deep space serenity with nebula whispers"
    },
    %{
      id: 6,
      name: "Arabesque Oasis",
      tagline: "Infinite geometry inspired by Islamic art and Moroccan tilework"
    },
    %{
      id: 7,
      name: "Ukiyo-e Dreams",
      tagline: "Floating world aesthetics from Japanese woodblock prints"
    },
    %{
      id: 8,
      name: "Shan Shui Mist",
      tagline: "Chinese ink wash mountains dissolving into ethereal fog"
    },
    %{
      id: 9,
      name: "Pojagi Light",
      tagline: "Korean patchwork fabric filtering warm afternoon light"
    },
    %{
      id: 10,
      name: "Jali Garden",
      tagline: "Mughal stone lattice screens framing a jeweled paradise"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_index, 0)
     |> assign(:mockups, @mockups)
     |> assign(:page_title, "UI Mockups")}
  end

  @impl true
  def handle_event("next", _params, socket) do
    new_index = rem(socket.assigns.current_index + 1, length(@mockups))
    {:noreply, assign(socket, :current_index, new_index)}
  end

  def handle_event("prev", _params, socket) do
    count = length(@mockups)
    new_index = rem(socket.assigns.current_index - 1 + count, count)
    {:noreply, assign(socket, :current_index, new_index)}
  end

  def handle_event("goto", %{"index" => index}, socket) do
    {:noreply, assign(socket, :current_index, String.to_integer(index))}
  end

  def handle_event("keydown", %{"key" => "ArrowRight"}, socket) do
    new_index = rem(socket.assigns.current_index + 1, length(@mockups))
    {:noreply, assign(socket, :current_index, new_index)}
  end

  def handle_event("keydown", %{"key" => "ArrowLeft"}, socket) do
    count = length(@mockups)
    new_index = rem(socket.assigns.current_index - 1 + count, count)
    {:noreply, assign(socket, :current_index, new_index)}
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :mockup, Enum.at(assigns.mockups, assigns.current_index))

    ~H"""
    <div class="min-h-screen bg-gray-950 text-white" phx-window-keydown="keydown">
      <%!-- Navigation Bar --%>
      <div class="fixed top-0 left-0 right-0 z-50 bg-gray-950/90 backdrop-blur-sm border-b border-white/10">
        <div class="max-w-7xl mx-auto px-4 py-3 flex items-center justify-between">
          <div>
            <h1 class="text-lg font-bold text-white/90">Slackex UI Concepts</h1>
            <p class="text-xs text-white/40">{@mockup.tagline}</p>
          </div>

          <div class="flex items-center gap-4">
            <%!-- Dot indicators --%>
            <div class="flex gap-2">
              <%= for {m, i} <- Enum.with_index(@mockups) do %>
                <button
                  phx-click="goto"
                  phx-value-index={i}
                  class={"w-2.5 h-2.5 rounded-full transition-all duration-300 #{if i == @current_index, do: "bg-white scale-125", else: "bg-white/30 hover:bg-white/50"}"}
                  title={m.name}
                />
              <% end %>
            </div>

            <%!-- Prev / Next --%>
            <div class="flex gap-1">
              <button phx-click="prev" class="btn btn-ghost btn-sm text-white/70 hover:text-white">
                <span class="hero-chevron-left size-5" />
              </button>
              <span class="text-sm text-white/50 min-w-[3ch] text-center tabular-nums">
                {@current_index + 1}/{length(@mockups)}
              </span>
              <button phx-click="next" class="btn btn-ghost btn-sm text-white/70 hover:text-white">
                <span class="hero-chevron-right size-5" />
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Mockup Content --%>
      <div class="pt-16 p-4">
        <%= case @mockup.id do %>
          <% 1 -> %>
            {render_aurora(assigns)}
          <% 2 -> %>
            {render_synthwave(assigns)}
          <% 3 -> %>
            {render_glass_garden(assigns)}
          <% 4 -> %>
            {render_candy_pop(assigns)}
          <% 5 -> %>
            {render_cosmic(assigns)}
          <% 6 -> %>
            {render_arabesque(assigns)}
          <% 7 -> %>
            {render_ukiyoe(assigns)}
          <% 8 -> %>
            {render_shanshui(assigns)}
          <% 9 -> %>
            {render_pojagi(assigns)}
          <% 10 -> %>
            {render_jali(assigns)}
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 1: Aurora Borealis
  # ---------------------------------------------------------------------------
  defp render_aurora(assigns) do
    ~H"""
    <style>
      .aurora-bg {
        background: linear-gradient(135deg, #0f0c29, #1a1040, #24243e);
        position: relative;
        overflow: hidden;
      }
      .aurora-bg::before {
        content: '';
        position: absolute;
        top: -50%;
        left: -50%;
        width: 200%;
        height: 200%;
        background:
          radial-gradient(ellipse at 20% 50%, rgba(120, 80, 220, 0.3), transparent 50%),
          radial-gradient(ellipse at 80% 20%, rgba(80, 200, 180, 0.25), transparent 50%),
          radial-gradient(ellipse at 40% 80%, rgba(200, 100, 180, 0.2), transparent 50%);
        animation: aurora-drift 15s ease-in-out infinite alternate;
      }
      @keyframes aurora-drift {
        0% { transform: translate(0, 0) rotate(0deg); }
        33% { transform: translate(2%, -3%) rotate(1deg); }
        66% { transform: translate(-1%, 2%) rotate(-1deg); }
        100% { transform: translate(3%, -1%) rotate(2deg); }
      }
      .aurora-sidebar {
        background: rgba(15, 12, 41, 0.85);
        backdrop-filter: blur(12px);
        border-right: 1px solid rgba(120, 80, 220, 0.15);
      }
      .aurora-channel {
        transition: all 0.2s ease;
        border-radius: 8px;
        padding: 6px 12px;
      }
      .aurora-channel:hover {
        background: rgba(120, 80, 220, 0.15);
      }
      .aurora-channel.active {
        background: linear-gradient(90deg, rgba(120, 80, 220, 0.25), rgba(80, 200, 180, 0.15));
        border-left: 3px solid #7850dc;
      }
      .aurora-msg {
        background: rgba(255, 255, 255, 0.05);
        border-radius: 12px;
        border: 1px solid rgba(255, 255, 255, 0.06);
        backdrop-filter: blur(4px);
        transition: background 0.2s;
      }
      .aurora-msg:hover {
        background: rgba(255, 255, 255, 0.08);
      }
      .aurora-input {
        background: rgba(255, 255, 255, 0.06);
        border: 1px solid rgba(120, 80, 220, 0.2);
        border-radius: 12px;
        backdrop-filter: blur(8px);
        transition: border-color 0.3s;
      }
      .aurora-input:focus-within {
        border-color: rgba(120, 80, 220, 0.5);
        box-shadow: 0 0 20px rgba(120, 80, 220, 0.1);
      }
      .aurora-avatar {
        background: linear-gradient(135deg, #7850dc, #50c8b4);
        border-radius: 50%;
      }
    </style>
    <div class="aurora-bg rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-2xl">
      <%!-- Sidebar --%>
      <div class="aurora-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-6">
          <h2 class="text-xl font-bold bg-gradient-to-r from-purple-300 to-teal-300 bg-clip-text text-transparent">
            Aurora Chat
          </h2>
          <p class="text-xs text-white/30 mt-1">Where ideas flow like light</p>
        </div>
        <div class="px-3 space-y-1 flex-1">
          <p class="text-[10px] uppercase tracking-widest text-white/25 px-3 mb-2">Channels</p>
          <div class="aurora-channel active text-white/90 text-sm">
            <span class="text-white/40">#</span> general
          </div>
          <div class="aurora-channel text-white/50 text-sm">
            <span class="text-white/25">#</span> design-studio
          </div>
          <div class="aurora-channel text-white/50 text-sm">
            <span class="text-white/25">#</span> northern-lights
          </div>
          <div class="aurora-channel text-white/50 text-sm">
            <span class="text-white/25">#</span> random
          </div>
          <p class="text-[10px] uppercase tracking-widest text-white/25 px-3 mb-2 mt-6">Direct Messages</p>
          <div class="aurora-channel text-white/50 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-emerald-400"></div> Luna
          </div>
          <div class="aurora-channel text-white/50 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-white/20"></div> Atlas
          </div>
        </div>
      </div>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col relative z-10">
        <%!-- Header --%>
        <div class="px-6 py-3 border-b border-white/5 backdrop-blur-sm bg-white/[0.02]">
          <h3 class="font-semibold text-white/90"><span class="text-white/30">#</span> general</h3>
          <p class="text-xs text-white/30">The aurora borealis of conversation</p>
        </div>

        <%!-- Messages --%>
        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          <div class="aurora-msg p-4 flex gap-3">
            <div class="aurora-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold">L</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-purple-200">Luna</span>
                <span class="text-[10px] text-white/20">2:34 PM</span>
              </div>
              <p class="text-sm text-white/70 mt-1">Has anyone seen the new gradient animations? They remind me of the actual northern lights!</p>
            </div>
          </div>
          <div class="aurora-msg p-4 flex gap-3">
            <div class="aurora-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold" style="background: linear-gradient(135deg, #50c8b4, #7850dc);">A</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-teal-200">Atlas</span>
                <span class="text-[10px] text-white/20">2:36 PM</span>
              </div>
              <p class="text-sm text-white/70 mt-1">Absolutely! The way the colors shift and blend is mesmerizing. Nature is the best designer.</p>
              <div class="mt-2 flex gap-1">
                <span class="text-xs bg-white/5 border border-white/10 rounded-full px-2 py-0.5 cursor-pointer hover:bg-white/10 transition">
                  ✨ 3
                </span>
                <span class="text-xs bg-white/5 border border-white/10 rounded-full px-2 py-0.5 cursor-pointer hover:bg-white/10 transition">
                  💜 2
                </span>
              </div>
            </div>
          </div>
          <div class="aurora-msg p-4 flex gap-3">
            <div class="aurora-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold" style="background: linear-gradient(135deg, #c864b4, #7850dc);">S</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-pink-200">Stella</span>
                <span class="text-[10px] text-white/20">2:38 PM</span>
              </div>
              <p class="text-sm text-white/70 mt-1">I just pushed a new theme to the repo. It uses layered radial gradients with slow drift animations. Check it out and let me know what you think!</p>
            </div>
          </div>
        </div>

        <%!-- Input --%>
        <div class="px-6 py-4">
          <div class="aurora-input flex items-center px-4 py-3">
            <span class="text-white/20 text-sm">Message #general...</span>
            <div class="ml-auto flex gap-2 text-white/20">
              <span class="cursor-pointer hover:text-white/40 transition">📎</span>
              <span class="cursor-pointer hover:text-white/40 transition">😊</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 2: Synthwave
  # ---------------------------------------------------------------------------
  defp render_synthwave(assigns) do
    ~H"""
    <style>
      .synth-bg {
        background: linear-gradient(180deg, #0d0221 0%, #150535 40%, #1a0a2e 100%);
        position: relative;
        overflow: hidden;
      }
      .synth-bg::before {
        content: '';
        position: absolute;
        bottom: 0;
        left: 0;
        right: 0;
        height: 40%;
        background:
          repeating-linear-gradient(
            transparent,
            transparent 30px,
            rgba(255, 0, 255, 0.03) 30px,
            rgba(255, 0, 255, 0.03) 31px
          ),
          repeating-linear-gradient(
            90deg,
            transparent,
            transparent 30px,
            rgba(255, 0, 255, 0.03) 30px,
            rgba(255, 0, 255, 0.03) 31px
          );
        mask-image: linear-gradient(to bottom, transparent, black);
      }
      .synth-bg::after {
        content: '';
        position: absolute;
        bottom: 30%;
        left: 0;
        right: 0;
        height: 3px;
        background: linear-gradient(90deg, transparent, #ff00ff, #00ffff, #ff00ff, transparent);
        box-shadow: 0 0 20px rgba(255, 0, 255, 0.5), 0 0 60px rgba(255, 0, 255, 0.2);
        opacity: 0.6;
      }
      .synth-sidebar {
        background: rgba(13, 2, 33, 0.95);
        border-right: 1px solid rgba(255, 0, 255, 0.15);
      }
      .synth-channel {
        transition: all 0.2s;
        border-radius: 4px;
        padding: 8px 12px;
        font-family: 'Courier New', monospace;
      }
      .synth-channel:hover {
        background: rgba(255, 0, 255, 0.08);
        text-shadow: 0 0 8px rgba(255, 0, 255, 0.5);
      }
      .synth-channel.active {
        background: rgba(255, 0, 255, 0.12);
        border-left: 2px solid #ff00ff;
        text-shadow: 0 0 10px rgba(255, 0, 255, 0.7);
      }
      .synth-msg {
        background: rgba(255, 255, 255, 0.03);
        border-left: 2px solid transparent;
        padding: 12px 16px;
        transition: all 0.2s;
      }
      .synth-msg:hover {
        border-left-color: #ff00ff;
        background: rgba(255, 0, 255, 0.04);
      }
      .synth-neon {
        text-shadow: 0 0 7px #fff, 0 0 10px #fff, 0 0 21px #fff, 0 0 42px #ff00ff, 0 0 82px #ff00ff;
      }
      .synth-neon-cyan {
        text-shadow: 0 0 7px #fff, 0 0 10px #fff, 0 0 21px #fff, 0 0 42px #00ffff, 0 0 82px #00ffff;
      }
      .synth-input {
        background: rgba(13, 2, 33, 0.8);
        border: 1px solid rgba(255, 0, 255, 0.3);
        border-radius: 4px;
        font-family: 'Courier New', monospace;
      }
      .synth-input:focus-within {
        border-color: #ff00ff;
        box-shadow: 0 0 15px rgba(255, 0, 255, 0.2), inset 0 0 15px rgba(255, 0, 255, 0.05);
      }
      .synth-avatar {
        border: 2px solid #ff00ff;
        box-shadow: 0 0 10px rgba(255, 0, 255, 0.3);
        border-radius: 4px;
      }
      @keyframes scan-line {
        0% { top: -10%; }
        100% { top: 110%; }
      }
      .synth-scan::after {
        content: '';
        position: absolute;
        left: 0;
        right: 0;
        height: 2px;
        background: rgba(255, 0, 255, 0.08);
        animation: scan-line 8s linear infinite;
      }
    </style>
    <div class="synth-bg synth-scan rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-2xl border border-purple-900/30">
      <%!-- Sidebar --%>
      <div class="synth-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-6">
          <h2 class="text-xl font-bold text-fuchsia-400 synth-neon" style="font-family: 'Courier New', monospace;">
            SYNTH//CHAT
          </h2>
          <p class="text-[10px] text-fuchsia-400/30 font-mono mt-1">SYS.ONLINE // v2.077</p>
        </div>
        <div class="px-3 space-y-0.5 flex-1">
          <p class="text-[10px] uppercase tracking-[0.3em] text-fuchsia-500/30 px-3 mb-2 font-mono">&gt; Channels</p>
          <div class="synth-channel active text-fuchsia-300 text-sm">
            // neon-lounge
          </div>
          <div class="synth-channel text-white/40 text-sm">
            // retro-wave
          </div>
          <div class="synth-channel text-white/40 text-sm">
            // pixel-art
          </div>
          <div class="synth-channel text-white/40 text-sm">
            // arcade
          </div>
          <p class="text-[10px] uppercase tracking-[0.3em] text-cyan-500/30 px-3 mb-2 mt-6 font-mono">&gt; Direct</p>
          <div class="synth-channel text-white/40 text-sm flex items-center gap-2">
            <div class="w-1.5 h-1.5 bg-cyan-400 shadow-[0_0_6px_rgba(0,255,255,0.6)]"></div> Nyx
          </div>
          <div class="synth-channel text-white/40 text-sm flex items-center gap-2">
            <div class="w-1.5 h-1.5 bg-fuchsia-400 shadow-[0_0_6px_rgba(255,0,255,0.6)]"></div> Chrome
          </div>
        </div>
      </div>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col relative z-10">
        <div class="px-6 py-3 border-b border-fuchsia-500/10 bg-black/20">
          <h3 class="font-mono font-bold text-fuchsia-300">// neon-lounge</h3>
          <p class="text-[10px] text-fuchsia-400/30 font-mono">3 users online &mdash; uptime: 23:47:12</p>
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-3">
          <div class="synth-msg flex gap-3">
            <div class="synth-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-fuchsia-950 text-fuchsia-300 font-mono">N</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-bold text-sm text-fuchsia-300 font-mono">Nyx</span>
                <span class="text-[10px] text-white/15 font-mono">23:14</span>
              </div>
              <p class="text-sm text-white/60 mt-1 font-mono">Just finished the new shader. The grid reflections look insane at 120fps.</p>
            </div>
          </div>
          <div class="synth-msg flex gap-3">
            <div class="synth-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-cyan-950 text-cyan-300 font-mono" style="border-color: #00ffff;">C</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-bold text-sm text-cyan-300 font-mono">Chrome</span>
                <span class="text-[10px] text-white/15 font-mono">23:15</span>
              </div>
              <p class="text-sm text-white/60 mt-1 font-mono">Send me the link. I want to hook it into the audio visualizer.</p>
              <div class="mt-2 inline-block bg-fuchsia-500/10 border border-fuchsia-500/20 rounded px-3 py-1.5 text-xs text-fuchsia-300/80 font-mono">
                shader_v3.glsl &mdash; 2.4kb
              </div>
            </div>
          </div>
          <div class="synth-msg flex gap-3">
            <div class="synth-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-purple-950 text-purple-300 font-mono" style="border-color: #a855f7;">R</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-bold text-sm text-purple-300 font-mono">Raze</span>
                <span class="text-[10px] text-white/15 font-mono">23:17</span>
              </div>
              <p class="text-sm text-white/60 mt-1 font-mono">The vaporwave aesthetic is alive and well. This is art. 🎨</p>
            </div>
          </div>
        </div>

        <div class="px-6 py-4">
          <div class="synth-input flex items-center px-4 py-3">
            <span class="text-fuchsia-500/30 text-sm font-mono">&gt; Enter message...</span>
            <div class="ml-auto flex gap-2 text-fuchsia-500/20">
              <span class="cursor-pointer hover:text-fuchsia-400/40 transition font-mono">[+]</span>
              <span class="cursor-pointer hover:text-fuchsia-400/40 transition font-mono">[:)]</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 3: Glass Garden
  # ---------------------------------------------------------------------------
  defp render_glass_garden(assigns) do
    ~H"""
    <style>
      .garden-bg {
        background:
          linear-gradient(135deg, #0a4a3a 0%, #1a6b4a 30%, #2d8f5e 60%, #1a5a3a 100%);
        position: relative;
        overflow: hidden;
      }
      .garden-bg::before {
        content: '';
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        bottom: 0;
        background:
          radial-gradient(circle at 15% 25%, rgba(144, 238, 144, 0.15), transparent 40%),
          radial-gradient(circle at 85% 75%, rgba(34, 139, 34, 0.2), transparent 40%),
          radial-gradient(circle at 50% 10%, rgba(255, 255, 200, 0.08), transparent 30%);
        animation: garden-sway 20s ease-in-out infinite alternate;
      }
      @keyframes garden-sway {
        0% { transform: scale(1) translate(0, 0); }
        50% { transform: scale(1.02) translate(-1%, 1%); }
        100% { transform: scale(1) translate(1%, -1%); }
      }
      .glass-panel {
        background: rgba(255, 255, 255, 0.08);
        backdrop-filter: blur(16px);
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 16px;
      }
      .glass-sidebar {
        background: rgba(255, 255, 255, 0.06);
        backdrop-filter: blur(20px);
        border-right: 1px solid rgba(255, 255, 255, 0.1);
      }
      .glass-channel {
        transition: all 0.25s ease;
        border-radius: 10px;
        padding: 8px 12px;
      }
      .glass-channel:hover {
        background: rgba(255, 255, 255, 0.08);
      }
      .glass-channel.active {
        background: rgba(255, 255, 255, 0.12);
        box-shadow: inset 0 0 20px rgba(144, 238, 144, 0.1);
      }
      .glass-msg {
        background: rgba(255, 255, 255, 0.06);
        backdrop-filter: blur(8px);
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 16px;
        transition: all 0.2s;
      }
      .glass-msg:hover {
        background: rgba(255, 255, 255, 0.1);
        transform: translateY(-1px);
        box-shadow: 0 4px 20px rgba(0, 0, 0, 0.1);
      }
      .glass-input {
        background: rgba(255, 255, 255, 0.08);
        backdrop-filter: blur(12px);
        border: 1px solid rgba(255, 255, 255, 0.15);
        border-radius: 14px;
        transition: all 0.3s;
      }
      .glass-input:focus-within {
        border-color: rgba(144, 238, 144, 0.4);
        box-shadow: 0 0 30px rgba(144, 238, 144, 0.08);
      }
      .garden-avatar {
        border-radius: 12px;
        background: linear-gradient(135deg, rgba(144,238,144,0.4), rgba(34,139,34,0.4));
        border: 1px solid rgba(255,255,255,0.15);
      }
      .leaf {
        position: absolute;
        font-size: 24px;
        opacity: 0.08;
        animation: float-leaf 25s ease-in-out infinite;
      }
      @keyframes float-leaf {
        0%, 100% { transform: translateY(0) rotate(0deg); }
        50% { transform: translateY(-20px) rotate(15deg); }
      }
    </style>
    <div class="garden-bg rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-2xl">
      <span class="leaf" style="top: 10%; left: 5%;">🌿</span>
      <span class="leaf" style="top: 60%; left: 90%; animation-delay: -8s;">🍃</span>
      <span class="leaf" style="top: 30%; left: 70%; animation-delay: -15s;">🌱</span>

      <%!-- Sidebar --%>
      <div class="glass-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-6">
          <h2 class="text-xl font-bold text-white/90">
            🌿 Glass Garden
          </h2>
          <p class="text-xs text-white/30 mt-1">Grow ideas together</p>
        </div>
        <div class="px-3 space-y-1 flex-1">
          <p class="text-[10px] uppercase tracking-widest text-white/20 px-3 mb-2">Greenhouses</p>
          <div class="glass-channel active text-white/90 text-sm flex items-center gap-2">
            <span class="text-base">🌻</span> sunflower-room
          </div>
          <div class="glass-channel text-white/50 text-sm flex items-center gap-2">
            <span class="text-base">🌊</span> water-garden
          </div>
          <div class="glass-channel text-white/50 text-sm flex items-center gap-2">
            <span class="text-base">🪨</span> rock-garden
          </div>
          <div class="glass-channel text-white/50 text-sm flex items-center gap-2">
            <span class="text-base">🦋</span> butterfly-path
          </div>
          <p class="text-[10px] uppercase tracking-widest text-white/20 px-3 mb-2 mt-6">Whispers</p>
          <div class="glass-channel text-white/50 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-green-400"></div> Willow
          </div>
          <div class="glass-channel text-white/50 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-green-400"></div> Fern
          </div>
        </div>
      </div>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col relative z-10">
        <div class="px-6 py-3 border-b border-white/5 backdrop-blur-sm">
          <h3 class="font-semibold text-white/90">🌻 sunflower-room</h3>
          <p class="text-xs text-white/30">A bright space for bright ideas</p>
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          <div class="glass-msg p-4 flex gap-3">
            <div class="garden-avatar w-10 h-10 flex-shrink-0 flex items-center justify-center text-sm">🌸</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-green-200">Willow</span>
                <span class="text-[10px] text-white/20">10:22 AM</span>
              </div>
              <p class="text-sm text-white/70 mt-1">Good morning! The new terrarium designs are looking absolutely stunning. The glass layers create such beautiful depth.</p>
            </div>
          </div>
          <div class="glass-msg p-4 flex gap-3">
            <div class="garden-avatar w-10 h-10 flex-shrink-0 flex items-center justify-center text-sm" style="background: linear-gradient(135deg, rgba(200,180,100,0.4), rgba(160,140,60,0.4));">🌾</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-yellow-200">Fern</span>
                <span class="text-[10px] text-white/20">10:25 AM</span>
              </div>
              <p class="text-sm text-white/70 mt-1">Thanks! I was inspired by morning dew on leaves. Each panel is like a dewdrop catching the light at different angles.</p>
              <div class="mt-3 glass-panel p-3 text-xs text-white/50">
                <p class="text-white/70 font-medium mb-1">🖼 terrarium-v3.fig</p>
                <p>Updated 2 minutes ago &middot; 3 variants</p>
              </div>
            </div>
          </div>
          <div class="glass-msg p-4 flex gap-3">
            <div class="garden-avatar w-10 h-10 flex-shrink-0 flex items-center justify-center text-sm" style="background: linear-gradient(135deg, rgba(100,180,200,0.4), rgba(60,140,160,0.4));">🌊</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-cyan-200">Brook</span>
                <span class="text-[10px] text-white/20">10:28 AM</span>
              </div>
              <p class="text-sm text-white/70 mt-1">The blur effects are chef's kiss. It really feels like looking through frosted glass on a spring morning. Can we add a subtle parallax scroll?</p>
            </div>
          </div>
        </div>

        <div class="px-6 py-4">
          <div class="glass-input flex items-center px-4 py-3">
            <span class="text-white/25 text-sm">Plant a thought in sunflower-room...</span>
            <div class="ml-auto flex gap-2 text-white/20">
              <span class="cursor-pointer hover:text-white/40 transition">🌺</span>
              <span class="cursor-pointer hover:text-white/40 transition">📎</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 4: Candy Pop
  # ---------------------------------------------------------------------------
  defp render_candy_pop(assigns) do
    ~H"""
    <style>
      .candy-bg {
        background: linear-gradient(135deg, #fff5f5, #fef3ff, #f0f7ff, #f5fff5);
        position: relative;
      }
      .candy-bg::before {
        content: '';
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        bottom: 0;
        background:
          radial-gradient(circle at 10% 20%, rgba(255, 130, 180, 0.12), transparent 35%),
          radial-gradient(circle at 90% 80%, rgba(130, 180, 255, 0.12), transparent 35%),
          radial-gradient(circle at 50% 50%, rgba(255, 220, 100, 0.08), transparent 40%);
      }
      .candy-sidebar {
        background: rgba(255, 255, 255, 0.85);
        border-right: 2px solid #fce4ec;
      }
      .candy-channel {
        transition: all 0.2s ease;
        border-radius: 14px;
        padding: 8px 12px;
        font-weight: 500;
      }
      .candy-channel:hover {
        background: rgba(255, 130, 180, 0.08);
        transform: scale(1.02);
      }
      .candy-channel.active {
        background: linear-gradient(90deg, #ffe0ec, #e0e8ff);
        box-shadow: 0 2px 10px rgba(255, 130, 180, 0.15);
      }
      .candy-msg {
        background: white;
        border-radius: 20px;
        box-shadow: 0 2px 12px rgba(0, 0, 0, 0.04);
        transition: all 0.2s;
        border: 1px solid rgba(0, 0, 0, 0.04);
      }
      .candy-msg:hover {
        transform: translateY(-2px);
        box-shadow: 0 6px 20px rgba(255, 130, 180, 0.12);
      }
      .candy-input {
        background: white;
        border: 2px solid #f3e4ff;
        border-radius: 18px;
        box-shadow: 0 2px 12px rgba(0, 0, 0, 0.03);
        transition: all 0.3s;
      }
      .candy-input:focus-within {
        border-color: #ff82b4;
        box-shadow: 0 4px 20px rgba(255, 130, 180, 0.15);
      }
      .candy-avatar {
        border-radius: 50%;
        border: 2px solid;
      }
      .candy-badge {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        background: linear-gradient(90deg, #ffe0ec, #e0e8ff);
        border-radius: 999px;
        padding: 2px 10px;
        font-size: 11px;
        font-weight: 600;
      }
      @keyframes candy-bounce {
        0%, 100% { transform: translateY(0); }
        50% { transform: translateY(-3px); }
      }
      .candy-emoji {
        display: inline-block;
        animation: candy-bounce 2s ease-in-out infinite;
      }
    </style>
    <div class="candy-bg rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-xl border border-pink-100">
      <%!-- Sidebar --%>
      <div class="candy-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-6">
          <h2 class="text-xl font-extrabold">
            <span class="bg-gradient-to-r from-pink-400 via-purple-400 to-blue-400 bg-clip-text text-transparent">
              Candy Pop
            </span>
            <span class="candy-emoji ml-1">🍬</span>
          </h2>
          <p class="text-xs text-gray-400 mt-1">Sweet conversations await</p>
        </div>
        <div class="px-3 space-y-1 flex-1">
          <p class="text-[10px] uppercase tracking-widest text-pink-300 px-3 mb-2 font-bold">Channels</p>
          <div class="candy-channel active text-gray-700 text-sm">
            🍭 fun-zone
          </div>
          <div class="candy-channel text-gray-400 text-sm">
            🎨 creative-corner
          </div>
          <div class="candy-channel text-gray-400 text-sm">
            🎵 music-box
          </div>
          <div class="candy-channel text-gray-400 text-sm">
            🎮 game-room
          </div>
          <p class="text-[10px] uppercase tracking-widest text-purple-300 px-3 mb-2 mt-6 font-bold">Friends</p>
          <div class="candy-channel text-gray-400 text-sm flex items-center gap-2">
            <div class="w-2.5 h-2.5 rounded-full bg-green-400 border-2 border-white"></div>
            <span>Poppy</span>
            <span class="candy-badge ml-auto">✨ Pro</span>
          </div>
          <div class="candy-channel text-gray-400 text-sm flex items-center gap-2">
            <div class="w-2.5 h-2.5 rounded-full bg-green-400 border-2 border-white"></div>
            <span>Biscuit</span>
          </div>
        </div>
      </div>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col relative z-10">
        <div class="px-6 py-3 border-b border-pink-100/50 bg-white/40">
          <h3 class="font-bold text-gray-700">🍭 fun-zone</h3>
          <p class="text-xs text-gray-400">Where every message is a treat!</p>
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          <div class="candy-msg p-4 flex gap-3">
            <div class="candy-avatar w-10 h-10 flex-shrink-0 flex items-center justify-center text-sm font-bold bg-pink-50 text-pink-500" style="border-color: #ff82b4;">P</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-bold text-sm text-pink-500">Poppy</span>
                <span class="text-[10px] text-gray-300">3:45 PM</span>
              </div>
              <p class="text-sm text-gray-600 mt-1">Hey everyone! I just made the most adorable loading animation! It's a little bouncing cupcake! 🧁</p>
              <div class="mt-2 flex gap-1">
                <span class="text-xs bg-pink-50 border border-pink-100 rounded-full px-2.5 py-1 cursor-pointer hover:bg-pink-100 transition font-medium">
                  🎉 5
                </span>
                <span class="text-xs bg-purple-50 border border-purple-100 rounded-full px-2.5 py-1 cursor-pointer hover:bg-purple-100 transition font-medium">
                  😍 3
                </span>
              </div>
            </div>
          </div>
          <div class="candy-msg p-4 flex gap-3">
            <div class="candy-avatar w-10 h-10 flex-shrink-0 flex items-center justify-center text-sm font-bold bg-blue-50 text-blue-500" style="border-color: #82b4ff;">B</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-bold text-sm text-blue-500">Biscuit</span>
                <span class="text-[10px] text-gray-300">3:47 PM</span>
              </div>
              <p class="text-sm text-gray-600 mt-1">OMG that's so cute!! Can you share the CodePen? I need this in my life right now!</p>
            </div>
          </div>
          <div class="candy-msg p-4 flex gap-3">
            <div class="candy-avatar w-10 h-10 flex-shrink-0 flex items-center justify-center text-sm font-bold bg-yellow-50 text-yellow-600" style="border-color: #ffd700;">M</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-bold text-sm text-yellow-600">Maple</span>
                <span class="text-[10px] text-gray-300">3:49 PM</span>
              </div>
              <p class="text-sm text-gray-600 mt-1">The color palette for this whole app is so satisfying. It's like being inside a box of macarons!</p>
              <div class="mt-2 flex gap-1.5">
                <div class="w-6 h-6 rounded-full bg-pink-300 shadow-sm"></div>
                <div class="w-6 h-6 rounded-full bg-purple-300 shadow-sm"></div>
                <div class="w-6 h-6 rounded-full bg-blue-300 shadow-sm"></div>
                <div class="w-6 h-6 rounded-full bg-yellow-300 shadow-sm"></div>
                <div class="w-6 h-6 rounded-full bg-green-300 shadow-sm"></div>
              </div>
            </div>
          </div>
        </div>

        <div class="px-6 py-4">
          <div class="candy-input flex items-center px-4 py-3">
            <span class="text-gray-300 text-sm">Say something sweet in fun-zone...</span>
            <div class="ml-auto flex gap-2 text-gray-300">
              <span class="cursor-pointer hover:text-pink-400 transition text-lg">🍬</span>
              <span class="cursor-pointer hover:text-pink-400 transition text-lg">😊</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 5: Cosmic Void
  # ---------------------------------------------------------------------------
  defp render_cosmic(assigns) do
    ~H"""
    <style>
      .cosmic-bg {
        background: radial-gradient(ellipse at center, #0a0a2e 0%, #050510 70%, #000005 100%);
        position: relative;
        overflow: hidden;
      }
      .cosmic-bg::before {
        content: '';
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        bottom: 0;
        background:
          radial-gradient(1px 1px at 20% 30%, rgba(255,255,255,0.8), transparent),
          radial-gradient(1px 1px at 40% 70%, rgba(255,255,255,0.6), transparent),
          radial-gradient(1px 1px at 60% 40%, rgba(255,255,255,0.5), transparent),
          radial-gradient(1px 1px at 80% 10%, rgba(255,255,255,0.7), transparent),
          radial-gradient(1.5px 1.5px at 10% 80%, rgba(200,200,255,0.9), transparent),
          radial-gradient(1px 1px at 70% 60%, rgba(255,255,255,0.4), transparent),
          radial-gradient(1px 1px at 30% 50%, rgba(255,255,255,0.6), transparent),
          radial-gradient(1.5px 1.5px at 90% 45%, rgba(200,200,255,0.8), transparent),
          radial-gradient(1px 1px at 15% 15%, rgba(255,255,255,0.5), transparent),
          radial-gradient(1px 1px at 55% 85%, rgba(255,255,255,0.4), transparent),
          radial-gradient(1px 1px at 85% 25%, rgba(255,255,255,0.6), transparent),
          radial-gradient(1px 1px at 45% 55%, rgba(255,255,255,0.3), transparent);
        animation: cosmic-twinkle 4s ease-in-out infinite alternate;
      }
      @keyframes cosmic-twinkle {
        0% { opacity: 0.7; }
        100% { opacity: 1; }
      }
      .cosmic-nebula {
        position: absolute;
        width: 60%;
        height: 60%;
        top: 20%;
        right: -10%;
        background: radial-gradient(ellipse, rgba(100, 50, 180, 0.08), rgba(30, 80, 180, 0.05), transparent 70%);
        filter: blur(40px);
        animation: nebula-pulse 12s ease-in-out infinite alternate;
      }
      @keyframes nebula-pulse {
        0% { transform: scale(1) rotate(0deg); opacity: 0.6; }
        100% { transform: scale(1.1) rotate(5deg); opacity: 1; }
      }
      .cosmic-sidebar {
        background: rgba(5, 5, 20, 0.85);
        backdrop-filter: blur(12px);
        border-right: 1px solid rgba(100, 100, 200, 0.1);
      }
      .cosmic-channel {
        transition: all 0.3s ease;
        border-radius: 8px;
        padding: 7px 12px;
      }
      .cosmic-channel:hover {
        background: rgba(100, 100, 200, 0.08);
      }
      .cosmic-channel.active {
        background: rgba(100, 80, 200, 0.12);
        border-left: 2px solid rgba(140, 120, 255, 0.6);
      }
      .cosmic-msg {
        background: rgba(255, 255, 255, 0.02);
        border-radius: 12px;
        border: 1px solid rgba(100, 100, 200, 0.06);
        transition: all 0.3s;
      }
      .cosmic-msg:hover {
        background: rgba(100, 80, 200, 0.06);
        border-color: rgba(100, 100, 200, 0.12);
      }
      .cosmic-input {
        background: rgba(10, 10, 40, 0.6);
        border: 1px solid rgba(100, 100, 200, 0.15);
        border-radius: 12px;
        backdrop-filter: blur(8px);
        transition: all 0.3s;
      }
      .cosmic-input:focus-within {
        border-color: rgba(140, 120, 255, 0.4);
        box-shadow: 0 0 30px rgba(100, 50, 180, 0.1);
      }
      .cosmic-avatar {
        border-radius: 50%;
        position: relative;
      }
      .cosmic-avatar::after {
        content: '';
        position: absolute;
        inset: -2px;
        border-radius: 50%;
        background: conic-gradient(from 0deg, rgba(140,120,255,0.4), rgba(80,150,255,0.4), rgba(140,120,255,0.4));
        z-index: -1;
        animation: orbit-spin 8s linear infinite;
      }
      @keyframes orbit-spin {
        100% { transform: rotate(360deg); }
      }
    </style>
    <div class="cosmic-bg rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-2xl">
      <div class="cosmic-nebula"></div>

      <%!-- Sidebar --%>
      <div class="cosmic-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-6">
          <h2 class="text-xl font-bold text-white/80">
            <span class="text-indigo-300/80">&#x2726;</span> Cosmic Void
          </h2>
          <p class="text-xs text-white/20 mt-1">Signals from the deep</p>
        </div>
        <div class="px-3 space-y-1 flex-1">
          <p class="text-[10px] uppercase tracking-[0.2em] text-indigo-400/30 px-3 mb-2">Frequencies</p>
          <div class="cosmic-channel active text-white/80 text-sm">
            <span class="text-indigo-400/50">&#x2726;</span> nebula-core
          </div>
          <div class="cosmic-channel text-white/35 text-sm">
            <span class="text-indigo-400/30">&#x2726;</span> dark-matter
          </div>
          <div class="cosmic-channel text-white/35 text-sm">
            <span class="text-indigo-400/30">&#x2726;</span> event-horizon
          </div>
          <div class="cosmic-channel text-white/35 text-sm">
            <span class="text-indigo-400/30">&#x2726;</span> star-forge
          </div>
          <p class="text-[10px] uppercase tracking-[0.2em] text-indigo-400/30 px-3 mb-2 mt-6">Signals</p>
          <div class="cosmic-channel text-white/35 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-indigo-400/60"></div> Orion
          </div>
          <div class="cosmic-channel text-white/35 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-blue-400/60"></div> Vega
          </div>
        </div>
      </div>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col relative z-10">
        <div class="px-6 py-3 border-b border-indigo-500/5 bg-black/10">
          <h3 class="font-semibold text-white/80"><span class="text-indigo-400/50">&#x2726;</span> nebula-core</h3>
          <p class="text-xs text-white/20">Transmitting across the void</p>
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          <div class="cosmic-msg p-4 flex gap-3">
            <div class="cosmic-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-indigo-950 text-indigo-300 rounded-full">O</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-indigo-300">Orion</span>
                <span class="text-[10px] text-white/15">cycle 847.3</span>
              </div>
              <p class="text-sm text-white/50 mt-1">The latest deep-field scan returned some extraordinary data. We're seeing patterns in the background radiation that suggest... structure.</p>
            </div>
          </div>
          <div class="cosmic-msg p-4 flex gap-3">
            <div class="cosmic-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-blue-950 text-blue-300 rounded-full">V</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-blue-300">Vega</span>
                <span class="text-[10px] text-white/15">cycle 847.3</span>
              </div>
              <p class="text-sm text-white/50 mt-1">Confirmed on our end. The harmonic resonance at the 400nm band is unlike anything in the archives. It's almost... musical.</p>
              <div class="mt-2 inline-flex items-center gap-2 bg-indigo-500/5 border border-indigo-500/10 rounded-lg px-3 py-2 text-xs text-indigo-300/60">
                <span>&#x266B;</span> spectral-analysis-847.wav &mdash; 1.2MB
              </div>
            </div>
          </div>
          <div class="cosmic-msg p-4 flex gap-3">
            <div class="cosmic-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-purple-950 text-purple-300 rounded-full">N</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-purple-300">Nova</span>
                <span class="text-[10px] text-white/15">cycle 847.4</span>
              </div>
              <p class="text-sm text-white/50 mt-1">I've overlaid the signal on the known pulsar map. There are correlations we didn't expect. Sharing the visualization now...</p>
              <div class="mt-3 h-16 rounded-lg bg-gradient-to-r from-indigo-500/5 via-purple-500/10 to-blue-500/5 border border-indigo-500/10 flex items-center justify-center">
                <div class="flex gap-[2px] items-end h-8">
                  <div class="w-1 bg-indigo-400/40 rounded-full" style="height: 30%;"></div>
                  <div class="w-1 bg-indigo-400/50 rounded-full" style="height: 60%;"></div>
                  <div class="w-1 bg-indigo-400/60 rounded-full" style="height: 90%;"></div>
                  <div class="w-1 bg-purple-400/70 rounded-full" style="height: 100%;"></div>
                  <div class="w-1 bg-purple-400/60 rounded-full" style="height: 70%;"></div>
                  <div class="w-1 bg-blue-400/50 rounded-full" style="height: 45%;"></div>
                  <div class="w-1 bg-blue-400/40 rounded-full" style="height: 80%;"></div>
                  <div class="w-1 bg-indigo-400/50 rounded-full" style="height: 55%;"></div>
                  <div class="w-1 bg-indigo-400/60 rounded-full" style="height: 95%;"></div>
                  <div class="w-1 bg-purple-400/50 rounded-full" style="height: 40%;"></div>
                  <div class="w-1 bg-blue-400/40 rounded-full" style="height: 65%;"></div>
                  <div class="w-1 bg-indigo-400/30 rounded-full" style="height: 35%;"></div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="px-6 py-4">
          <div class="cosmic-input flex items-center px-4 py-3">
            <span class="text-white/15 text-sm">Transmit to nebula-core...</span>
            <div class="ml-auto flex gap-2 text-white/15">
              <span class="cursor-pointer hover:text-indigo-400/40 transition">&#x25C8;</span>
              <span class="cursor-pointer hover:text-indigo-400/40 transition">&#x2606;</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 6: Arabesque Oasis
  # ---------------------------------------------------------------------------
  defp render_arabesque(assigns) do
    ~H"""
    <style>
      .arabesque-bg {
        background: linear-gradient(160deg, #0c1445 0%, #132054 30%, #0f1a3d 70%, #091230 100%);
        position: relative;
        overflow: hidden;
      }
      .arabesque-bg::before {
        content: '';
        position: absolute;
        top: 0; left: 0; right: 0; bottom: 0;
        background:
          radial-gradient(circle at 20% 80%, rgba(212, 175, 55, 0.06), transparent 40%),
          radial-gradient(circle at 80% 20%, rgba(0, 180, 180, 0.05), transparent 40%);
      }
      .arabesque-pattern {
        position: absolute;
        top: 0; left: 0; right: 0; bottom: 0;
        opacity: 0.03;
        background-image:
          repeating-conic-gradient(from 0deg at 50% 50%, transparent 0deg 60deg, rgba(212,175,55,0.5) 60deg 120deg, transparent 120deg 180deg, rgba(212,175,55,0.5) 180deg 240deg, transparent 240deg 300deg, rgba(212,175,55,0.5) 300deg 360deg);
        background-size: 60px 60px;
      }
      .arabesque-sidebar {
        background: rgba(9, 18, 48, 0.92);
        backdrop-filter: blur(12px);
        border-right: 1px solid rgba(212, 175, 55, 0.12);
      }
      .arabesque-channel {
        transition: all 0.3s ease;
        border-radius: 8px;
        padding: 8px 14px;
        position: relative;
      }
      .arabesque-channel:hover {
        background: rgba(212, 175, 55, 0.06);
      }
      .arabesque-channel.active {
        background: linear-gradient(90deg, rgba(212, 175, 55, 0.1), rgba(0, 180, 180, 0.06));
        border-right: 3px solid #d4af37;
      }
      .arabesque-msg {
        background: rgba(255, 255, 255, 0.03);
        border-radius: 2px 16px 16px 16px;
        border: 1px solid rgba(212, 175, 55, 0.06);
        transition: all 0.2s;
      }
      .arabesque-msg:hover {
        background: rgba(212, 175, 55, 0.04);
        border-color: rgba(212, 175, 55, 0.12);
      }
      .arabesque-input {
        background: rgba(9, 18, 48, 0.7);
        border: 1px solid rgba(212, 175, 55, 0.15);
        border-radius: 12px;
        backdrop-filter: blur(8px);
      }
      .arabesque-input:focus-within {
        border-color: rgba(212, 175, 55, 0.35);
        box-shadow: 0 0 25px rgba(212, 175, 55, 0.06);
      }
      .arabesque-avatar {
        border-radius: 50%;
        border: 2px solid rgba(212, 175, 55, 0.3);
        position: relative;
      }
      .arabesque-divider {
        height: 1px;
        background: linear-gradient(90deg, transparent, rgba(212,175,55,0.15), rgba(0,180,180,0.1), rgba(212,175,55,0.15), transparent);
        margin: 4px 0;
      }
      .arabesque-star {
        display: inline-block;
        color: rgba(212, 175, 55, 0.4);
        font-size: 8px;
      }
      .arabesque-ornament {
        text-align: center;
        color: rgba(212, 175, 55, 0.15);
        font-size: 14px;
        letter-spacing: 8px;
      }
    </style>
    <div class="arabesque-bg rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-2xl border border-yellow-900/20">
      <div class="arabesque-pattern"></div>

      <%!-- Sidebar --%>
      <div class="arabesque-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-4">
          <h2 class="text-xl font-bold text-amber-200/90" style="font-family: Georgia, serif;">
            &#x2726; Arabesque
          </h2>
          <p class="text-[10px] text-amber-200/25 mt-1" style="font-family: Georgia, serif;">Where patterns meet purpose</p>
        </div>
        <div class="arabesque-ornament mb-3">&#x2726; &#x2727; &#x2726;</div>
        <div class="px-3 space-y-1 flex-1">
          <p class="text-[10px] uppercase tracking-[0.2em] text-amber-300/25 px-3 mb-2">Chambers</p>
          <div class="arabesque-channel active text-amber-100/80 text-sm">
            <span class="arabesque-star">&#x2726;</span> the-courtyard
          </div>
          <div class="arabesque-channel text-white/35 text-sm">
            <span class="arabesque-star">&#x2726;</span> mosaic-hall
          </div>
          <div class="arabesque-channel text-white/35 text-sm">
            <span class="arabesque-star">&#x2726;</span> fountain-room
          </div>
          <div class="arabesque-channel text-white/35 text-sm">
            <span class="arabesque-star">&#x2726;</span> starlight-terrace
          </div>
          <div class="arabesque-divider mt-5 mb-3"></div>
          <p class="text-[10px] uppercase tracking-[0.2em] text-teal-300/25 px-3 mb-2">Whispers</p>
          <div class="arabesque-channel text-white/35 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-teal-400/60"></div> Layla
          </div>
          <div class="arabesque-channel text-white/35 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-amber-400/60"></div> Karim
          </div>
        </div>
      </div>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col relative z-10">
        <div class="px-6 py-3 border-b border-amber-500/5">
          <h3 class="font-semibold text-amber-100/80" style="font-family: Georgia, serif;">
            <span class="arabesque-star">&#x2726;</span> the-courtyard
          </h3>
          <p class="text-[10px] text-amber-200/25" style="font-family: Georgia, serif;">Where all paths converge beneath the stars</p>
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          <div class="arabesque-msg p-4 flex gap-3">
            <div class="arabesque-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-amber-950/80 text-amber-200">L</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-amber-200" style="font-family: Georgia, serif;">Layla</span>
                <span class="text-[10px] text-white/15">sunset hour</span>
              </div>
              <p class="text-sm text-white/55 mt-1">Have you seen the new geometric tiling generator? It creates perfect 8-fold symmetry patterns. The mathematics behind Islamic art never ceases to amaze me.</p>
            </div>
          </div>
          <div class="arabesque-msg p-4 flex gap-3">
            <div class="arabesque-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-teal-950/80 text-teal-200" style="border-color: rgba(0,180,180,0.3);">K</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-teal-200" style="font-family: Georgia, serif;">Karim</span>
                <span class="text-[10px] text-white/15">sunset hour</span>
              </div>
              <p class="text-sm text-white/55 mt-1">The way a single motif tessellates into infinity... it's a meditation on the infinite nature of creation. Each tile is simple, but together they form something transcendent.</p>
              <div class="mt-2 flex gap-1">
                <span class="text-xs bg-amber-500/5 border border-amber-500/10 rounded-full px-2.5 py-0.5 cursor-pointer hover:bg-amber-500/10 transition text-amber-200/50">
                  &#x2726; 4
                </span>
              </div>
            </div>
          </div>
          <div class="arabesque-msg p-4 flex gap-3">
            <div class="arabesque-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-indigo-950/80 text-indigo-200" style="border-color: rgba(120,120,200,0.3);">Z</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-indigo-200" style="font-family: Georgia, serif;">Zara</span>
                <span class="text-[10px] text-white/15">evening hour</span>
              </div>
              <p class="text-sm text-white/55 mt-1">I've been studying the zellige work in Fez. The artisans cut each piece by hand &mdash; no two tiles are perfectly identical, yet the whole is flawlessly harmonious. There's a lesson there for how we build software.</p>
            </div>
          </div>
        </div>

        <div class="px-6 py-4">
          <div class="arabesque-input flex items-center px-4 py-3">
            <span class="text-amber-200/20 text-sm" style="font-family: Georgia, serif;">Speak to the courtyard...</span>
            <div class="ml-auto flex gap-3 text-amber-200/15">
              <span class="cursor-pointer hover:text-amber-200/30 transition">&#x2726;</span>
              <span class="cursor-pointer hover:text-amber-200/30 transition">&#x263E;</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 7: Ukiyo-e Dreams
  # ---------------------------------------------------------------------------
  defp render_ukiyoe(assigns) do
    ~H"""
    <style>
      .ukiyoe-bg {
        background: linear-gradient(180deg, #f5efe0 0%, #ede4d0 50%, #e8dcc4 100%);
        position: relative;
        overflow: hidden;
      }
      .ukiyoe-bg::before {
        content: '';
        position: absolute;
        top: 0; left: 0; right: 0; bottom: 0;
        background:
          radial-gradient(ellipse at 80% 90%, rgba(38, 70, 110, 0.04), transparent 50%),
          radial-gradient(ellipse at 10% 10%, rgba(200, 80, 60, 0.03), transparent 40%);
      }
      .ukiyoe-wave {
        position: absolute;
        bottom: 0;
        left: 0;
        right: 0;
        height: 30%;
        background:
          radial-gradient(ellipse at 20% 100%, rgba(38, 70, 110, 0.06), transparent 40%),
          radial-gradient(ellipse at 50% 100%, rgba(38, 70, 110, 0.04), transparent 35%),
          radial-gradient(ellipse at 80% 100%, rgba(38, 70, 110, 0.05), transparent 40%);
      }
      .ukiyoe-sidebar {
        background: rgba(38, 70, 110, 0.06);
        backdrop-filter: blur(8px);
        border-right: 1px solid rgba(38, 70, 110, 0.08);
      }
      .ukiyoe-channel {
        transition: all 0.3s ease;
        border-radius: 4px;
        padding: 8px 12px;
      }
      .ukiyoe-channel:hover {
        background: rgba(38, 70, 110, 0.05);
      }
      .ukiyoe-channel.active {
        background: rgba(38, 70, 110, 0.08);
        border-left: 3px solid #26466e;
      }
      .ukiyoe-msg {
        background: rgba(255, 255, 255, 0.5);
        border-radius: 4px 16px 16px 4px;
        border-left: 2px solid transparent;
        box-shadow: 0 1px 4px rgba(0, 0, 0, 0.04);
        transition: all 0.3s;
      }
      .ukiyoe-msg:hover {
        border-left-color: #26466e;
        box-shadow: 0 2px 8px rgba(38, 70, 110, 0.08);
      }
      .ukiyoe-input {
        background: rgba(255, 255, 255, 0.6);
        border: 1px solid rgba(38, 70, 110, 0.12);
        border-radius: 8px;
        transition: all 0.3s;
      }
      .ukiyoe-input:focus-within {
        border-color: rgba(38, 70, 110, 0.3);
        box-shadow: 0 0 20px rgba(38, 70, 110, 0.05);
      }
      .ukiyoe-avatar {
        border-radius: 4px;
        border: 1px solid rgba(38, 70, 110, 0.15);
      }
      .ukiyoe-accent { color: #26466e; }
      .ukiyoe-vermillion { color: #c8503c; }
      .ukiyoe-ink { color: #2a2a28; }
    </style>
    <div class="ukiyoe-bg rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-xl border border-stone-300/40">
      <div class="ukiyoe-wave"></div>

      <%!-- Sidebar --%>
      <div class="ukiyoe-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-6">
          <h2 class="text-xl font-bold ukiyoe-ink" style="font-family: Georgia, serif; letter-spacing: 0.05em;">
            浮世絵
          </h2>
          <p class="text-[11px] text-stone-500 mt-1" style="font-family: Georgia, serif;">Pictures of the floating world</p>
        </div>
        <div class="px-3 space-y-1 flex-1">
          <p class="text-[10px] uppercase tracking-[0.2em] text-stone-400 px-3 mb-2">Rooms</p>
          <div class="ukiyoe-channel active ukiyoe-ink text-sm">
            <span class="ukiyoe-vermillion">&#x25CF;</span> tokaido-road
          </div>
          <div class="ukiyoe-channel text-stone-500 text-sm">
            <span class="text-stone-300">&#x25CF;</span> ink-garden
          </div>
          <div class="ukiyoe-channel text-stone-500 text-sm">
            <span class="text-stone-300">&#x25CF;</span> moon-viewing
          </div>
          <div class="ukiyoe-channel text-stone-500 text-sm">
            <span class="text-stone-300">&#x25CF;</span> wave-study
          </div>
          <div class="h-px bg-stone-300/40 my-5"></div>
          <p class="text-[10px] uppercase tracking-[0.2em] text-stone-400 px-3 mb-2">Letters</p>
          <div class="ukiyoe-channel text-stone-500 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-sm bg-green-700/50"></div> Hana
          </div>
          <div class="ukiyoe-channel text-stone-500 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-sm bg-stone-400/40"></div> Ren
          </div>
        </div>
      </div>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col relative z-10">
        <div class="px-6 py-3 border-b border-stone-300/30">
          <h3 class="font-semibold ukiyoe-ink" style="font-family: Georgia, serif;">
            <span class="ukiyoe-vermillion">&#x25CF;</span> tokaido-road
          </h3>
          <p class="text-[11px] text-stone-400" style="font-family: Georgia, serif;">Fifty-three stations of contemplation</p>
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          <div class="ukiyoe-msg p-4 flex gap-3">
            <div class="ukiyoe-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-indigo-50 ukiyoe-accent">H</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm ukiyoe-accent" style="font-family: Georgia, serif;">Hana</span>
                <span class="text-[10px] text-stone-400">morning bell</span>
              </div>
              <p class="text-sm text-stone-600 mt-1">The cherry blossoms outside the studio window are at their peak today. Mono no aware &mdash; the beauty is more poignant because it is fleeting.</p>
            </div>
          </div>
          <div class="ukiyoe-msg p-4 flex gap-3">
            <div class="ukiyoe-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-red-50 ukiyoe-vermillion">R</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm ukiyoe-vermillion" style="font-family: Georgia, serif;">Ren</span>
                <span class="text-[10px] text-stone-400">morning bell</span>
              </div>
              <p class="text-sm text-stone-600 mt-1">I finished the new print series last night. 36 views, each one capturing the same mountain from a different perspective. Hokusai would understand &mdash; the subject never changes, but our perception of it is infinite.</p>
              <div class="mt-3 rounded bg-stone-100 border border-stone-200 p-3 text-xs text-stone-500">
                <p class="text-stone-600 font-medium">fujisan-series-36.png</p>
                <p class="mt-0.5">Woodblock print &middot; 2400 &times; 3600</p>
              </div>
            </div>
          </div>
          <div class="ukiyoe-msg p-4 flex gap-3">
            <div class="ukiyoe-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-stone-100 ukiyoe-ink">S</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm ukiyoe-ink" style="font-family: Georgia, serif;">Sen</span>
                <span class="text-[10px] text-stone-400">midday</span>
              </div>
              <p class="text-sm text-stone-600 mt-1">In wabi-sabi there is no need for perfection. The crack in the bowl is where the light enters. I think our best work comes from embracing that.</p>
            </div>
          </div>
        </div>

        <div class="px-6 py-4">
          <div class="ukiyoe-input flex items-center px-4 py-3">
            <span class="text-stone-400 text-sm" style="font-family: Georgia, serif;">Write along the road...</span>
            <div class="ml-auto flex gap-2 text-stone-400/50">
              <span class="cursor-pointer hover:text-stone-500 transition">&#x7B46;</span>
              <span class="cursor-pointer hover:text-stone-500 transition">&#x2609;</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 8: Shan Shui Mist
  # ---------------------------------------------------------------------------
  defp render_shanshui(assigns) do
    ~H"""
    <style>
      .shanshui-bg {
        background: linear-gradient(180deg, #f0f0f0 0%, #e8e8e8 30%, #ddd 60%, #ccc 100%);
        position: relative;
        overflow: hidden;
      }
      .shanshui-bg::before {
        content: '';
        position: absolute;
        top: 0; left: 0; right: 0; bottom: 0;
        background:
          radial-gradient(ellipse at 30% 80%, rgba(40, 40, 50, 0.08), transparent 45%),
          radial-gradient(ellipse at 70% 70%, rgba(40, 40, 50, 0.06), transparent 40%),
          radial-gradient(ellipse at 50% 95%, rgba(40, 40, 50, 0.1), transparent 35%);
      }
      .shanshui-mist {
        position: absolute;
        bottom: 0; left: 0; right: 0;
        height: 50%;
        background: linear-gradient(to top, rgba(240,240,240,0.9), transparent);
        animation: mist-drift 20s ease-in-out infinite alternate;
      }
      @keyframes mist-drift {
        0% { opacity: 0.5; transform: translateX(0); }
        100% { opacity: 0.8; transform: translateX(2%); }
      }
      .shanshui-sidebar {
        background: rgba(245, 245, 245, 0.7);
        backdrop-filter: blur(12px);
        border-right: 1px solid rgba(0, 0, 0, 0.06);
      }
      .shanshui-channel {
        transition: all 0.3s;
        border-radius: 4px;
        padding: 8px 12px;
      }
      .shanshui-channel:hover {
        background: rgba(0, 0, 0, 0.03);
      }
      .shanshui-channel.active {
        background: rgba(0, 0, 0, 0.05);
        border-left: 2px solid #333;
      }
      .shanshui-msg {
        background: rgba(255, 255, 255, 0.5);
        border-radius: 12px;
        border: 1px solid rgba(0, 0, 0, 0.04);
        backdrop-filter: blur(6px);
        transition: all 0.3s;
      }
      .shanshui-msg:hover {
        background: rgba(255, 255, 255, 0.7);
        box-shadow: 0 4px 16px rgba(0, 0, 0, 0.04);
      }
      .shanshui-input {
        background: rgba(255, 255, 255, 0.5);
        border: 1px solid rgba(0, 0, 0, 0.08);
        border-radius: 10px;
        backdrop-filter: blur(8px);
      }
      .shanshui-input:focus-within {
        border-color: rgba(0, 0, 0, 0.15);
        box-shadow: 0 0 20px rgba(0, 0, 0, 0.03);
      }
      .shanshui-avatar {
        border-radius: 50%;
        border: 1px solid rgba(0, 0, 0, 0.08);
      }
      .shanshui-red { color: #c23a2b; }
      .shanshui-ink { color: #2a2a2a; }
      .shanshui-seal {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        background: #c23a2b;
        color: white;
        font-size: 8px;
        width: 18px;
        height: 18px;
        border-radius: 2px;
        font-weight: bold;
      }
    </style>
    <div class="shanshui-bg rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-xl border border-stone-200">
      <div class="shanshui-mist"></div>

      <%!-- Sidebar --%>
      <div class="shanshui-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-6 flex items-center gap-2">
          <div>
            <h2 class="text-xl font-bold shanshui-ink" style="font-family: Georgia, serif;">
              山水
            </h2>
            <p class="text-[11px] text-stone-400 mt-0.5" style="font-family: Georgia, serif;">Mountain and water</p>
          </div>
          <span class="shanshui-seal ml-auto">&#x5370;</span>
        </div>
        <div class="px-3 space-y-1 flex-1">
          <p class="text-[10px] tracking-[0.15em] text-stone-400 px-3 mb-2" style="font-family: Georgia, serif;">Pavilions</p>
          <div class="shanshui-channel active shanshui-ink text-sm">
            &#x5C71; cloud-pavilion
          </div>
          <div class="shanshui-channel text-stone-400 text-sm">
            &#x6C34; bamboo-grove
          </div>
          <div class="shanshui-channel text-stone-400 text-sm">
            &#x96F2; mist-bridge
          </div>
          <div class="shanshui-channel text-stone-400 text-sm">
            &#x6708; moon-gate
          </div>
          <div class="h-px bg-stone-200 my-5"></div>
          <p class="text-[10px] tracking-[0.15em] text-stone-400 px-3 mb-2" style="font-family: Georgia, serif;">Correspondences</p>
          <div class="shanshui-channel text-stone-400 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-emerald-600/50"></div> Wei
          </div>
          <div class="shanshui-channel text-stone-400 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-stone-400/40"></div> Mei
          </div>
        </div>
      </div>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col relative z-10">
        <div class="px-6 py-3 border-b border-stone-200/60">
          <h3 class="font-semibold shanshui-ink" style="font-family: Georgia, serif;">
            &#x5C71; cloud-pavilion
          </h3>
          <p class="text-[11px] text-stone-400" style="font-family: Georgia, serif;">High above the mist, clarity finds us</p>
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          <div class="shanshui-msg p-4 flex gap-3">
            <div class="shanshui-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-stone-100 shanshui-ink">W</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm shanshui-ink" style="font-family: Georgia, serif;">Wei</span>
                <span class="text-[10px] text-stone-400">hour of the dragon</span>
              </div>
              <p class="text-sm text-stone-500 mt-1">The new ink wash algorithm produces strokes that thin and thicken based on velocity, just like a real brush on rice paper. The empty space is as expressive as the marks themselves.</p>
            </div>
          </div>
          <div class="shanshui-msg p-4 flex gap-3">
            <div class="shanshui-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-red-50 shanshui-red">M</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm shanshui-red" style="font-family: Georgia, serif;">Mei</span>
                <span class="text-[10px] text-stone-400">hour of the dragon</span>
              </div>
              <p class="text-sm text-stone-500 mt-1">Beautiful. In shan shui, we paint the essence, not the appearance. Three strokes suggest a mountain &mdash; the viewer's mind completes the landscape. Our interfaces should trust users the same way.</p>
              <div class="mt-3 rounded bg-stone-50 border border-stone-200 p-3 flex items-center gap-3">
                <div class="w-12 h-12 bg-gradient-to-b from-stone-200 to-stone-100 rounded flex items-center justify-center text-stone-400 text-2xl">&#x5C71;</div>
                <div class="text-xs text-stone-500">
                  <p class="text-stone-600 font-medium">landscape-study-17.ink</p>
                  <p>Digital ink wash &middot; 4 layers</p>
                </div>
              </div>
            </div>
          </div>
          <div class="shanshui-msg p-4 flex gap-3">
            <div class="shanshui-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-emerald-50 text-emerald-800">L</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm text-emerald-800" style="font-family: Georgia, serif;">Lin</span>
                <span class="text-[10px] text-stone-400">hour of the serpent</span>
              </div>
              <p class="text-sm text-stone-500 mt-1">The porcelain palette &mdash; cobalt on white &mdash; has endured for a thousand years. There is wisdom in restraint. Sometimes two colors are all you need.</p>
            </div>
          </div>
        </div>

        <div class="px-6 py-4">
          <div class="shanshui-input flex items-center px-4 py-3">
            <span class="text-stone-400 text-sm" style="font-family: Georgia, serif;">Inscribe your thoughts...</span>
            <div class="ml-auto flex gap-2 text-stone-400/50">
              <span class="cursor-pointer hover:text-stone-600 transition">&#x7B46;</span>
              <span class="shanshui-seal cursor-pointer" style="font-size: 7px;">&#x5370;</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 9: Pojagi Light
  # ---------------------------------------------------------------------------
  defp render_pojagi(assigns) do
    ~H"""
    <style>
      .pojagi-bg {
        background: #faf8f5;
        position: relative;
        overflow: hidden;
      }
      .pojagi-bg::before {
        content: '';
        position: absolute;
        top: 0; left: 0; right: 0; bottom: 0;
        background:
          linear-gradient(45deg, rgba(200, 60, 60, 0.04) 0%, transparent 30%),
          linear-gradient(135deg, rgba(50, 80, 160, 0.04) 0%, transparent 30%),
          linear-gradient(225deg, rgba(200, 180, 40, 0.04) 0%, transparent 30%),
          linear-gradient(315deg, rgba(40, 120, 60, 0.04) 0%, transparent 30%);
      }
      .pojagi-patch {
        position: absolute;
        border-radius: 4px;
        opacity: 0.06;
      }
      .pojagi-sidebar {
        background: rgba(255, 255, 255, 0.7);
        backdrop-filter: blur(10px);
        border-right: 1px solid rgba(0, 0, 0, 0.06);
      }
      .pojagi-channel {
        transition: all 0.25s;
        border-radius: 6px;
        padding: 8px 12px;
        position: relative;
      }
      .pojagi-channel::before {
        content: '';
        position: absolute;
        left: 0; top: 0; bottom: 0;
        width: 3px;
        border-radius: 3px;
        opacity: 0;
        transition: opacity 0.25s;
      }
      .pojagi-channel:hover {
        background: rgba(0, 0, 0, 0.02);
      }
      .pojagi-channel.active {
        background: rgba(50, 80, 160, 0.05);
      }
      .pojagi-channel.active::before {
        opacity: 1;
        background: linear-gradient(180deg, #c83c3c, #3250a0, #c8b428, #287840);
      }
      .pojagi-msg {
        background: rgba(255, 255, 255, 0.65);
        border-radius: 12px;
        border: 1px solid rgba(0, 0, 0, 0.04);
        backdrop-filter: blur(4px);
        transition: all 0.2s;
        position: relative;
        overflow: hidden;
      }
      .pojagi-msg::before {
        content: '';
        position: absolute;
        top: 0; left: 0; bottom: 0; width: 3px;
        opacity: 0;
        transition: opacity 0.2s;
      }
      .pojagi-msg:hover {
        background: rgba(255, 255, 255, 0.85);
        box-shadow: 0 2px 12px rgba(0, 0, 0, 0.04);
      }
      .pojagi-msg:hover::before {
        opacity: 1;
      }
      .pojagi-msg:nth-child(1)::before { background: #c83c3c; }
      .pojagi-msg:nth-child(2)::before { background: #3250a0; }
      .pojagi-msg:nth-child(3)::before { background: #287840; }
      .pojagi-input {
        background: rgba(255, 255, 255, 0.6);
        border: 1px solid rgba(0, 0, 0, 0.06);
        border-radius: 10px;
        backdrop-filter: blur(6px);
      }
      .pojagi-input:focus-within {
        border-image: linear-gradient(90deg, #c83c3c, #3250a0, #c8b428, #287840) 1;
        border-style: solid;
        border-width: 1px;
        border-radius: 0;
      }
      .pojagi-avatar {
        border-radius: 6px;
        border: 1.5px solid;
      }
      .pojagi-obangsaek {
        display: flex;
        gap: 3px;
      }
      .pojagi-obangsaek span {
        width: 8px;
        height: 8px;
        border-radius: 2px;
      }
    </style>
    <div class="pojagi-bg rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-xl border border-stone-200/50">
      <%!-- Translucent patchwork overlays --%>
      <div class="pojagi-patch" style="top: 5%; left: 60%; width: 15%; height: 20%; background: rgba(200,60,60,0.08);"></div>
      <div class="pojagi-patch" style="top: 25%; left: 75%; width: 20%; height: 15%; background: rgba(50,80,160,0.08);"></div>
      <div class="pojagi-patch" style="top: 60%; left: 55%; width: 18%; height: 25%; background: rgba(200,180,40,0.06);"></div>
      <div class="pojagi-patch" style="top: 45%; left: 80%; width: 12%; height: 20%; background: rgba(40,120,60,0.07);"></div>

      <%!-- Sidebar --%>
      <div class="pojagi-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-5">
          <h2 class="text-xl font-bold text-stone-700" style="font-family: Georgia, serif;">
            보자기
          </h2>
          <p class="text-[11px] text-stone-400 mt-1" style="font-family: Georgia, serif;">Light through layered cloth</p>
          <div class="pojagi-obangsaek mt-2">
            <span style="background: #c83c3c;"></span>
            <span style="background: #3250a0;"></span>
            <span style="background: #c8b428;"></span>
            <span style="background: #287840;"></span>
            <span style="background: #2a2a2a;"></span>
          </div>
        </div>
        <div class="px-3 space-y-1 flex-1">
          <p class="text-[10px] uppercase tracking-[0.15em] text-stone-400 px-3 mb-2 font-medium">Rooms</p>
          <div class="pojagi-channel active text-stone-700 text-sm font-medium">
            &#x25A0; weaving-circle
          </div>
          <div class="pojagi-channel text-stone-400 text-sm">
            &#x25A1; color-study
          </div>
          <div class="pojagi-channel text-stone-400 text-sm">
            &#x25A1; pattern-library
          </div>
          <div class="pojagi-channel text-stone-400 text-sm">
            &#x25A1; hanbok-draping
          </div>
          <div class="h-px bg-stone-200/60 my-5"></div>
          <p class="text-[10px] uppercase tracking-[0.15em] text-stone-400 px-3 mb-2 font-medium">Messages</p>
          <div class="pojagi-channel text-stone-400 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-sm bg-green-600/60"></div> Soo-jin
          </div>
          <div class="pojagi-channel text-stone-400 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-sm bg-stone-300"></div> Min-ho
          </div>
        </div>
      </div>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col relative z-10">
        <div class="px-6 py-3 border-b border-stone-200/40">
          <h3 class="font-semibold text-stone-700" style="font-family: Georgia, serif;">
            &#x25A0; weaving-circle
          </h3>
          <p class="text-[11px] text-stone-400" style="font-family: Georgia, serif;">Many pieces, one cloth &mdash; many voices, one conversation</p>
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          <div class="pojagi-msg p-4 flex gap-3">
            <div class="pojagi-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-red-50 text-red-700" style="border-color: #c83c3c;">S</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm" style="color: #c83c3c; font-family: Georgia, serif;">Soo-jin</span>
                <span class="text-[10px] text-stone-400">afternoon</span>
              </div>
              <p class="text-sm text-stone-600 mt-1">I've been experimenting with layering translucent color panels &mdash; inspired by how pojagi catches afternoon light. Each layer is simple, but the overlapping creates depths neither layer has alone.</p>
            </div>
          </div>
          <div class="pojagi-msg p-4 flex gap-3">
            <div class="pojagi-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-blue-50 text-blue-700" style="border-color: #3250a0;">M</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm" style="color: #3250a0; font-family: Georgia, serif;">Min-ho</span>
                <span class="text-[10px] text-stone-400">afternoon</span>
              </div>
              <p class="text-sm text-stone-600 mt-1">That's exactly the obangsaek philosophy &mdash; the five cardinal colors represent the elements in balance. Red for fire, blue for water, yellow for earth, green for wood, black for metal. Harmony through diversity.</p>
              <div class="mt-2 pojagi-obangsaek">
                <span style="background: #c83c3c; width: 24px; height: 24px; border-radius: 4px;" class="flex items-center justify-center text-white text-[8px]">&#x706B;</span>
                <span style="background: #3250a0; width: 24px; height: 24px; border-radius: 4px;" class="flex items-center justify-center text-white text-[8px]">&#x6C34;</span>
                <span style="background: #c8b428; width: 24px; height: 24px; border-radius: 4px;" class="flex items-center justify-center text-white text-[8px]">&#x571F;</span>
                <span style="background: #287840; width: 24px; height: 24px; border-radius: 4px;" class="flex items-center justify-center text-white text-[8px]">&#x6728;</span>
                <span style="background: #2a2a2a; width: 24px; height: 24px; border-radius: 4px;" class="flex items-center justify-center text-white text-[8px]">&#x91D1;</span>
              </div>
            </div>
          </div>
          <div class="pojagi-msg p-4 flex gap-3">
            <div class="pojagi-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-green-50 text-green-700" style="border-color: #287840;">J</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm" style="color: #287840; font-family: Georgia, serif;">Ji-yeon</span>
                <span class="text-[10px] text-stone-400">late afternoon</span>
              </div>
              <p class="text-sm text-stone-600 mt-1">The most moving thing about pojagi is that it was originally made from scraps &mdash; nothing wasted, everything repurposed into something beautiful. A philosophy for sustainable design.</p>
            </div>
          </div>
        </div>

        <div class="px-6 py-4">
          <div class="pojagi-input flex items-center px-4 py-3">
            <span class="text-stone-400 text-sm" style="font-family: Georgia, serif;">Add your thread to the weaving circle...</span>
            <div class="ml-auto flex gap-2 text-stone-400/50">
              <span class="cursor-pointer hover:text-stone-600 transition">&#x25A0;</span>
              <span class="cursor-pointer hover:text-stone-600 transition">&#x2661;</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mockup 10: Jali Garden
  # ---------------------------------------------------------------------------
  defp render_jali(assigns) do
    ~H"""
    <style>
      .jali-bg {
        background: linear-gradient(160deg, #1a0a1e 0%, #2a1028 30%, #1e0a28 60%, #120820 100%);
        position: relative;
        overflow: hidden;
      }
      .jali-bg::before {
        content: '';
        position: absolute;
        top: 0; left: 0; right: 0; bottom: 0;
        background:
          radial-gradient(circle at 25% 75%, rgba(220, 40, 80, 0.08), transparent 40%),
          radial-gradient(circle at 75% 25%, rgba(40, 100, 200, 0.06), transparent 40%),
          radial-gradient(circle at 50% 50%, rgba(200, 160, 40, 0.04), transparent 50%);
      }
      .jali-lattice {
        position: absolute;
        top: 0; left: 0; right: 0; bottom: 0;
        opacity: 0.02;
        background-image:
          radial-gradient(circle, rgba(200,160,40,0.8) 1px, transparent 1px),
          radial-gradient(circle, rgba(200,160,40,0.4) 1px, transparent 1px);
        background-size: 40px 40px;
        background-position: 0 0, 20px 20px;
      }
      .jali-sidebar {
        background: rgba(18, 8, 32, 0.9);
        backdrop-filter: blur(12px);
        border-right: 1px solid rgba(200, 160, 40, 0.08);
      }
      .jali-channel {
        transition: all 0.3s;
        border-radius: 8px;
        padding: 8px 14px;
      }
      .jali-channel:hover {
        background: rgba(200, 160, 40, 0.05);
      }
      .jali-channel.active {
        background: linear-gradient(90deg, rgba(220, 40, 80, 0.1), rgba(200, 160, 40, 0.05));
        border-left: 3px solid;
        border-image: linear-gradient(180deg, #dc2850, #c8a028) 1;
      }
      .jali-msg {
        background: rgba(255, 255, 255, 0.03);
        border-radius: 4px 14px 14px 14px;
        border: 1px solid rgba(200, 160, 40, 0.05);
        transition: all 0.25s;
      }
      .jali-msg:hover {
        background: rgba(200, 160, 40, 0.04);
        border-color: rgba(200, 160, 40, 0.1);
      }
      .jali-input {
        background: rgba(18, 8, 32, 0.7);
        border: 1px solid rgba(200, 160, 40, 0.12);
        border-radius: 12px;
        backdrop-filter: blur(8px);
      }
      .jali-input:focus-within {
        border-color: rgba(200, 160, 40, 0.3);
        box-shadow: 0 0 25px rgba(200, 160, 40, 0.05);
      }
      .jali-avatar {
        border-radius: 50%;
        position: relative;
        border: 2px solid;
      }
      .jali-gem {
        display: inline-flex;
        width: 10px;
        height: 10px;
        border-radius: 2px;
        transform: rotate(45deg);
      }
      .jali-ornament {
        text-align: center;
        color: rgba(200, 160, 40, 0.2);
        font-size: 10px;
        letter-spacing: 12px;
      }
      .jali-jewel-ruby { color: #e84070; border-color: rgba(232, 64, 112, 0.3); }
      .jali-jewel-sapphire { color: #4080e8; border-color: rgba(64, 128, 232, 0.3); }
      .jali-jewel-emerald { color: #40b868; border-color: rgba(64, 184, 104, 0.3); }
      .jali-jewel-gold { color: #c8a028; border-color: rgba(200, 160, 40, 0.3); }
    </style>
    <div class="jali-bg rounded-2xl h-[calc(100vh-6rem)] flex overflow-hidden shadow-2xl border border-purple-900/20">
      <div class="jali-lattice"></div>

      <%!-- Sidebar --%>
      <div class="jali-sidebar w-64 flex flex-col py-4 relative z-10">
        <div class="px-4 mb-4">
          <h2 class="text-xl font-bold text-amber-200/80" style="font-family: Georgia, serif;">
            &#x2756; Jali Garden
          </h2>
          <p class="text-[10px] text-amber-200/25 mt-1" style="font-family: Georgia, serif;">Light through carved stone</p>
        </div>
        <div class="jali-ornament mb-3">&#x2756; &#x2756; &#x2756;</div>
        <div class="px-3 space-y-1 flex-1">
          <p class="text-[10px] uppercase tracking-[0.2em] text-amber-200/20 px-3 mb-2">Courts</p>
          <div class="jali-channel active text-amber-100/75 text-sm">
            <span class="jali-gem bg-amber-500/30 mr-1" style="width:6px;height:6px;display:inline-block;"></span> lotus-court
          </div>
          <div class="jali-channel text-white/30 text-sm">
            <span class="jali-gem bg-pink-500/20 mr-1" style="width:6px;height:6px;display:inline-block;"></span> rose-garden
          </div>
          <div class="jali-channel text-white/30 text-sm">
            <span class="jali-gem bg-blue-500/20 mr-1" style="width:6px;height:6px;display:inline-block;"></span> mirror-hall
          </div>
          <div class="jali-channel text-white/30 text-sm">
            <span class="jali-gem bg-emerald-500/20 mr-1" style="width:6px;height:6px;display:inline-block;"></span> jasmine-walk
          </div>
          <div class="h-px bg-gradient-to-r from-transparent via-amber-500/10 to-transparent my-5"></div>
          <p class="text-[10px] uppercase tracking-[0.2em] text-amber-200/20 px-3 mb-2">Private</p>
          <div class="jali-channel text-white/30 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-pink-400/50"></div> Priya
          </div>
          <div class="jali-channel text-white/30 text-sm flex items-center gap-2">
            <div class="w-2 h-2 rounded-full bg-emerald-400/50"></div> Arjun
          </div>
        </div>
      </div>

      <%!-- Main --%>
      <div class="flex-1 flex flex-col relative z-10">
        <div class="px-6 py-3 border-b border-amber-500/5">
          <h3 class="font-semibold text-amber-100/80" style="font-family: Georgia, serif;">
            &#x2756; lotus-court
          </h3>
          <p class="text-[10px] text-amber-200/25" style="font-family: Georgia, serif;">Where jewels of thought are polished into wisdom</p>
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          <div class="jali-msg p-4 flex gap-3">
            <div class="jali-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-pink-950/60 jali-jewel-ruby">P</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm jali-jewel-ruby" style="font-family: Georgia, serif;">Priya</span>
                <span class="text-[10px] text-white/15">golden hour</span>
              </div>
              <p class="text-sm text-white/50 mt-1">The jali screen at the Taj Mahal filters sunlight into patterns that change throughout the day. Every hour reveals a different design &mdash; same stone, infinite expressions. That's what great UI should feel like.</p>
            </div>
          </div>
          <div class="jali-msg p-4 flex gap-3">
            <div class="jali-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-emerald-950/60 jali-jewel-emerald">A</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm jali-jewel-emerald" style="font-family: Georgia, serif;">Arjun</span>
                <span class="text-[10px] text-white/15">golden hour</span>
              </div>
              <p class="text-sm text-white/50 mt-1">I've been studying Rajasthani textile palettes for the new theme system. Ruby, sapphire, emerald, gold &mdash; each jewel tone has been refined over centuries. The vibrancy is extraordinary.</p>
              <div class="mt-3 flex gap-2">
                <div class="w-10 h-10 rounded-lg shadow-lg flex items-center justify-center text-[9px] text-white/80 font-bold" style="background: linear-gradient(135deg, #e84070, #c83060);">Ruby</div>
                <div class="w-10 h-10 rounded-lg shadow-lg flex items-center justify-center text-[9px] text-white/80 font-bold" style="background: linear-gradient(135deg, #4080e8, #3060c8);">Sapph</div>
                <div class="w-10 h-10 rounded-lg shadow-lg flex items-center justify-center text-[9px] text-white/80 font-bold" style="background: linear-gradient(135deg, #40b868, #308848);">Emer</div>
                <div class="w-10 h-10 rounded-lg shadow-lg flex items-center justify-center text-[9px] text-white/80 font-bold" style="background: linear-gradient(135deg, #c8a028, #a88020);">Gold</div>
              </div>
            </div>
          </div>
          <div class="jali-msg p-4 flex gap-3">
            <div class="jali-avatar w-9 h-9 flex-shrink-0 flex items-center justify-center text-xs font-bold bg-blue-950/60 jali-jewel-sapphire">D</div>
            <div>
              <div class="flex items-baseline gap-2">
                <span class="font-semibold text-sm jali-jewel-sapphire" style="font-family: Georgia, serif;">Devi</span>
                <span class="text-[10px] text-white/15">twilight</span>
              </div>
              <p class="text-sm text-white/50 mt-1">There's a concept in rangoli art &mdash; you create the most intricate patterns knowing they'll be swept away. The beauty is in the making, not the keeping. Like ephemeral messages.</p>
              <div class="mt-2 flex gap-1">
                <span class="text-xs bg-pink-500/5 border border-pink-500/10 rounded-full px-2.5 py-0.5 cursor-pointer hover:bg-pink-500/10 transition text-pink-300/50">
                  &#x2756; 6
                </span>
                <span class="text-xs bg-amber-500/5 border border-amber-500/10 rounded-full px-2.5 py-0.5 cursor-pointer hover:bg-amber-500/10 transition text-amber-300/50">
                  &#x2661; 3
                </span>
              </div>
            </div>
          </div>
        </div>

        <div class="px-6 py-4">
          <div class="jali-input flex items-center px-4 py-3">
            <span class="text-amber-200/20 text-sm" style="font-family: Georgia, serif;">Offer a jewel to the lotus court...</span>
            <div class="ml-auto flex gap-3 text-amber-200/15">
              <span class="cursor-pointer hover:text-amber-200/30 transition">&#x2756;</span>
              <span class="cursor-pointer hover:text-amber-200/30 transition">&#x2740;</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
