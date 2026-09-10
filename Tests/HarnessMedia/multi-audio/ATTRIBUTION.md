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
