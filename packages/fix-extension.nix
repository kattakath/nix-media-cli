# fix-extension — rename files whose EXTENSION lies about their CONTENT.
#
#   fix-extension [--dry-run] [--only image|video|audio] [--print0] <file-or-dir>...
#
# Why this exists: Finder's thumbnail generator trusts the extension → UTI, so
# a JPEG named `.png` is handed to the PNG decoder, which rejects it, and the
# file falls back to a generic icon. Preview and Quick Look's full view sniff
# the magic bytes instead and open it fine — which is what makes the symptom so
# confusing: the file is clearly readable, yet Finder shows no thumbnail.
# Measured on a Google Photos/Picasa export: 10 of 15 `.png` files were JPEG,
# and exactly those 10 had no thumbnail.
#
# The fix is a RENAME, never a re-encode. The bytes are already a valid image;
# converting them would add a second lossy generation and gain nothing.
#
# Two guards keep this from being destructive:
#
#   - An extension is only rewritten when the sniffed type is in the table
#     below AND the current extension is not already an accepted spelling of
#     that type. Unknown types are left alone rather than guessed at, and
#     `.jpeg`/`.tif`/`.m4v` are not "corrected" to their canonical sibling.
#   - `video/quicktime` accepts `.mp4` too: some MP4s sniff as QuickTime, and
#     renaming a working `.mp4` to `.mov` would be a regression, not a fix.
#
# A directory argument is walked recursively, and files with no recognisable
# type are then passed over silently — a photo folder is full of them and one
# line each would bury the actual findings. Named explicitly, the same file
# reports why it was skipped.
#
# THE WALK NEVER ENTERS A macOS PACKAGE. `~/Pictures/Photos Library.photoslibrary`
# is a directory, and renaming files inside it is not a fix — it is library
# corruption. Verified on this Mac: that path reports `com.apple.package` in
# `kMDItemContentTypeTree`, which is what `is_package` asks Spotlight. Spotlight
# answers nothing on an unindexed volume, so a curated extension list runs first
# as the fast path and the safety net; a dotted directory that is NOT a package
# (`2019.holiday`) is still walked, so the check cannot silently swallow real
# folders.
#
# Three per-file guards run BEFORE anything reads the bytes, because reading is
# itself the hazard:
#
#   dataless   — an iCloud file whose contents are not on disk (`stat -f %Sf`
#                reports `dataless`; measured on this Mac under CloudDocs).
#                Sniffing it would materialise it, so a folder sweep would
#                quietly pull gigabytes down and fail offline.
#   in-flight  — `.crdownload`/`.part`/`.partial`/`.download`. The bytes are
#                incomplete, so any verdict drawn from them is wrong.
#   AppleDouble — `._name` resource-fork siblings, which are metadata, not media.
#
# `--only` and `--print0` exist for ONE caller, fix-media, and are what let it
# compose this with a repair step instead of reimplementing the sniffing:
#
#   --only  restricts the run to one media class, so "fix the videos in this
#           folder" does not quietly rename the photos next to them. A file
#           matches on its SNIFFED class or its EXTENSION's class, not just the
#           first — otherwise a `.mp4` whose type `file` cannot place would
#           drop out of a video run before anything could look at it.
#   --print0  writes the RESULTING path of every file considered to stdout,
#           NUL-separated, so the next stage receives the new name after a
#           rename. Diagnostics stay on stderr, so the two never mix.
#
# Output grammar (`done:` / `skip:` / `OK:` / `error:`) is shared with the other
# media-toolkit CLIs so the Finder Service wrapper can summarise it into a
# notification. See packages/media-quick-actions.nix.
{
  writeShellApplication,
  file,
  coreutils,
  findutils,
}:
writeShellApplication {
  name = "fix-extension";
  # `mdls` and BSD `stat` are called by ABSOLUTE /usr/bin path, not left to PATH:
  # coreutils below shadows `stat`, and GNU stat reads `-f` as "filesystem
  # status" rather than a format string — the dataless guard would have been
  # dead code. Neither tool has a nixpkgs equivalent, so they are not pinnable.
  runtimeInputs = [
    file
    coreutils
    findutils
  ];
  text = ''
    prog=fix-extension
    usage="usage: $prog [--dry-run] [--only image|video|audio] [--print0] <file-or-directory>..."
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }

    dry=0
    print0=0
    only=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run|-n) dry=1; shift ;;
        --print0)     print0=1; shift ;;
        --only)
          [ $# -ge 2 ] || die "--only needs a class (image, video or audio)"
          case "$2" in
            image|video|audio) only=$2 ;;
            *) die "unknown class '$2' (image, video or audio)" ;;
          esac
          shift 2 ;;
        --help|-h)
          echo "$usage" >&2
          echo "  renames files whose extension disagrees with their content" >&2
          echo "  (e.g. a JPEG named .png, which Finder cannot thumbnail)" >&2
          echo "  the bytes are never touched; directories are walked recursively" >&2
          exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option '$1' (try --help)" ;;
        *) break ;;
      esac
    done

    [ $# -ge 1 ] || die "$usage"

    failed=0

    # mime-type -> accepted extensions, CANONICAL FIRST. A file is renamed only
    # when its current extension is absent from its type's list, so the aliases
    # here are what stops `.jpeg` and `.m4v` being churned into `.jpg`/`.mp4`.
    exts_for() {
      case "$1" in
        image/jpeg)                  echo "jpg jpeg jpe jfif" ;;
        image/png)                   echo "png" ;;
        image/gif)                   echo "gif" ;;
        image/webp)                  echo "webp" ;;
        image/heic|image/heif)       echo "heic heif" ;;
        image/tiff)                  echo "tiff tif" ;;
        image/bmp|image/x-ms-bmp)    echo "bmp" ;;
        image/svg+xml)               echo "svg" ;;
        image/vnd.adobe.photoshop)   echo "psd" ;;
        image/x-icon)                echo "ico" ;;
        video/mp4)                   echo "mp4 m4v" ;;
        # .mp4 stays accepted: some MP4s sniff as QuickTime, and renaming a
        # working .mp4 to .mov would break it for no gain.
        video/quicktime)             echo "mov qt mp4" ;;
        video/x-matroska)            echo "mkv" ;;
        video/webm)                  echo "webm" ;;
        video/x-msvideo)             echo "avi" ;;
        video/mpeg)                  echo "mpg mpeg" ;;
        audio/mpeg)                  echo "mp3" ;;
        audio/mp4|audio/x-m4a)       echo "m4a mp4" ;;
        audio/wav|audio/x-wav)       echo "wav" ;;
        audio/flac|audio/x-flac)     echo "flac" ;;
        audio/ogg|application/ogg)   echo "ogg oga" ;;
        application/pdf)             echo "pdf" ;;
        *) return 1 ;;
      esac
    }

    # The two halves of --only. A file matches on either, so a video whose type
    # `file` cannot place still counts as a video when it is named like one.
    class_of_mime() {
      case "$1" in
        image/*) echo image ;;
        video/*) echo video ;;
        audio/*) echo audio ;;
        *) return 1 ;;
      esac
    }
    class_of_ext() {
      case "$1" in
        jpg|jpeg|jpe|jfif|png|gif|webp|heic|heif|tiff|tif|bmp|svg|psd|ico) echo image ;;
        mp4|m4v|mov|qt|mkv|webm|avi|mpg|mpeg)                             echo video ;;
        mp3|m4a|wav|flac|ogg|oga)                                         echo audio ;;
        *) return 1 ;;
      esac
    }

    # A macOS package is a directory Finder presents as one file. Spotlight is
    # the authority, but it goes quiet on an unindexed volume, so the extension
    # list is both the fast path and the fallback. Unknown dotted directories
    # fail OPEN — they get walked — so a folder merely named `2019.holiday` is
    # not silently skipped.
    is_package() {
      case "$(printf '%s' "''${1##*.}" | tr '[:upper:]' '[:lower:]')" in
        app|photoslibrary|aplibrary|migratedphotolibrary|musiclibrary|tvlibrary) return 0 ;;
        imovielibrary|theater|fcpbundle|band|logicx|sparsebundle|rtfd|scptd) return 0 ;;
        bundle|framework|plugin|kext|pkg|mpkg|workflow|download|lrcat|lrdata) return 0 ;;
      esac
      /usr/bin/mdls -name kMDItemContentTypeTree -raw "$1" 2>/dev/null \
        | grep -q "com.apple.package"
    }

    # Guards that must run BEFORE the bytes are read, because reading is the
    # hazard: sniffing a dataless file materialises it. Echoes a reason when the
    # file should be left alone, and nothing when it is safe to look at.
    # Parameter expansion, never basename/dirname: at four forks per file a
    # 10k-photo folder spends minutes in process creation alone. Measured on
    # this Mac at ~19ms/file before this, ~9ms after.
    unsafe_reason() {
      local f=$1 flags base dir
      base=''${f##*/}
      case "$base" in
        ._*) echo "AppleDouble metadata, not media"; return 0 ;;
      esac
      case "$base" in
        *.crdownload|*.part|*.partial|*.download)
          echo "still downloading"; return 0 ;;
      esac
      # /usr/bin/stat, ABSOLUTELY: coreutils is on PATH and GNU stat reads -f as
      # "filesystem status", so the unqualified call would error out, leave
      # flags empty under `|| true`, and silently pass every dataless file.
      flags=$(/usr/bin/stat -f '%Sf' "$f" 2>/dev/null || true)
      case "$flags" in
        *dataless*) echo "not downloaded from iCloud — reading it would fetch it"; return 0 ;;
      esac
      # A rename writes to the DIRECTORY, so that is what has to be writable.
      dir=''${f%/*}
      [ "$dir" = "$f" ] && dir=.
      if [ ! -w "$dir" ]; then
        echo "read-only location"; return 0
      fi
      return 0
    }

    # Where the pipeline learns what a file is called NOW. Every path that
    # survived the class filter is reported, renamed or not, so the next stage
    # sees the whole selection rather than only what changed.
    emit() {
      [ "$print0" -eq 1 ] && printf '%s\0' "$1"
      return 0
    }

    # $1 = path, $2 = 1 when the path was named on the command line (so a skip
    # is worth reporting) and 0 when it came out of a directory walk.
    fix_one() {
      local f=$1 explicit=$2 base ext mime accepted canon target tname mclass eclass unsafe
      local -a accepted_arr

      if [ ! -f "$f" ]; then
        [ "$explicit" -eq 1 ] && info "skip: '$f' — not found"
        return 0
      fi

      # Before the bytes are read, not after: sniffing is the hazard.
      unsafe=$(unsafe_reason "$f")
      if [ -n "$unsafe" ]; then
        [ "$explicit" -eq 1 ] && info "skip: '$f' — $unsafe"
        return 0
      fi

      mime=$(file -b --mime-type "$f" 2>/dev/null || true)

      base=''${f##*/}
      case "$base" in
        *.*) ext=$(printf '%s' "''${base##*.}" | tr '[:upper:]' '[:lower:]') ;;
        *)   ext="" ;;
      esac

      if [ -n "$only" ]; then
        mclass=$(class_of_mime "$mime" || true)
        eclass=$(class_of_ext "$ext" || true)
        if [ "$only" != "$mclass" ] && [ "$only" != "$eclass" ]; then
          [ "$explicit" -eq 1 ] && info "skip: '$f' — not a(n) $only file"
          return 0
        fi
      fi

      if ! accepted=$(exts_for "$mime"); then
        [ "$explicit" -eq 1 ] && info "skip: '$f' — unrecognised type (''${mime:-unknown})"
        emit "$f"
        return 0
      fi

      read -ra accepted_arr <<< "$accepted"
      for a in "''${accepted_arr[@]}"; do
        if [ "$ext" = "$a" ]; then
          [ "$explicit" -eq 1 ] && info "OK: '$f' — extension already matches ($mime)"
          emit "$f"
          return 0
        fi
      done

      canon=''${accepted%% *}
      if [ -n "$ext" ]; then
        target="''${f%.*}.$canon"
      else
        target="$f.$canon"
      fi
      tname=''${target##*/}

      # -ef, not a string compare: on a case-insensitive volume `IMG.JPG` and
      # `IMG.jpg` are the same file, and `mv` there is a legitimate case fix.
      if [ -e "$target" ] && ! [ "$target" -ef "$f" ]; then
        info "skip: '$f' — '$tname' already exists"
        emit "$f"
        return 0
      fi

      if [ "$dry" -eq 1 ]; then
        info "would rename: '$f' -> '$tname' (''${ext:-no extension} but $mime)"
        emit "$f"
        return 0
      fi

      # A rename preserves the bytes, xattrs and both timestamps, so there is
      # nothing here to verify or roll back.
      if ! mv "$f" "$target"; then
        # Reported, not fatal: one unwritable file must not abandon the rest of
        # a folder. `failed` makes the run exit non-zero anyway, which is what
        # tells the Finder Service wrapper to show the error rather than
        # "nothing to do".
        info "error: could not rename '$f'"
        failed=1
        emit "$f"
        return 0
      fi
      info "done: '$target' (was .''${ext:-none}, actually $mime)"
      emit "$target"
    }

    # Two passes per level rather than one `find` over everything: pass one takes
    # the files while pruning EVERY dotted directory (so `find` never descends
    # into a package, however large), pass two re-enters only the dotted
    # directories that turned out not to be packages. Pruning at the `find`
    # level is what keeps a 100k-file Photos library from being enumerated at
    # all.
    # `-mindepth 1` ON BOTH PASSES is load-bearing, not tidiness. `-name '*.*'`
    # matches the STARTING directory too — and `*` matches empty, so it matches a
    # bare `.` as well. Without it:
    #   - pass two printed $root itself, and `walk "$d"` then re-entered the same
    #     directory forever. `fix-media --image .`, or any dotted folder such as
    #     `Trip 2019.raw`, hung outright — and under the media-queue worker that
    #     is a PERMANENT wedge, because the job holds the queue lock while it
    #     spins, so nothing else ever drains.
    #   - pass one PRUNED $root, so a dotted directory's own files were never
    #     scanned at all — the walk silently did nothing and reported success.
    # `-mindepth 1` excludes only the start point, which is exactly the term that
    # should never have been a candidate for pruning or recursion.
    walk() {
      local root=$1 f d
      while IFS= read -r -d "" f; do
        fix_one "$f" 0
      done < <(find "$root" -mindepth 1 -type d -name '*.*' -prune -o -type f -print0 2>/dev/null)
      while IFS= read -r -d "" d; do
        if is_package "$d"; then
          info "skip: '$d' — macOS package, not descending into it"
        else
          walk "$d"
        fi
      done < <(find "$root" -mindepth 1 -type d -name '*.*' -prune -print0 2>/dev/null)
    }

    for arg in "$@"; do
      if [ -d "$arg" ]; then
        if is_package "$arg"; then
          info "skip: '$arg' — macOS package, not descending into it"
          continue
        fi
        walk "$arg"
      else
        fix_one "$arg" 1
      fi
    done

    [ "$failed" -eq 0 ] || exit 1
  '';
}
