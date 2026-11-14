# Playback

A signed-in user plays video and audio from Files, resumes where they stopped,
chooses subtitles and audio tracks, casts to a receiver, and downloads video for
offline playback.

## Sub-features

- `walk` signs in, recovers a failed video load, plays to the end, autoplays
  the next episode at its saved position, and signs out. This is the recorded
  walk.
- `resume` asks Resume or Start over for a partly watched video, before the
  player or after a conversion, skips, pauses, scrubs, hides and shows the
  controls, and keeps the position across Close and reopening a file.
- `audio` plays, pauses, skips 10 seconds, changes speed, moves to the previous
  and next file in the folder, retries a failed load, plays a one-file folder,
  and plays from the Up next list while its mark follows playback. The mini
  player stays across tabs and folders, keeps the last row above it, and Stop
  playback saves the position and removes it.
- `subtitles` picks subtitles from the player menu without changing audio, and
  follows the preferences.
- `playback-preferences` saves proxy, subtitle, and autoplay settings, retries a
  failed save, and keeps them across relaunch.
- `resume-setting` asks before turning resume off, reverts a failed save, and
  plays a saved video from zero in portrait with Rotate off.
- `playback-method` reverts a failed Direct play save, applies it on the next
  tap, and keeps it across relaunch.
- `proxy` waits on a slow proxy list and keeps the checked proxy when put.io
  refuses the tapped one.
- `cast` connects, controls the session, switches subtitles, and syncs the
  position back.
- `downloads` picks audio tracks, queues, plays offline, syncs the position, and
  removes the download.
- `unsaved-downloads` reports a download that finished outside Downloads.
- `download-start-failed` reports a download that put.io refuses to start.
- `large-text-audio` keeps the audio controls usable at the largest text size
  in portrait and landscape.

## How to get to it (user POV)

- Files tab: tap a video or audio row.
- Long-press a video row and choose Download; the Downloads tab lists it.
- Account: playback preferences and Cast settings.
- The player menu for audio, subtitles, and speed.

## Driving it with the harness

Preconditions:

- Seeded `files-browser` fixtures and the harness's loopback media server.
  `Root Movie.mkv` (412) starts with an invalid stream; its saved position is
  in [`HarnessSeededAPI`](../../../../Apps/Shared/Sources/Harness/HarnessSeededAPI.swift).

- **Walk.** Run the full journey without `--only`. Screenshots:
  `runtime-sign-in`, `runtime-playback`, `runtime-signed-out`, plus
  `runtime-proof-walk.mp4`.
- **Resume and transport.** Run `--only resume-persistence`. Screenshots:
  `runtime-resume-prompt`, `runtime-video-controls`,
  `runtime-video-controls-hidden`. `--only resume-setting` covers a video with
  no saved position and resume off. Board: `rd-ios-pb-01-resume`.
- **Audio.** Run `--only audio`. Screenshots: `runtime-audio-player`,
  `runtime-audio-error`, `runtime-audio-single`, `runtime-audio-up-next`.
  `--putio-harness-music` seeds a Music folder of four tracks and a one-file
  folder under Singles; `--putio-harness-audio-fails-once` and
  `--putio-harness-audio-held` fail or hold the second track's first load, and
  `--putio-harness-audio-near-end` starts the third track 10 seconds before its
  end. Boards: `rd-ios-pb-04-now-playing`, `rd-ios-pb-12-up-next`,
  `rd-ios-pb-25-preparing-audio`, `rd-ios-pb-37-audio-error`,
  `rd-ios-pb-39-single-audio`, `rd-ios-pb-40-ipad-now-playing`,
  `rd-ios-pb-05-mini`, `rd-ios-pb-41-ipad-mini`.
- **Subtitles.** Run `--only subtitles`. Screenshots: `runtime-subtitles-menu`,
  `runtime-subtitles-selected`.
- **Preferences.** Run `--only playback-preferences`. Screenshot:
  `runtime-playback-preferences`.
- **Resume setting.** Run `--only resume-setting`. Screenshot:
  `runtime-resume-off-confirm`.
- **Playback method.** Run `--only playback-method`. Screenshot:
  `runtime-playback-method`.
- **Proxy.** Run `--only proxy`. Screenshot: `runtime-proxy-refused`.
  `--putio-harness-proxy ready|slow|refused` seeds the proxy list with the
  account on `cdn77`; `slow` holds the list for 6 s and `refused` answers every
  proxy save with `UNAVAILABLE_VALUE`. Boards: `rd-ios-acc-07-proxy`,
  `rd-ios-acc-31-proxy-loading`, `rd-ios-acc-32-proxy-failed`,
  `rd-ios-acc-33-proxy-unavailable`.
- **Cast.** Run `--only cast`. Screenshots: `runtime-cast-settings`,
  `runtime-cast-error`, `runtime-cast-controls`, `runtime-cast-signed-out`.
- **Downloads.** Run `--only downloads,unsaved-downloads,download-start-failed`.
  Screenshots: `runtime-downloads-picker`, `runtime-downloads-queue`,
  `runtime-downloads-detail`, `runtime-downloads-selection`,
  `runtime-downloads-remove`, `runtime-downloads-start-failed`.
- **Large text.** Run `--only accessibility-audio`. Screenshots:
  `runtime-accessibility-audio-portrait`, `runtime-accessibility-audio-landscape`,
  and their `-controls` variants.

## Gotchas

- Cast uses a stub receiver. It cannot prove a physical Chromecast.
- Slider dragging does not prove VoiceOver gestures or spoken output.
- A failed audio preflight saves audio error codes in `.audio.audio.log` beside
  its bundle.
