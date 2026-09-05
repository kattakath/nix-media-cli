# media-quick-actions (macOS only) — Finder right-click → SERVICES entries for
# the media-toolkit CLIs, generated declaratively.
#
# Note the submenu: these land under **Services**, not "Quick Actions", even
# with presentationMode = 11 below. Finder's Quick Actions submenu is fed by
# App Extensions and Shortcuts actions (see `defaults read pbs` → FinderActive,
# which lists only APPEXTENSION-* and is.workflow.actions.* entries); an
# Automator .workflow service cannot appear there. Verified on macOS 26.6.2.
#
# A Quick Action is just an Automator `.workflow` BUNDLE OF TWO PLISTS —
# Contents/Info.plist (what the menu item is called, and which file types it
# attaches to) and Contents/document.wflow (what it runs). Nothing needs
# Automator.app to author it, so both are generated here with
# `lib.generators.toPlist` and the bundle is linked into ~/Library/Services by
# home.nix. Verified: macOS registers a bundle reached through a SYMLINK, so
# the home.file/store-path model works — no copy-into-place needed.
#
# Two details that are load-bearing and non-obvious:
#
#   inputMethod = 1  — pass the selected files to the script as "$@". The
#     default (0) pipes them on stdin instead, which silently produces a
#     script that runs and does nothing.
#   presentationMode = 11  — what Automator writes for a Quick Action. Kept
#     because this exact bundle shape is the one verified working; it does NOT
#     actually move the item into the Quick Actions submenu (see above).
#
# The script execs an absolute /nix/store path because a Service inherits a
# minimal PATH, not the login shell's.
{
  lib,
  runCommand,
  writeText,
  writeShellApplication,
  callPackage,
  media-toolkit ? callPackage ./media-toolkit.nix { },
  media-queue ? callPackage ./media-queue.nix { },
}:
let
  # One entry per menu item. `cmd` is appended to the store path, so adding an
  # action is a line here rather than another copy of the plist scaffolding.
  #
  # The actions ENQUEUE; they do not do the work. `media-enqueue` writes one job
  # file per selected item and returns, so Finder is never blocked and a batch
  # survives logout — see packages/media-queue.nix for what drains it. Before
  # this, a two-hour re-encode ran inside the Service with no progress, no
  # cancel, and no chance of surviving a logout.
  #
  # Items are named for WHAT THE OPERATOR SELECTED, not for the defect they
  # repair: "Fix Video File(s)", not "Fix Google Video" or "Fix File Extension".
  # Someone whose photo has no thumbnail does not know that their `.png` is
  # really a JPEG — a menu of diagnoses asks them to diagnose it first, which is
  # the one thing they came here unable to do. `fix-media` takes the class and
  # decides what is actually wrong; see packages/fix-media.nix. `cmd` is
  # therefore a command AND its flags, spliced ahead of "$@" in the runner.
  #
  # `sendTypes` decides which selections Finder offers the item on, and
  # `inputType` is Automator's matching declaration. They are per-action rather
  # than a shared constant because the actions do not agree on what they act on.
  actions = [
    {
      name = "Extract Audio";
      id = "extractAudio";
      cmd = "extract-audio"; # MP3 by default; --copy is the lossless path
      # NOT queued: extracting one track is seconds, so a round trip through
      # launchd would buy nothing.
      sendTypes = [ "public.movie" ];
      inputType = "com.apple.Automator.fileSystemObject.movie";
    }
    {
      name = "Fix Video File(s)";
      id = "fixVideo";
      cmd = "media-enqueue --video";
      # `public.folder` makes a whole export folder one right-click; the class
      # filter inside fix-media is what stops it touching the photos in there.
      sendTypes = [
        "public.movie"
        "public.folder"
      ];
      inputType = "com.apple.Automator.fileSystemObject";
    }
    {
      name = "Fix Image File(s)";
      id = "fixImage";
      cmd = "media-enqueue --image";
      # A JPEG named `.png` still reports `public.png` from its extension, which
      # conforms to `public.image`, so the mislabeled file this action exists
      # for does reach the menu. `public.data` — every extensionless file — is
      # deliberately absent: it would put this item on the menu for literally
      # everything, and a file with no extension is not the reported problem.
      sendTypes = [
        "public.image"
        "public.folder"
      ];
      inputType = "com.apple.Automator.fileSystemObject";
    }
    {
      name = "Describe Image(s)";
      id = "describeImage";
      cmd = "media-enqueue --describe";
      # Queued for the same reason the fixes are, only more so: measured here,
      # a caption costs ~26s on the first image (loading the vision model) and
      # ~4s warm, so a right-clicked folder is minutes of work. Running that
      # inside the Service would freeze Finder's menu with no progress and no
      # cancel — which is the exact failure the queue exists to prevent.
      # Named for the OUTCOME the operator wants, not the mechanism: nobody
      # right-clicks looking for "Write XMP metadata". Same reasoning as the
      # "Fix … File(s)" items above — the menu states what you get.
      sendTypes = [
        "public.image"
        "public.folder"
      ];
      inputType = "com.apple.Automator.fileSystemObject";
    }
  ];

  mkRunner =
    a:
    writeShellApplication {
      name = "media-service-${a.id}";
      runtimeInputs = [
        media-toolkit
        media-queue
      ];
      text = ''
        # NO SUMMARY, NO NOTIFICATION. This used to parse the CLI's done:/skip:
        # grammar and post an AppleScript banner, because a Finder Service has
        # nowhere to put stdout and "skipped, already done" and "crashed" would
        # otherwise look identical. That reporting was removed deliberately: the
        # queue reports nothing either now, and one silent path is easier to
        # reason about than two half-working ones.
        #
        # WHAT YOU GIVE UP: a Service that fails is now completely silent — you
        # click and nothing visible happens, success or failure alike. The log is
        # the only channel left: ~/Library/Logs/nix-media-queue.log for queued
        # work, and for an unqueued action nothing at all.
        exec ${a.cmd} "$@"
      '';
    };

  infoPlist =
    {
      name,
      id,
      sendTypes,
      ...
    }:
    lib.generators.toPlist { escape = true; } {
      CFBundleIdentifier = "com.kattakath.services.${id}";
      CFBundleName = name;
      CFBundleShortVersionString = "1.0";
      NSServices = [
        {
          NSMenuItem.default = name;
          NSMessage = "runWorkflowAsService";
          # Only offer it inside Finder — these act on selected files.
          NSRequiredContext.NSApplicationIdentifier = "com.apple.finder";
          NSSendFileTypes = sendTypes;
        }
      ];
    };

  documentWflow =
    {
      runner,
      inputType,
      ...
    }:
    lib.generators.toPlist { escape = true; } {
      AMApplicationVersion = "2.10";
      AMDocumentVersion = "2";
      actions = [
        {
          action = {
            AMAccepts = {
              Container = "List";
              Optional = true;
              Types = [ "com.apple.cocoa.string" ];
            };
            AMActionVersion = "2.0.3";
            AMProvides = {
              Container = "List";
              Types = [ "com.apple.cocoa.string" ];
            };
            ActionBundlePath = "/System/Library/Automator/Run Shell Script.action";
            ActionName = "Run Shell Script";
            ActionParameters = {
              COMMAND_STRING = ''exec ${runner}/bin/${runner.name} "$@"'';
              CheckedForUserDefaultShell = true;
              inputMethod = 1; # files as "$@", NOT stdin
              shell = "/bin/zsh";
              source = "";
            };
            BundleIdentifier = "com.apple.RunShellScript";
            CFBundleVersion = "2.0.3";
            "Class Name" = "RunShellScriptAction";
            # Automator wants these present; the values only have to be stable.
            InputUUID = "0A1B2C3D-0001-4000-8000-000000000001";
            OutputUUID = "0A1B2C3D-0002-4000-8000-000000000002";
            UUID = "0A1B2C3D-0003-4000-8000-000000000003";
            isViewVisible = 1;
          };
          isViewVisible = 1;
        }
      ];
      connectors = { };
      workflowMetaData = {
        presentationMode = 11; # what Automator writes; item still lands under Services
        serviceApplicationBundleID = "com.apple.finder";
        serviceApplicationPath = "/System/Library/CoreServices/Finder.app";
        serviceInputTypeIdentifier = inputType;
        serviceOutputTypeIdentifier = "com.apple.Automator.nothing";
        workflowTypeIdentifier = "com.apple.Automator.servicesMenu";
      };
    };

  mkAction =
    a:
    runCommand "quick-action-${a.id}" { } ''
      d="$out/${a.name}.workflow/Contents"
      mkdir -p "$d"
      cp ${writeText "Info.plist" (infoPlist a)} "$d/Info.plist"
      cp ${writeText "document.wflow" (documentWflow (a // { runner = mkRunner a; }))} "$d/document.wflow"
    '';
in
runCommand "media-quick-actions"
  {
    passthru.actionNames = map (a: a.name) actions;
    meta.description = "Finder right-click → Services entries for the media-toolkit CLIs";
  }
  ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (a: "cp -r ${mkAction a}/*.workflow $out/") actions}
  ''
