# The end-to-end test of the native analyser needs the binary, which is built
# on the machine that runs it and never committed. Build it with
# `make -C native/jukebox_audio_analyzer build/jukebox_audio_analyzer build/pcm_gen`
# to include that test; without it the test is skipped.
native_build = Path.expand("../native/jukebox_audio_analyzer/build", __DIR__)

native_built? =
  Enum.all?(["jukebox_audio_analyzer", "pcm_gen"], &File.exists?(Path.join(native_build, &1)))

ExUnit.start(exclude: if(native_built?, do: [], else: [:native_analyzer]))
