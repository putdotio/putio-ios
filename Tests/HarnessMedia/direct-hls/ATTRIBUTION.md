# Runtime-proof HLS media

`runtime-proof-000.ts` is a visually static Big Buck Bunny clip, © 2008 Blender
Foundation, licensed under Creative Commons Attribution 3.0.

Source: <https://archive.org/details/BigBuckBunny>

The fixture is a remux of the repository's historical deterministic E2E asset,
`Putio/E2EMedia/big-buck-bunny.mp4`, introduced in commit `076b8d0`. The source
MP4 is a 590-second, 1 fps H.264 clip. It was remuxed without re-encoding:

```sh
ffmpeg -i big-buck-bunny.mp4 -map 0:v:0 -c copy -f hls \
  -hls_time 600 -hls_list_size 0 \
  -hls_segment_filename 'runtime-proof-%03d.ts' runtime-proof.m3u8
```

The frames are visually stable, with minor pixel-level codec drift. The
590-second duration prevents playback from ending during capture while keeping
proof deterministic. The Tuist app target copies these files only into Debug
builds; distributed builds remove the fixture directory.
