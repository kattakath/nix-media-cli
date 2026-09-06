# BEHAVIOURAL COVERAGE FOR THE QUEUE STATE MACHINE — the real `media-worker`,
# driven end to end against a temp $HOME.
#
# Every other check in this flake is an EVALUATION assertion (the module's
# plists) or a package BUILD (shellcheck, via writeShellApplication). Neither
# executes a single transition, so the ~1089 lines of stateful shell in
# packages/media-queue.nix had exactly zero behavioural coverage: oldest-first
# claim order, the fresh-stamp requeue, MAX_TRIES dead-lettering, the
# demote-vs-preserve rule and count-per-JOB-not-per-ATTEMPT were each enforced
# only by the comment sitting next to them. This runs them.
#
# STUBBED AT THE NIX SEAM, NOT ON $PATH. `media-fix` and `media-describe` are
# already explicit arguments of packages/media-queue.nix — they exist so nothing
# re-instantiates them (see that file's own comment) — so a stub goes in exactly
# the way the real ones do. $PATH could not have done it anyway:
# writeShellApplication PREPENDS runtimeInputs, so an ambient stub loses to the
# real CLI every time. The consequence is the whole point: no ollama, no Vision
# framework, no network, no TCC-protected folder, no launchd, no real media file.
#
# WHAT THE BUILD SANDBOX CAN AND CANNOT RUN — MEASURED 2026-09-06 inside a real
# build on aarch64-darwin (Determinate Nix 3.22.3; `sandbox = false`, the darwin
# default, so this is the PERMISSIVE case):
#
#   /usr/bin/lockf     execs, rc 0     the worker's real flock(2) re-exec works
#                                      here, so it is NOT bypassed with
#                                      MEDIA_QUEUE_LOCK_HELD — the lock is under
#                                      test like everything else.
#   /usr/bin/pmset     execs, rc 0     and answers for the REAL machine — see the
#                                      awk shadow below, this is the one hazard.
#   /bin/launchctl     execs, rc 113   `kickstart` on an absent agent; enqueue's
#                                      own `|| true` absorbs it, as designed.
#   /usr/sbin/lsof     execs, rc 1
#   /bin/ps            EPERM, rc 126   it is setuid root (-rwsr-xr-x) and the
#                                      build user may not exec it.
#
# /bin/ps is the hole, and it BOUNDS this check honestly. Every path that reads a
# process state — media-queue-pause/resume, media-queue-power-monitor,
# cleanup()'s "spare a PAUSED job", and the ADOPTION half of orphan recovery —
# needs it. Those are not stubbed into passing and not asserted at all; the
# scenarios below deliberately stay on the side of orphan recovery that /bin/ps
# never reaches (a job pid that is already dead). Adoption and pause need a live
# login session with signals flying between processes that outlive their parent;
# that is a manual runbook, not `nix flake check`, and pretending otherwise would
# be a test that asserts nothing.
{ pkgs }:
let
  # THE DISPATCH TARGET, SCRIPTABLE PER ATTEMPT. `plan/<basename>.plan` holds one
  # verdict per line, read by attempt number, so a single file can fail twice and
  # then succeed — which is the only way to observe that a `done:` line from a
  # FAILED attempt is discarded rather than counted. The grammar it prints is the
  # parsed one (`: done:` / `: skip:` / `: error:`); `fail-done` prints `done:`
  # AND exits non-zero on purpose.
  stub =
    prog:
    pkgs.writeShellApplication {
      name = prog;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gnused
      ];
      text = ''
        plan_dir=''${MEDIA_QUEUE_TEST_PLAN:?stub needs MEDIA_QUEUE_TEST_PLAN}
        # The worker calls `media-fix --<class> <path>` or `media-describe <path>`.
        path=""
        for a in "$@"; do
          case "$a" in --*) ;; *) path="$a" ;; esac
        done
        base=''${path##*/}
        n=1
        if [ -f "$plan_dir/$base.n" ]; then n=$(( $(cat "$plan_dir/$base.n") + 1 )); fi
        echo "$n" > "$plan_dir/$base.n"
        verdict=ok
        if [ -f "$plan_dir/$base.plan" ]; then
          verdict=$(sed -n "''${n}p" "$plan_dir/$base.plan")
          [ -n "$verdict" ] || verdict=ok
        fi
        echo "${prog} $base attempt=$n verdict=$verdict" >> "$plan_dir/calls"
        case "$verdict" in
          ok)        echo "${prog}: done: '$path'"; exit 0 ;;
          skip)      echo "${prog}: skip: '$path' — already correct"; exit 0 ;;
          fail-done) echo "${prog}: done: '$path'"; echo "${prog}: error: '$path' — stub" >&2; exit 1 ;;
          *)         echo "${prog}: error: '$path' — stub" >&2; exit 1 ;;
        esac
      '';
    };

  # THE ONE THING THE SANDBOX CANNOT MAKE DETERMINISTIC, AND THE ONLY LEVER THAT
  # REACHES IT. media-worker gates every dispatch on `lowpower_active()`, which
  # shells out to `/usr/bin/pmset` — an ABSOLUTE path, so no $PATH stub can touch
  # it, and it reports the power state of whatever Mac is building. MEASURED
  # 2026-09-06: pmset execs fine in the sandbox and returned `lowpowermode 1` on
  # this laptop, which makes the worker defer every job and exit — a check that
  # would then assert NOTHING AT ALL, silently, whenever the operator is on
  # battery, and pass on CI's plugged-in runner. That is the exact "passes for the
  # wrong reason" failure this file exists to avoid.
  #
  # `awk` is the one command in that pipeline that comes from the AMBIENT $PATH:
  # media-worker's runtimeInputs are coreutils, findutils, util-linuxMinimal and
  # the two dispatch CLIs — none ships an awk — so shadowing awk is the only
  # interception point that exists. Narrow on purpose: anything that is not the
  # lowpowermode probe is handed straight to the real gawk. And it RECORDS that it
  # was consulted, which the first scenario asserts — so if the probe ever stops
  # going through awk, this check fails loudly instead of quietly going back to
  # depending on the builder's battery.
  awkShadow = pkgs.writeShellApplication {
    name = "awk";
    text = ''
      case "$*" in
        *lowpowermode*)
          echo consulted >> "''${MEDIA_QUEUE_TEST_AWK_MARK:?}"
          echo 0
          exit 0
          ;;
      esac
      exec ${pkgs.gawk}/bin/awk "$@"
    '';
  };

  # `date` SHADOWED FOR THE SAME REASON AS awk, and it is not optional: without
  # it the collision scenario is a COIN FLIP that can green-light the bug.
  #
  # The parked-retry name is built from `date +%s`, which is second-granularity,
  # so "two jobs requeued in the same second collide" only reproduces when both
  # requeues land inside one real wall-clock second. MEASURED on this machine,
  # same unfixed media-queue.nix, same check: one run FAILED (both requeues in
  # one second — the collision the assertion is looking for) and a later run
  # PASSED (they straddled a second boundary, no collision, staging held 2).
  # A check that reports a known-broken tree as green depending on how fast the
  # builder is running that minute is worse than no check, because it is
  # believed.
  #
  # Pinned only while MEDIA_QUEUE_TEST_EPOCH is set, and only for `+%s`;
  # everything else goes to the real coreutils date, so `log()`'s human
  # timestamps are untouched. The pinned value is far above the 1000000001
  # fixture stamps, so the "a retry gets a FRESH stamp" assertion still means
  # what it says.
  dateShadow = pkgs.writeShellApplication {
    name = "date";
    text = ''
      if [ -n "''${MEDIA_QUEUE_TEST_EPOCH:-}" ] && [ "''${1:-}" = "+%s" ]; then
        echo "$MEDIA_QUEUE_TEST_EPOCH"
        exit 0
      fi
      exec ${pkgs.coreutils}/bin/date "$@"
    '';
  };

  queue = pkgs.callPackage ../packages/media-queue.nix {
    media-fix = stub "media-fix";
    media-describe = stub "media-describe";
  };
