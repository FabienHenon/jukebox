defmodule Jukebox.AnimationTest do
  use ExUnit.Case, async: true

  alias Jukebox.Animation

  setup do
    pubsub = :"pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    name = :"animation_#{System.unique_integer([:positive])}"
    start_supervised!({Animation, name: name, pubsub: pubsub, style: :waves})
    :ok = Animation.subscribe(pubsub)
    {:ok, server: name, pubsub: pubsub}
  end

  test "starts with the requested style", %{server: server} do
    assert Animation.get(server) == :waves
  end

  test "the button walks through every style and wraps around", %{server: server} do
    assert Animation.cycle(server) == :chase
    assert_receive {:animation_style, :chase}
    assert Animation.cycle(server) == :party
    assert_receive {:animation_style, :party}
    assert Animation.cycle(server) == :calm
    assert_receive {:animation_style, :calm}
    assert Animation.cycle(server) == :waves
    assert_receive {:animation_style, :waves}
    assert Animation.get(server) == :waves
  end

  test "set/2 selects a style and only broadcasts a change", %{server: server} do
    assert Animation.set(server, :party) == :ok
    assert_receive {:animation_style, :party}
    assert Animation.get(server) == :party

    assert Animation.set(server, :party) == :ok
    refute_receive {:animation_style, _}, 20
  end

  test "get/1 falls back to the default style when the server is down" do
    assert Animation.default_style() == :chase
    assert Animation.get(:animation_server_that_does_not_exist) == :chase
  end

  describe "saved choice" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      # A directory that does not exist yet: the server creates it on demand.
      {:ok, state_file: Path.join([tmp_dir, "state", "animation_style"])}
    end

    defp start_animation(context, opts \\ []) do
      name = :"animation_#{System.unique_integer([:positive])}"
      defaults = [name: name, pubsub: context.pubsub, state_file: context.state_file]
      opts = Keyword.merge(defaults, opts)
      start_supervised!({Animation, opts}, id: name)
      name
    end

    test "the chosen style is still there after a restart", context do
      first = start_animation(context)
      assert Animation.get(first) == :chase
      refute File.exists?(context.state_file)

      assert Animation.cycle(first) == :party
      assert File.read!(context.state_file) == "party\n"
      stop_supervised!(first)

      second = start_animation(context)
      assert Animation.get(second) == :party

      assert Animation.set(second, :calm) == :ok
      stop_supervised!(second)
      assert Animation.get(start_animation(context)) == :calm
    end

    test "an explicit starting style wins over the saved one", context do
      File.mkdir_p!(Path.dirname(context.state_file))
      File.write!(context.state_file, "party\n")
      assert Animation.get(start_animation(context, style: :calm)) == :calm
    end

    test "a damaged file falls back to the default style", context do
      File.mkdir_p!(Path.dirname(context.state_file))
      File.write!(context.state_file, "disco")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Animation.get(start_animation(context)) == :chase
        end)

      assert log =~ "unknown style"
    end

    test "a file that cannot be written never stops the button", context do
      # The parent "directory" is a regular file, so nothing can be created in it.
      File.write!(Path.join(context.tmp_dir, "state"), "")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          server = start_animation(context)
          assert Animation.cycle(server) == :party
          assert Animation.get(server) == :party
        end)

      assert log =~ "cannot save the style"
    end

    test "nothing is written without a state file", context do
      server = start_animation(context, state_file: nil)
      assert Animation.cycle(server) == :party
      refute File.exists?(context.state_file)
    end
  end

  test "next/1 follows the documented order" do
    assert Animation.styles() == [:calm, :waves, :chase, :party]
    assert Enum.map(Animation.styles(), &Animation.next/1) == [:waves, :chase, :party, :calm]
  end

  test "parse/1 maps strings to styles only" do
    assert Animation.parse("chase") == {:ok, :chase}
    assert Animation.parse("disco") == :error
    assert Animation.parse(:chase) == :error
  end

  test "the beat length comes from the configured tempo" do
    assert Animation.beat_ms() == 500
  end
end
