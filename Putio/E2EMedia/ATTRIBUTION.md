# E2E media attribution

## big-buck-bunny.mp4

A single frame of **Big Buck Bunny**, © 2008 Blender Foundation,
<https://peach.blender.org>.

Licensed under the [Creative Commons Attribution 3.0 license](https://creativecommons.org/licenses/by/3.0/).

Source: <https://archive.org/details/BigBuckBunny> (`big_buck_bunny_480p_h264.mov`).
The frame at 00:47 was extracted and encoded as a 9:50 854x480 H.264 clip at
1 fps without audio.

## Why it is here

The mocked e2e suite plays a local asset rather than streaming, so playback is
hermetic and the walk's screenshots are deterministic. This clip is what the
video player shows in those captures, including the App Store screenshot in
slot 2.

It is a **still frame held for the whole duration**, not moving footage, and that
is deliberate. With real motion, a half-second of timing drift between a
maintainer's Mac and CI decodes an entirely different frame and fails the pixel
comparison — intermittently, which is worse than failing outright. Holding one
frame means only the timestamp and scrubber move, which the snapshot tolerance
absorbs.

Every frame is identical at the source, so x264 encodes them as skips: 590
seconds costs 314 KB. `aq-mode=0` matters here — adaptive quantization varies
the residual frame to frame and quadruples the file for no visible gain.

9:50 rather than a few seconds for two reasons. A short clip finishes before the
capture and the player shows a full scrubber and a replay button, reading as a
finished video rather than a playing one. And the duration is on screen: a
listing image whose scrubber reads `-0:09` advertises a nine-second video.

It is bundled only when `PUTIO_BUNDLE_E2E_MEDIA` is `YES`, which is set in
`Config/Verify.xcconfig` and nowhere else — so it reaches test builds and never
a distributed one.

The fixture library elsewhere in the e2e mocks uses the same Blender open
content — Sintel, Tears of Steel, Elephants Dream, Cosmos Laundromat,
Caminandes — so the listing and the gallery tell one consistent story.
