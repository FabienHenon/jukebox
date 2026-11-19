defmodule Jukebox.AudioAnalysis.FrameTest do
  use ExUnit.Case, async: true

  alias Jukebox.AudioAnalysis.Frame

  @valid ~s({"level":0.42,"bass":0.71,"onset":0.83,"beat_id":127,"bpm":118.4,"confidence":0.76})

  defp payload(overrides) do
    @valid |> Jason.decode!() |> Map.merge(overrides) |> Jason.encode!()
  end

  describe "decode/1" do
    test "decodes the native protocol" do
      assert Frame.decode(@valid) ==
               {:ok,
                %Frame{
                  level: 0.42,
                  bass: 0.71,
                  onset: 0.83,
                  beat_id: 127,
                  bpm: 118.4,
                  confidence: 0.76
                }}
    end

    test "accepts integers where the analyser prints whole numbers, and ignores extra fields" do
      assert {:ok, frame} =
               Frame.decode(
                 ~s({"level":1,"bass":0,"onset":0,"beat_id":0,"bpm":120,"confidence":1,"extra":true})
               )

      assert frame.level === 1.0
      assert frame.bass === 0.0
      assert frame.bpm === 120.0
      assert frame.confidence === 1.0
    end

    test "rejects malformed JSON" do
      assert Frame.decode("") == {:error, :invalid_json}
      assert Frame.decode("not json") == {:error, :invalid_json}
      assert Frame.decode(~s({"level":0.4,)) == {:error, :invalid_json}
      assert Frame.decode(<<255, 254, 0, 1>>) == {:error, :invalid_json}
      assert Frame.decode(:not_a_binary) == {:error, :invalid_json}
    end

    test "rejects JSON that is not an object" do
      assert Frame.decode("[1,2,3]") == {:error, :not_an_object}
      assert Frame.decode("42") == {:error, :not_an_object}
      assert Frame.decode("null") == {:error, :not_an_object}
    end

    test "rejects a payload with a missing field" do
      for field <- ~w(level bass onset beat_id bpm confidence) do
        json = @valid |> Jason.decode!() |> Map.delete(field) |> Jason.encode!()
        assert Frame.decode(json) == {:error, {:missing, String.to_existing_atom(field)}}
      end
    end

    test "clamps normalised values to 0..1" do
      assert {:ok, frame} =
               Frame.decode(
                 payload(%{"level" => 1.7, "bass" => -0.2, "onset" => 250, "confidence" => -3})
               )

      assert frame.level == 1.0
      assert frame.bass == 0.0
      assert frame.onset == 1.0
      assert frame.confidence == 0.0
    end

    test "rejects values that are not numbers" do
      assert Frame.decode(payload(%{"level" => "0.4"})) == {:error, {:invalid, :level}}
      assert Frame.decode(payload(%{"bass" => nil})) == {:error, {:invalid, :bass}}
      assert Frame.decode(payload(%{"onset" => true})) == {:error, {:invalid, :onset}}
      assert Frame.decode(payload(%{"confidence" => [1]})) == {:error, {:invalid, :confidence}}
    end

    test "rejects NaN, infinity and numbers too large to be a float" do
      for token <- ["NaN", "Infinity", "-Infinity", "1e999", "-1e999", "nan", "inf"] do
        json = String.replace(@valid, "0.42", token)
        assert Frame.decode(json) == {:error, :invalid_json}, "accepted #{token}"
      end
    end

    test "the beat counter must be a non-negative integer" do
      assert {:ok, %Frame{beat_id: 0}} = Frame.decode(payload(%{"beat_id" => 0}))
      assert Frame.decode(payload(%{"beat_id" => -1})) == {:error, {:invalid, :beat_id}}
      assert Frame.decode(payload(%{"beat_id" => 1.5})) == {:error, {:invalid, :beat_id}}
      assert Frame.decode(payload(%{"beat_id" => "12"})) == {:error, {:invalid, :beat_id}}

      assert Frame.decode(payload(%{"beat_id" => 10 ** 30})) == {:error, {:invalid, :beat_id}}
    end

    test "no tempo yet is null or zero; an implausible tempo counts as none" do
      assert {:ok, %Frame{bpm: nil}} = Frame.decode(payload(%{"bpm" => nil}))
      assert {:ok, %Frame{bpm: nil}} = Frame.decode(payload(%{"bpm" => 0}))
      assert {:ok, %Frame{bpm: nil}} = Frame.decode(payload(%{"bpm" => 0.0}))
      assert {:ok, %Frame{bpm: nil}} = Frame.decode(payload(%{"bpm" => 12}))
      assert {:ok, %Frame{bpm: nil}} = Frame.decode(payload(%{"bpm" => 999.0}))
      assert {:ok, %Frame{bpm: 30.0}} = Frame.decode(payload(%{"bpm" => 30}))
      assert {:ok, %Frame{bpm: 300.0}} = Frame.decode(payload(%{"bpm" => 300}))
      assert Frame.decode(payload(%{"bpm" => -120})) == {:error, {:invalid, :bpm}}
      assert Frame.decode(payload(%{"bpm" => "fast"})) == {:error, {:invalid, :bpm}}
    end

    test "rejects oversized payloads without parsing them" do
      padding = String.duplicate(" ", 600)
      assert Frame.decode(@valid <> padding) == {:error, :too_large}
    end
  end

  describe "new/1" do
    test "accepts atom keys" do
      assert {:ok, %Frame{level: 0.5, bpm: nil, beat_id: 3}} =
               Frame.new(%{
                 level: 0.5,
                 bass: 0.1,
                 onset: 0,
                 beat_id: 3,
                 bpm: nil,
                 confidence: 0.2
               })
    end

    test "rejects anything that is not a map" do
      assert Frame.new(level: 1) == {:error, :not_an_object}
    end
  end

  test "to_payload/1 is the compact map sent to the browser" do
    {:ok, frame} =
      Frame.new(%{
        level: 0.123456,
        bass: 0.98765,
        onset: 0.5,
        beat_id: 9,
        bpm: 118.449,
        confidence: 0.33333
      })

    assert Frame.to_payload(frame) == %{
             level: 0.123,
             bass: 0.988,
             onset: 0.5,
             beat_id: 9,
             bpm: 118.4,
             confidence: 0.333
           }

    assert Frame.to_payload(%{frame | bpm: nil}).bpm == nil
    assert {:ok, _json} = Jason.encode(Frame.to_payload(frame))
  end
end
