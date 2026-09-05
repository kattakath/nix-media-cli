# media-toolkit — the fleet's local media-file CLIs, as one installable unit.
#
#   fix-google-video <file>...                    re-encode editor-hostile video
#   extract-audio [--mp3|--wav|--flac] <file>...  pull out the audio track
#   fix-extension <file-or-dir>...                rename a file whose extension
#                                                 lies about its content
#   fix-media <--video|--image> <file-or-dir>...  repair a media file by CLASS,
#                                                 deciding which of the above
#                                                 it actually needs
#   media <describe|fix|audio> ...                one entry point for the below
#   photo-describe <file-or-dir>...               write what an image IS into
#                                                 the image (XMP description +
#                                                 keywords + rating)
#
# A symlinkJoin, deliberately, not a single dispatching binary: each CLI stays
# its own derivation, keeps its own `nix run .#<name>` app, and is shellchecked
# and testable on its own. This only bundles them, so `home.packages` carries
# one entry instead of drifting out of sync as CLIs are added — which already
# happened once: extract-audio shipped as a flake package but was never added
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
# fix-extension is the one member that changes no bytes — it only renames. It
# still belongs: it operates directly on the selected media file and repairs it
# for the same consumer (Finder/Photos) the other two serve, and the rule above
# exists to exclude tools that never touch a file at all, not to require a
# re-encode.
#
# fix-media is the odd one out in the other direction: it transforms nothing
# itself, it DISPATCHES to the members that do. It belongs here because it is
# the entry point the Finder Services actually call, and because splitting a
# dispatcher from the things it dispatches to is how the two drift apart.
#
# photo-describe is the third edge case, and the closest call. It changes no
# pixels — like fix-extension it only rewrites what the file SAYS about itself
# — and it is the only member with a soft dependency on a service (Ollama) that
# lives outside its closure. It still belongs: it acts directly on the media
# file the operator selected, and it repairs the same defect fix-extension does
# for the same consumer — a file Finder and Spotlight cannot answer questions
# about. It is also the natural next stage AFTER fix-extension, whose --print0
# seam it consumes exactly as fix-media does.
#
# The Ollama dependency is what keeps it from being folded into fix-media's
# --image pipeline: a repair must finish offline and in bounded time, and a
# vision model is neither. So describing stays a separate, explicit verb.
{
  symlinkJoin,
  callPackage,
  fix-google-video ? callPackage ./fix-google-video.nix { },
  extract-audio ? callPackage ./extract-audio.nix { },
  fix-extension ? callPackage ./fix-extension.nix { },
  fix-media ? callPackage ./fix-media.nix { },
  photo-describe ? callPackage ./photo-describe.nix { },
  media ? callPackage ./media.nix { },
}:
symlinkJoin {
  name = "media-toolkit";
  paths = [
    fix-google-video
    extract-audio
    fix-extension
    fix-media
    photo-describe
    media
  ];
  meta = {
    description = "Local media-file CLIs: fix-google-video (re-encode editor-hostile video), extract-audio (pull out the audio track) fix-extension (rename files whose extension lies about their content), fix-media (repair a media file by class) and photo-describe (write an image's description/keywords into its own XMP)";
    mainProgram = "fix-google-video";
  };
}
