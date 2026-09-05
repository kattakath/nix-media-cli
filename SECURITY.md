# Security Policy

## The model

These tools are **local and offline by design**. Nothing here uploads a photo,
calls a hosted API, or phones home. The only network call any CLI makes is to
an **Ollama endpoint you control** (`127.0.0.1:11434` by default) for the
caption step, and that step is optional — with Ollama absent, `photo-describe`
still writes Vision labels and a rating and says so.

Point `ollamaHost` at a remote machine and that stops being true: your images
are then sent to that host. That is your call to make deliberately.

## What these tools do to your files

Worth understanding before enabling, because several are **destructive by
design**:

- **`photo-describe` writes into your images.** It adds `XMP:Description`,
  `XMP:Subject`, `XMP:Rating` and `IPTC:Keywords` in place. It preserves the
  original modification time (`exiftool -P`), so a successful write does *not*
  bump the mtime — do not use mtime to detect whether it ran.
- **`fix-extension` renames files.** Guarded: it only rewrites an extension when
  the sniffed type is in a known table and the current extension is not already
  an accepted spelling. It never enters a macOS package such as
  `Photos Library.photoslibrary`, and it skips dataless iCloud files rather than
  materialising gigabytes.
- **`fix-google-video` replaces the input by default.** The re-encode is
  verified (non-trivial output, duration matches) before the swap, and the
  original is moved to `~/.Trash` — never `rm`'d. `--keep` writes alongside
  instead.
- **`media-enqueue` hands paths to a background worker** that runs the above
  without further confirmation.

Use `--dry-run` where offered, and try a copy of a folder first.

## The launchd `arg0` behaviour

The queue's agents deliberately use a `/nix/store` `nix-media-queue` `arg0`
because macOS's TCC grants such a binary read access to `~/Pictures`,
`~/Desktop` and `~/Downloads`, while `/bin/sh` is denied without a grant.

This is **undocumented by Apple** and was verified on macOS 26.6.2 only. It may
change in any OS update. Treat it as a reason the named wrapper is mandatory —
**not** as a security boundary to rely on.

## Reporting a vulnerability

Please open a **private** security advisory via GitHub
("Security" → "Report a vulnerability"), or contact the maintainer directly.
Do not file public issues for undisclosed vulnerabilities.
