# home-manager module: programs.mediaCli
#
# One switch for the whole media stack: the CLIs on PATH, the durable launchd
# work queue that drains them, and the Finder right-click Services that feed it.
# Turn it off and every one of those disappears together — no orphaned package,
# no dangling session variable, no stale menu item.
#
# macOS-ONLY: everything below is gated on stdenv.isDarwin, so enabling it on a
# Linux host is a clean no-op (safe for a mixed nix-darwin + NixOS fleet). That
# gate is real, not defensive: only extract-audio is portable — fix-extension
# calls /usr/bin/mdls and BSD `stat -f`, fix-google-video adds /usr/bin/SetFile
# and ~/.Trash, photo-describe shells out to /usr/bin/sips and Apple's Vision
# framework, the Services are Automator bundles, and the queue is launchd.
#
# EVERY QUEUE MECHANISM IS launchd's, NOT OURS:
#
#   QueueDirectories               THE QUEUE. launchd starts the worker whenever
#                                  a watched directory is non-empty, and again
#                                  after it exits if anything is left. No polling
#                                  loop, no scheduler, no daemon of ours.
#   ProcessType = "Background"     THE LOAD CONTROL. macOS throttles CPU and I/O
#                                  for Background jobs specifically so they
#                                  cannot disrupt the user experience — a
#                                  200-file re-encode stops being something you
#                                  feel in the foreground.
#   KeepAlive.SuccessfulExit=false THE RETRY, for the worker PROCESS (per-JOB
#   + ThrottleInterval             retry is the worker's own three-strikes rule).
#   RunAtLoad                      Recovery: a logout mid-batch left jobs queued.
#   StartInterval (power monitor)  BATTERY AWARENESS, via launchd's own periodic
#                                  primitive rather than a `sleep` loop of ours.
#
# THE arg0 IS LOAD-BEARING, NOT COSMETIC. `ProgramArguments[0]` is what macOS's
# Background Task Manager displays AND what TCC attributes file access to.
# Measured on macOS 26.6.2: an adhoc-signed /nix/store binary may READ the
# protected user folders (~/Pictures, ~/Desktop, ~/Downloads); Apple's own
# /bin/sh is attributable and gets EPERM without an explicit grant. So a worker
# whose arg0 is /bin/sh runs, logs nothing useful, and quietly does no work.
#
# Upstream home-manager wraps every agent as
#   ProgramArguments = [ "/bin/sh" "-c" "wait4path … && exec …" ]
# which is exactly that failure mode. This module therefore builds its OWN
# `nix-<activity>` wrapper and sets ProgramArguments itself, keeping wait4path
# inside it. That also means this flake works with UPSTREAM home-manager and
# needs no vendored launchd fork.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.mediaCli;
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  fix-extension = pkgs.callPackage ../packages/fix-extension.nix { };
  fix-google-video = pkgs.callPackage ../packages/fix-google-video.nix { };
  extract-audio = pkgs.callPackage ../packages/extract-audio.nix { };
  fix-media = pkgs.callPackage ../packages/fix-media.nix { inherit fix-extension fix-google-video; };
  photo-describe = pkgs.callPackage ../packages/photo-describe.nix {
    inherit fix-extension;
    defaultModel = cfg.visionModel;
  };
  media-queue = pkgs.callPackage ../packages/media-queue.nix { inherit fix-media photo-describe; };
  media = pkgs.callPackage ../packages/media.nix {
    inherit
      fix-media
      extract-audio
      photo-describe
      media-queue
      ;
  };
  media-toolkit = pkgs.callPackage ../packages/media-toolkit.nix {
    inherit
      fix-google-video
      extract-audio
      fix-extension
      fix-media
      photo-describe
      media
      ;
  };
  media-quick-actions = pkgs.callPackage ../packages/media-quick-actions.nix {
    inherit media-toolkit media-queue;
  };

  stateDir = "${config.home.homeDirectory}/Library/Application Support/nix-media-queue";
  logFile = "${config.home.homeDirectory}/${cfg.logRelPath}";

  # See the arg0 note in the header. wait4path stays INSIDE the wrapper: launchd
  # can start an agent before /nix/store is mounted.
  mkAgentProgram =
    name: exe:
    let
      wrapper = pkgs.writeShellScriptBin "nix-${name}" ''
        set -euo pipefail
        /bin/wait4path /nix/store
        exec ${exe}
      '';
    in
    [ "${wrapper}/bin/nix-${name}" ];

  loadControl = {
    ProcessType = "Background";
    Nice = 5;
    LowPriorityIO = true;
    StandardOutPath = logFile;
    StandardErrorPath = logFile;
  };
