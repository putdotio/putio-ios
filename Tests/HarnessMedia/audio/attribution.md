# Runtime-proof audio media

`runtime-proof-audio.m4a` is a synthetic 20-second 440 Hz sine tone generated
with FFmpeg. It contains no third-party content:

```sh
ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 20 \
  -c:a aac -b:a 32k -movflags +faststart runtime-proof-audio.m4a
```

The journey scrubs near the end so the item finishes on cue.
The Tuist app target copies the file only into Debug builds.
