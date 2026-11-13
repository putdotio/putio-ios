# Playback

A signed-in user plays video and audio from Files, resumes where they stopped,
chooses subtitles and audio tracks, casts to a receiver, and downloads video for
offline playback.

## Sub-features

- `video-wait` shows Preparing video, buffering, the 10-second label and the
  30-second stall, recovers on its own, and leaves or reloads from the stall.
- `walk` signs in, recovers a failed video load, plays to the end, autoplays
  the next episode at its saved position, and signs out. This is the recorded
  walk.
- `resume` asks Resume or Start over for a partly watched video, before the
  player or after a conversion, skips, pauses, scrubs, hides and shows the
  controls, and keeps the position across Close and reopening a file.
- `video-errors` shows the expired-access and Connection lost states, keeps Close
  and the file name, and Try again plays at the saved position after one silent
  refetch of a 403.
- `conversion-gate`, `conversion-completed`, `conversion-failed`,
  `conversion-unavailable` and `conversion-status` walk the conversion gate:
  Cancel and reopen, Open in VLC, play on completion, Convert again, Can’t play
  this file, and a lost status check.
- `audio` plays, pauses, skips 10 seconds, changes speed, moves to the previous
  and next file in the folder, retries a failed load, plays a one-file folder,
  plays from the Up next list while its mark follows playback, and pauses when
  the sleep timer runs out. The mini player stays across tabs and folders, keeps
  the last row above it, and Stop playback saves the position, removes it, and
  cancels the sleep timer.
- `subtitles` picks subtitles from the player chips without changing audio, and
  follows the preferences.
- `subtitle-menu` groups the Subtitles menu by source for zero, one and three
  tracks, remembers the last language, and turns a track that fails to load
  off with a toast while playback continues.
- `subtitle-size-timing` keeps playing while Size and timing is open, grows
  the caption at Extra large, shows a cue 0.5 s later and earlier, resets, and
  keeps the size but not the timing for the next file.
- `video-chips` shows each chip's choice, keeps the controls up while a chip
  menu is open, and puts Picture in Picture first in the route group.
- `direct-play` plays a Matroska original in the Direct play engine from the
  file menu on Standard, keeps a plain tap on HLS, follows the setting, then
  seeks, switches to the E-AC-3 track and resumes on Direct play.
- `audio-speed` switches English to Turkish from the Audio chip and keeps 2.5×
  on the next file and after a relaunch. `speed-landscape` scrolls the speed
  menu to 4× in landscape. `audio-tracks` disables the Audio chip with one track
  and keeps English when the switch to Turkish fails.
- `direct-play-fallback` and `direct-play-cant-play` fail an original before
  its first frame: it plays converted at the same position and starts converted
  on the next play, or, with no converted version, shows Can’t play this file
  with Open in VLC.
- `playback-preferences` saves proxy, subtitle, and autoplay settings, retries a
  failed save, and keeps them across relaunch. Rotate to landscape on holds
  landscape and restores portrait on Close; off, the player and the conversion
  gate follow the device both ways and keep the position and the chips.
- `resume-setting` asks before turning resume off, reverts a failed save, and
  plays a saved video from zero in portrait with Rotate off.
- `playback-method` reverts a failed Direct play save, applies it on the next
  tap, and keeps it across relaunch.
- `proxy` waits on a slow proxy list and keeps the checked proxy when put.io
  refuses the tapped one.
- `cast` connects from the player, controls the session, switches subtitles and audio,
  and syncs the position back.
- `cast-audio` casts an audio file from Now Playing to the stub speaker, retries
  a failed load, pauses, plays the next file on the receiver, and stops back to
  the phone, paused at the receiver's position.
- `cast-routes` shows Picture in Picture, AirPlay and Cast in the route group,
  drops Cast with no device, and explains Local Network when it is off.
- `cast-picker` lists a TV and a speaker while playback continues, connects to
  the TV, and stops casting.
- `cast-conversion` connects during a conversion wait and plays the converted
  video on the receiver, not the phone.
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
- The player chips for audio, subtitles, and speed; Picture in Picture,
  AirPlay and Cast in the top bar.

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
- **Video errors.** Run `--only video-errors`. Screenshots:
  `runtime-video-access-expired`, `runtime-video-connection-lost`,
  `runtime-video-recovered`. `--putio-harness-video-faults` takes a comma list
  (`forbidden`, `refused`, `none`) that the seeded video loads use in order:
  `forbidden` gets a 403 from the media server and `refused` points at a closed
  loopback port. Boards: `rd-ios-pb-18-link-expired`,
  `rd-ios-pb-19-connection-lost`.
