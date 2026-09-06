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
          # `nixfmt-tree`, NOT bare `nixfmt-rfc-style`. `nix fmt` invokes the
          # formatter with the directory to format, and nixfmt 1.4.0 deprecated
          # directory arguments — it prints "Passing directories or non-Nix
          # files (such as \".\") is deprecated ... use the `pkgs.nixfmt-tree`
          # wrapper instead" and then FAILS to parse, so `nix fmt` errored and
          # formatted nothing. Silently, in practice: the failure is a parse
          # error on stderr, and a repo whose CI checks formatting with its own
          # separate `nix run nixpkgs#nixfmt-rfc-style` invocation never noticed
          # that its `nix fmt` had never worked. Measured by shipping an
          # unformatted flake.nix past a green local `nix fmt`.
          #
          # `nixfmt-tree` is nixfmt's OWN recommended wrapper, already in
          # nixpkgs — a treefmt harness that walks the tree. No new input, no
          # hand-rolled find-and-pipe.
          formatter = pkgs.nixfmt-tree;

          # ONE graph, shared with modules/media-cli.nix — see lib/packages.nix
          # for why a second copy here is where an option goes to die.
          packages = pkgs.lib.optionalAttrs (system == "aarch64-darwin") (
            let
              graph = import ./lib/packages.nix { inherit pkgs; };
            in
            graph // { default = graph.media-toolkit; }
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
              mkHm =
                extra:
                home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  # `extra` is its OWN module, never `base // extra`: `//` is a
                  # SHALLOW merge, so `{ programs.mediaCli.ollamaHost = …; }`
                  # replaces the whole `programs` attrset and takes
                  # `programs.mediaCli.enable = true` with it — the module then
                  # defines no agents at all and the assertion below dies on a
                  # missing attribute instead of testing anything. The module
                  # system merges module lists deeply; that is its job.
                  modules = [
                    self.homeManagerModules.default
                    {
                      home.username = "tester";
                      home.homeDirectory = "/Users/tester";
                      home.stateVersion = "24.05";
                      programs.mediaCli.enable = true;
                    }
                    extra
                  ];
                };
              hm = mkHm { };
              workerArg0 = c: builtins.head c.config.launchd.agents.media-queue.config.ProgramArguments;
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

              # REGRESSION GUARD for a bug this repo actually shipped: an
              # `ollamaHost` that reached the interactive CLI and NOT the launchd
              # worker, because its only delivery was `home.sessionVariables` and
              # a launchd agent inherits no shell profile. Ollama is a SOFT
              # dependency, so the worker did not fail — it wrote labels with no
              # caption and said "no ollama at ...". Silent, and invisible while
              # the option's default happened to equal the tool's own fallback.
              #
              # Asserted as INEQUALITY rather than by grepping a closure: if the
              # host does not reach the worker, the two agents are byte-identical
              # and their arg0 is the same store path. That is exactly the old
              # behaviour, and it is a pure evaluation — no closure walk, no
              # sandbox question about whether a runtime reference is present.
              host-reaches-worker =
                let
                  a = workerArg0 (mkHm {
                    programs.mediaCli.ollamaHost = "127.0.0.1:11434";
                  });
                  b = workerArg0 (mkHm {
                    programs.mediaCli.ollamaHost = "sentinel.invalid:65000";
                  });
                in
                pkgs.runCommand "media-cli-host-reaches-worker" { } ''
                  test "${a}" != "${b}" || {
                    echo "programs.mediaCli.ollamaHost does not reach the launchd worker" >&2
                    echo "both hosts produced arg0: ${a}" >&2
                    exit 1
                  }
                  echo ok > "$out"
                '';

              # The other half: prove the value is actually BAKED, not merely
              # that something in the closure moved. Greps the generated script
              # for a host no resolver will ever answer.
              host-is-baked =
                let
                  describe =
                    (import ./lib/packages.nix {
                      inherit pkgs;
                      defaultHost = "http://sentinel.invalid:65000";
                    }).media-describe;
                in
                pkgs.runCommand "media-cli-host-is-baked" { } ''
                  grep -q 'sentinel\.invalid:65000' ${describe}/bin/media-describe || {
                    echo "defaultHost is not baked into media-describe" >&2
                    exit 1
                  }
                  echo ok > "$out"
                '';

              # The only check here that EXECUTES the queue rather than
              # evaluating or building it — see checks/queue-state-machine.nix
              # for what the build sandbox can and cannot run, and for the two
              # state-machine paths (/bin/ps: pause, adoption) it deliberately
              # does not claim to cover. `import` with `inherit pkgs`, matching
              # `host-is-baked` above: it needs the package FUNCTION, wired to
              # stubs, not the ready-made graph in lib/packages.nix.
              queue-state-machine = import ./checks/queue-state-machine.nix { inherit pkgs; };
            }
            // self.packages.${system}
          );
        };
    };
}
