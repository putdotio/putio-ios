# Runtime-proof preview media

Every fixture is generated in-repo and contains no third-party content.

- `runtime-proof-image.png` is a 640×400 RGB PNG of four solid quadrants
  written with the Python standard library (`zlib` + `struct`).
- `runtime-proof-document.pdf` is a hand-assembled twelve-page PDF 1.4 file
  with filled rectangles and one line of Helvetica text per page.
- `runtime-proof-subtitles.srt` is three hand-written SubRip cues.
- `runtime-proof-long.srt` is about 312 kB of numbered SubRip cues that cycle
  three lines, so a preview stops at 250 kB partway through.

The Tuist app target copies these files only into Debug builds; the harness
media server serves them to the seeded scenario in place of put.io downloads.