- **Video waits.** Run `--only video-wait`. Screenshots:
  `runtime-video-preparing`, `runtime-video-buffering`,
  `runtime-video-buffering-long`, `runtime-video-stalled`,
  `runtime-video-stall-retried`. `PUTIO_HARNESS_HELD_STREAM=<start|middle>:<token>`
  streams the [held fixture](../../../../Tests/HarnessMedia/held/attribution.md);
  [`HeldStream`](../../../../Tests/iOSUITests/Sources/HeldStream.swift) releases
  it. Boards: `rd-ios-pb-24-preparing-video`, `rd-ios-pb-10-buffering`,
  `rd-ios-pb-26-buffering-long`, `rd-ios-pb-27-stalled`.
- **Conversion gate.** Run `--only conversion-gate,conversion-completed,conversion-failed,conversion-unavailable,conversion-status`.
  `--putio-harness-episode-conversion queued|converting|failed|offline|unavailable|completes|completes-late`
  makes the first Blue Lights episode need conversion and seeds its status
  reads; `completes-late` finishes several reads after `completes`.
  `video.conversion-reads` counts them. Boards:
  `rd-ios-pb-28-conversion-queued`, `rd-ios-pb-15-converting`,
  `rd-ios-pb-16-conversion-failed`, `rd-ios-pb-29-conversion-status-failed`,
  `rd-ios-pb-30-cannot-convert`, `rd-ios-pb-42-ipad-converting`.
- **Audio.** Run `--only audio`. Screenshots: `runtime-audio-player`,
  `runtime-audio-error`, `runtime-audio-single`, `runtime-audio-up-next`,
  `runtime-audio-sleep-menu`, `runtime-audio-sleep-running`.
  `--putio-harness-music` seeds a Music folder of four tracks and a one-file
  folder under Singles; `--putio-harness-audio-fails-once` and
  `--putio-harness-audio-held` fail or hold the second track's first load, and
  `--putio-harness-audio-near-end` starts the third track 10 seconds before its
  end. `--putio-harness-sleep-clock` puts the sleep timer on a manual clock:
  each tap on the `audio.sleep-clock` probe moves it by
  [`harnessStep`](../../../../Apps/iOS/Sources/Harness/HarnessSleepTimerClock.swift).
  Boards: `rd-ios-pb-04-now-playing`, `rd-ios-pb-11-sleep`,
  `rd-ios-pb-12-up-next`, `rd-ios-pb-25-preparing-audio`,
  `rd-ios-pb-36-sleep-running`, `rd-ios-pb-37-audio-error`,
  `rd-ios-pb-39-single-audio`, `rd-ios-pb-40-ipad-now-playing`,
  `rd-ios-pb-05-mini`, `rd-ios-pb-41-ipad-mini`.
- **Subtitles.** Run `--only subtitles`. Screenshots: `runtime-subtitles-menu`,
  `runtime-subtitles-selected`.
- **Subtitles menu.** Run `--only subtitle-menu`. Screenshots:
  `runtime-subtitles-sources`, `runtime-subtitles-none`,
  `runtime-subtitles-failed`. `--putio-harness-subtitle-tracks
  none|one|three|failing` picks the
  [fixture master](../../../../Tests/HarnessMedia/multi-audio/attribution.md)
  and the subtitles list behind it; the `video.subtitle-text` probe reports the
  cue on screen. Boards: `rd-ios-pb-03-subtitles`,
  `rd-ios-pb-14-ipad-subtitles`, `rd-ios-pb-20-no-subtitles`,
  `rd-ios-pb-38-subtitles-failed`.
- **Chips and Picture in Picture.** Run `--only video-chips`. Screenshots:
  `runtime-video-chips`, `runtime-video-chips-changed`. Boards:
  `rd-ios-pb-02-video`, `rd-ios-pb-13-ipad-video`, which stream the multi-audio
  fixture.
- **Up next.** The walk, `resume-persistence` and `playback-preferences` cover
  autoplay, Cancel and the chip. `--putio-harness-next-episode` chains the
  Blue Lights episodes, `--putio-harness-next-file-fails <n>` fails the first n
  next-file lookups and `--putio-harness-up-next-held` holds the countdown.
  Boards: `rd-ios-pb-21-up-next`, `rd-ios-pb-35-next-episode`, and
  `video-next-not-found` with no board.
