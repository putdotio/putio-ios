# Runtime-proof multi-audio HLS media

A synthetic 20-second HLS asset with one 320×180 H.264 video rendition and
two AAC audio renditions tagged `eng` (440 Hz sine) and `tur` (660 Hz sine).
It contains no third-party content and was generated with FFmpeg:

```sh
ffmpeg -f lavfi -i "color=c=0x1a1a1e:s=320x180:r=1:d=20" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=20" \
  -f lavfi -i "sine=frequency=660:sample_rate=44100:duration=20" \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -preset veryfast -tune stillimage \
  -g 20 -pix_fmt yuv420p -b:v 48k -c:a aac -b:a 32k \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=tur \
  -f hls -hls_time 10 -hls_list_size 0 -hls_playlist_type vod \
  -master_pl_name runtime-proof-multi.m3u8 \
  -var_stream_map "a:0,agroup:aud,language:eng,name:English,default:yes a:1,agroup:aud,language:tur,name:Turkish v:0,agroup:aud" \
  -hls_segment_filename "multi-%v-%03d.ts" "multi-%v.m3u8"
```

The video rendition was renamed from `multi-2` to `multi-video` and the audio
rendition names set to `English` and `Turkish` afterwards. The harness media
server serves every file in this directory; the downloads journey fetches the
master playlist through `AVAssetDownloadURLSession`. The Tuist app target
copies the directory only into Debug builds.

The WebVTT subtitle renditions are hand-written text: one cue per rendition
(`multi-subtitle-English.vtt`, `multi-subtitle-Spanish.vtt`,
`multi-subtitle-Turkish.vtt`) spanning the 20 seconds, each in a one-segment
playlist. `X-TIMESTAMP-MAP=MPEGTS:126000` matches
the audio segments' first PTS. The `multi-subtitles*.m3u8` masters reuse the
renditions above in the shapes put.io's HLS endpoint serves for
`subtitle_key=all`:

- `multi-subtitles.m3u8`: English `DEFAULT=YES,AUTOSELECT=YES`, Turkish off.
- `multi-subtitles-unselected.m3u8`: both off, for "Do not select subtitles by
  default".
- `multi-subtitles-hidden.m3u8`: no subtitle renditions, for "Show subtitles"
  off.
- `multi-subtitles-autoselect-audio.m3u8`: `multi-subtitles.m3u8` with both
  audio renditions `AUTOSELECT=YES`, so automatic selection may pick either by
  the viewer's language.
- `multi-subtitles-one.m3u8`: English alone.
- `multi-subtitles-three.m3u8`: English, Spanish and Turkish. AVFoundation
  keeps only the first of two renditions that share a language and name, as
  put.io names them, so the three tracks use three languages.
- `multi-subtitles-failing.m3u8`: English; Turkish, whose playlist the
  server does not have; and German, whose playlist names a segment the server
  does not have. Selecting either fails with a 404.
- `multi-subtitles-timed.m3u8`: English from `multi-subtitle-Timed.vtt`, five
  cues of 4 seconds each ("First line" to "Fifth line"), for cue timing.

These masters declare `CLOSED-CAPTIONS=NONE`, as put.io does. The subtitles
journey streams them with `--putio-harness-subtitled-stream`, and
`--putio-harness-subtitle-tracks none|one|three|failing|timed` picks the hidden,
one, three, failing or timed master.

The audio menu journey streams two more masters with
`--putio-harness-audio-tracks`: `multi-audio-one.m3u8` keeps only the English
audio rendition, and `multi-audio-failing.m3u8` points the Turkish rendition
at a playlist that does not exist, so switching to it fails.

AVPlayer pauses an HLS video above 2× unless the master lists an I-frame
playlist, as put.io's HLS does. `multi-audio-speed.m3u8`
(`--putio-harness-audio-tracks fast-forward`) pairs the audio renditions with
`multi-fast-video.m3u8`, the video re-encoded with a keyframe every 2 seconds,
and lists its segments again as `multi-fast-iframes.m3u8`:

```sh
ffmpeg -i multi-video-000.ts -map 0:v -c:v libx264 -preset veryfast \
  -tune stillimage -g 2 -pix_fmt yuv420p -b:v 48k -f hls -hls_time 4 \
  -hls_playlist_type vod -hls_segment_filename "multi-fast-video-%03d.ts" \
  multi-fast-video.m3u8
```
