# media — one name for the media CLIs, and one `--help` that lists them.
#
#   media describe [...]   write what an image IS into the image
#   media fix [...]        repair a media file by class
#   media audio [...]      pull the audio track out of a video
#   media enqueue [...]    hand that same work to the background queue instead
#   media queue [...]      inspect and control the background work queue
#
# WHY THIS EXISTS: discoverability, not ergonomics. The five media CLIs are
# individually well-named, but nothing tells an operator they are related, or
# that `media-describe` exists at all — `media <TAB>` and `media --help` do.
# Typing `media describe` is LONGER than `media-describe`, so if this were about
# saving keystrokes it would be a net loss.
#
# IT IS PURELY ADDITIVE. Every underlying binary stays on PATH under its own
# name, because three consumers already hardcode those names and must keep
# working: the Finder Services bake absolute /nix/store paths into their
# document.wflow, `nix run .#media-describe` names the app, and the operator's
# own notes are written in the direct form. A dispatcher that REPLACED them
# would be a breaking change bought for a shorter help listing.
#
# THE LINE THE DISPATCHER DRAWS: `media` is what a HUMAN types; the bare names
# are what MACHINES call. Every tool an operator runs BY HAND belongs behind the
# dispatcher — media-enqueue, media-queue-status, media-queue-top,
# media-queue-pause, media-queue-resume. The rest stays out for the concrete
# reasons below, which are about breakage, not taste.
#
# THIS PARAGRAPH USED TO STATE A DIFFERENT CRITERION, and it was wrong: it said
# those tools belong here because "nothing hardcodes them — no Finder .workflow,
# no launchd arg0, no flake app, no composition seam". That is a fact about the
# CALLERS, not a membership rule, and reading it as one is what kept
# media-enqueue out. A verb is ADDITIVE: the binary keeps its name, so every
# hardcoded caller is untouched by definition. media-queue-status is the proof
# it was never the real rule — it is reachable as `media queue` AND under its
# own name, and always has been. The genuine exclusions below turn on breakage
# (an arg0 that must stay `nix-media-queue` for TCC, a composition seam not
# meant for hand use), never on who happens to call a tool today.
#
# RETRACTED 2026-09-06 — `enqueue` IS a verb. This file used to exclude it in
# one line, "the Finder Services call it by absolute store path". That is true
# (packages/media-quick-actions.nix:73, 85, 100) and it argues about the
# BINARY's NAME, which the ADDITIVE rule above already settles for all of
# these: a verb ADDS a name and removes none, so no store-path caller can tell
# the difference. The HUMAN-types/MACHINES-call line above partitions CALLERS,
# not verbs — one name serves both, which is what "purely additive" means.
# media-worker directly below is what a REAL exclusion looks like: there the
# dispatcher REPLACES the arg0 launchd execs and the TCC grant dies with it.
# The confusion had a concrete cost: `media-describe <dir>` and the Describe
# Image(s) Quick Action run the same work through the same binary
# (packages/media-queue.nix:782), and only the Quick Action's copy ever
# appeared in `media queue` — a shell-started pass could not be put into the
# list the operator was already watching, pausing and resuming.
#
# WHAT IS DELIBERATELY NOT A VERB, and why each one would break if it were:
#
#   media-worker      launchd-only, takes no arguments, and its arg0 must stay
#                     `nix-media-queue` — per .claude/rules/launchd-naming.md a
#                     /nix/store arg0 is what grants it TCC access to the very
#                     folders it exists to read (~/Pictures, ~/Downloads).
#                     Behind a dispatcher the arg0 becomes `media`, and it
#                     silently loses that access: it would run, log nothing
#                     useful, and quietly do no work.
#   media-queue-power-monitor
#                     launchd StartInterval only; it is a tick, not a command,
#                     and `media queue power-monitor` would invite running it
#                     by hand, which does nothing useful.
#   media-fix-extension     `--only`/`--print0` are a COMPOSITION seam for media-fix
#                     and media-describe, not a user feature. Promoting it
#                     invites hand use of a flag pair that exists so two other
#                     CLIs can pipeline through it.
#   media-transcode  `media-fix --video` is the discoverable name for it; the
#                     menu deliberately names the media CLASS, not the defect.
#
# `exec` rather than a wrapper function: the verb's own exit status, stdout and
# stderr must reach the caller untouched, because media-queue's worker parses
# that grammar and counts `done:` lines from it.
{
  writeShellApplication,
  callPackage,
  media-fix ? callPackage ./media-fix.nix { },
  media-extract-audio ? callPackage ./media-extract-audio.nix { },
  media-describe ? callPackage ./media-describe.nix { },
  # For the `queue` verb. media-queue takes media-fix/media-describe rather
  # than the media-toolkit bundle precisely so this reference does not close a
  # cycle — see the parameter comment in packages/media-queue.nix.
  media-queue ? callPackage ./media-queue.nix { },
}:
writeShellApplication {
  name = "media";
  runtimeInputs = [
    media-fix
    media-extract-audio
    media-describe
    media-queue
  ];
  text = ''
    usage() {
      cat >&2 <<'EOF'
    usage: media <command> [args...]

      describe  <file-or-dir>...            write what an image IS into the image:
                                            Apple Vision labels + rating, and a
                                            caption from a local vision model, as
                                            XMP that Spotlight indexes
      fix       <--video|--image> <path>... repair a media file by class — fixes a
                                            lying extension, re-encodes an
                                            editor-hostile codec
      audio     [--mp3|--wav|--flac] <file> pull the audio track out of a video
      enqueue   <--video|--image|--describe> [--priority high|normal|low] <path>...
                                            the same describe/fix work, handed
                                            to the background queue instead of
                                            run here — returns at once
      queue     [status|top|pause|resume]   inspect and control that queue: bare
                                            or `status` is a one-shot read,
                                            `top` follows it live, pause/resume
                                            freeze and thaw the in-flight job

    TWO WAYS TO RUN THE WORK. `media describe|fix` runs it HERE: you watch it,
    you get its exit status, and closing the terminal or logging out kills it.
    `media enqueue --describe|--video|--image` hands the identical job to
    launchd: it returns immediately, runs throttled in the background, survives
    logout, and is the only path that shows up in `media queue`. The Finder
    Quick Actions enqueue for exactly that reason. (`audio` has no queue class:
    one track is seconds, so a round trip through launchd would buy nothing.)

    Each command takes --help of its own. The underlying CLIs remain on PATH
    under their own names (media-describe, media-fix, media-extract-audio,
    media-enqueue, media-queue-status, media-queue-top, media-queue-pause,
    media-queue-resume).
    EOF
    }

    # `queue` is the one verb with a sub-verb, because the four queue tools are
    # one subject with four operations rather than four unrelated commands.
    # Bare `media queue` is the status read: that is what you want nine times
    # out of ten, and making the common case the default is why this reads
    # better than `media queue status`.
    queue() {
      case "''${1:-}" in
        # `if` rather than `[ $# -gt 0 ] && shift`: that idiom returns 1 on the
        # no-argument path, which `set -e` turns into a silent exit.
        ""|status) if [ $# -gt 0 ]; then shift; fi; exec media-queue-status "$@" ;;
        top)       shift; exec media-queue-top "$@" ;;
        pause)     shift; exec media-queue-pause "$@" ;;
        resume)    shift; exec media-queue-resume "$@" ;;
        -h|--help|help)
          echo "usage: media queue [status|top|pause|resume]" >&2
          echo "  (no argument)  one-shot status — what is running, queued, failed" >&2
          echo "  top            the same, refreshed live; q to quit" >&2
          echo "  pause          SIGSTOP the in-flight job's process group" >&2
          echo "  resume         SIGCONT it (refuses during Low Power Mode)" >&2
          exit 0 ;;
        *) echo "media queue: error: unknown subcommand '$1'" >&2
           echo "usage: media queue [status|top|pause|resume]" >&2
           exit 1 ;;
      esac
    }

    case "''${1:-}" in
      describe) shift; exec media-describe "$@" ;;
      fix)      shift; exec media-fix "$@" ;;
      audio)    shift; exec media-extract-audio "$@" ;;
      # `exec` like the three above rather than a function like `queue`:
      # media-enqueue is one binary with no sub-verb to route, so a frame
      # between the caller and its exit status would buy nothing. It is
      # already on PATH via the media-queue symlinkJoin in runtimeInputs.
      enqueue)  shift; exec media-enqueue "$@" ;;
      queue)    shift; queue "$@" ;;
      -h|--help|help|"") usage; [ $# -eq 0 ] && exit 1; exit 0 ;;
      *) echo "media: error: unknown command '$1'" >&2; usage; exit 1 ;;
    esac
  '';
  meta = {
    description = "One entry point for the media CLIs: media describe / fix / audio / enqueue / queue";
    mainProgram = "media";
  };
}
