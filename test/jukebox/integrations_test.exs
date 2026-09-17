defmodule Jukebox.IntegrationsTest do
  # Mutates application env, so it must not run concurrently.
  use ExUnit.Case, async: false

  alias Jukebox.Integrations

  test "builds child specs from the configured adapters (test: demo + fake)" do
    ids = Integrations.children() |> Enum.map(& &1.id)
    assert Jukebox.RemoteControls.Demo in ids
    assert Jukebox.MetadataSources.Demo in ids
    assert Jukebox.Inputs.Fake in ids
  end

  test "process-less remote controls are not supervised and the noop input starts nothing" do
    previous_remote = Application.fetch_env!(:jukebox, :remote_control)
    previous_input = Application.fetch_env!(:jukebox, :input)

    on_exit(fn ->
      Application.put_env(:jukebox, :remote_control, previous_remote)
      Application.put_env(:jukebox, :input, previous_input)
    end)

    Application.put_env(:jukebox, :remote_control, {Jukebox.RemoteControls.Shairport, []})
    Application.put_env(:jukebox, :input, {Jukebox.Inputs.Noop, []})

    ids = Integrations.children() |> Enum.map(& &1.id)
    refute Jukebox.RemoteControls.Shairport in ids
    assert Jukebox.Inputs.Noop in ids
    assert Jukebox.Inputs.Noop.start_link([]) == :ignore
  end

  test "the Shairport MQTT source builds a permanent connection child spec without connecting" do
    spec =
      Jukebox.MetadataSources.ShairportMqtt.child_spec(
        topic: "custom/topic",
        host: "broker.local",
        port: 1884
      )

    assert spec.id == Jukebox.MetadataSources.ShairportMqtt
    assert spec.restart == :permanent
    {Tortoise311.Connection, :start_link, [opts]} = spec.start
    assert opts[:subscriptions] == [{"custom/topic/#", 0}]
    assert {Tortoise311.Transport.Tcp, host: "broker.local", port: 1884} = opts[:server]
    assert {Jukebox.Shairport.MqttHandler, handler_opts} = opts[:handler]
    assert handler_opts[:topic] == "custom/topic"
  end

  test "the Shairport remote control reports capabilities from configuration and fails safely" do
    previous = Application.get_env(:jukebox, Jukebox.Shairport, [])
    on_exit(fn -> Application.put_env(:jukebox, Jukebox.Shairport, previous) end)

    Application.put_env(
      :jukebox,
      Jukebox.Shairport,
      Keyword.put(previous, :remote_control_enabled, false)
    )

    assert Jukebox.RemoteControls.Shairport.capabilities() == MapSet.new()
    assert Jukebox.RemoteControls.Shairport.next_track() == {:error, :remote_control_disabled}

    Application.put_env(
      :jukebox,
      Jukebox.Shairport,
      Keyword.put(previous, :remote_control_enabled, true)
    )

    assert Jukebox.RemoteControls.Shairport.capabilities() ==
             MapSet.new([:previous_track, :toggle_playback, :next_track])

    # No MQTT connection is running in tests: the publish must fail, not raise.
    assert {:error, _reason} = Jukebox.RemoteControls.Shairport.next_track()
  end

  test "the MQTT handler forwards decoded events and stores artwork" do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    server =
      start_supervised!(
        {Jukebox.Playback.Server,
         name: :"playback_#{System.unique_integer([:positive])}", pubsub: pubsub}
      )

    store = :"store_#{System.unique_integer([:positive])}"
    start_supervised!({Jukebox.Artwork.Store, name: store})

    {:ok, handler} =
      Jukebox.Shairport.MqttHandler.init(
        topic: "jukebox/shairport",
        playback: server,
        store: store
      )

    {:ok, handler} = Jukebox.Shairport.MqttHandler.connection(:up, handler)

    {:ok, handler} =
      Jukebox.Shairport.MqttHandler.handle_message(
        ["jukebox", "shairport", "active_start"],
        "",
        handler
      )

    {:ok, handler} =
      Jukebox.Shairport.MqttHandler.handle_message(
        ["jukebox", "shairport", "title"],
        "Instant Crush",
        handler
      )

    {:ok, handler} =
      Jukebox.Shairport.MqttHandler.handle_message(
        ["jukebox", "shairport", "cover"],
        <<0xFF, 0xD8, 0xFF, 1>>,
        handler
      )

    {:ok, handler} =
      Jukebox.Shairport.MqttHandler.handle_message(
        ["jukebox", "shairport", "cover"],
        "not an image",
        handler
      )

    {:ok, handler} =
      Jukebox.Shairport.MqttHandler.handle_message(["other", "topic"], "ignored", handler)

    {:ok, _handler} =
      Jukebox.Shairport.MqttHandler.handle_message(
        ["jukebox", "shairport", "mystery"],
        "ignored",
        handler
      )

    Jukebox.Playback.Server.sync(server)
    state = Jukebox.Playback.Server.get_state(server)
    assert state.metadata_connected?
    assert state.session_status == :active
    assert state.title == "Instant Crush"
    # the malformed cover replaced the valid one with the fallback (nil)
    assert state.artwork == nil
    assert [_id] = Jukebox.Artwork.Store.ids(store)
  end
end
