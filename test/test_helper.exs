# The end-to-end test of the native analyser needs the binary, which is built
# on the machine that runs it and never committed. Build it with
# `make -C native/jukebox_audio_analyzer build/jukebox_audio_analyzer build/pcm_gen`
# to include that test; without it the test is skipped.
native_build = Path.expand("../native/jukebox_audio_analyzer/build", __DIR__)

native_built? =
  Enum.all?(["jukebox_audio_analyzer", "pcm_gen"], &File.exists?(Path.join(native_build, &1)))

# The tests of the two Python programs (power controller, input helper) need
# a Python 3 interpreter; without one they are skipped.
python? = System.find_executable("python3") != nil

excluded =
  if(native_built?, do: [], else: [:native_analyzer]) ++ if(python?, do: [], else: [:python])

# The hardware tests start real helper processes while the Python suites run
# beside them; on a busy machine a message can take longer than ExUnit's
# default 100 ms to arrive. This is only the longest an `assert_receive` waits.
ExUnit.start(exclude: excluded, assert_receive_timeout: 1_000)
