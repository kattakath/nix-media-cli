# fix-google-video — detect and re-encode video files with editor-incompatible
# codecs (most commonly VP9-in-MP4, the "space saver" flavor Google Photos'
# download button serves for videos not backed up at Original quality) into
# H.264 + AAC, so they import cleanly into CapCut/Premiere/Final Cut/etc.
#
# Root cause: Apple's AVFoundation (which QuickTime, Photos, and the Finder's
# built-in "Encode Selected Video Files" quick action all sit on top of) has
# never shipped a VP9 decoder, so that quick action fails silently on these
# files — it can't even read the video stream to re-encode it. Google Photos
# doesn't let you choose the download codec; the only real prevention is
# backing up FUTURE videos at "Original quality" in the Photos app (Storage
# Saver / old "High quality" tier videos get transcoded server-side at
# ingest, and what you download later is that transcode, not the original).
#
#   fix-google-video <file>...          # REPLACES the input; original -> Trash
#   fix-google-video --keep <file>...   # write <name>_h264.mp4 alongside instead
#
# Idempotent -- already-editor-safe files are skipped, so re-running over a
# folder is free.
#
# Auto-detects VideoToolbox (Apple Silicon/Intel hardware H.264 encoder,
# ~7x realtime) and falls back to libx264 software encode (CRF 18) if it's
# unavailable in this ffmpeg build. By default the input is REPLACED:
# the encode lands in a temp file beside it, is verified (non-trivial, duration
# matches the source), and only then swaps in, with the original moved to
# ~/.Trash -- never rm'd. So a failed encode, a full disk, or a
# truncated-but-exit-0 ffmpeg leaves the original untouched, and a batch that
# went wrong is recoverable. A non-.mp4 input (.mkv, .avi) is replaced by a
# .mp4 of the same basename, since the output is H.264 in MP4. --keep restores
# the old side-by-side behaviour. Creation date,
# QuickTime metadata and filesystem timestamps are carried over, so a converted
# Takeout library keeps its original ordering instead of collapsing to today.
{
  writeShellApplication,
  ffmpeg,
  gnugrep,
  coreutils,
}:
writeShellApplication {
  name = "fix-google-video";
  runtimeInputs = [
    ffmpeg
    gnugrep
    coreutils
  ];
  text = ''
    prog=fix-google-video
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }

    # A failed file is REPORTED and the batch continues; only a usage error is
    # fatal. `die` inside the loop would abandon 199 good files because file 200
    # was corrupt — which is precisely the shape of a Takeout folder.
    failed=0
    fail() { echo "$prog: error: $*" >&2; failed=1; }

    # The temp encode is removed if this run is interrupted. Without it a
    # Ctrl-C, a logout, or a launchd kill during a two-hour batch strands a
    # multi-GB `.fixing-*.mp4` beside every source it was working on.
    tmpout=""
    cleanup() { [ -n "$tmpout" ] && rm -f "$tmpout"; return 0; }
    trap cleanup EXIT INT TERM

    keep=0
    case "''${1:-}" in
      --keep) keep=1; shift ;;
      --help|-h)
        echo "usage: $prog [--keep] <video-file>..." >&2
        echo "  default: replace the input, moving the original to the Trash" >&2
        echo "  --keep:  write <name>_h264.mp4 alongside, original untouched" >&2
        exit 0 ;;
      -*) die "unknown option '$1' (try --help)" ;;
    esac

    [ $# -ge 1 ] || die "usage: $prog [--keep] <video-file>..."

    # Codecs mainstream editors (CapCut, Premiere, Final Cut, Resolve) import
    # without a second thought. Anything else (VP9, AV1, etc.) gets re-encoded.
    VIDEO_OK="h264|hevc|prores|mpeg4|mjpeg"
    AUDIO_OK="aac|ac3|alac|mp3|pcm_s16le|pcm_s24le"

    has_videotoolbox() {
      ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_videotoolbox"
    }

    for f in "$@"; do
      [ -f "$f" ] || { info "skip: '$f' not found"; continue; }
      fdir=''${f%/*}
      [ "$fdir" = "$f" ] && fdir=.

      # /usr/bin/stat by absolute path: coreutils is on PATH and GNU stat reads
      # -f as "filesystem status", so an unqualified call silently reports no
      # flags and every dataless file would sail through. A dataless file is an
      # iCloud placeholder — ffprobe would materialise it, so a folder sweep
      # would quietly pull gigabytes down and fail offline. (fix-extension
      # applies the same guard; these lines are duplicated rather than shared
      # because a sourced shell library costs more than it saves at this size.)
      case "$(/usr/bin/stat -f '%Sf' "$f" 2>/dev/null || true)" in
        *dataless*) info "skip: '$f' — not downloaded from iCloud"; continue ;;
      esac

      # Left over from a run that was killed mid-encode. Sweeping here rather
      # than only at startup means it also catches a sibling batch's debris.
      for stale in "$fdir"/*.fixing-*.mp4; do
        [ -e "$stale" ] || continue
        sname="''${stale##*/}"
        info "removing stale temp encode '$sname'"
        rm -f "$stale"
      done

      vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null || true)
      acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null || true)

      if [ -z "$vcodec" ]; then
        info "skip: '$f' — no readable video stream"
        continue
      fi

      need_video=1
      echo "$vcodec" | grep -qE "^($VIDEO_OK)$" && need_video=0

      need_audio=0
      if [ -n "$acodec" ] && ! echo "$acodec" | grep -qE "^($AUDIO_OK)$"; then
        need_audio=1
      fi

      if [ "$need_video" -eq 0 ] && [ "$need_audio" -eq 0 ]; then
        info "OK: '$f' already editor-safe (video=$vcodec''${acodec:+, audio=$acodec})"
        continue
      fi

      # REPLACES the input. The encode goes to a temp file beside it first, is
      # verified, and only then swaps in — so an ffmpeg failure or a full disk
      # leaves the original untouched rather than half-written.
      #
      # The original is moved to ~/.Trash, never rm'd. This tool runs over photo
      # libraries in batches; "recoverable" is worth more here than "tidy".
      # --keep restores the old side-by-side behaviour.
      target="''${f%.*}.mp4"     # .mkv/.avi inputs become .mp4 — H.264 in MP4
      if [ "$keep" -eq 1 ]; then
        target="''${f%.*}_h264.mp4"
        if [ -e "$target" ]; then
          info "skip: '$target' already exists"
          continue
        fi
      fi
      out="''${f%.*}.fixing-$$.mp4"
      tmpout="$out"

      # Re-encoding writes a whole second copy before the original goes. A
      # VideoToolbox encode at 8 Mbps can be LARGER than a heavily compressed
      # source, so the headroom is twice the source, not the source. Running out
      # of space mid-encode is the failure that leaves the biggest mess.
      need_kb=$(( ( $(/usr/bin/stat -f '%z' "$f") / 512 ) + 1 ))
      free_kb=$(/bin/df -k "$fdir" | awk 'NR==2 {print $4}')
      if [ "$free_kb" -lt "$need_kb" ]; then
        fail "not enough free space for '$f' (needs ~''${need_kb}KB, has ''${free_kb}KB) — skipped"
        continue
      fi

      vargs=(-c:v copy)
      if [ "$need_video" -eq 1 ]; then
        if has_videotoolbox; then
          vargs=(-c:v h264_videotoolbox -b:v 8M -pix_fmt yuv420p)
        else
          vargs=(-c:v libx264 -pix_fmt yuv420p -crf 18 -preset medium)
        fi
      fi
      aargs=(-c:a copy)
      [ "$need_audio" -eq 1 ] && aargs=(-c:a aac -b:a 192k)

      info "re-encoding '$f' (video=$vcodec, audio=''${acodec:-none}) -> '$target'"
      if ! ffmpeg -y -i "$f" -map_metadata 0 "''${vargs[@]}" "''${aargs[@]}" -movflags +faststart "$out"; then
        rm -f "$out"; tmpout=""
        fail "ffmpeg failed on '$f' (original untouched)"
        continue
      fi

      # Verify before anything destructive happens: a non-trivial file whose
      # duration matches the source. A truncated encode that still exits 0 is
      # the failure mode that would otherwise eat the original.
      src_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null || echo 0)
      out_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" 2>/dev/null || echo 0)
      if ! awk -v a="$src_dur" -v b="$out_dur" \
             'BEGIN { d = a - b; if (d < 0) d = -d; exit !(b > 0 && d <= 1.0) }'; then
        rm -f "$out"; tmpout=""
        fail "encode of '$f' failed verification (source ''${src_dur}s vs output ''${out_dur}s) — original untouched"
        continue
      fi

      # Carry the dates over. -map_metadata keeps the QuickTime creation_time
      # Photos reads on import; the filesystem mtime and (on macOS) birthtime
      # are what Finder sorts by, and both are otherwise stamped "now" — which
      # silently reorders a whole Takeout library to today's date.
      touch -r "$f" "$out"
      if [ -x /usr/bin/SetFile ] && [ -x /usr/bin/GetFileInfo ]; then
        /usr/bin/SetFile -d "$(/usr/bin/GetFileInfo -d "$f")" "$out" 2>/dev/null || true
      fi

      if [ "$keep" -eq 1 ]; then
        mv -f "$out" "$target"
        tmpout=""
        info "done: '$target' (original kept)"
        continue
      fi

      # Trash the original, then swap the new file in. Collisions in ~/.Trash
      # get a counter rather than clobbering whatever is already there.
      trash="$HOME/.Trash"
      mkdir -p "$trash"
      base=$(basename "$f")
      dest="$trash/$base"
      n=1
      while [ -e "$dest" ]; do
        dest="$trash/''${base%.*} $n.''${base##*.}"
        n=$((n + 1))
      done
      if ! mv "$f" "$dest"; then
        rm -f "$out"; tmpout=""
        fail "could not move '$f' to the Trash — original untouched"
        continue
      fi
      mv -f "$out" "$target"
      tmpout=""
      info "done: '$target' (original in Trash)"
    done

    [ "$failed" -eq 0 ] || exit 1
  '';
}
