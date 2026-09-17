defmodule Jukebox.Shairport.DecoderTest do
  use ExUnit.Case, async: true

  alias Jukebox.Shairport.Decoder

  describe "parsed topics" do
    test "session and playback markers" do
      assert Decoder.decode(["active_start"], "") == {:ok, [{:session_started, %{}}]}

      assert Decoder.decode(["active_end"], "") ==
               {:ok, [{:session_ended, %{reason: :sender_disconnected}}]}

      assert Decoder.decode(["play_start"], "") == {:ok, [{:playback_changed, :playing}]}
      assert Decoder.decode(["play_resume"], "") == {:ok, [{:playback_changed, :playing}]}
      assert Decoder.decode(["play_flush"], "") == {:ok, [{:playback_changed, :paused}]}
      assert Decoder.decode(["play_end"], "") == {:ok, [{:playback_changed, :stopped}]}
    end

    test "text metadata is passed through as partial metadata" do
      assert Decoder.decode(["title"], "Instant Crush") ==
               {:ok, [{:metadata_changed, %{title: "Instant Crush"}}]}

      assert Decoder.decode(["artist"], "Daft Punk") ==
               {:ok, [{:metadata_changed, %{artist: "Daft Punk"}}]}

      assert Decoder.decode(["album"], "RAM") == {:ok, [{:metadata_changed, %{album: "RAM"}}]}

      assert Decoder.decode(["genre"], "Electronic") ==
               {:ok, [{:metadata_changed, %{genre: "Electronic"}}]}
    end

    test "source device name and model" do
      assert Decoder.decode(["client_name"], "Fabien's iPhone") ==
               {:ok, [{:source_changed, %{source_name: "Fabien's iPhone"}}]}

      assert Decoder.decode(["client_model"], "iPhone14,2") ==
               {:ok, [{:source_changed, %{source_model: "iPhone14,2"}}]}
    end

    test "volume converts the AirPlay -30..0 range into a percentage" do
      assert Decoder.decode(["volume"], "-15.00,-25.50,-96.30,0.00") ==
               {:ok, [{:volume_changed, 50.0}]}

      assert Decoder.decode(["volume"], "0.00,0.00,-96.30,0.00") ==
               {:ok, [{:volume_changed, 100.0}]}

      assert Decoder.decode(["volume"], "-30.00,-96.30,-96.30,0.00") ==
               {:ok, [{:volume_changed, 0.0}]}

      assert Decoder.decode(["volume"], "-144.00,-96.30,-96.30,0.00") ==
               {:ok, [{:volume_changed, 0.0}]}
    end

    test "progress converts RTP frames at 44.1 kHz into milliseconds" do
      assert {:ok, [{:progress_changed, %{position_ms: 1_000, duration_ms: 60_000}}]} =
               Decoder.decode(["progress"], "100000/144100/2746000")
    end

    test "progress without a usable end omits the duration" do
      assert {:ok, [{:progress_changed, attrs}]} = Decoder.decode(["progress"], "100/44200/100")
      assert attrs == %{position_ms: 1_000}
    end

    test "progress survives RTP timestamp wrap-around" do
      start = 4_294_960_000
      current = 4_100
      finish = 433_704

      assert {:ok, [{:progress_changed, %{position_ms: pos, duration_ms: 10_000}}]} =
               Decoder.decode(["progress"], "#{start}/#{current}/#{finish}")

      assert_in_delta pos, 258, 2
    end

    test "cover art becomes a binary artwork event; empty cover clears" do
      assert Decoder.decode(["cover"], <<0xFF, 0xD8, 0xFF, 1, 2>>) ==
               {:ok, [{:artwork_binary, <<0xFF, 0xD8, 0xFF, 1, 2>>}]}

      assert Decoder.decode(["cover"], "") == {:ok, [{:artwork_changed, nil}]}
    end

    test "known-but-irrelevant topics are ignored, unknown ones reported" do
      assert Decoder.decode(["client_ip"], "192.168.1.10") == {:ok, []}
      assert Decoder.decode(["remote"], "nextitem") == {:ok, []}
      assert Decoder.decode(["something", "deep"], "x") == :unknown
      assert Decoder.decode([], "x") == :unknown
    end
  end

  describe "raw topics" do
    test "core codes map to text metadata, duration and persistent ids" do
      assert Decoder.decode(["core", "minm"], "Title") ==
               {:ok, [{:metadata_changed, %{title: "Title"}}]}

      assert Decoder.decode(["core", "asar"], "Artist") ==
               {:ok, [{:metadata_changed, %{artist: "Artist"}}]}

      assert Decoder.decode(["core", "astm"], <<0, 3, 13, 64>>) ==
               {:ok, [{:progress_changed, %{duration_ms: 200_000}}]}

      assert Decoder.decode(["core", "astm"], "200000") ==
               {:ok, [{:progress_changed, %{duration_ms: 200_000}}]}

      assert Decoder.decode(["core", "mper"], <<0, 0, 0, 0, 0, 0, 0, 255>>) ==
               {:ok, [{:metadata_changed, %{track_id: "FF"}}]}

      assert Decoder.decode(["core", "mper"], "abc123") ==
               {:ok, [{:metadata_changed, %{track_id: "abc123"}}]}

      assert Decoder.decode(["core", "asdk"], "1") == {:ok, []}
    end

    test "ssnc codes map to playback markers, source, volume, progress, art and remote" do
      assert Decoder.decode(["ssnc", "pbeg"], "") == {:ok, [{:playback_changed, :playing}]}
      assert Decoder.decode(["ssnc", "pfls"], "") == {:ok, [{:playback_changed, :paused}]}
      assert Decoder.decode(["ssnc", "pend"], "") == {:ok, [{:playback_changed, :stopped}]}
      assert Decoder.decode(["ssnc", "abeg"], "") == {:ok, [{:session_started, %{}}]}

      assert Decoder.decode(["ssnc", "aend"], "") ==
               {:ok, [{:session_ended, %{reason: :sender_disconnected}}]}

      assert Decoder.decode(["ssnc", "snam"], "Phone") ==
               {:ok, [{:source_changed, %{source_name: "Phone"}}]}

      assert Decoder.decode(["ssnc", "pvol"], "-30,0,0,0") == {:ok, [{:volume_changed, 0.0}]}
      assert {:ok, [{:progress_changed, _}]} = Decoder.decode(["ssnc", "prgr"], "0/44100/88200")
      assert Decoder.decode(["ssnc", "PICT"], "PNGdata") == {:ok, [{:artwork_binary, "PNGdata"}]}

      assert Decoder.decode(["ssnc", "daid"], "123") ==
               {:ok, [{:remote_control_changed, :available}]}

      assert Decoder.decode(["ssnc", "clip"], "10.0.0.2") == {:ok, []}
    end
  end

  describe "malformed payloads" do
    test "never raise" do
      for topic <- [
            ["volume"],
            ["progress"],
            ["ssnc", "pvol"],
            ["ssnc", "prgr"],
            ["core", "astm"],
            ["core", "mper"]
          ],
          payload <- [
            "",
            "garbage",
            "1/2",
            "a,b,c",
            "-1/-2/-3",
            <<0xFF, 0xFE>>,
            "99999999999/1/2",
            String.duplicate("9", 40)
          ] do
        assert {:ok, events} = Decoder.decode(topic, payload)
        assert is_list(events)
      end
    end

    test "malformed numbers produce no event" do
      assert Decoder.decode(["volume"], "loud") == {:ok, []}
      assert Decoder.decode(["progress"], "1/2") == {:ok, []}
      assert Decoder.decode(["progress"], "a/b/c") == {:ok, []}
      assert Decoder.decode(["core", "astm"], "soon!") == {:ok, []}
      assert Decoder.decode(["core", "astm"], "abc") == {:ok, []}

      assert Decoder.decode(["core", "astm"], "1234") ==
               {:ok, [{:progress_changed, %{duration_ms: 1234}}]}

      assert Decoder.decode(["core", "astm"], <<0, 0, 0, 0>>) == {:ok, []}
      assert Decoder.decode(["core", "mper"], "   ") == {:ok, []}
    end

    test "invalid UTF-8 text is passed on for the reducer to sanitise" do
      assert {:ok, [{:metadata_changed, %{title: <<0xFF, "x">>}}]} =
               Decoder.decode(["title"], <<0xFF, "x">>)
    end
  end
end
