# Held HLS media

A synthetic 60-second HLS asset: one 320×180 H.264 video track and one AAC
440 Hz sine, in ten 6-second segments. It contains no third-party content and
was generated with FFmpeg:

```sh
ffmpeg -f lavfi -i "color=c=0x1a1a1e:s=320x180:r=1:d=60" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=60" \
  -map 0:v -map 1:a -c:v libx264 -preset veryfast -tune stillimage \
  -g 6 -keyint_min 6 -sc_threshold 0 -pix_fmt yuv420p -b:v 32k \
  -c:a aac -b:a 24k -f hls -hls_time 6 -hls_list_size 0 \
  -hls_playlist_type vod -hls_segment_filename "held-%03d.ts" held.m3u8
```

The harness media server serves it under `/held/<token>/<start|middle>/`.
`start` holds the first segment and `middle` the sixth, at 30 seconds: the server sends one
TS packet per second until `/release/<token>` arrives. The video wait journey
and board captures stream it with `PUTIO_HARNESS_HELD_STREAM=<start|middle>:<token>`.
The Tuist app target copies the directory only into Debug builds.
