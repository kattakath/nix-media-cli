# media-toolkit — the fleet's local media-file CLIs, as one installable unit.
#
#   media <describe|fix|audio|queue> ...   one entry point for everything below
#   media-describe <file-or-dir>...        write what an image IS into the image
#                                          (XMP description + keywords + rating)
#   media-fix <--video|--image> <path>...  repair a media file by CLASS, deciding
#                                          which of the below it actually needs
#   media-fix-extension <file-or-dir>...   rename a file whose extension lies
#                                          about its content
#   media-transcode <file>...              re-encode editor-hostile video
#   media-extract-audio [--mp3|…] <file>…  pull out the audio track
#
# THE NAMING SCHEME: one domain prefix, verb first, flat. `media` is the domain
# word and stays bare, because a dispatcher named for its domain is the standard
# shape (git, nix, docker). Everything else is `media-<verb>`.
#
# Matches this fleet's own precedent rather than a generic convention:
# kattakath/nix-vast-provision settled on flat `vast-<verb>` — vast-rent,
# vast-repo-check, vast-account-vars-set — with no dispatcher layer. This is that
# scheme plus the umbrella it had already grown.
#
# Renamed 2026-09-05, from three clashing schemes that had accreted from
# different directions: a `fix-*` prefix (fix-media, fix-extension,
# fix-google-video), bare nouns (photo-describe, extract-audio), and the
# `media-queue-*` family. Two of those names were actively wrong, not merely
# inconsistent:
#
#   fix-google-video -> media-transcode
#     Named for a SYMPTOM and, worse, for one vendor. Its codec allowlist is
#     h264|hevc|prores|mpeg4|mjpeg — it re-encodes ANY editor-hostile codec
#     (VP9, AV1), and nothing in the script is Google-specific. The Google
#     Photos Takeout story is real and stays in that file's header, where a
#     motivating anecdote belongs; it has no business in a permanent CLI name.
#
#   photo-describe -> media-describe
#     A fourth prefix owned by a single tool, and inaccurate besides: it handles
#     screenshots and receipts too (Apple's aesthetics pass returns an
#     is_utility flag precisely so it can skip captioning those).
#
# The cost was real and was accepted deliberately: the machine cost is nil (the
# Finder .workflow bundles are generated from these derivations and follow a
# rename automatically), but the operator's muscle memory and notes were written
# in the old form. No aliases ship, because this flake was two hours old with a
# single consumer when the rename landed — the moment for it was exactly then.
#
# A symlinkJoin, deliberately, not a single dispatching binary: each CLI stays
# its own derivation, keeps its own `nix run .#<name>` app, and is shellchecked
# and testable on its own. This only bundles them, so `home.packages` carries
# one entry instead of drifting out of sync as CLIs are added — which already
# happened once: media-extract-audio shipped as a flake package but was never added
# to home.nix, so it was reachable by `nix run` and absent from PATH.
#
# TWO DIFFERENT MEMBERSHIP QUESTIONS, and conflating them is the mistake this
# comment exists to prevent:
#
#   1. What ships in THIS FLAKE?  "Media work you want to add or strip off as
#      one unit." That is a repo-scope question, and it is generous.
#   2. What goes in THIS BUNDLE?  A CLI that ACTS ON A MEDIA FILE the operator
#      selected, on this machine. That is a dependency-scope question, and it
#      is strict — because `media-toolkit` is what media-worker and the Finder
#      Services put on their PATH, so every member becomes a runtime dependency
#      of the queue.
#
# `obs-fb-setup` and `fidelity-enhance` answer YES to (1) and NO to (2):
#
#   - obs-fb-setup writes an OBS config profile and reads a Keychain secret.
#     It configures an app; it never touches a media file.
#   - fidelity-enhance is an MCP server / referee for an agentic image loop,
#     running an ephemeral uv environment (~1 GB of torch/insightface on first
#     run). It judges images, generating and transforming nothing.
#
# So they live in this flake, behind their own opt-in module options, and stay
# OUT of this bundle. Folding them in would put a uv/Python environment and a
# Keychain read on the media queue worker's PATH for no reason, and would make
# "media-toolkit" mean only "vaguely about media", which is not a useful thing
# for it to mean.
#
# (Earlier revisions of this header said both "stay separate" full stop, from
# when this file lived in a mono-repo where separate-from-the-bundle and
# separate-from-the-repo were the same thing. They no longer are.)
#
# media-fix-extension is the one member that changes no bytes — it only renames. It
# still belongs: it operates directly on the selected media file and repairs it
# for the same consumer (Finder/Photos) the other two serve, and the rule above
# exists to exclude tools that never touch a file at all, not to require a
# re-encode.
#
# media-fix is the odd one out in the other direction: it transforms nothing
# itself, it DISPATCHES to the members that do. It belongs here because it is
# the entry point the Finder Services actually call, and because splitting a
# dispatcher from the things it dispatches to is how the two drift apart.
#
# media-describe is the third edge case, and the closest call. It changes no
# pixels — like media-fix-extension it only rewrites what the file SAYS about itself
# — and it is the only member with a soft dependency on a service (Ollama) that
# lives outside its closure. It still belongs: it acts directly on the media
# file the operator selected, and it repairs the same defect media-fix-extension does
# for the same consumer — a file Finder and Spotlight cannot answer questions
# about. It is also the natural next stage AFTER media-fix-extension, whose --print0
# seam it consumes exactly as media-fix does.
#
# The Ollama dependency is what keeps it from being folded into media-fix's
# --image pipeline: a repair must finish offline and in bounded time, and a
# vision model is neither. So describing stays a separate, explicit verb.
{
  symlinkJoin,
  callPackage,
  media-transcode ? callPackage ./media-transcode.nix { },
  media-extract-audio ? callPackage ./media-extract-audio.nix { },
  media-fix-extension ? callPackage ./media-fix-extension.nix { },
  media-fix ? callPackage ./media-fix.nix { },
  media-describe ? callPackage ./media-describe.nix { },
  media ? callPackage ./media.nix { },
}:
symlinkJoin {
  name = "media-toolkit";
  paths = [
    media-transcode
    media-extract-audio
    media-fix-extension
    media-fix
    media-describe
    media
  ];
  meta = {
    description = "Local media-file CLIs: media-transcode (re-encode editor-hostile video), media-extract-audio (pull out the audio track) media-fix-extension (rename files whose extension lies about their content), media-fix (repair a media file by class) and media-describe (write an image's description/keywords into its own XMP)";
    # `media`, not the first member alphabetically. The bundle's entry point is
    # the dispatcher — that is what `nix run` on this package should give you.
    mainProgram = "media";
  };
}