in
{
  options.programs.mediaCli = {
    enable = lib.mkEnableOption ''
      the media-file CLIs, the launchd work queue that drains them, and the
      Finder right-click Services that feed it (macOS only; a no-op elsewhere)
    '';

    installQuickActions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the Finder right-click Services into ~/Library/Services.

        They are COPIED, not symlinked, and the copy is what makes them
        removable: set this false and the next activation deletes them.
      '';
    };

    visionModel = lib.mkOption {
      type = lib.types.str;
      default = "huihui_ai/qwen3-vl-abliterated";
      example = "qwen2.5vl:7b";
      description = ''
        The Ollama vision model `photo-describe` asks for a caption, when no
        `--model` is given. Ollama is a SOFT dependency: with it absent or the
        model unpulled, a run still writes Vision labels and a rating and says
        so, rather than failing and leaving a library half-tagged.
      '';
    };

    ollamaHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:11434";
      description = "Where `photo-describe` looks for Ollama's HTTP API.";
    };

    logRelPath = lib.mkOption {
      type = lib.types.str;
      default = "Library/Logs/nix-media-queue.log";
      description = ''
        Queue log, relative to $HOME. The default is where Console.app looks,
        so the log viewer is off-the-shelf too.
      '';
    };

    extraSearchPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [ exiftool ];
      defaultText = lib.literalExpression "with pkgs; [ exiftool ]";
      description = ''
        Companion tools installed alongside the CLIs. `exiftool` is the default
        because it is the metadata writer `photo-describe` shells out to and the
        only tool that reads or writes the full EXIF/IPTC/XMP surface — `mdls`
        shows only Spotlight's lossy derived view and `sips` has no EXIF tag
        access at all.

        Set to `[ ]` to install none, or extend it with your own retrieval
        companions (e.g. `rclip` for vector search over the pixels).
      '';
    };
  };

  config = lib.mkIf (cfg.enable && isDarwin) {
    home.packages = [
      media-toolkit
      media-queue
    ]
    ++ cfg.extraSearchPackages;

    # OLLAMA_HOST only. `visionModel` is threaded into photo-describe at BUILD
    # time (see its `defaultModel` argument) rather than exported here — an env
    # var would be a third source of truth between the Nix default and `--model`,
    # and the store path would stop telling you which model actually ran.
    home.sessionVariables.OLLAMA_HOST = cfg.ollamaHost;

    # COPIED, not symlinked. macOS does register a bundle reached through a
    # symlink, but a copy is what lets `installQuickActions = false` actually
    # remove them: home.file would only unlink what it still knows about.
    home.activation.mediaCliQuickActions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      svc="${config.home.homeDirectory}/Library/Services"
      run mkdir -p "$svc"
      ${lib.concatMapStringsSep "\n" (n: ''
        run rm -rf "$svc/${n}.workflow"
        ${lib.optionalString cfg.installQuickActions ''
          run cp -RL "${media-quick-actions}/${n}.workflow" "$svc/${n}.workflow"
          run chmod -R u+w "$svc/${n}.workflow"
        ''}
      '') media-quick-actions.actionNames}
    '';

    launchd.agents = {
      media-queue = {
        enable = true;
        config = {
          ProgramArguments = mkAgentProgram "media-queue" "${media-queue}/bin/media-worker";
          # All three tiers watched: launchd fires the worker whenever ANY is
          # non-empty. `queue` is the normal path; `queue-high` is the explicit
          # `media-enqueue --priority high` lever; `queue-low` is where the
          # crash-recovery paths demote to, so a system cleaning up after a lost
          # worker never queues ahead of a fresh human request.
          QueueDirectories = [
            "${stateDir}/queue-high"
            "${stateDir}/queue"
            "${stateDir}/queue-low"
          ];
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
          # Stated rather than inherited because it is LOAD-BEARING FOR LATENCY,
          # not only for crash bounding: the throttle spaces every start of the
          # job, so at launchd's default of 60 a right-click waited a full minute
          # (measured). `media-enqueue` also kickstarts the agent, so this is now
          # only the ceiling for a job arriving without an enqueue, and for a
          # crash restart.
          ThrottleInterval = 10;
        }
        // loadControl;
      };

      media-queue-power = {
        enable = true;
        config = {
          ProgramArguments = mkAgentProgram "media-queue-power" "${media-queue}/bin/media-queue-power-monitor";
          # launchd's own periodic-run primitive. Kept as its own agent rather
          # than a loop inside the worker: that first version was a second direct
          # child of the worker process, indistinguishable from the real job to
          # `pgrep -P` — a whole bug class this shape does not have, since it is
          # not the worker's child at all.
          StartInterval = 20;
          RunAtLoad = true;
        }
        // loadControl;
      };
    };
  };
}
