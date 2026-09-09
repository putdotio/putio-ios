# Runtime-proof audio media

`runtime-proof-audio.m4a` is a synthetic 4-second 440 Hz sine tone generated
with FFmpeg. It contains no third-party content:

```sh
ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 4 \
  -c:a aac -b:a 32k -movflags +faststart runtime-proof-audio.m4a
```

The short duration lets the audio journey reach end-of-item deterministically.
The Tuist app target copies the file only into Debug builds.
