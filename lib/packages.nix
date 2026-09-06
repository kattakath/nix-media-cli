# THE PACKAGE GRAPH, ONCE.
#
# flake.nix's `perSystem` and modules/media-cli.nix both need every package in
# this repo, wired to each other in exactly one way. They used to each spell the
# whole graph out — 11 `callPackage`s apiece, differing only in `./` vs `../`
# and in one line the module had and the flake did not.
#
# That one line is the whole argument for this file. `defaultModel =
# cfg.visionModel` existed on the module side alone, so the flake's
# `packages.media-describe` and the module's were quietly different
# derivations; and when `defaultHost` was added for the launchd worker (see
# packages/media-describe.nix), there was a second knob that had to be
# remembered in two places or silently apply in one. A copy of a graph is not
# DRY debt in the abstract — it is a place for an option to go missing.
#
# The flake's own warning already said this about ONE file:
#
#   Named so siblings can be threaded in explicitly rather than
#   re-instantiated: callPackage's defaults would otherwise build a SECOND
#   media-fix-extension for media-fix and a third for media-describe, and the
#   three could drift.
#
# Same hazard, one level up. This is that fix applied BETWEEN the two callers.
{
  pkgs,
  # Both default to the underlying package's own default, so a caller that
  # cares about neither passes neither and gets exactly what it got before.
  defaultModel ? null,
  defaultHost ? null,
}:
let
  inherit (pkgs) callPackage lib;
  # `lib.optionalAttrs` rather than always passing: `callPackage x { foo = null; }`
  # OVERRIDES the argument's own default with null, it does not fall back to it.
  describeArgs =
    lib.optionalAttrs (defaultModel != null) { inherit defaultModel; }
    // lib.optionalAttrs (defaultHost != null) { inherit defaultHost; };

  media-fix-extension = callPackage ../packages/media-fix-extension.nix { };
  media-transcode = callPackage ../packages/media-transcode.nix { };
  media-extract-audio = callPackage ../packages/media-extract-audio.nix { };
  media-fix = callPackage ../packages/media-fix.nix { inherit media-fix-extension media-transcode; };
  media-describe = callPackage ../packages/media-describe.nix (
    { inherit media-fix-extension; } // describeArgs
  );
  # media-queue takes the two CLIs its worker dispatches to, NOT the
  # media-toolkit bundle — that bundle contains `media`, and `media` has a
  # `queue` verb, so the bundle would close an eval cycle.
  media-queue = callPackage ../packages/media-queue.nix { inherit media-fix media-describe; };
  media = callPackage ../packages/media.nix {
    inherit
      media-fix
      media-extract-audio
      media-describe
      media-queue
      ;
  };
  media-toolkit = callPackage ../packages/media-toolkit.nix {
    inherit
      media-transcode
      media-extract-audio
      media-fix-extension
      media-fix
      media-describe
      media
      ;
  };
in
{
  inherit
    media-fix-extension
    media-transcode
    media-extract-audio
    media-fix
    media-describe
    media-queue
    media
    media-toolkit
    ;
  media-quick-actions = callPackage ../packages/media-quick-actions.nix {
    inherit media-toolkit media-queue;
  };
  # Deliberately NOT in media-toolkit — see the two membership questions in
  # packages/media-toolkit.nix. Both are opt-in in the module: fidelity-enhance
  # pulls ~1 GB of torch/insightface on first run, and obs-fb-setup is inert
  # until you put FB_PERSISTENT_STREAM_KEY in the login Keychain.
  fidelity-enhance = callPackage ../packages/fidelity-enhance.nix { };
  obs-fb-setup = callPackage ../packages/obs-fb-setup.nix { };
}
