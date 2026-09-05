# fix-media — "my videos/photos are broken, fix them", by media class.
#
#   fix-media --video <file-or-dir>...   # repair video files
#   fix-media --image <file-or-dir>...   # repair image files
#
# This exists for the MENU, not for the shell. The Finder Services it backs are
# named for what the operator has selected — "Fix Video File(s)", "Fix Image
# File(s)" — because the operator does not know which of several unrelated
# defects their file has, and cannot be expected to. A menu of diagnoses
# ("Fix Google Video", "Fix File Extension") asks them to diagnose it first,
# which is the one thing they came here unable to do. So the menu names the
# class, and this decides what is actually wrong.
#
# The per-class pipelines today:
#
#   --video   fix-extension --only video   then  fix-google-video
#   --image   fix-extension --only image
#
# `--image` has exactly one step. That is not an oversight and not a stub: the
# only image defect the fleet has met is the lying extension. The value it adds
# is the discoverable name, and the place a second image repair goes when one
# turns up.
#
# STAGE ORDER is load-bearing. fix-extension runs first and RENAMES its inputs,
# so stage two cannot be handed the original paths — it gets the resulting ones
# from `--print0` (NUL-separated on stdout, diagnostics on stderr). Reading them
# into an array rather than piping to xargs also means an empty selection ends
# the run quietly, instead of invoking the next CLI with no arguments and
# turning "nothing to fix" into a usage error the Service would report as a
# failure.
#
# No --dry-run, deliberately: fix-google-video has none, so the flag could only
# ever rehearse half the pipeline while implying it rehearsed all of it. Preview
# the rename half with `fix-extension --dry-run --only video` instead.
{
  writeShellApplication,
  callPackage,
  coreutils,
  fix-extension ? callPackage ./fix-extension.nix { },
  fix-google-video ? callPackage ./fix-google-video.nix { },
}:
writeShellApplication {
  name = "fix-media";
  runtimeInputs = [
    fix-extension
    fix-google-video
    coreutils
  ];
  text = ''
    prog=fix-media
    usage="usage: $prog <--video|--image> <file-or-directory>..."
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }

    class=""
    case "''${1:-}" in
      --video) class=video; shift ;;
      --image) class=image; shift ;;
      --help|-h)
        echo "$usage" >&2
        echo "  --video: fix the extension, then re-encode editor-hostile codecs" >&2
        echo "  --image: fix the extension" >&2
        echo "  directories are walked recursively" >&2
        exit 0 ;;
      *) die "$usage" ;;
    esac

    [ $# -ge 1 ] || die "$usage"

    # Stage one for both classes. Its stdout is the surviving file list; its
    # log goes to stderr, where the Service wrapper collects it.
    list=$(mktemp)
    trap 'rm -f "$list"' EXIT
    rc=0
    fix-extension --only "$class" --print0 "$@" > "$list" || rc=$?

    files=()
    while IFS= read -r -d "" f; do
      files+=("$f")
    done < "$list"

    if [ "$class" = video ] && [ ''${#files[@]} -gt 0 ]; then
      fix-google-video "''${files[@]}" || rc=$?
    fi

    [ ''${#files[@]} -gt 0 ] || info "OK: 'selection' — no $class files to look at"
    exit "$rc"
  '';
}
