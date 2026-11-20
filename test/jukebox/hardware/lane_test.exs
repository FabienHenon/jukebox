defmodule Jukebox.Hardware.LaneTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Jukebox.Hardware.Lane

  defp lane(opts \\ []), do: start_supervised!({Lane, opts})

  # A job that tells the test it started and waits to be released.
  defp held(test, name) do
    fn ->
      send(test, {:started, name, self()})

      receive do
        :release -> name
      end
    end
  end

  test "jobs run one at a time, in order" do
    test = self()
    lane = lane()

    Lane.submit(lane, held(test, :first), reply_to: {test, :first})
    Lane.submit(lane, fn -> send(test, {:ran, :second}) end, reply_to: {test, :second})

    assert_receive {:started, :first, pid}
    refute_receive {:ran, :second}, 50
    assert %{running?: true, queued: 1} = Lane.status(lane)

    send(pid, :release)
    assert_receive {:first, {:done, :first}}
    assert_receive {:ran, :second}
    assert_receive {:second, {:done, _}}
  end

  test "beyond its bound the queue drops new jobs instead of growing" do
    test = self()
    lane = lane(max_queue: 2)

    Lane.submit(lane, held(test, :running))
    assert_receive {:started, :running, pid}

    for n <- 1..5, do: Lane.submit(lane, fn -> send(test, {:ran, n}) end, reply_to: {test, n})

    for n <- 3..5, do: assert_receive({^n, {:dropped, :overflow}})
    assert %{queued: 2, dropped: 3} = Lane.status(lane)

    send(pid, :release)
    assert_receive {:ran, 1}
    assert_receive {:ran, 2}
    refute_receive {:ran, _}, 50
  end

  test "a job that waited too long is dropped, not run late" do
    test = self()
    lane = lane(ttl_ms: 40)

    Lane.submit(lane, held(test, :slow))
    assert_receive {:started, :slow, pid}
    Lane.submit(lane, fn -> send(test, :stale_ran) end, reply_to: {test, :stale})

    Process.sleep(80)
    send(pid, :release)

    assert_receive {:stale, {:dropped, :expired}}
    refute_receive :stale_ran, 50
    assert %{expired: 1} = Lane.status(lane)

    # The lane itself is fine: a fresh job runs.
    Lane.submit(lane, fn -> send(test, :fresh_ran) end)
    assert_receive :fresh_ran
  end

  test "a failing job is reported and does not stop the lane" do
    test = self()
    lane = lane()

    log =
      capture_log(fn ->
        Lane.submit(lane, fn -> raise "boom" end, reply_to: {test, :bad})
        assert_receive {:bad, {:failed, _reason}}
      end)

    assert log =~ "queued action failed"
    Lane.submit(lane, fn -> :ok end, reply_to: {test, :good})
    assert_receive {:good, {:done, :ok}}
    assert %{failed: 1, completed: 1} = Lane.status(lane)
  end

  test "a job that never ends is stopped at its deadline" do
    test = self()
    lane = lane(job_timeout_ms: 40)

    Lane.submit(lane, held(test, :stuck), reply_to: {test, :stuck})
    assert_receive {:started, :stuck, pid}
    ref = Process.monitor(pid)

    assert_receive {:stuck, {:failed, :timeout}}, 500
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500

    Lane.submit(lane, fn -> :ok end, reply_to: {test, :next})
    assert_receive {:next, {:done, :ok}}
  end

  test "submitting to a lane that is not running fails quietly" do
    assert Lane.submit(:no_such_lane, fn -> :ok end, reply_to: {self(), :orphan}) == :ok
    assert_receive {:orphan, {:failed, :not_running}}
    assert Lane.status(:no_such_lane) == {:error, :not_running}
  end
end
