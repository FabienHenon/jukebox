defmodule JukeboxWeb.JukeboxComponents do
  @moduledoc """
  Function components for the kiosk display: the pastel jukebox frame, the
  three screens (idle, connecting, now playing), the artwork, progress and
  the command-feedback overlay.

  Everything here is passive: no buttons, no pointer handlers, no focusable
  transport symbols. Decorative elements carry `aria-hidden`.
  """

  use Phoenix.Component

  alias JukeboxWeb.Presenter
  alias Phoenix.LiveView.JS

  @bulb_colors ~w(lemon sky mint rose)

  # -- frame -------------------------------------------------------------------

  @doc "The pink jukebox body: marquee, side pillars, screen window and base."
  attr :view, Presenter, required: true
  slot :inner_block, required: true

  def jukebox_frame(assigns) do
    ~H"""
    <div class="jb-body">
      <.marquee wave={@view.mode != :now_playing} />
      <.pillar side="left" />
      <section class="jb-screen" aria-label="Jukebox display">
        {render_slot(@inner_block)}
      </section>
      <.pillar side="right" />
      <.base view={@view} />
    </div>
    """
  end

  attr :wave, :boolean,
    default: true,
    doc: "wave the letters (idle) or sweep a light through them (playing)"

  def marquee(assigns) do
    ~H"""
    <header class="jb-marquee">
      <.lights count={6} />
      <h1 class="jb-wordmark"><.sign_letters wave={@wave} /></h1>
      <.lights count={6} offset={6} />
    </header>
    """
  end

  @sign_letters "Jukebox" |> String.graphemes() |> Enum.with_index()

  @doc """
  The wordmark text. With `wave`, one span per letter so they can bob
  (transform only). Without it, plain text plus a text-clipped overlay that
  carries the moving light reflection (see `.jb-wordmark__text::after`).
  """
  attr :wave, :boolean, default: true

  def sign_letters(assigns) do
    assigns = assign(assigns, :letters, @sign_letters)

    ~H"""
    <%= if @wave do %>
      <span :for={{letter, i} <- @letters} class="jb-wordmark__letter" style={"--i:#{i}"}>
        {letter}
      </span>
    <% else %>
      <span class="jb-wordmark__text" data-text="Jukebox">Jukebox</span>
    <% end %>
    """
  end

  @doc "A row of pastel bulbs that light up in sequence."
  attr :count, :integer, default: 6
  attr :offset, :integer, default: 0

  def lights(assigns) do
    assigns = assign(assigns, :bulbs, bulbs(assigns.count, assigns.offset))

    ~H"""
    <div class="jb-lights" aria-hidden="true">
      <span :for={{i, color} <- @bulbs} class="bulb" data-color={color} style={"--i:#{i}"}></span>
    </div>
    """
  end

  attr :side, :string, required: true

  def pillar(assigns) do
    ~H"""
    <div class={"jb-pillar jb-pillar--#{@side}"} aria-hidden="true">
      <i class="jb-seg" data-color="lemon"><b class="jb-lamp"></b></i>
      <i class="jb-seg" data-color="sky"><b class="jb-lamp"></b></i>
      <i class="jb-seg" data-color="mint"><b class="jb-lamp"></b></i>
    </div>
    """
  end

  attr :view, Presenter, required: true

  def base(assigns) do
    ~H"""
    <footer class="jb-base">
      <div class="jb-grille" aria-hidden="true"></div>
      <p id="status-line" class="jb-statusline" data-reconnecting={to_string(@view.reconnecting?)}>
        <span :if={@view.reconnecting?} class="jb-statusline__dot" aria-hidden="true"></span>
        {@view.status_line}
      </p>
      <div class="jb-grille" aria-hidden="true"></div>
    </footer>
    """
  end

  @doc "Startup overlay shown until the LiveView is connected, then faded out."
  attr :ready?, :boolean, required: true

  def boot_overlay(assigns) do
    ~H"""
    <div id="boot" class={["jb-boot", @ready? && "is-done"]} aria-hidden={if @ready?, do: "true"}>
      <div class="jb-boot__inner">
        <.lights count={7} />
        <p class="jb-wordmark jb-wordmark--boot"><.sign_letters /></p>
        <p class="jb-boot__line">Starting the music…</p>
      </div>
    </div>
    """
  end

  # -- screens -----------------------------------------------------------------

  attr :view, Presenter, required: true

  def idle_screen(assigns) do
    ~H"""
    <section id="screen-idle" class="screen screen--idle" phx-remove={screen_out()}>
      <div class="idle">
        <div class="idle__stage" aria-hidden="true">
          <span class="idle__note idle__note--1">♪</span>
          <span class="idle__note idle__note--2">♫</span>
          <span class="idle__note idle__note--3">♪</span>
          <div class="idle__record"><.record /></div>
        </div>
        <h2 class="idle__heading">{@view.heading}</h2>
        <p class="idle__instruction">
          Start music on your iPhone, then choose “Jukebox” in AirPlay.
        </p>
      </div>
    </section>
    """
  end

  attr :view, Presenter, required: true

  def connecting_screen(assigns) do
    ~H"""
    <section id="screen-connecting" class="screen screen--connecting" phx-remove={screen_out()}>
      <div class="connecting">
        <div class="connecting__art" aria-hidden="true">
          <img src={@view.artwork_url} alt="" decoding="async" />
        </div>
        <div class="connecting__text">
          <h2 class="connecting__heading">{@view.heading}</h2>
          <p :if={@view.source_name} class="connecting__source">from {@view.source_name}</p>
          <div class="connecting__skeleton" aria-hidden="true"><i></i><i></i></div>
        </div>
      </div>
    </section>
    """
  end

  attr :view, Presenter, required: true

  def now_playing_screen(assigns) do
    ~H"""
    <section id="screen-playing" class="screen screen--playing" phx-remove={screen_out()}>
      <div class="np">
        <div class="np__art-slot">
          <.artwork
            url={@view.artwork_url}
            key={@view.artwork_key}
            fallback?={@view.artwork_fallback?}
          />
        </div>
        <div class="np__meta-slot">
          <div id={"meta-#{@view.track_key}"} class="np__meta" phx-remove={meta_out()}>
            <h2 class="np__title">{@view.title}</h2>
            <p :if={@view.artist} class="np__artist">{@view.artist}</p>
            <p :if={@view.album} class="np__album">{@view.album}</p>
            <.progress :if={@view.progress} progress={@view.progress} key={@view.track_key} />
            <div class="np__status">
              <.status_pill :if={@view.status_pill} pill={@view.status_pill} />
              <span :if={@view.volume} class="np__volume">Volume {@view.volume}%</span>
            </div>
            <.waves level={@view.wave_level} />
          </div>
        </div>
      </div>
    </section>
    """
  end

  # -- parts -------------------------------------------------------------------

  @doc """
  Square artwork with layered pastel plates. Keyed so a new image animates in.
  The `ArtworkPalette` hook samples the image once and tints the plates and
  progress fill through CSS custom properties (see artwork_palette.js).
  """
  attr :url, :string, required: true
  attr :key, :string, required: true
  attr :fallback?, :boolean, default: false

  def artwork(assigns) do
    ~H"""
    <figure
      id={"art-#{@key}"}
      class="np__art"
      data-fallback={to_string(@fallback?)}
      data-palette-key={@key}
      phx-hook="ArtworkPalette"
      phx-remove={art_out()}
    >
      <img src={@url} alt="" decoding="async" />
    </figure>
    """
  end

  @doc """
  Progress line. The server renders the anchor values as data attributes; the
  `JukeboxProgress` hook interpolates locally while playing and stops while
  paused. The inner block is `phx-update="ignore"` so the hook owns it.
  """
  attr :progress, :map, required: true
  attr :key, :string, required: true

  def progress(assigns) do
    ~H"""
    <div
      id={"progress-#{@key}"}
      class="np__progress"
      phx-hook="JukeboxProgress"
      data-position={@progress.position_ms}
      data-duration={@progress.duration_ms}
      data-playing={to_string(@progress.playing?)}
      data-total={@progress.total}
    >
      <div id={"progress-live-#{@key}"} class="np__progress-live" phx-update="ignore">
        <div class="np__bar" aria-hidden="true">
          <div class="np__bar-fill" data-progress-fill></div>
        </div>
        <span class="np__time np__time--elapsed" data-progress-elapsed>{@progress.elapsed}</span>
        <span class="np__time np__time--total" data-progress-total>{@progress.total}</span>
      </div>
    </div>
    """
  end

  @doc """
  Decorative waves for the Now Playing screen. They scroll while playing,
  freeze while paused or stopped and scale with the reported volume. They are
  driven purely by playback state: the jukebox never analyses audio, and the
  markup is aria-hidden so nothing suggests otherwise.
  """
  attr :level, :float, default: 1.0

  @wave_layers [
    {1,
     "M0 20 Q25 3 50 20 T100 20 T150 20 T200 20 T250 20 T300 20 T350 20 T400 20 T450 20 T500 20 T550 20 T600 20 T650 20 T700 20 T750 20 T800 20 T850 20 T900 20 T950 20 T1000 20 T1050 20 T1100 20 T1150 20 T1200 20"},
    {2,
     "M0 20 Q25 37 50 20 T100 20 T150 20 T200 20 T250 20 T300 20 T350 20 T400 20 T450 20 T500 20 T550 20 T600 20 T650 20 T700 20 T750 20 T800 20 T850 20 T900 20 T950 20 T1000 20 T1050 20 T1100 20 T1150 20 T1200 20"},
    {3,
     "M0 20 Q25 11 50 20 T100 20 T150 20 T200 20 T250 20 T300 20 T350 20 T400 20 T450 20 T500 20 T550 20 T600 20 T650 20 T700 20 T750 20 T800 20 T850 20 T900 20 T950 20 T1000 20 T1050 20 T1100 20 T1150 20 T1200 20"}
  ]

  def waves(assigns) do
    assigns = assign(assigns, :layers, @wave_layers)

    ~H"""
    <div class="np__waves" style={"--wave-level: #{@level}"} aria-hidden="true">
      <svg
        :for={{layer, path} <- @layers}
        class={"np__wave np__wave--#{layer}"}
        viewBox="0 0 1200 40"
        preserveAspectRatio="none"
      >
        <path d={path} />
      </svg>
    </div>
    """
  end

  attr :pill, :map, required: true

  def status_pill(assigns) do
    ~H"""
    <span class="pill" data-kind={@pill.kind}>
      <.glyph icon={@pill.kind} />
      {@pill.label}
    </span>
    """
  end

  @doc "Brief, non-interactive acknowledgement of a physical button press."
  attr :feedback, :map, default: nil

  def command_feedback(assigns) do
    ~H"""
    <div
      :if={@feedback}
      id={"feedback-#{@feedback.id}"}
      class="jb-feedback"
      data-kind={@feedback.kind}
      role="status"
      aria-live="polite"
    >
      <.glyph icon={@feedback.icon} />
      <span>{@feedback.label}</span>
    </div>
    """
  end

  @doc "Small passive glyphs (never focusable, never clickable)."
  attr :icon, :atom, required: true

  def glyph(assigns) do
    ~H"""
    <svg class="glyph" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <%= case @icon do %>
        <% :previous -> %>
          <path d="M6 5h2.5v14H6zM18 5.5v13L9.5 12z" />
        <% :next -> %>
          <path d="M15.5 5H18v14h-2.5zM6 5.5v13l8.5-6.5z" />
        <% :pause -> %>
          <path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z" />
        <% :paused -> %>
          <path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z" />
        <% :play -> %>
          <path d="M8 5v14l10-7z" />
        <% :playing -> %>
          <path d="M8 5v14l10-7z" />
        <% :stopped -> %>
          <path d="M6 6h12v12H6z" />
        <% :ending -> %>
          <path d="M12 3a9 9 0 1 0 9 9h-2.5A6.5 6.5 0 1 1 12 5.5z" />
        <% _ -> %>
          <circle cx="12" cy="12" r="4" />
      <% end %>
    </svg>
    """
  end

  @doc "Abstract record illustration for the idle screen."
  def record(assigns) do
    ~H"""
    <svg class="record" viewBox="0 0 200 200" aria-hidden="true" focusable="false">
      <circle cx="100" cy="100" r="98" fill="#3B2A4A" />
      <g fill="none" stroke="#FFFDF7" stroke-opacity="0.09" stroke-width="2">
        <circle cx="100" cy="100" r="88" />
        <circle cx="100" cy="100" r="78" />
        <circle cx="100" cy="100" r="68" />
        <circle cx="100" cy="100" r="58" />
        <circle cx="100" cy="100" r="48" />
      </g>
      <path
        d="M34 74A72 72 0 0 1 74 34"
        fill="none"
        stroke="#FFFDF7"
        stroke-opacity="0.28"
        stroke-width="7"
        stroke-linecap="round"
      />
      <circle cx="100" cy="100" r="35" fill="#F3A6C4" />
      <circle cx="100" cy="100" r="35" fill="none" stroke="#E967A1" stroke-width="3" />
      <path d="M100 76a24 24 0 0 1 0 48" fill="none" stroke="#F7D96F" stroke-width="4" />
      <path d="M100 124a24 24 0 0 1 0-48" fill="none" stroke="#93D5F4" stroke-width="4" />
      <circle cx="100" cy="100" r="6" fill="#FFF5DF" />
    </svg>
    """
  end

  # -- transitions (phx-remove) ---------------------------------------------------

  defp screen_out,
    do: JS.transition({"screen-leave", "screen-leave-start", "screen-leave-end"}, time: 320)

  defp art_out, do: JS.transition({"art-leave", "art-leave-start", "art-leave-end"}, time: 280)

  defp meta_out,
    do: JS.transition({"meta-leave", "meta-leave-start", "meta-leave-end"}, time: 240)

  defp bulbs(count, offset) do
    for i <- 0..(count - 1) do
      {i + offset, Enum.at(@bulb_colors, rem(i + offset, length(@bulb_colors)))}
    end
  end
end
