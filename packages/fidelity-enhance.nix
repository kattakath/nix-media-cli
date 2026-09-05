# `fidelity-enhance` / `fidelity-enhance-mcp` — the referee for an agentic
# image-editing loop. Grok Imagine (driven by grok-build) generates the images;
# this judges each result against the ORIGINAL and answers retry / next-step /
# done, plus concrete guidance on what to change about the prompt. It generates
# nothing itself.
#
# Two binaries:
#   fidelity-enhance-mcp   stdio MCP server — what `grok mcp add` points at
#   fidelity-enhance       CLI, for measuring drift and testing offline
#
# Packaged the same way as jobspy: an EPHEMERAL uv environment (`uv run --with`),
# with uv + Python pinned from Nix and the project itself fetched from git at
# first run and cached. Nothing is pip-installed globally, and there is no
# hand-made venv in $HOME for this config to depend on.
#
# Python 3.12 rather than latest: torch/onnxruntime/insightface wheel coverage is
# reliable there, and the project only requires >=3.11.
#
# FIRST RUN IS SLOW. The `identity` and `perceptual` extras pull torch and
# insightface — on the order of a gigabyte — which uv downloads once and then
# caches. Warm it deliberately before wiring the MCP server into an agent, or the
# first tool call will look like a hang:
#
#     fidelity-enhance capabilities
#
# Those extras are not optional decoration: without them the identity metric
# degrades to a weaker structural proxy, which is the whole point of the tool.
# `opencv` is deliberately absent — insightface already pulls the full
# opencv-python, and adding opencv-python-headless alongside it puts two native
# cv2 builds on one import path.
{
  writeShellApplication,
  symlinkJoin,
  uv,
  coreutils,
  git,
}:
let
  # SEARGraph#1's MERGE COMMIT on main, not the PR branch head it used to pin.
  # The PR landed 2026-08-22, and that branch
  # (claude/fidelity-image-enhancement-mcp-e9a0ab) still exists only by luck —
  # a pin to a merged PR's branch breaks silently the day someone deletes it.
  # Content-identical, so this is a durability change and not a version bump:
  # both revs have git tree 2bedd7ee4ac0ca20f94a9b89cd8df9d18e28bd33 (verified).
  # Main has since moved on to a different tree; taking it would be a real
  # upgrade and wants its own testing, so it is deliberately not done here.
  rev = "2cd3572f410122b87f119bbcddde680ff44fd76c";
  spec =
    "fidelity-enhance[agent,mcp,imaging,perceptual,identity,realesrgan] "
    + "@ git+https://github.com/ismailkattakath/SEARGraph@${rev}";

  # Both entry points share one uv spec, so they resolve to the same cached env.
  mk =
    name:
    writeShellApplication {
      inherit name;
      runtimeInputs = [
        uv
        coreutils
        git # uv shells out to git to fetch the project
      ];
      text = ''
        # --no-project is load-bearing, not tidiness. `uv run` otherwise adopts
        # any project in the CURRENT DIRECTORY, and an MCP server inherits
        # whatever cwd its client happened to have. Launched from a checkout with
        # its own pyproject.toml, uv ran that project instead of this spec and
        # silently dropped the extras — leaving the identity gate switched off
        # while still reporting success. Verified: from a directory containing a
        # pyproject.toml, insightface and lpips were missing; from /tmp they were
        # present.
        #
        # argparse inside the tool owns every flag — just forward "$@".
        exec uv run --quiet --no-project --python 3.12 --with "${spec}" ${name} "$@"
      '';
    };
in
symlinkJoin {
  name = "fidelity-enhance";
  paths = [
    (mk "fidelity-enhance-mcp")
    (mk "fidelity-enhance")
  ];
}
