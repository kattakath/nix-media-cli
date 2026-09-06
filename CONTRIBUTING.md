# Contributing

A small, focused, macOS-only flake — contributions that keep it that way are the
most welcome.

## Dev loop

```sh
nix flake check -L                        # build every CLI (shellcheck) + module eval
nix run nixpkgs#nixfmt-rfc-style -- .     # format all .nix (CI enforces this)
nix build .#media-toolkit                 # the bundle everything else composes
nix run .#media-describe -- --help
```

## Guidelines

- **The CLIs stay POSIX-ish shell** in `writeShellApplication`, shellcheck-clean
  under `set -euo pipefail`. If something needs a real language, it probably
  needs a different repo.
- **The output grammar is a contract, not a style.** Every CLI reports
  `done:` / `skip:` / `OK:` / `error:`, each naming the file in single quotes.
  `media-worker` counts `done:` lines and lifts the first `skip:`/`OK:` as the
  reason a batch changed nothing, so a CLI that invents its own vocabulary
  silently reports "0 done" forever.
- **Never rewrite pixels to fix metadata.** `media-fix-extension` renames; it does not
  re-encode. A second lossy generation to correct a filename is a bad trade.
- **Comments explain WHY, and cite the measurement.** Most of the non-obvious
  code here exists because something was measured — `auge --all` being 30x
  slower and unparseable, `temperature: 0` being required for reproducible
  captions, `ThrottleInterval` costing a full minute of right-click latency.
  Keep that record; it is the most valuable thing in the file.
- **Respect the launchd `arg0` rule.** Any agent this repo emits must have a
  `/nix/store` `nix-<activity>` `ProgramArguments[0]`. It is what TCC attributes
  file access to; a bare interpreter there silently loses access to the very
  folders the worker exists to read. See the note in `README.md`.
- **Preserve timestamps.** Several tools carry `mtime`/creation date across a
  rewrite on purpose: a fresh mtime silently reorders a whole photo library.
- Update `README.md` for user-facing changes; CI (format + build + module eval)
  must pass.

## Testing something that touches the queue

The queue keeps live state in
`~/Library/Application Support/nix-media-queue`. Check it is idle before and
after:

```sh
media queue          # nothing running, nothing queued, nothing in failed/
```

A job left in `failed/` or a stranded `running-*.job` after your change is a
bug, not noise.
