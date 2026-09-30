# Runtime-proof audio media

`runtime-proof-audio.m4a` is a synthetic 60-second 440 Hz sine tone generated
with FFmpeg. It contains no third-party content:

```sh
ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 60 \
  -c:a aac -b:a 32k -movflags +faststart runtime-proof-audio.m4a
```

The journey scrubs near the end so the item finishes on cue. The length leaves
headroom for its playing steps on a loaded host; a shorter item can finish
before the journey pauses or scrubs it.
The Tuist app target copies the file only into Debug builds.