in
pkgs.runCommand "media-cli-queue-state-machine" { } ''
  export PATH="${dateShadow}/bin:${awkShadow}/bin:${queue}/bin:$PATH"
  # Every `date +%s` in this check answers 1788700000, so the same-second
  # collision the retry scenario probes is DETERMINISTIC rather than a race
  # against the builder's clock. See the dateShadow comment for the measurement.
  export MEDIA_QUEUE_TEST_EPOCH=1788700000
  export MEDIA_QUEUE_TEST_AWK_MARK="$TMPDIR/awk-consulted"

  # The log and the state tree are the evidence; print them on any failure so a
  # red CI leg is diagnosable without re-running anything by hand.
  fail() {
    echo "queue-state-machine: FAIL: $*" >&2
    echo "--- worker log"; cat "$LOG" 2>/dev/null || true
    echo "--- state tree"; find "$STATE" 2>/dev/null || true
    echo "--- stub calls"; cat "$MEDIA_QUEUE_TEST_PLAN/calls" 2>/dev/null || true
    exit 1
  }

  # A fresh $HOME per scenario: the queue's whole state lives under it, so this
  # is the isolation boundary — no cleanup logic of our own. The literal space in
  # "Application Support" is deliberate coverage of the quoting.
  scenario() {
    export HOME="$TMPDIR/$1"
    export MEDIA_QUEUE_TEST_PLAN="$TMPDIR/$1.plan"
    STATE="$HOME/Library/Application Support/nix-media-queue"
    mkdir -p "$MEDIA_QUEUE_TEST_PLAN" "$STATE/queue-high" "$STATE/queue" \
             "$STATE/queue-low" "$STATE/staging" "$STATE/failed" "$HOME/Library/Logs"
    LOG="$TMPDIR/$1.log"
    : > "$LOG"
    echo "== $1: $2"
  }

  # Land a job the way media-enqueue does — written in staging, moved in — so a
  # scenario can pick the epoch in the name, which is the thing under test.
  job() { printf '%s\0' "$2" "$3" > "$STATE/staging/$1"; mv "$STATE/staging/$1" "$4/$1"; }

  count() { find "$1" -maxdepth 1 -name '*.job' -type f | wc -l | tr -d ' '; }

  #####################################################################
  scenario enqueue "media-enqueue routes --priority to the right tier"
  media-enqueue --image --priority high /tmp/a.jpg
  media-enqueue --image /tmp/b.jpg
  media-enqueue --describe --priority normal /tmp/c.jpg
  media-enqueue --video --priority low /tmp/d.mov
  test "$(count "$STATE/queue-high")" = 1 || fail "--priority high did not land in queue-high"
  test "$(count "$STATE/queue")" = 2 || fail "the default and --priority normal did not land in queue"
  test "$(count "$STATE/queue-low")" = 1 || fail "--priority low did not land in queue-low"
  test "$(count "$STATE/staging")" = 0 || fail "media-enqueue left a job behind in staging"
  hi=$(find "$STATE/queue-high" -name '*.job')
  case "$(basename "$hi")" in *.t1.job) ;; *) fail "an enqueued job must start at .t1: $hi" ;; esac
  tr '\0' '\n' < "$hi" | head -2 > "$TMPDIR/got-fields"
  test "$(head -1 "$TMPDIR/got-fields")" = image || fail "job field 1 is not the class"
  test "$(sed -n 2p "$TMPDIR/got-fields")" = /tmp/a.jpg || fail "job field 2 is not the path"

  #####################################################################
  scenario order "the worker claims jobs oldest-first by the epoch in the name"
  # Created NEWEST first, so a worker that took directory order rather than the
  # sorted epoch would be caught.
  job 1000000002-9-1.t1.job image /tmp/third.jpg  "$STATE/queue"
  job 1000000000-7-1.t1.job image /tmp/first.jpg  "$STATE/queue"
  job 1000000001-8-1.t1.job image /tmp/second.jpg "$STATE/queue"
  media-worker >> "$LOG" 2>&1 || fail "worker exited non-zero"
  test -s "$MEDIA_QUEUE_TEST_AWK_MARK" \
    || fail "the Low Power Mode probe never went through the awk shadow — this check would now depend on the builder's battery"
  test "$(date +%s)" = 1788700000 \
    || fail "the date shadow is not on PATH — the collision scenario would be a race against the builder's clock instead of a test"
  grep -o "start image '/tmp/[a-z]*\.jpg'" "$LOG" | sed "s#.*/tmp/##;s#\.jpg'##" > "$TMPDIR/got-order"
  printf 'first\nsecond\nthird\n' > "$TMPDIR/want-order"
  diff -u "$TMPDIR/want-order" "$TMPDIR/got-order" \
    || fail "jobs were not claimed oldest-first by the filename epoch"

  #####################################################################
  scenario retry "a failing job: fresh stamp, t2, t3, dead letter — counted once"
  printf 'fail-done\nfail-done\nok\n' > "$MEDIA_QUEUE_TEST_PLAN/good.jpg.plan"
  printf 'fail\nfail\nfail\n'         > "$MEDIA_QUEUE_TEST_PLAN/bad.jpg.plan"
  job 1000000000-1-1.t1.job image /tmp/good.jpg "$STATE/queue"
  job 1000000001-1-2.t1.job image /tmp/bad.jpg  "$STATE/queue"

  media-worker >> "$LOG" 2>&1 || fail "worker run 1 exited non-zero"
  test "$(count "$STATE/staging")" = 2 \
    || fail "two jobs failed in the SAME SECOND and staging/ holds $(count "$STATE/staging") — the parked retry name has no per-job discriminator, so one job was silently overwritten"
  for f in "$STATE/staging"/*.job; do
    b=$(basename "$f")
    case "$b" in *-retry.t2.job) ;; *) fail "a parked retry is not *-retry.t2.job: $b" ;; esac
    stamp=''${b%%-*}
    test "$stamp" -gt 1000000001 \
      || fail "the retry kept its ORIGINAL stamp ($stamp) — it must be fresh, or it is handed straight back and spins"
  done
  grep -q "idle — 0 changed, 0 skipped, 0 failed" "$LOG" \
    || fail "a FAILED attempt that printed done: was counted — run 1 must report 0 changed"

  # THE BACKOFF TIMER IS BRIDGED HERE, NOT WAITED OUT. The real one is a disowned
  # `sleep 20` then `sleep 45` per job (next*next*5), and the stranded-retry
  # reclaim that would otherwise rescue them needs `find -mmin +2` — three
  # minutes of sleeping inside `nix flake check` to observe file moves already
  # asserted above. The timer's TARGET TIER is what actually needs the real
  # thing, and the `preserve` scenario below pays the 20 s to watch it. Moving
  # into queue/ is only sound because both jobs came from queue/.
  bridge() {
    for f in "$STATE/staging"/*-retry.t*.job; do
      if [ -e "$f" ]; then mv "$f" "$STATE/queue/$(basename "$f")"; fi
    done
  }

  bridge
  media-worker >> "$LOG" 2>&1 || fail "worker run 2 exited non-zero"
  for f in "$STATE/staging"/*.job; do
    case "$(basename "$f")" in *-retry.t3.job) ;; *) fail "attempt 3 was not scheduled as t3: $f" ;; esac
  done

  bridge
  media-worker >> "$LOG" 2>&1 || fail "worker run 3 exited non-zero"
  grep -q "giving up on '/tmp/bad.jpg' after 3 attempts" "$LOG" || fail "MAX_TRIES did not dead-letter"
  test "$(find "$STATE/failed" -type f | wc -l | tr -d ' ')" = 1 || fail "failed/ does not hold exactly the one dead job"
  case "$(basename "$(find "$STATE/failed" -type f)")" in
    *.t3.job) ;; *) fail "the dead-lettered name lost its attempt count" ;;
  esac
  test "$(count "$STATE/queue")$(count "$STATE/queue-low")$(count "$STATE/staging")" = 000 \
    || fail "the queue is not drained after three runs"
  test "$(grep -c 'attempt=' "$MEDIA_QUEUE_TEST_PLAN/calls")" = 6 \
    || fail "expected exactly 6 dispatches (2 jobs x 3 attempts)"
  # The stub printed `done:` on all three of good.jpg's attempts. Per JOB, that
  # is ONE change; per ATTEMPT it would be three — the "12 change(s) for four
  # photos" bug the worker's own comment records.
  changed=0
  while read -r n; do changed=$((changed + n)); done < <(sed -n 's/.*idle — \([0-9]*\) changed.*/\1/p' "$LOG")
  test "$changed" = 1 \
    || fail "done: was counted per ATTEMPT, not per JOB (total changed=$changed across the three runs, want 1)"

  #####################################################################
  scenario demote "crash recovery DEMOTES an orphan to queue-low"
  # A pid that is definitively dead: forked, reaped, then proven gone. The job
  # file carries only two fields, so its third — the job's own pid — is absent
  # and the worker takes the RECOVER branch, never the ADOPT one. That is what
  # keeps this scenario clear of /bin/ps, which the build user cannot exec.
  sleep 0 & dead=$!
  wait "$dead" || true
  if kill -0 "$dead" 2>/dev/null; then fail "the 'dead' worker pid $dead is still alive — scenario is invalid"; fi
  printf '%s\0' image /tmp/orphan.jpg > "$STATE/running-$dead.job"
  # The decoy is stamped in the year 2286, so it loses on epoch to anything the
  # recovery writes. It can therefore only be claimed FIRST if the recovered job
  # went to a LOWER tier — which is the assertion. A decoy with an ordinary
  # stamp would win on epoch either way and prove nothing.
  job 9999999999-1-1.t1.job image /tmp/decoy.jpg "$STATE/queue"
  media-worker >> "$LOG" 2>&1 || fail "worker exited non-zero"
  grep -q "recovering orphaned job from pid $dead" "$LOG" || fail "the orphan was not recovered at all"
  grep -o "start image '/tmp/[a-z]*\.jpg'" "$LOG" | sed "s#.*/tmp/##;s#\.jpg'##" > "$TMPDIR/got-demote"
  printf 'decoy\norphan\n' > "$TMPDIR/want-demote"
  diff -u "$TMPDIR/want-demote" "$TMPDIR/got-demote" \
    || fail "the recovered job was NOT demoted to queue-low — it beat a far newer job sitting in queue/"

  #####################################################################
  scenario preserve "an ordinary retry PRESERVES its source tier"
  printf 'fail\n' > "$MEDIA_QUEUE_TEST_PLAN/keepme.jpg.plan"
  job 1000000000-1-1.t1.job image /tmp/keepme.jpg "$STATE/queue-high"
  media-worker >> "$LOG" 2>&1 || fail "worker exited non-zero"
  test "$(count "$STATE/staging")" = 1 || fail "the failed job was not parked in staging/"
  # THE REAL TIMER, NOT A BRIDGE. The tier a retry returns to is decided inside
  # the disowned `( sleep 20; mv ... )` subshell and is recorded NOWHERE else —
  # the parked filename carries no tier — so this is the one assertion that has
  # to pay for the wall clock. MEASURED: the subshell survives the worker's exit
  # inside the build and delivered at 19 s. Polled, not slept, so it costs what
  # it costs and no more; the ceiling is 2x the 20 s backoff.
  waited=0
  while [ "$(count "$STATE/queue-high")" = 0 ] && [ "$waited" -lt 40 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  test "$(count "$STATE/queue-high")" = 1 \
    || fail "the retry never came back to queue-high (waited ''${waited}s for a 20s backoff)"
  test "$(count "$STATE/queue")" = 0 || fail "the retry was requeued to queue/ instead of its own tier"
  test "$(count "$STATE/queue-low")" = 0 \
    || fail "the retry was DEMOTED to queue-low — only crash recovery may demote"

  echo ok > "$out"
''
