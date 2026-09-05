# photo-describe — make a photo describe ITSELF, so you can find it later.
#
#   photo-describe [--dry-run] [--overwrite] [--no-caption]
#                  [--model NAME] [--min-score N] <file-or-dir>...
#
# Why this exists: choosing which shot to post is a RETRIEVAL problem, and a
# photo library answers no questions about itself. Finder can sort by date and
# nothing else; `IMG_7454.jpg` tells you nothing. This writes what the image is
# INTO the image, so Spotlight, Finder, Lightroom and Bridge can all answer
# "which one was the hillside shot?" without a database in between.
#
# THE DURABILITY RULE, which is the whole design: words go in the FILE, vectors
# go in an INDEX. A caption survives every model upgrade and every move between
# machines; an embedding is invalidated the day you change embedding models. So
# the expensive, irreplaceable artifact (the sentence) is embedded, and the
# cheap, regenerable one (the vector) is left to `rclip`, which keeps its own
# SQLite index, rebuildable at any time by RE-SCANNING THE PHOTOS. Note rclip
# embeds the PIXELS, not these captions — which is exactly why it finds things no
# caption mentions, and why a description could never reconstruct its index.
# Nothing here writes a vector into a photo.
#
# What gets written, and why these tags:
#
#   XMP:Description   the sentence. VERIFIED on this Mac: Spotlight indexes it
#                     as kMDItemDescription, so `mdfind` and Finder's search
#                     bar find it. This is the one that pays for the run.
#   XMP:Subject       the labels, as keywords. Also verified: it lands in
#                     kMDItemKeywords.
#   XMP:Rating        derived from the aesthetics score, for Lightroom/Bridge.
#                     NOT indexed by Spotlight (kMDItemStarRating stays null —
#                     measured), so it is a bonus for other tools, never the
#                     reason to run this.
#   IPTC:Keywords     the legacy IIM twin of dc:subject, for the older tools
#                     and indexers that read only that one.
#
# WHAT IS DELIBERATELY *NOT* WRITTEN: XMP-iptcCore:AltTextAccessibility. An
# earlier version put this same sentence there too, and that was wrong twice
# over. IPTC 2025.1 defines Alt Text as something that "should not be confused
# with" Description/Caption — the caption is the who/what/why and may name
# people, while alt text is replacement text for assistive technology — so one
# string cannot correctly be both. More seriously, the HTML Living Standard's
# "Guidance for markup generators" (§4.8.4.4.14) tells generators to obtain alt
# text FROM THE USER and, failing that, to write nothing, precisely so that the
# error of a missing alt attribute is not replaced by "the even more egregious
# error of providing phony alternative text". Alt text is defined by an image's
# purpose IN CONTEXT; this tool sees pixels and no context, so anything it wrote
# there would be an unreviewed guess sitting in the field WCAG conformance
# depends on. Nothing reads that field today, so writing it bought nothing and
# risked exactly that. If these photos are ever published, their alt text wants
# a human.
#
# (Kept for whoever adds it back: the family is `iptcCore`, NOT `iptcExt` —
# the tags live under "new IPTC Core 1.3 properties" in exiftool's XMP.pm, and
# an `-XMP-iptcExt:AltTextAccessibility=` write silently fails.)
#
# THE WALK IS NOT REIMPLEMENTED. Stage one is `fix-extension --only image
# --print0`, whose `--print0` seam exists for exactly this kind of caller. That
# buys, for free and already tested, the recursive walk, the refusal to enter a
# macOS package (`.photoslibrary`), and the three read-before-you-read guards:
# dataless iCloud files (sniffing one materialises it, so a folder sweep would
# quietly pull gigabytes down), in-flight `.crdownload`/`.part` files, and
# `._name` AppleDouble siblings. It also RENAMES a lying extension first, which
# matters here: `auge` and `exiftool` both dispatch on the extension, so a JPEG
# named `.png` would be analysed and tagged as the wrong format. Reusing it
# means those guards can never drift out of sync between the two tools.
#
# THREE TARGETED `auge` CALLS, NEVER `--all`. Measured on this Mac (macOS
# 26.6.2, auge 1.9.0), on one 18-megapixel JPEG:
#
#   --classify      0.07s     --aesthetics  0.12s     --face-quality  0.14s
#   --all          10.4s      AND its stdout is not parseable JSON — Vision
#                             writes framework noise (`FBBA: creating
#                             VNFaceBBoxAligner…`, a missing smudgenet bundle)
#                             into the stream, so `jq` fails on it.
#
# So `--all` is ~30x slower AND unusable from a script. The three calls are
# clean JSON and total ~0.33s. Combining flags does NOT work either — `auge
# --classify --aesthetics` silently reports only the LAST mode given, so each
# analysis genuinely needs its own invocation.
#
# `is_utility` SHORT-CIRCUITS THE EXPENSIVE HALF. Apple's aesthetics pass
# returns a flag meaning "this is a screenshot/receipt/document, not a
# photograph". Those still get labels, but never a caption: the VLM call is
# three orders of magnitude more expensive than the Vision calls, and a
# generated sentence about a screenshot is worth nothing for choosing a post.
#
# THE CAPTION GOES THROUGH OLLAMA'S HTTP API, NOT `ollama run`. The CLI finds
# images by parsing file paths out of the prompt STRING, which breaks on the
# spaces that fill every real photo library ("Screenshot 2026-08-30 at 6.14.18
# AM.png"). The API takes the image as base64 in a JSON field, where a filename
# cannot be misread as prose. Ollama is a soft dependency, deliberately: with
# it absent or the model unpulled, the run still writes labels and rating and
# says so, rather than failing and leaving the library half-tagged.
#
# `temperature: 0` AND A FIXED SEED ARE LOAD-BEARING, not tuning. At Ollama's
# default sampling the same photo gets a DIFFERENT caption on every run —
# measured, twice in a row on one image:
#
#   "…hillside path, holding cameras, with trees and steps…"
#   "…hillside with stone steps, enjoying a casual outdoor adventure."
#
# That makes re-describing a library non-reproducible and quietly shifts every
# downstream embedding, so an index built from these captions can never be
# rebuilt identically. At temperature 0 with a seed, two runs are byte-identical.
# Note what else that first sample shows: the model DOES see the cameras. An
# object missing from a caption is usually the sampler, not the model's sight.
#
# THE PROMPT ASKS FOR NOUNS, NOT MOOD, for the same retrieval reason. "Conveying
# casual, friendly camaraderie" spends a third of a 25-word budget on words
# nothing will ever search for. Measured against the older mood-first wording on
# the same three photos, the noun-first prompt recovered a camera, a wristwatch
# and a wall dispenser that the mood-first one had dropped — and lost nothing.
#
# HEIC is converted to a TEMPORARY JPEG for the caption step only. Every iPhone
# photo is HEIC and vision models generally reject it; the original is never
# rewritten by that conversion, only read.
#
# Idempotent by default: a file that already carries an XMP:Description is
# skipped, so re-running over a library only fills the gaps. `--overwrite`
# forces a re-describe when you change models.
#
# Output grammar (`done:` / `skip:` / `OK:` / `error:`, each naming the file in
# single quotes) is the one shared with the other media CLIs — see
# fix-extension.nix. It is a CONTRACT, not a style: media-queue's worker counts
# `done:` lines to report what changed and lifts the first `skip:`/`OK:` line as
# the reason a batch changed nothing, so a CLI that invents its own vocabulary
# is silently reported as having done nothing at all.
#
# `-overwrite_original_in_place -P` is deliberate. Plain `-overwrite_original`
# writes a NEW file and renames it over the original, which drops every extended
# attribute (Finder tags, `kMDItemWhereFroms` download provenance) and stamps a
# fresh mtime on every photo — reordering the library by Date Modified and making
# backups re-upload everything. In-place keeps the inode and `-P` keeps the date.
# Neither form leaves a full
# `IMG_1234.jpg_original` copy beside every file, which in a photo library
# means doubling it on disk and showing the operator two of everything in
# Finder. The writes are metadata-segment-only — the compressed image data is
# preserved byte-for-byte, so there is nothing to roll back to.
#
# `-P` MAKES MTIME A LIVENESS TRAP — MEASURED, incident 2026-09-05. Because
# `-P` deliberately preserves the original modification time, a SUCCESSFUL
# write never bumps it. `ls -lt`, `find -newermt`, and any other mtime-based
# "is this tool doing anything?" check is a GUARANTEED FALSE NEGATIVE against
# this file, no matter how many photos it has actually described. That false
# reading, stacked with the worker's own end-of-job-only log flush (see
# packages/media-queue.nix's `tail -f "$scratch"` comment), is what turned a
# perfectly healthy ~4-hour describe batch into a "hung job" diagnosis. The
# real liveness probes, also in docs/photo-system.md:
#
#   # authoritative: how many are actually described right now
#   exiftool -q -q -m -if '$XMP:Description' -p '1' "<folder>" | wc -l
#
#   # is a model call in flight right now
#   pgrep -afl curl | grep 11434
#
{
  lib,
  writeShellApplication,
  callPackage,
  auge,
  exiftool,
  jq,
  curl,
  coreutils,
  fix-extension ? callPackage ./fix-extension.nix { },
  # The caption model, as a BUILD-TIME override rather than an env var. It has
  # to be one or the other and it cannot be both: `--model` already owns the
  # per-run axis, and a third source of truth (env) between the Nix default and
  # the flag is exactly how "which model actually ran?" stops being answerable
  # from the derivation. A fork or the home-manager option sets this; an
  # operator uses --model.
  defaultModel ? "huihui_ai/qwen3-vl-abliterated",
}:
writeShellApplication {
  name = "photo-describe";
  runtimeInputs = [
    fix-extension
    auge
    exiftool
    jq
    curl
    coreutils
  ];
  text = ''
    prog=photo-describe
    usage="usage: $prog [--dry-run] [--overwrite] [--no-caption] [--model NAME] [--min-score N] <file-or-directory>..."
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }

    dry=0
    overwrite=0
    caption=1
    # Qwen3-VL, abliterated. Same base as the stock `qwen3-vl:4b-instruct` this
    # replaced — chosen on PhotoPrism's 12-model captioning benchmark (best label
    # coverage at its size, and no animal-misidentification bug) — but with the
    # refusal behaviour removed.
    #
    # WHY THAT MATTERS FOR A PERSONAL LIBRARY: a safety-tuned captioner does not
    # refuse loudly on an ordinary private photo, it hedges — it generalises, omits
    # what it is unsure it should mention, and still returns a confident-looking
    # sentence. Measured here: the stock model captioned a dim bedroom photo as
    # "both bare-chested" when only one person is, which is the shape that failure
    # takes. Since every consumer of this metadata is the operator searching their
    # OWN photos, a hedge is pure loss — it makes the picture harder to find and
    # gives no one any protection.
    #
    # Override per run with --model; nothing here is load-bearing beyond the
    # default, and the caption step degrades to labels-only if the model is absent.
    model=${lib.escapeShellArg defaultModel}

    # Long-edge cap for the image handed to the vision model. See the
    # measurements at the downscale step for why 1024 and not 4000 or 256.
    CAPTION_MAX_PX=1024
    # EMPTY means "no gate", NOT zero. Apple's aesthetics score is NOT 0-1: it
    # goes NEGATIVE on poor images (measured -0.14 on a dark indoor snapshot).
    # A default of 0 therefore silently gated captioning off for exactly the
    # photos that most need a description to be findable — they got labels and
    # no sentence, with nothing in the output saying why.
    min_score=""
    host="''${OLLAMA_HOST:-http://127.0.0.1:11434}"
    # Bare host:port is a legal OLLAMA_HOST; curl needs a scheme.
    case "$host" in http://*|https://*) ;; *) host="http://$host" ;; esac

    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run)    dry=1; shift ;;
        --overwrite)  overwrite=1; shift ;;
        --no-caption) caption=0; shift ;;
        --model)      model="''${2:-}"; [ -n "$model" ] || die "--model needs a name"; shift 2 ;;
        --min-score)  min_score="''${2:-}"; [ -n "$min_score" ] || die "--min-score needs a number"; shift 2 ;;
        --help|-h)
          echo "$usage" >&2
          echo "  writes XMP:Description + XMP:Subject + XMP:Rating into each image" >&2
          echo "  --no-caption   labels and rating only; never calls the vision model" >&2
          echo "  --min-score N  only caption photos scoring above N (0-1)" >&2
          echo "  --overwrite    re-describe files that already have a description" >&2
          echo "  directories are walked recursively" >&2
          exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1" ;;
        *)  break ;;
      esac
    done

    [ $# -ge 1 ] || die "$usage"

    # Stage one: the walk, the package/dataless/in-flight/AppleDouble guards and
    # the extension repair all belong to fix-extension. Its stdout is the
    # surviving file list (NUL-separated), its log goes to stderr.
    list=$(mktemp)
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$list" "$tmpdir"' EXIT
    rc=0
    # --dry-run MUST be forwarded. Stage one RENAMES files whose extension lies
    # about their content, so without this the one command meant to preview
    # changes was itself mutating the tree. fix-extension's own --dry-run still
    # emits the paths on --print0, so the rest of this run previews normally.
    stage1_flags=()
    [ "$dry" -eq 1 ] && stage1_flags+=(--dry-run)
    fix-extension --only image --print0 ''${stage1_flags[@]+"''${stage1_flags[@]}"} "$@" \
      > "$list" 2> "$tmpdir/stage1.err" || rc=$?
    # Stage one's `OK:` lines say "nothing was wrong with the extension", which is
    # the normal case here and is never a reason for anything this CLI reports.
    # They must not reach the caller: media-queue lifts the FIRST skip:/OK: line
    # as the reason a batch changed nothing, so passing them through made a
    # right-click on an already-described photo announce "extension already
    # matches (image/jpeg)" instead of "already described". `done:`/`skip:`/
    # `error:` still pass — those are real outcomes the operator should see.
    grep -v ': OK: ' "$tmpdir/stage1.err" >&2 || true

    files=()
    while IFS= read -r -d "" f; do
      files+=("$f")
    done < "$list"

    if [ ''${#files[@]} -eq 0 ]; then
      # "readable" not "no image files": stage one also drops files it cannot
      # safely touch — a dataless iCloud placeholder, an in-flight download, a
      # macOS package, or a directory exiftool has no write access to. Reporting
      # those as "no image files" claimed the folder was empty when it was not.
      info "OK: 'selection' — no readable image files to look at"
      exit "$rc"
    fi

    # One reachability probe for the whole run, not one per file.
    ollama_up=0
    # WHY a caption is missing, carried into the per-file skip: line. A partial
    # result must say what was missing, or a whole batch run against a stopped
    # Ollama is indistinguishable from a complete one.
    vlm_gap="captions disabled"
    if [ "$caption" -eq 1 ]; then
      if curl -fsS -m 3 "$host/api/tags" -o "$tmpdir/tags.json" 2>/dev/null; then
        # `:latest` is IMPLICIT everywhere except here. Ollama registers an
        # untagged pull as `name:latest` and its /api/generate resolves a bare
        # name back to it, so a bare `--model foo` runs fine — but an exact
        # string match against /api/tags does not, and this check then reported a
        # present model as "not pulled" and silently downgraded every photo to
        # labels-only. Match the bare name OR its :latest form.
        if jq -e --arg m "$model" \
          '.models[]?.name | select(. == $m or . == ($m + ":latest"))' \
          "$tmpdir/tags.json" >/dev/null 2>&1; then
          ollama_up=1
        else
          vlm_gap="model '$model' not pulled"
          info "note: model '$model' is not pulled — writing labels only (ollama pull $model)"
        fi
      else
        vlm_gap="no ollama at $host"
        info "note: no ollama at $host — writing labels only"
      fi
    fi

    # EXIF:UserComment, NOT XMP:Identifier. Measured which fields survive an
    # edit by cropping a described file with `sips`: Description, Source,
    # photoshop:Instructions, IPTC:SpecialInstructions and UserComment all
    # survived — `XMP:Identifier` and `XMP:Label` were the only two DROPPED. The
    # stamp has to outlive the edit it exists to detect, so Identifier was
    # exactly the wrong choice. UserComment is the least semantically loaded of
    # the survivors; the prefix keeps it identifiable and stops this from ever
    # claiming a comment the operator wrote.
    stampPrefix="photo-describe:pixhash="

    described=0
    skipped=0

    for f in "''${files[@]}"; do
      if [ "$overwrite" -eq 0 ]; then
        # Read the description AND the pixel hash in ONE call, as JSON. `-s3`
        # would omit an empty tag entirely, so two values could not be told
        # apart when one is missing; jq keys them by name instead.
        meta=$(exiftool -json -XMP:Description -EXIF:UserComment "$f" 2>/dev/null || true)
        existing=$(printf '%s' "$meta" | jq -r '.[0].Description // ""' 2>/dev/null || true)
        stamped=$(printf '%s' "$meta" | jq -r '.[0].UserComment // ""' 2>/dev/null || true)
        # The stamp carries the pixel hash AND the labels this tool last wrote:
        #   photo-describe:pixhash=<md5>;labels=a,b,c
        # The label list is what makes a re-describe able to remove ITS OWN stale
        # keywords without touching the operator's. Keywords are append-only by
        # design (clearing them was destroying hand-authored ones), so nothing
        # else can retract a label that is no longer true — measured: a photo
        # cropped until no person remained kept `people, adult, eyeglasses` while
        # its regenerated caption said "zero people".
        prior_labels=""
        case "$stamped" in
          "$stampPrefix"*)
            stamped=''${stamped#"$stampPrefix"}
            case "$stamped" in
              *";labels="*)
                prior_labels=''${stamped#*";labels="}
                stamped=''${stamped%%";labels="*}
                ;;
            esac
            ;;
          *) stamped="" ;;
        esac
        if [ -n "$existing" ]; then
          # A DESCRIPTION IS NOT PROOF IT IS STILL TRUE. Skipping on its mere
          # presence meant an image edited after being described kept a caption
          # of content that no longer existed — measured: a photo captioned "A
          # man in a striped shirt stands before Tower Bridge" was cropped until
          # no person remained, and the re-run said "already described" while the
          # correct caption was "Tower Bridge spans a river; zero people
          # visible". Editors preserve XMP on save, so that is the DEFAULT
          # outcome of editing a described photo, not an edge case.
          #
          # ImageDataHash hashes the PIXELS only — writing metadata does not
          # change it (verified when proving these writes are lossless), so it is
          # exactly the signal for "has the picture itself changed". It costs
          # ~8ms against a 16s caption.
          #
          # An unstamped file was described before this existed: stamp it and
          # trust the caption rather than re-running the model on the whole
          # library the first time this ships.
          current=$(exiftool -api requesthash=md5 -s3 -ImageDataHash "$f" 2>/dev/null || true)
          if [ -z "$stamped" ] && [ -n "$current" ]; then
            exiftool -overwrite_original_in_place -P -q -q "-EXIF:UserComment=$stampPrefix$current;labels=" "$f" 2>/dev/null || true
            skipped=$((skipped + 1))
            info "OK: '$f' — already described (stamped for future edit detection)"
            continue
          fi
          if [ -z "$current" ] || [ "$stamped" = "$current" ]; then
            skipped=$((skipped + 1))
            info "OK: '$f' — already described"
            continue
          fi
          info "re-describing '$f' — the image changed since it was described"
          # Retract exactly the labels WE wrote last time, before the new ones go
          # on. Anything the operator added is absent from this list and survives.
          if [ -n "$prior_labels" ]; then
            retract=()
            IFS=',' read -r -a old_labels <<< "$prior_labels"
            for ol in ''${old_labels[@]+"''${old_labels[@]}"}; do
              [ -n "$ol" ] || continue
              retract+=("-XMP:Subject-=$ol" "-IPTC:Keywords-=$ol")
            done
            [ ''${#retract[@]} -gt 0 ] && exiftool -overwrite_original_in_place -P -q -q \
              "''${retract[@]}" "$f" 2>/dev/null || true
          fi
        fi
      fi

      # --- Apple Vision: labels + aesthetics, on-device, no network ---
      labels=()
      vision_ok=0
      if auge --classify --top 12 --min-confidence 0.3 --json --compact "$f" > "$tmpdir/cls.json" 2>/dev/null; then
        vision_ok=1
        while IFS= read -r l; do
          [ -n "$l" ] && labels+=("$l")
        done < <(jq -r '.results.classifications[]?.label // empty' "$tmpdir/cls.json" 2>/dev/null || true)
      fi

      score=""
      utility=false
      if auge --aesthetics --json --compact "$f" > "$tmpdir/aes.json" 2>/dev/null; then
        vision_ok=1
        score=$(jq -r '.results.aesthetics.overall // empty' "$tmpdir/aes.json" 2>/dev/null || true)
        utility=$(jq -r '.results.aesthetics.is_utility // false' "$tmpdir/aes.json" 2>/dev/null || echo false)
      fi

      # A format Vision cannot read at all (WebP, PSD, ICO — none of which auge
      # handles) used to fall straight through to the exiftool call below with
      # NOTHING to add. The arg vector was then pure DELETION: it cleared the
      # file's keywords and wrote nothing back, and still reported `done:`.
      # Refuse the file instead. This must come BEFORE the arg vector is built,
      # not inside it, because the destructive part is the clear, not the write.
      if [ "$vision_ok" -eq 0 ]; then
        skipped=$((skipped + 1))
        info "skip: '$f' — no readable image data (unsupported format?)"
        continue
      fi

      # Apple's 0-1 aesthetics score onto XMP's 0-5 stars, for Lightroom/Bridge.
      rating=""
      [ -n "$score" ] && rating=$(awk -v s="$score" 'BEGIN{ r=int(s*5+0.5); if(r>5)r=5; if(r<0)r=0; print r }')

      # --- the caption: skipped for screenshots, and for anything below the gate ---
      sentence=""
      caption_gap="$vlm_gap"
      want_caption=0
      if [ "$ollama_up" -eq 1 ] && [ "$utility" = "true" ]; then
        caption_gap="screenshot/document, not a photograph"
      fi
      if [ "$ollama_up" -eq 1 ] && [ "$utility" != "true" ]; then
        if [ -z "$score" ] || [ -z "$min_score" ] || awk -v s="$score" -v m="$min_score" 'BEGIN{ exit !(s >= m) }'; then
          want_caption=1
        else
          caption_gap="aesthetics $score below --min-score $min_score"
        fi
      fi

      if [ "$want_caption" -eq 1 ]; then
        caption_gap="the vision model returned nothing"
        shot="$f"
        # Case-folded: `.Heic` is rare from macOS but a `case` listing only the
        # two common spellings silently skipped the JPEG conversion, and the
        # model then rejected the file — a permanent, silent caption loss.
        case "$(printf '%s' "''${f##*.}" | tr '[:upper:]' '[:lower:]')" in
          heic|heif)
            shot="$tmpdir/shot.jpg"
            /usr/bin/sips -s format jpeg "$f" --out "$shot" >/dev/null 2>&1 || shot="$f" ;;
        esac

        # DOWNSCALE FOR THE MODEL. Qwen3-VL resizes to its own patch budget
        # anyway, so the megapixels past that budget are encoded, transferred
        # and thrown away. Measured on this Mac, one 4000x3000 JPEG, same model,
        # temperature 0 and seed 42, alternating runs to control for warm state:
        #
        #   4000px  21s   "...holds a smartphone in a tiled room with teal and
        #                  gray tiles"
        #   1024px  11s   "...holds a smartphone AND EARPHONES against a tiled
        #                  wall with gray and teal accents"
        #
        # Half the time, and the smaller input named a detail the full-resolution
        # one missed — the model is not seeing more at 4000px, it is picking
        # different salient objects. Content held steady down to 256px; 128px is
        # where it broke, turning a tiled room into "an office with white walls".
        # 1024 is the cap because it was both the fastest measured and the run
        # that caught the extra detail.
        #
        # ONLY EVER SHRINKS. `sips -Z` UPSCALES a smaller source — measured, a
        # 256px image came back 1024px — which would inflate every WhatsApp
        # thumbnail and screenshot in a Takeout dump into a bigger payload
        # carrying no more information. Hence the dimension check rather than an
        # unconditional call.
        #
        # The original is never touched: this writes a throwaway into $tmpdir,
        # and only the caption step ever sees it. OCR and face work are NOT
        # routed through here, because those genuinely need the pixels.
        long=$(/usr/bin/sips -g pixelWidth -g pixelHeight "$shot" 2>/dev/null \
               | awk '/pixel(Width|Height)/ { if ($2 > m) m = $2 } END { print m + 0 }')
        if [ "''${long:-0}" -gt "$CAPTION_MAX_PX" ]; then
          small="$tmpdir/shot-''${CAPTION_MAX_PX}.jpg"
          if /usr/bin/sips -s format jpeg -Z "$CAPTION_MAX_PX" "$shot" --out "$small" >/dev/null 2>&1; then
            shot="$small"
          fi
        fi
        if base64 < "$shot" | tr -d '\n' > "$tmpdir/b64" 2>/dev/null; then
          jq -n --arg m "$model" --rawfile b "$tmpdir/b64" \
            '{model:$m, stream:false, images:[$b],
              options:{temperature:0, seed:42},
              prompt:"Describe this photograph in one plain sentence under 25 words. Name the concrete things visible: how many people, what they wear or hold, the setting, and any notable objects. Prefer specific nouns over mood words. Do not begin with \"This image\" or \"The photo\"."}' \
            > "$tmpdir/req.json" 2>/dev/null || true
          if curl -fsS -m 180 -H 'Content-Type: application/json' \
               -d @"$tmpdir/req.json" "$host/api/generate" > "$tmpdir/resp.json" 2>/dev/null; then
            # `|| true`: every sibling jq here is guarded and this one was not.
            # A 200 response whose body is not JSON (a proxy interstitial in
            # front of a non-default OLLAMA_HOST) exits jq 5, and under
            # `set -euo pipefail` that aborted the WHOLE batch silently — no
            # grammar line, no summary, remaining files untouched. Unreachable
            # against a local Ollama, whose error paths are all 4xx JSON that
            # `curl -f` already catches, but a one-token guard against a
            # whole-run abort is worth having regardless.
            sentence=$(jq -r '.response // empty' "$tmpdir/resp.json" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//' || true)
          fi
        fi
      fi

      if [ "$dry" -eq 1 ]; then
        echo "$prog: would describe: $f"
        [ -n "$score" ]  && echo "    score:   $score (rating $rating, utility=$utility)"
        [ ''${#labels[@]} -gt 0 ] && echo "    labels:  ''${labels[*]}"
        [ -n "$sentence" ] && echo "    caption: $sentence"
        described=$((described + 1))
        continue
      fi

      # `-overwrite_original_in_place`, NOT `-overwrite_original`: the latter
      # writes a NEW file and renames it over the original, which silently drops
      # every extended attribute (Finder tags, and `com.apple.metadata:
      # kMDItemWhereFroms` — the download provenance) and stamps a fresh mtime on
      # every photo it touches. That reorders the library by Date Modified and
      # makes every backup re-upload the whole set. In-place keeps the inode;
      # `-P` preserves the modification date. Both verified.
      args=(-overwrite_original_in_place -P -q -q)
      # APPEND, never clear. This used to clear XMP:Subject and IPTC:Keywords
      # first "so a re-describe replaces the list" — but that clear ran on the
      # DEFAULT path for every photo, so a file carrying keywords from Lightroom,
      # Photos or the operator's own hand lost them irreversibly, with no backup
      # (see -overwrite_original above). `+=` with `-api NoDups` gets the intended
      # idempotence without the destruction: re-running adds nothing, because the
      # labels are the same. IPTC:Keywords is the legacy IIM twin of dc:subject,
      # written alongside it for the older tools that read only that one.
      # `-=` then `+=` per value is exiftool's add-if-absent idiom, and it is what
      # makes appending idempotent WITHOUT a clear: the delete removes only that
      # exact value if present, the add puts it back exactly once, and every other
      # keyword on the file is untouched. `-api NoDups` does NOT do this — measured
      # on exiftool 13.59, it leaves `alpha, alpha, beta` after a repeat `+=`.
      human_labels=()
      for l in ''${labels[@]+"''${labels[@]}"}; do
        # Apple's label identifiers are snake_case (`consumer_electronics`,
        # `wood_processed`). That underscore is an internal token, not a word:
        # it survives into Finder's Get Info, reads as machine output, and
        # breaks the substring search this metadata exists to serve.
        human=''${l//_/ }
        human_labels+=("$human")
        args+=(
          "-XMP:Subject-=$human" "-XMP:Subject+=$human"
          "-IPTC:Keywords-=$human" "-IPTC:Keywords+=$human"
        )
      done
      # RATING IS A HUMAN JUDGEMENT WHEREVER ONE EXISTS. Lightroom/Bridge stars
      # live in this field, and an aesthetics score is not entitled to overwrite
      # them. Write only into an empty field — unless --overwrite, which is the
      # operator explicitly asking for this tool's opinion instead.
      if [ -n "$rating" ]; then
        existing_rating=$(exiftool -s3 -XMP:Rating "$f" 2>/dev/null || true)
        if [ -z "$existing_rating" ] || [ "$overwrite" -eq 1 ]; then
          args+=("-XMP:Rating=$rating")
        fi
      fi
      # Stamp the pixel hash ALONGSIDE the caption, so a later run can tell
      # whether the picture still matches the words. Only when a caption is
      # actually written: stamping a labels-only file would claim a description
      # had been checked against these pixels when there is no description.
      if [ -n "$sentence" ]; then
        args+=("-XMP:Description=$sentence")
        pixhash=$(exiftool -api requesthash=md5 -s3 -ImageDataHash "$f" 2>/dev/null || true)
        # Never clobber a comment the operator wrote: only claim the field when it
        # is empty or already carries our prefix.
        prior=$(exiftool -s3 -EXIF:UserComment "$f" 2>/dev/null || true)
        case "$prior" in
          ""|"$stampPrefix"*)
            # The HUMANIZED forms, because those are what actually go on the
            # file — storing the raw snake_case ones meant `-=water_body` could
            # never match the written `water body`, so retraction silently
            # missed every multi-word label.
            written=$(IFS=,; echo "''${human_labels[*]-}")
            [ -n "$pixhash" ] && args+=("-EXIF:UserComment=$stampPrefix$pixhash;labels=$written")
            ;;
        esac
      fi

      if exiftool "''${args[@]}" "$f" 2>/dev/null; then
        described=$((described + 1))
        if [ -n "$sentence" ]; then
          info "done: '$f' — $sentence"
        else
          # `skip:`, NOT `done:` — and it does not count as described. A photo
          # that got labels but no sentence is the tool's PARTIAL result, and
          # reporting it as done made a whole batch run with Ollama stopped look
          # like complete success. It is now visible in the grammar the queue
          # parses, so the notification can say what actually happened, and a
          # later run still picks the file up (idempotence keys on Description).
          described=$((described - 1))
          skipped=$((skipped + 1))
          info "skip: '$f' — labelled only, no caption ($caption_gap)"
        fi
      else
        info "error: '$f' — could not write metadata"
        rc=1
      fi
    done

    # Summary WITHOUT the grammar prefix. `OK: 'selection' — …` matched the
    # worker's skip:/OK: grep, so every describe job scored a phantom +1 skip and
    # could have its reason lifted from a line that names no file. Only the
    # empty-selection case keeps the grammar form, exactly as fix-media does,
    # because there it IS the outcome.
    info "summary: $described described, $skipped skipped"
    exit "$rc"
  '';
}
