# Playback

A signed-in user plays video and audio from Files, resumes where they stopped,
chooses subtitles and audio tracks, casts to a receiver, and downloads video for
offline playback.

## Sub-features

- `walk` signs in, recovers a failed video load, plays to the end, autoplays
  the next episode at its saved position, and signs out. This is the recorded
  walk.
- `resume` keeps the playback position across reopening a file.
- `audio` plays, pauses, changes speed, and advances to the next track.
- `subtitles` picks subtitles from the system menu without changing audio, and
  follows the preferences.
- `playback-preferences` saves proxy, subtitle, and autoplay settings, retries a
  failed save, and keeps them across relaunch.
- `cast` connects, controls the session, switches subtitles, and syncs the
  position back.
- `downloads` picks audio tracks, queues, plays offline, syncs the position, and
  removes the download.
- `unsaved-downloads` reports a download that finished outside Downloads.
- `large-text-audio` keeps the audio controls usable at the largest text size
  in portrait and landscape.

## How to get to it (user POV)

- Files tab: tap a video or audio row.
- Long-press a video row and choose Download; the Downloads tab lists it.
- Account: playback preferences and Cast settings.
- The player's system menus for subtitles and audio.

## Driving it with the harness

Preconditions:

- Seeded `files-browser` fixtures and the harness's loopback media server.
  `Root Movie.mkv` (412) is watched to 589 s and starts with an invalid stream.

- **Walk.** Run the full journey without `--only`. Screenshots:
  `runtime-sign-in`, `runtime-playback`, `runtime-signed-out`, plus
  `runtime-proof-walk.mp4`.
- **Resume.** Run `--only resume-persistence`.
- **Audio.** Run `--only audio`. Screenshot: `runtime-audio-player`.
- **Subtitles.** Run `--only subtitles`. Screenshots: `runtime-subtitles-menu`,
  `runtime-subtitles-selected`.
- **Preferences.** Run `--only playback-preferences`. Screenshot:
  `runtime-playback-preferences`.
- **Cast.** Run `--only cast`. Screenshots: `runtime-cast-settings`,
  `runtime-cast-error`, `runtime-cast-controls`, `runtime-cast-signed-out`.
- **Downloads.** Run `--only downloads,unsaved-downloads`. Screenshots:
  `runtime-downloads-picker`, `runtime-downloads-queue`,
  `runtime-downloads-detail`, `runtime-downloads-remove`.
- **Large text.** Run `--only accessibility-audio`. Screenshots:
  `runtime-accessibility-audio-portrait`, `runtime-accessibility-audio-landscape`,
  and their `-controls` variants.

## Gotchas

- Cast uses a stub receiver. It cannot prove a physical Chromecast.
- Slider dragging does not prove VoiceOver gestures or spoken output.
- A failed audio preflight saves audio error codes in `.audio.audio.log` beside
  its bundle.
