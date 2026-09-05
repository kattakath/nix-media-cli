# extract-audio — pull the audio track out of a video file.
#
#   extract-audio <file>...              # MP3 (the default)
#   extract-audio --copy <file>...       # lossless: copy the stream as-is
#   extract-audio --wav|--flac <file>... # other transcodes
#
# MP3 is the default because it plays everywhere without a second thought,
# which is what "extract the audio" is usually in service of.
#
# `--copy` is the quality-preserving path and stays available: a video's audio
# track is already a finished encode, so transcoding it is a second lossy
# generation, and copying needs no decode at all (~16000x realtime, measured).
# What copying costs is a container decision, which is why this is a wrapper
# and not a bare ffmpeg alias: a copied stream has to land in a container that
# accepts that codec, and `-c:a copy` into the wrong one fails ("could not
# find tag for codec"). The codec→extension map below is that knowledge --
# `.m4a` for AAC/ALAC, `.ogg` for Vorbis, `.wav` for PCM -- with `.mka`
# (Matroska accepts anything) as the fallback for unrecognised codecs.
#
# Output is written alongside the input; the original is never modified, and
# an existing output is skipped, so a re-run over a folder is idempotent.
# Timestamps are carried over — same reasoning as fix-google-video.nix, where
# a fresh mtime silently reorders a whole library.
{
  writeShellApplication,
  ffmpeg,
  coreutils,
}:
writeShellApplication {
  name = "extract-audio";
  runtimeInputs = [
    ffmpeg
    coreutils
  ];
  text = ''
    prog=extract-audio
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }

    mode=mp3
    case "''${1:-}" in
      --mp3)  mode=mp3;  shift ;;
      --copy) mode=copy; shift ;;
      --wav)  mode=wav;  shift ;;
      --flac) mode=flac; shift ;;
      --help|-h)
        echo "usage: $prog [--mp3|--copy|--wav|--flac] <video-file>..." >&2
        echo "  default: MP3. --copy keeps the original stream losslessly." >&2
        exit 0 ;;
      -*) die "unknown option '$1' (try --help)" ;;
    esac

    [ $# -ge 1 ] || die "usage: $prog [--mp3|--copy|--wav|--flac] <video-file>..."

    # A copied stream must land in a container that accepts that codec.
    # Matroska (.mka) takes anything, so it is the safe fallback.
    container_for() {
      case "$1" in
        aac|alac)      echo m4a ;;
        mp3)           echo mp3 ;;
        opus)          echo opus ;;
        flac)          echo flac ;;
        vorbis)        echo ogg ;;
        ac3)           echo ac3 ;;
        eac3)          echo eac3 ;;
        dts)           echo dts ;;
        pcm_*)         echo wav ;;
        *)             echo mka ;;
      esac
    }

    for f in "$@"; do
      [ -f "$f" ] || { info "skip: '$f' not found"; continue; }

      acodec=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null || true)
      if [ -z "$acodec" ]; then
        info "skip: '$f' — no audio stream"
        continue
      fi

      case "$mode" in
        copy) ext=$(container_for "$acodec"); aargs=(-c:a copy) ;;
        mp3)  ext=mp3;  aargs=(-c:a libmp3lame -q:a 2) ;;
        wav)  ext=wav;  aargs=(-c:a pcm_s16le) ;;
        flac) ext=flac; aargs=(-c:a flac) ;;
      esac

      out="''${f%.*}.$ext"
      [ "$out" = "$f" ] && out="''${f%.*}_audio.$ext"
      if [ -e "$out" ]; then
        info "skip: '$out' already exists"
        continue
      fi

      if [ "$mode" = copy ]; then
        info "extracting '$f' (''${acodec}, copy) -> '$out'"
      else
        info "extracting '$f' (''${acodec} -> ''${mode}) -> '$out'"
      fi

      # -vn drops video, -map 0:a:0 takes the first audio track only (a file
      # with several would otherwise be muxed into one stream set), and
      # -map_metadata 0 keeps titles/dates rather than writing a bare file.
      ffmpeg -y -i "$f" -vn -map 0:a:0 -map_metadata 0 "''${aargs[@]}" "$out" \
        || die "ffmpeg failed on '$f'"
      touch -r "$f" "$out"
      info "done: '$out'"
    done
  '';
}
