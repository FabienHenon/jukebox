defmodule Jukebox.Shairport.TrackChangeTest do
  @moduledoc """
  Replays a "next track" exactly as Shairport Sync published it for YouTube
  Music on the Raspberry Pi: the new song is announced with a provisional id
  and no album, an empty cover ("--"), the same bundle again, the real cover,
  and half a second later the complete metadata under a *different* id.

  The kiosk must go from the old track to the new one in one step and keep
  the cover; it must never fall back to "Receiving music".
  """

  use ExUnit.Case, async: true

  alias Jukebox.Playback.{Artwork, Server, State}
  alias Jukebox.Shairport.MqttHandler

  @previous_cover <<0x89, "PNG\r\n", 0x1A, "\n", "previous cover">>
  @cover <<0x89, "PNG\r\n", 0x1A, "\n", "thunderstruck cover">>

  setup do
    unique = System.unique_integer([:positive])
    pubsub = :"pubsub_tc_#{unique}"
    start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: pubsub}, id: pubsub))

    # A long window: only `Server.sync/1` flushes, so each test decides where a
    # burst ends instead of depending on timing.
    server =
      start_supervised!(
        {Server, name: :"playback_tc_#{unique}", pubsub: pubsub, coalesce_ms: 60_000}
      )

    store = :"store_tc_#{unique}"
    start_supervised!({Jukebox.Artwork.Store, name: store})

    {:ok, handler} = MqttHandler.init(topic: "jukebox/shairport", playback: server, store: store)
    :ok = Server.subscribe(pubsub)
    {:ok, server: server, handler: handler}
  end

  defp msg(handler, topic, payload) do
    levels = ["jukebox", "shairport"] ++ String.split(topic, "/")
    {:ok, handler} = MqttHandler.handle_message(levels, payload, handler)
    handler
  end

  # One metadata bundle as published with publish_raw and publish_parsed on.
  defp bundle(handler, id, album, artist, title, duration_ms \\ nil) do
    handler =
      handler
      |> msg("ssnc/mdst", "4277139737")
      |> msg("core/mper", <<String.to_integer(id, 16)::unsigned-big-64>>)
      |> msg("track_id", id)
      |> msg("core/asal", album)
      |> msg("album", album)
      |> msg("core/asar", artist)
      |> msg("artist", artist)
      |> msg("core/ascp", "--")
      |> msg("core/asgn", "--")
      |> msg("genre", "--")
      |> msg("core/minm", title)
      |> msg("title", title)
      |> msg("core/caps", <<1>>)

    handler =
      if duration_ms,
        do: msg(handler, "core/astm", <<duration_ms::unsigned-big-32>>),
        else: handler

    msg(handler, "ssnc/mden", "4277139737")
  end

  defp cover(handler, payload) do
    handler
    |> msg("ssnc/pcst", "4277141849")
    |> msg("ssnc/PICT", payload)
    |> msg("cover", payload)
    |> msg("ssnc/pcen", "4277141849")
  end

  defp playing_previous_track(handler, server) do
    handler =
      handler
      |> msg("active_start", "--")
      |> msg("client_name", "Fabien's iPhone")
      |> bundle("AAAA000011112222", "Back in Black", "AC/DC", "Hells Bells", 312_000)
      |> cover(@previous_cover)
      |> msg("ssnc/prgr", "1000000/1441000/14759200")
      |> msg("play_start", "--")

    Server.sync(server)
    assert_receive {:playback_state, %State{title: "Hells Bells", artwork: %Artwork{}}}
    handler
  end

  test "the track change shows the new track in one step and keeps its cover", ctx do
    handler = playing_previous_track(ctx.handler, ctx.server)

    # First burst: provisional bundle, empty cover, the bundle again, real cover.
    handler =
      handler
      |> bundle("18AC3C26D57FC54B", "--", "AC/DC", "Thunderstruck")
      |> msg("ssnc/prgr", "4277139454/4277140793/4288354128")
      |> cover("--")
      |> bundle("18AC3C26D57FC54B", "--", "AC/DC", "Thunderstruck")
      |> cover(@cover)

    Server.sync(ctx.server)

    assert_receive {:playback_state,
                    %State{
                      session_status: :active,
                      title: "Thunderstruck",
                      artist: "AC/DC",
                      album: nil,
                      genre: nil,
                      track_id: "18AC3C26D57FC54B",
                      artwork: %Artwork{content_type: "image/png"} = artwork
                    }}

    refute_receive {:playback_state, _}, 50

    # Half a second later: the same song, complete, under another id.
    handler
    |> bundle("BF20B047D36A042D", "The Razors Edge", "AC/DC", "Thunderstruck", 293_925)
    |> msg("ssnc/prgr", "4277161512/4277162265/4290078446")

    Server.sync(ctx.server)

    assert_receive {:playback_state,
                    %State{
                      session_status: :active,
                      title: "Thunderstruck",
                      album: "The Razors Edge",
                      track_id: "BF20B047D36A042D",
                      artwork: ^artwork,
                      duration_ms: 292_900
                    }}

    refute_receive {:playback_state, _}, 50
  end

  test "a bundle reaches the playback state as one event, whatever the buffering", ctx do
    # No coalescing at all: the bundle markers alone keep the track whole.
    unique = System.unique_integer([:positive])
    pubsub = :"pubsub_tc_raw_#{unique}"
    start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: pubsub}, id: pubsub))

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Server, name: :"playback_tc_raw_#{unique}", pubsub: pubsub, coalesce_ms: 0},
          id: :raw_server
        )
      )

    handler = %{ctx.handler | playback: server}
    :ok = Server.subscribe(pubsub)

    handler = bundle(handler, "AAAA000011112222", "Back in Black", "AC/DC", "Hells Bells")
    assert_receive {:playback_state, %State{title: "Hells Bells", artist: "AC/DC"} = first}
    assert first.album == "Back in Black"

    handler |> cover(@cover) |> bundle("18AC3C26D57FC54B", "--", "AC/DC", "Thunderstruck")
    assert_receive {:playback_state, %State{title: "Hells Bells", artwork: %Artwork{}}}

    # Straight from one complete track to the next: no state without a title.
    assert_receive {:playback_state,
                    %State{title: "Thunderstruck", artist: "AC/DC", artwork: nil}}

    refute_receive {:playback_state, _}, 50
  end

  test "a bundle left open by a missing end marker is not lost", ctx do
    ctx.handler
    |> msg("ssnc/mdst", "1")
    |> msg("title", "First")
    |> msg("ssnc/mdst", "2")
    |> msg("title", "Second")
    |> msg("ssnc/mden", "2")

    Server.sync(ctx.server)
    assert %State{title: "Second"} = Server.get_state(ctx.server)
  end

  test "without bundle markers the fields are still delivered", ctx do
    ctx.handler |> msg("title", "Parsed Only") |> msg("artist", "Somebody")
    Server.sync(ctx.server)
    assert %State{title: "Parsed Only", artist: "Somebody"} = Server.get_state(ctx.server)
  end
end
