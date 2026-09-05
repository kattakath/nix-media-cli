# media — one name for the media CLIs, and one `--help` that lists them.
#
#   media describe [...]   write what an image IS into the image
#   media fix [...]        repair a media file by class
#   media audio [...]      pull the audio track out of a video
#   media queue [...]      inspect and control the background work queue
#
# WHY THIS EXISTS: discoverability, not ergonomics. The five media CLIs are
# individually well-named, but nothing tells an operator they are related, or
# that `photo-describe` exists at all — `media <TAB>` and `media --help` do.
# Typing `media describe` is LONGER than `photo-describe`, so if this were about
# saving keystrokes it would be a net loss.
#
# IT IS PURELY ADDITIVE. Every underlying binary stays on PATH under its own
# name, because three consumers already hardcode those names and must keep
# working: the Finder Services bake absolute /nix/store paths into their
# document.wflow, `nix run .#photo-describe` names the app, and the operator's
# own notes are written in the direct form. A dispatcher that REPLACED them
# would be a breaking change bought for a shorter help listing.
#
# THE LINE THE `queue` VERB DRAWS: `media` is what a HUMAN types; the bare
# names are what MACHINES call. media-queue-status/-top/-pause/-resume are the
# four queue tools an operator runs by hand, and nothing hardcodes them — no
# Finder .workflow, no launchd arg0, no flake app, no composition seam — so
# they belong behind the dispatcher for the same discoverability reason the
# other three verbs do. The rest of the queue stays out for the concrete
# reasons below, which are about breakage, not taste. Before this verb existed
# the split was accidental: these four simply postdated this file's header.
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
#   media-enqueue     the Finder Services call it by absolute store path.
#   media-queue-power-monitor
#                     launchd StartInterval only; it is a tick, not a command,
#                     and `media queue power-monitor` would invite running it
#                     by hand, which does nothing useful.
#   fix-extension     `--only`/`--print0` are a COMPOSITION seam for fix-media
#                     and photo-describe, not a user feature. Promoting it
#                     invites hand use of a flag pair that exists so two other
#                     CLIs can pipeline through it.
#   fix-google-video  `fix-media --video` is the discoverable name for it; the
#                     menu deliberately names the media CLASS, not the defect.
#
# `exec` rather than a wrapper function: the verb's own exit status, stdout and
# stderr must reach the caller untouched, because media-queue's worker parses
# that grammar and counts `done:` lines from it.
{
  writeShellApplication,
  callPackage,
  fix-media ? callPackage ./fix-media.nix { },
  extract-audio ? callPackage ./extract-audio.nix { },
  photo-describe ? callPackage ./photo-describe.nix { },
  # For the `queue` verb. media-queue takes fix-media/photo-describe rather
  # than the media-toolkit bundle precisely so this reference does not close a
  # cycle — see the parameter comment in packages/media-queue.nix.
  media-queue ? callPackage ./media-queue.nix { },
}:
writeShellApplication {
  name = "media";
  runtimeInputs = [
    fix-media
    extract-audio
    photo-describe
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
      queue     [top|pause|resume]          the background work queue behind the
                                            Finder Services: bare prints a
                                            one-shot status, `top` follows it
                                            live, pause/resume freeze and thaw
                                            the in-flight job

    Each command takes --help of its own. The underlying CLIs remain on PATH
    under their own names (photo-describe, fix-media, extract-audio,
    media-queue-status, media-queue-top, media-queue-pause, media-queue-resume).
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
      describe) shift; exec photo-describe "$@" ;;
      fix)      shift; exec fix-media "$@" ;;
      audio)    shift; exec extract-audio "$@" ;;
      queue)    shift; queue "$@" ;;
      -h|--help|help|"") usage; [ $# -eq 0 ] && exit 1; exit 0 ;;
      *) echo "media: error: unknown command '$1'" >&2; usage; exit 1 ;;
    esac
  '';
  meta = {
    description = "One entry point for the media CLIs: media describe / fix / audio / queue";
    mainProgram = "media";
  };
}
