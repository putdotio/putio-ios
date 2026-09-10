# Runtime-proof preview media

Both fixtures are generated in-repo and contain no third-party content.

- `runtime-proof-image.png` is a 640×400 RGB PNG of four solid quadrants
  written with the Python standard library (`zlib` + `struct`).
- `runtime-proof-document.pdf` is a hand-assembled two-page PDF 1.4 file with
  one filled rectangle and one line of Helvetica text per page.

The Tuist app target copies both files only into Debug builds; the harness
media server serves them to the seeded scenario in place of put.io downloads.
