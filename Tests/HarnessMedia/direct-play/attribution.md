# Runtime-proof Direct play media

`runtime-proof-direct.mkv` is a synthetic 30-second Matroska file for the
Direct play journey. It contains no third-party content:

- Video: 320×180 H.264 at 1 fps, a keyframe every 2 seconds.
- Audio 1: AAC stereo, `eng`, "English", default (440 Hz sine).
- Audio 2: E-AC-3 5.1, `tur`, "Turkish" (660 Hz sine).
- Subtitle: embedded SRT, `eng`, one cue from 1 to 29 seconds.

AVPlayer can't open the container, so the file plays only through the Direct
play engine. It was generated with FFmpeg:

```sh
printf '1\n00:00:01,000 --> 00:00:29,000\nDirect play subtitle\n' > en.srt
ffmpeg -f lavfi -i "color=c=0x1a1a1e:s=320x180:r=1:d=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=30" \
  -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=30" \
  -i en.srt \
  -filter_complex "[1:a]pan=stereo|FL=c0|FR=c0[st];[2:a]pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0[s]" \
  -map 0:v -map "[st]" -map "[s]" -map 3:s \
  -c:v libx264 -preset veryfast -tune stillimage -g 2 -pix_fmt yuv420p -b:v 48k \
  -c:a:0 aac -b:a:0 32k -c:a:1 eac3 -b:a:1 96k -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title=English \
  -metadata:s:a:1 language=tur -metadata:s:a:1 title=Turkish \
  -metadata:s:s:0 language=eng \
  -disposition:v:0 default -disposition:a:0 default -disposition:a:1 0 \
  runtime-proof-direct.mkv
```

Nothing copies it into the app yet; the Direct play journey adds it to the
Debug-only harness media.
