> [!IMPORTANT]
> ## Archived 2026-09-12 — this flake now lives inside `kattakath/nix-config`
>
> The code moved to **`modules/features/media-cli/`** in
> [kattakath/nix-config](https://github.com/kattakath/nix-config), as a *capsule*: a
> directory that may not reach outside itself, enforced by the repo's `ast-grep` gate rather
> than by convention.
>
> **Why:** maintaining seven satellite flakes cost seven CI pipelines, seven merge queues and a
> lock-bump dance for every cross-cutting change — for repos with 2 GitHub stars between them.
> The rationale, the four competing architectures that were scored, the adversarial review that
> found three blocking defects, and an honest list of what the collapse gives up are all in
> [`docs/monoflake-capsule-adr.md`](https://github.com/kattakath/nix-config/blob/main/docs/monoflake-capsule-adr.md).
>
> **This repository is read-only.** Its history is preserved here and is the only place it
> exists — the absorption was a plain copy, not a `git subtree`, so `git blame` in nix-config
> stops at the collapse commit and continues here.

# nix-media-cli

**Make a photo describe itself, repair the file that lies about its own format,
and push the slow work into a queue that survives a logout.** Local, offline,
macOS-native. One home-manager switch turns the whole thing on or off.

```nix
programs.mediaCli.enable = true;
```

That single option installs the CLIs, registers a durable launchd work queue,
and puts four entries in Finder's right-click menu. Set it to `false` and all
three disappear together — no orphaned package, no dangling environment
variable, no stale menu item.

## Why

A photo library answers no questions about itself. Finder sorts by date;
`IMG_7454.jpg` tells you nothing. `media-describe` writes what an image **is**
*into the image* — Apple Vision labels and a rating, plus a caption from a local
vision model, as XMP that Spotlight already indexes. Then `mdfind` finds your
photos, with no database in between and nothing leaving the machine.

**The durability rule, which is the whole design:** words go in the FILE,
vectors go in an INDEX. A caption survives every model upgrade and every move
between machines; an embedding is invalidated the day you change embedding
models. So the expensive, irreplaceable artifact is embedded in the file, and
the cheap, regenerable one is left to a tool like [`rclip`](https://github.com/yurijmikhalevich/rclip).

## The CLIs

| Command | What it does |
|---|---|
| `media` | one entry point — `describe`, `fix`, `audio`, `enqueue`, `queue` |
| `media-describe` | Vision labels + rating + a local-VLM caption → the image's own XMP |
| `media-fix --video\|--image` | repair by media CLASS; decides what is actually wrong |
| `media-fix-extension` | rename files whose extension lies about their content |
| `media-transcode` | re-encode editor-hostile codecs (VP9-in-MP4, AV1) to H.264+AAC |
| `media-extract-audio` | pull the audio track out of a video |
| `media enqueue` / `media-enqueue` | hand the same work to the queue and return at once |
| `media queue [status\|top\|pause\|resume]` | inspect and control the queue |

Every one takes `--help`. All of them stay on `PATH` under their own names;
`media` is additive, never a replacement.

### Two more, opt-in

| Command | Option | Why it is off by default |
|---|---|---|
| `fidelity-enhance` / `-mcp` | `fidelityEnhance.enable` | the referee for an agentic image-editing loop — judges a generated image against the original and answers retry / next-step / done. First run pulls ~1 GB of torch + insightface |
| `obs-fb-setup` | `obsFacebookSetup.enable` | writes an OBS "Facebook" profile with researched 1080p30 screencast settings. Inert until `FB_PERSISTENT_STREAM_KEY` is in your login Keychain |

These ship here so the media story is **one repo you add or strip off**, but
they stay out of the `media-toolkit` bundle: that bundle is what the queue
worker and the Finder Services put on their `PATH`, so every member becomes a
runtime dependency of the queue. A uv/Python environment and a Keychain read
have no business there.

## The queue is launchd's, not ours

Re-encoding two hundred videos is hours of `ffmpeg`. Doing that inside an
Automator Service means the work dies at logout, cannot be paused, reports
nothing until it ends, and fights your foreground apps for CPU.

Moving it behind launchd fixes all four with **no scheduler of our own**:

| launchd primitive | What it buys |
|---|---|
| `QueueDirectories` | *is* the queue — the worker starts whenever a directory is non-empty |
| `ProcessType = "Background"` | macOS throttles CPU and I/O so a 200-file batch is not something you feel |
| `KeepAlive.SuccessfulExit = false` | worker-process retry, bounded by `ThrottleInterval` |
| `RunAtLoad` | drains whatever a logout interrupted |
| `StartInterval` | the battery-awareness tick, no `sleep` loop |

What is genuinely ours is only the part launchd has no opinion about: what a
job *is*, and what to do with one that fails. Three priority tiers, three
attempts then a dead-letter directory, `SIGSTOP`/`SIGCONT` pause that freezes a
job mid-`ffmpeg` without losing progress, and adoption of an orphaned job across
a worker restart (the `MAINPID` pattern, borrowed from systemd by name).

## Install

```nix
{
  inputs.media-cli.url = "github:kattakath/nix-media-cli";
  inputs.media-cli.inputs.nixpkgs.follows = "nixpkgs";
  inputs.media-cli.inputs.home-manager.follows = "home-manager";
}
```

```nix
{
  imports = [ inputs.media-cli.homeManagerModules.default ];
  programs.mediaCli.enable = true;
}
```

Or run a CLI without installing anything:

```bash
nix run github:kattakath/nix-media-cli#media-describe -- ~/Pictures/holiday
```

## Options

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | the whole switch |
| `installQuickActions` | `true` | the four Finder right-click Services |
| `visionModel` | `huihui_ai/qwen3-vl-abliterated` | baked into `media-describe` at build time |
| `ollamaHost` | `127.0.0.1:11434` | exported as `OLLAMA_HOST` |
| `logRelPath` | `Library/Logs/nix-media-queue.log` | where Console.app looks |
| `extraSearchPackages` | `[ pkgs.exiftool ]` | companion tools; `[ ]` for none |
| `fidelityEnhance.enable` | `false` | the agentic-loop referee (~1 GB first run) |
| `obsFacebookSetup.enable` | `false` | the OBS Facebook Live profile writer |

## Requirements

- **macOS on Apple Silicon.** Every package is `aarch64-darwin`-gated. This is
  not the usual "shell scripts are portable" case: only `media-extract-audio` really
  is. The rest call `/usr/bin/mdls`, BSD `stat -f`, `/usr/bin/sips`,
  `/usr/bin/SetFile`, `~/.Trash`, Automator, or launchd.
- **[`auge`](https://github.com/dnlmlr/auge)** for Apple's Vision framework, and
  **`exiftool`** for metadata. Both come from nixpkgs.
- **[Ollama](https://ollama.com)** is a *soft* dependency. With it absent or the
  model unpulled, `media-describe` still writes labels and a rating, says so,
  and exits clean rather than leaving a library half-tagged.

## One thing to know before you enable it

The queue's launchd agents run with an `arg0` of `nix-media-queue`, and that is
**load-bearing, not cosmetic**. `ProgramArguments[0]` is what macOS attributes
file access to. Measured on macOS 26.6.2: an adhoc-signed `/nix/store` binary
may read the TCC-protected folders (`~/Pictures`, `~/Desktop`, `~/Downloads`);
Apple's own `/bin/sh` is attributable and gets `EPERM` without an explicit
grant. Upstream home-manager wraps every agent as `/bin/sh -c 'wait4path … &&
exec …'`, which is exactly that failure mode — the worker would run, log
nothing useful, and quietly do no work. This module therefore builds its own
named wrapper and sets `ProgramArguments` itself.

That behaviour is **undocumented by Apple** and verified on one OS version.
Treat it as a reason the wrapper is mandatory, not as a security boundary.

## License

MIT.
