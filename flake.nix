{
  description = "Local, offline media-file CLIs for macOS: describe a photo INTO the photo (Apple Vision + a local VLM, written as XMP that Spotlight indexes), repair a lying extension, re-encode editor-hostile video, pull an audio track — plus a durable launchd work queue and Finder right-click Services that drive them.";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [ "https://kattakath.cachix.org" ];
    extra-trusted-public-keys = [
      "kattakath.cachix.org-1:y/w6wnb4ZArdlbfWJ82c81uCXeYgG/sGDUYCszavmEw="
    ];
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      home-manager,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # The formatter runs on all three; every package here is macOS-only and
      # gated per-system below. This is NOT the usual "shell scripts are
      # portable" case — measured, only media-extract-audio is: media-fix-extension calls
      # /usr/bin/mdls and BSD `stat -f`, media-transcode adds /usr/bin/SetFile
      # and moves originals to ~/.Trash, media-describe shells out to
      # /usr/bin/sips and `auge` (Apple's Vision framework), media-quick-actions
      # emits Automator bundles, and media-queue is launchd end to end.
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake = {
        homeManagerModules.mediaCli = ./modules/media-cli.nix;
        homeManagerModules.default = self.homeManagerModules.mediaCli;
      };

      perSystem =
        { pkgs, system, ... }:
        {
          formatter = pkgs.nixfmt-rfc-style;

          packages = pkgs.lib.optionalAttrs (system == "aarch64-darwin") (
            let
              # Named so siblings can be threaded in explicitly rather than
              # re-instantiated: callPackage's defaults would otherwise build a
              # SECOND media-fix-extension for media-fix and a third for
              # media-describe, and the three could drift.
              media-fix-extension = pkgs.callPackage ./packages/media-fix-extension.nix { };
              media-transcode = pkgs.callPackage ./packages/media-transcode.nix { };
              media-extract-audio = pkgs.callPackage ./packages/media-extract-audio.nix { };
              media-fix = pkgs.callPackage ./packages/media-fix.nix {
                inherit media-fix-extension media-transcode;
              };
              media-describe = pkgs.callPackage ./packages/media-describe.nix { inherit media-fix-extension; };
              # media-queue takes the two CLIs its worker dispatches to, NOT the
              # media-toolkit bundle — that bundle contains `media`, and `media`
              # has a `queue` verb, so the bundle would close an eval cycle.
              media-queue = pkgs.callPackage ./packages/media-queue.nix { inherit media-fix media-describe; };
              media = pkgs.callPackage ./packages/media.nix {
                inherit
                  media-fix
                  media-extract-audio
                  media-describe
                  media-queue
                  ;
              };
              media-toolkit = pkgs.callPackage ./packages/media-toolkit.nix {
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
              media-quick-actions = pkgs.callPackage ./packages/media-quick-actions.nix {
                inherit media-toolkit media-queue;
              };
              # In the flake, deliberately NOT in media-toolkit — see the two
              # membership questions in packages/media-toolkit.nix. Both are
              # opt-in in the module: fidelity-enhance pulls ~1 GB of
              # torch/insightface on first run, and obs-fb-setup is inert until
              # you put FB_PERSISTENT_STREAM_KEY in the login Keychain.
              fidelity-enhance = pkgs.callPackage ./packages/fidelity-enhance.nix { };
              obs-fb-setup = pkgs.callPackage ./packages/obs-fb-setup.nix { };
              default = media-toolkit;
            }
          );

          # Every package gets an app. In the mono-repo this had drifted to 3 of
          # 8, so `nix run` worked for some CLIs and not others for no reason.
          apps = pkgs.lib.optionalAttrs (system == "aarch64-darwin") (
            pkgs.lib.genAttrs
              [
                "media-fix-extension"
                "media-transcode"
                "media-extract-audio"
                "media-fix"
                "media-describe"
                "media"
                "fidelity-enhance"
                "obs-fb-setup"
              ]
              (name: {
                type = "app";
                program = "${self.packages.${system}.${name}}/bin/${name}";
              })
            // {
              default = {
                type = "app";
                program = "${self.packages.${system}.media}/bin/media";
              };
            }
          );

          checks = pkgs.lib.optionalAttrs (system == "aarch64-darwin") (
            let
              hm = home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [
                  self.homeManagerModules.default
                  {
                    home.username = "tester";
                    home.homeDirectory = "/Users/tester";
                    home.stateVersion = "24.05";
                    programs.mediaCli.enable = true;
                  }
                ];
              };
            in
            {
              # The module's whole job is the wiring, so assert the wiring:
              # both launchd agents exist, the worker watches all three priority
              # tiers, and the agent's arg0 is a /nix/store `nix-*` path. That
              # last one is not cosmetic — an adhoc-signed /nix/store arg0 is
              # what lets the worker READ the TCC-protected folders it exists to
              # work on; a bare interpreter there silently reads nothing.
              module-evaluates =
                let
                  agents = hm.config.launchd.agents;
                  worker = agents.media-queue.config;
                  arg0 = builtins.head worker.ProgramArguments;
                in
                pkgs.runCommand "media-cli-module-eval" { } ''
                  test "${toString (builtins.length worker.QueueDirectories)}" = 3
                  test "${toString worker.RunAtLoad}" = "1"
                  test "${worker.ProcessType}" = "Background"
                  test "${toString agents.media-queue-power.config.StartInterval}" = "20"
                  case "${builtins.baseNameOf arg0}" in nix-*) ;; *) echo "arg0 must be nix-*: ${arg0}" >&2; exit 1 ;; esac
                  case "${arg0}" in /nix/store/*) ;; *) echo "arg0 must be a store path: ${arg0}" >&2; exit 1 ;; esac
                  echo ok > "$out"
                '';
            }
            // self.packages.${system}
          );
        };
    };
}