- **Direct play.** Run `--only direct-play`. Screenshots:
  `runtime-direct-play-menu`, `runtime-direct-play-controls`,
  `runtime-direct-play-audio`. It streams
  [`runtime-proof-direct.mkv`](../../../../Tests/HarnessMedia/direct-play/attribution.md)
  and serves put.io's subtitle files as the loopback SubRip file. Captures
  compare with `rd-ios-pb-02-video`, `rd-ios-pb-06-audio` and
  `rd-ios-pb-13-ipad-video`.
- **Audio and speed.** Run `--only audio-speed,speed-landscape,audio-tracks`.
  Screenshots: `runtime-audio-menu`, `runtime-speed-kept`,
  `runtime-speed-menu-scrolled`, `runtime-audio-one-track`,
  `runtime-audio-switch-failed`. Harness launches reset the video speed unless
  they pass `--putio-harness-keep-playback-speed`;
  `--putio-harness-audio-tracks one|failing|fast-forward` streams one audio track, a
  Turkish track whose playlist is missing, or an I-frame playlist for speeds above 2×. Boards: `rd-ios-pb-06-audio`,
  `rd-ios-pb-07-speed`.
- **Direct play fallback.** Run `--only direct-play-fallback,direct-play-cant-play`.
  Screenshots: `runtime-direct-play-fallback`, `runtime-direct-play-cant-play`.
  `--putio-harness-original-fails converted|none` puts the first Blue Lights
  episode on Direct play at 120 seconds, streams it as the unopenable
  `runtime-proof-undecodable.mkv`, and gives it a converted version or none.
  Board: `rd-ios-pb-17-cant-play`.
- **Preferences.** Run `--only playback-preferences`. Screenshots:
  `runtime-playback-preferences`, `runtime-rotate-off-portrait`,
  `runtime-rotate-off-converting`. `--putio-harness-rotate-off` starts with
  Rotate to landscape off; video boards captured with `--orientation portrait` pass it.
  Boards: `rd-ios-pb-43-portrait-video`, `rd-ios-pb-44-portrait-converting`.
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
- **Cast.** Run `--only cast`. Screenshots: `runtime-cast-failed`,
  `runtime-cast-playing`, `runtime-cast-tracks`, `runtime-cast-signed-out`.
  `cast.active-tracks` holds the stub receiver's active track ids: audio 1
  (English) and 2 (Turkish), subtitles from 1000 in load order.
  `--putio-harness-cast-load-fails-once` makes the stub receiver refuse the
  first load and `--putio-harness-cast-load-held` holds every load. Boards:
  `rd-ios-pb-32-cast-loading`, `rd-ios-pb-08-casting`,
  `rd-ios-pb-09-cast-failed`.
- **Audio cast.** Run `--only cast-audio`. Screenshots:
  `runtime-audio-cast-failed`, `runtime-audio-casting`,
  `runtime-audio-cast-stopped`. Board: `rd-ios-pb-34-now-playing-casting`.
- **Route group.** Run `--only cast-routes`. Screenshots: `runtime-cast-routes`,
  `runtime-cast-routes-no-device`, `runtime-cast-local-network-off`.
  `--putio-harness-cast-no-device` removes the stub receiver and
  `--putio-harness-cast-local-network-denied` reports Local Network off.
  `--putio-harness-airplay-device <name>` shows the player as AirPlaying to
  that device. Boards: `rd-ios-pb-45-no-cast-device`, `rd-ios-pb-23-airplay`.
- **Cast picker.** Run `--only cast-picker`. Screenshot: `runtime-cast-picker`.
  The stub receiver lists "Living Room TV" and "Kitchen speaker" and keeps
  searching. Boards:
  `rd-ios-pb-31-cast-picker`, `rd-ios-pb-33-local-network-off`.
- **Downloads.** Run `--only downloads,unsaved-downloads,download-start-failed`.
  Screenshots: `runtime-downloads-queue`, `runtime-downloads-detail`,
  `runtime-downloads-selection`, `runtime-downloads-remove`,
  `runtime-downloads-start-failed`.
- **Large text.** Run `--only accessibility-audio`. Screenshots:
  `runtime-accessibility-audio-portrait`, `runtime-accessibility-audio-landscape`,
  and their `-controls` variants.

## Gotchas

- Cast uses a stub receiver. It cannot prove a physical Chromecast.
- The AirPlay fixture forces the layout only; a real AirPlay receiver needs a
  device.
- The Simulator does not support Picture in Picture.
  `--putio-harness-picture-in-picture` shows its button for layout only;
  starting and restoring it needs a device.
- Slider dragging does not prove VoiceOver gestures or spoken output.
- A failed audio preflight saves audio error codes in `.audio.audio.log` beside
  its bundle.
