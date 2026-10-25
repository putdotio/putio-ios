# E2E media attribution

## big-buck-bunny.mp4

A single frame of **Big Buck Bunny**, © 2008 Blender Foundation,
<https://peach.blender.org>.

Licensed under the [Creative Commons Attribution 3.0 license](https://creativecommons.org/licenses/by/3.0/).

Source: <https://archive.org/details/BigBuckBunny> (`big_buck_bunny_480p_h264.mov`).
The frame at 00:47 was encoded as a 9:50 854x480 H.264 clip at 1 fps without
audio.

## Why it looks like this

The mocked e2e suite plays this local clip, so playback is hermetic and the
walk's screenshots, including App Store slot 2, are deterministic.

- **One still frame for the whole clip.** With real motion, half a second of
  timing drift between a Mac and CI decodes a different frame and fails the
  pixel comparison intermittently. With one frame, only the timestamp and
  scrubber move, and the snapshot tolerance absorbs them.
- **`aq-mode=0`.** Identical frames encode as skips. Adaptive quantization
  varies the residual frame to frame and quadruples the file for no visible
  gain.
- **9:50 long.** A short clip ends before the capture and shows a replay
  button, and the scrubber would advertise a nine-second video in the listing.

`PUTIO_BUNDLE_E2E_MEDIA = YES` is set only in `Config/Verify.xcconfig`, so the
clip reaches test builds and never a distributed one.

The other e2e fixtures use the same Blender open content (Sintel, Tears of
Steel, Elephants Dream, Cosmos Laundromat, Caminandes), so the listing and the
gallery tell one story.
