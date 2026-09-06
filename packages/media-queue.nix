# media-queue — the durable work queue behind the Finder Services.
#
#   media-enqueue <--video|--image> [--priority high|normal|low] <file-or-dir>...
#                                                       write jobs, return at once
#   media-worker                                       drain the queue (launchd)
#   media-queue-pause                                  freeze the in-flight job
#   media-queue-resume                                 unfreeze it
#   media-queue-status                                 what's running/queued/failed
#   media-queue-top                                     media-queue-status, refreshed live (viddy)
#   media-queue-power-monitor                          launchd StartInterval only, not for interactive use
#
# WHY A QUEUE AT ALL. Re-encoding two hundred videos is hours of ffmpeg. Doing
# that inside the Automator Service means the work dies at logout, cannot be
# paused or cancelled, reports nothing until it ends, and competes with the
# user's foreground apps for CPU. Moving it behind launchd fixes all four with
# no scheduler of our own.
#
# EVERY MECHANISM HERE IS launchd's, NOT OURS — see modules/shared/media-queue.nix:
#
#   QueueDirectories               the queue: launchd starts the worker whenever
#                                  the directory is non-empty
#   ProcessType = "Background"     the load control: the OS throttles CPU and
#                                  I/O bandwidth so a batch cannot make the Mac
#                                  feel slow
#   KeepAlive.SuccessfulExit=false the crash retry, with ThrottleInterval as the
#   + ThrottleInterval             backoff
#   RunAtLoad                      drains whatever a logout interrupted
#   StandardOutPath                the log, in the place Console.app reads
#
# What is left for this file is the part launchd has no opinion about: what a
# job IS, and what to do with one that fails.
#
# ONE FILE PER JOB, not one job per selection. It costs a process per file and
# buys everything else: progress is just the queue depth, retry and cancellation
# are per file, and one hopeless file cannot drag its neighbours down with it. A
# DIRECTORY argument stays a single job — expanding it at enqueue time would put
# a recursive walk inside the Finder click, which is the one thing enqueueing
# must never do.
#
# A FAILED JOB IS REQUEUED WITH A FRESH TIMESTAMP, not its original one. Jobs
# are picked oldest-first by the epoch in their name, so keeping the old stamp
# would hand the same failing file straight back to the worker and spin. Three
# attempts, then it moves to `failed/` — a dead-letter directory, the standard
# shape, so a permanent failure stops costing anything but stays inspectable.
#
# The worker requeues its in-flight job on SIGTERM, so a logout or a
# `launchctl kill` costs at most a repeat of one file rather than the batch.
#
# THREE QUEUE DIRECTORIES, NOT ONE — `queue-high`/`queue`/`queue`-adjacent
# `queue-low`, drained in that order. `queue` is the original, unchanged
# tier every existing caller already uses. This exists because launchd
# reloading this agent (an `activate`, a logout) kills whatever worker is
# holding a job, and that worker's own crash-recovery — the orphan-recovery
# loop below, the stranded-retry reclaim, and `cleanup()`'s own
# requeue-on-interrupt — used to put the job straight back in `queue`,
# where it competed evenly with a brand new request. MEASURED, 2026-09-05:
# a handful of `activate` runs on this Mac left 6 duplicate `media-describe`
# passes over the same folder, each one system-generated noise a fresh
# Finder click would have queued behind. Those three recovery sites now
# demote to `queue-low` UNCONDITIONALLY; a normal failing-job retry
# (`MAX_TRIES`, its own backoff) and a Low-Power-Mode defer instead
# PRESERVE `$src_tier` — a transient failure or a global power condition is
# not the job's fault the way a crashed worker is, and doesn't deserve to
# lose its place. `media-enqueue --priority high` is the explicit lever for
# `queue-high`; nothing calls it today except a human at the CLI — no
# Finder Service is wired to it, so every existing Quick Action is
# unaffected.
#
# PAUSE IS SIGSTOP ON THE JOB'S PROCESS GROUP, NOT SIGTERM ON THE WORKER.
# SIGTERM is already spoken for above — it means "give this job back to the
# queue", which is right for a logout but wrong for "hold on a second": it
# throws away everything the current file (or, for `describe`, the current
# BATCH — a directory is one job) has done and restarts it from the top on
# resume. SIGSTOP instead freezes the job exactly where it is — mid-`exiftool`
# write, mid-`curl` to Ollama — and SIGCONT picks it back up from that same
# byte, no progress lost, no requeue, no fresh attempt counted against
# MAX_TRIES.
#
# `-$pid`, NEVER bare `$pid`. `setsid` in media-worker gives the backgrounded
# job its own SESSION, which is by construction also its own process group
# (pgid == its own pid) — specifically so the existing `kill -TERM -"$child"`
# in the SIGTERM path can reach grandchildren like media-transcode's ffmpeg.
# The negative pid is what makes a signal hit the whole group instead of only
# the immediate child; pause/resume reuse that same convention so a stop
# actually freezes exiftool/curl/ffmpeg too, not just the shell driving them.
# The SESSION half (not just the group) is load-bearing, not incidental —
# see media-worker's own `setsid` comment for why a plain process group
# alone was not enough.
#
# THE WORKER LOOP PAUSES FOR FREE. `media-worker` calls `wait "$child"`, and
# POSIX `wait` only returns on termination, never on stop — so a SIGSTOPped
# job leaves the worker parked in that syscall rather than moving on to the
# next queued file. Nothing extra is needed to stop the QUEUE, only the job.
#
# FOUND VIA `running-<worker-pid>.job`, THE SAME MARKER THE WORKER USES FOR
# ITS OWN ORPHAN RECOVERY. `pgrep -P` on that pid is a DIRECT child by
# construction (the job is backgrounded once, from that exact process), so
# this can never accidentally reach into some other worker's job.
#
# KNOWN GAP: the brief window between one job finishing and the next being
# claimed has no `running-*.job` file, so a pause issued in that instant finds
# nothing to freeze and the next file starts anyway. Harmless for the case
# this exists for — pausing a long batch mid-flight — and not worth a second
# mechanism to close a race measured in milliseconds.
#
# KNOWN COST: a job frozen past Ollama's own read timeout, or past whatever a
# paused `curl` call's peer decides to give up on, resumes into a failed
# request rather than a completed one. That is not a new failure mode — the
# per-file retry/backoff loop above already exists to absorb exactly this —
# it only means a very long pause can cost the one file that was mid-caption
# when it started, not the batch.
{
  lib,
  symlinkJoin,
  writeShellApplication,
  callPackage,
  coreutils,
  findutils,
  util-linuxMinimal,
  viddy,
  # The two CLIs media-worker dispatches to, NOT the whole media-toolkit bundle
  # it used to take. Two reasons, and the first is load-bearing:
  #
  #   1. media-toolkit bundles `media`, and `media` now exposes a `queue` verb
  #      that needs media-queue — so depending on the bundle here is an
  #      evaluation CYCLE (media -> media-queue -> media-toolkit -> media).
  #      Naming the two leaves breaks it; neither depends on `media`.
  #   2. It was always over-broad. The dispatch below only ever calls these
  #      two, and media-fix brings media-fix-extension/media-transcode along in its
  #      own runtimeInputs, so nothing is lost.
  media-fix ? callPackage ./media-fix.nix { },
  media-describe ? callPackage ./media-describe.nix { },
}:
let
  # Spliced into all three, so the layout is stated once. INLINED rather than
  # sourced from a `writeText`: shellcheck cannot follow a `.` into /nix/store
  # (SC1091) and would then treat every shared variable as unassigned, so the
  # lint gate would have to be switched off for exactly the code most worth
  # linting. $HOME at RUNTIME — these are paths the tools read and write, not
  # Nix source paths.

  common = ''
    STATE="$HOME/Library/Application Support/nix-media-queue"
    # THREE TIERS, NOT ONE, so a fresh request never queues behind traffic
    # the SYSTEM generated recovering from its own interruption. `queue`
    # keeps its name and meaning unchanged — every existing caller (all
    # three Finder Quick Actions, any script) lands here exactly as before.
    # `queue-high` is the explicit `media-enqueue --priority high` lever.
    # `queue-low` is where crash-recovery specifically gets demoted to —
    # see the per-site comments in media-worker for which paths do that
    # and which instead PRESERVE a job's original tier.
    QUEUE_HIGH="$STATE/queue-high"
    QUEUE="$STATE/queue"
    QUEUE_LOW="$STATE/queue-low"
    STAGE="$STATE/staging"
    FAILED="$STATE/failed"

    # `staging` is a SIBLING of the queue dirs, never a dotfile inside one:
    # launchd starts the worker the moment ANY queue dir is non-empty, so a
    # job written in place could be picked up half-written. Jobs land by
    # rename, which is atomic within a filesystem.
    ensure_dirs() {
      mkdir -p "$QUEUE_HIGH" "$QUEUE" "$QUEUE_LOW" "$STAGE" "$FAILED" "$HOME/Library/Logs"
    }

    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

    # THE STANDARD WAY TO READ LOW POWER MODE FROM A SHELL, VERIFIED ON THIS
    # MAC. Apple's real API is `ProcessInfo.isLowPowerModeEnabled` +
    # `NSProcessInfoPowerStateDidChangeNotification`, but that notification
    # is explicitly UNAVAILABLE ON MACOS (iOS-only) — so there is no
    # event-driven alternative to poll for anyway. `pmset -g`'s "Currently
    # in use" block already merges AC/battery into one live value, which is
    # why this respects Low Power Mode regardless of power source for free
    # — no separate AC/battery branch needed. Reading it needs no
    # privilege; only WRITING it (`pmset -a/-b/-c`) needs root. Fails OPEN
    # on any parse hiccup — every caller compares the result against the
    # literal string "1", so a missing/empty/unexpected value reads as "not
    # active" rather than blocking work. An optional efficiency signal must
    # never be able to wedge the whole queue. Used by media-worker (the
    # pre-dispatch gate), media-queue-power-monitor (the periodic pause/
    # resume) and media-queue-resume (the refusal check) — shared here
    # rather than duplicated, per this file's own "common holds what more
    # than one script needs" rule.
    lowpower_active() {
      /usr/bin/pmset -g 2>/dev/null | awk '/lowpowermode/{print $2; exit}'
    }

  '';

  # Named (not inlined in `paths` below) so media-queue-top can put it on
  # its own runtimeInputs and call it by name — the same explicit-dependency
  # style media-worker already uses for media-toolkit, rather than relying
  # on it happening to already be on $PATH.
  media-queue-status = writeShellApplication {
    name = "media-queue-status";
    runtimeInputs = [
      coreutils
      findutils
    ];
    text = ''
      ${common}
      prog=media-queue-status
      [ $# -eq 0 ] || { echo "usage: $prog" >&2; exit 1; }
      ensure_dirs

      pending_high=$(find "$QUEUE_HIGH" -maxdepth 1 -name '*.job' -type f 2>/dev/null | wc -l | tr -d ' ')
      pending=$(find "$QUEUE" -maxdepth 1 -name '*.job' -type f 2>/dev/null | wc -l | tr -d ' ')
      pending_low=$(find "$QUEUE_LOW" -maxdepth 1 -name '*.job' -type f 2>/dev/null | wc -l | tr -d ' ')
      backoff=$(find "$STAGE" -maxdepth 1 -name '*-retry.t*.job' -type f 2>/dev/null | wc -l | tr -d ' ')
      dead=$(find "$FAILED" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')

      any_running=0
      for running in "$STATE"/running-*.job; do
        [ -e "$running" ] || continue
        wpid=''${running##*/running-}
        wpid=''${wpid%%.job}

        items=()
        while IFS= read -r -d "" x; do items+=("$x"); done < "$running"
        class=''${items[0]:-unknown}
        path=''${items[1]:-unknown}
        # THE JOB'S REAL PID — media-worker's own MAINPID-style record,
        # written right after forking it, independent of whether ITS
        # worker is still alive. That decoupling is what makes an
        # orphaned-but-alive job (its worker already dead) visible here
        # at all: it no longer needs a live `$wpid` to be found.
        jpid=''${items[2]:-}

        if [ -z "$jpid" ] || ! kill -0 "$jpid" 2>/dev/null; then
          # No recorded pid (a pre-upgrade job file) or it is genuinely
          # dead either way: the next worker's own orphan-recovery loop
          # reclaims this — see media-worker — so it is transient, not a
          # bug, and reported ONLY when there is truly no live worker
          # left to reclaim it on its own.
          if [ -z "$wpid" ] || ! kill -0 "$wpid" 2>/dev/null; then
            echo "$prog: stale marker $(basename "$running") — will self-heal on next worker start"
          fi
          continue
        fi

        any_running=1
        if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
          owner="worker $wpid"
        else
          owner="ORPHANED — no live worker, will be adopted on next worker start"
        fi
        # NOT the attempt number: media-worker renames the job to
        # running-$$.job the moment it dequeues it, which drops the
        # original `.tN` suffix that carried the attempt count. That
        # number exists only in the worker's own `log "start ... (attempt
        # N)"` line, not in any state this tool can read without coupling
        # to the log's format — so it is left out rather than guessed.
        state=$(/bin/ps -o stat= -p "$jpid" 2>/dev/null | tr -d ' ')
        case "$state" in
          T*)
            # The marker is media-queue-power-monitor's own trail:
            # present only for a pause IT made, never for one the
            # operator made by hand with media-queue-pause.
            if [ -f "$STATE/power-paused-$jpid" ]; then
              label="PAUSED (Low Power Mode, auto)"
            else
              label="PAUSED (SIGSTOP, manual)"
            fi
            ;;
          "") label="gone" ;;
          *)  label="running" ;;
        esac
        echo "$prog: $class '$path' — $label, pid $jpid ($owner)"

        # The scratch file is a bare mktemp with no name this tool ever
        # recorded — media-worker's own choice, on purpose (see its
        # comment on `scratch=$(mktemp)`), so the only way to find it
        # after the fact is the same place the kernel keeps it: the job's
        # own open stdout fd. `-Fn` gives just the name field, one write
        # NUL-free line, which survives a path full of spaces.
        scratch=$(/usr/sbin/lsof -a -p "$jpid" -d 1 -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1)
        if [ -n "$scratch" ] && [ -f "$scratch" ]; then
          d=$(grep -c ': done:' "$scratch" 2>/dev/null || true)
          sk=$(grep -cE ': (skip|OK):' "$scratch" 2>/dev/null || true)
          er=$(grep -c ': error:' "$scratch" 2>/dev/null || true)
          last=$(tail -n1 "$scratch" 2>/dev/null || true)
          echo "$prog:   progress so far: $((d + sk + er)) processed ($d done, $sk skip/OK, $er error)"
          [ -n "$last" ] && echo "$prog:   last: $last"
        fi
      done

      if [ "$any_running" -eq 0 ]; then
        echo "$prog: worker idle — nothing in flight"
      fi

      echo "$prog: queue: $pending_high high, $pending normal, $pending_low low pending, $backoff backing off (retry), $dead dead-letter (failed/)"
    '';
  };
in
symlinkJoin {
  name = "media-queue";
  paths = [
    (writeShellApplication {
      name = "media-enqueue";
      runtimeInputs = [ coreutils ];
      text = ''
        ${common}
        prog=media-enqueue
        usage="usage: $prog <--video|--image|--describe> [--priority high|normal|low] <file-or-directory>..."
        die() { echo "$prog: error: $*" >&2; exit 1; }

        class=""
        # `normal` (today's only tier) stays the default, so every EXISTING
        # caller — all three Finder Quick Actions, any script already using
        # this — is unaffected without a single change on their side.
        priority=normal
        while [ $# -gt 0 ]; do
          case "$1" in
            # `--describe` is a class like the other two, not a flag on
            # --image: it ENRICHES a working file rather than repairing a
            # broken one, and it is the only class whose work needs a
            # vision model, so an operator asking to repair photos must
            # never be made to wait on one.
            --video) class=video; shift ;;
            --image) class=image; shift ;;
            --describe) class=describe; shift ;;
            --priority)
              priority="''${2:-}"
              case "$priority" in
                high|normal|low) ;;
                *) die "--priority must be high, normal, or low" ;;
              esac
              shift 2 ;;
            --help|-h) echo "$usage" >&2; exit 0 ;;
            --) shift; break ;;
            -*) die "$usage" ;;
            *) break ;;
          esac
        done
        [ -n "$class" ] || die "$usage"
        [ $# -ge 1 ] || die "$usage"

        # Same three-way split media-worker's requeue sites use to decide
        # which tier a job belongs in — see packages/media-queue.nix's
        # media-worker for the demote-vs-preserve rule this feeds into.
        case "$priority" in
          high) target_queue="$QUEUE_HIGH" ;;
          low)  target_queue="$QUEUE_LOW" ;;
          *)    target_queue="$QUEUE" ;;
        esac

        ensure_dirs
        stamp=$(date +%s)
        n=0
        for p in "$@"; do
          # Absolute, but NOT resolved: the worker runs with a different working
          # directory, while `realpath` would also follow symlinks and rename
          # something the operator did not select.
          case "$p" in
            /*) ;;
            *) p="$PWD/$p" ;;
          esac
          n=$((n + 1))
          job="$stamp-$$-$n.t1.job"
          printf '%s\0' "$class" "$p" > "$STAGE/$job"
          mv "$STAGE/$job" "$target_queue/$job"
        done

        # Ask launchd to run the worker NOW. QueueDirectories gets there on its
        # own, but only after ThrottleInterval, which spaces every start of the
        # job rather than only its respawns — measured, a right-click waited a
        # full minute at 60s. `kickstart` is launchd's own "run this now", so the
        # fast path is still launchd's mechanism rather than a private one.
        # Failure is ignored deliberately: the CLI must work where the agent is
        # not installed, and the directory watch is the fallback either way.
        /bin/launchctl kickstart "gui/$(id -u)/org.nix-community.home.media-queue" \
          >/dev/null 2>&1 || true
      '';
    })

    (writeShellApplication {
      name = "media-worker";
      runtimeInputs = [
        coreutils
        findutils
        media-fix
        media-describe
        util-linuxMinimal
      ];
      text = ''
        ${common}
        ensure_dirs

        # The prelude holds only what ALL THREE scripts use; anything narrower
        # lives with its user, because an unused variable is a lint failure —
        # and rightly so, since it is usually a leftover.
        LOCK="$STATE/worker.lock"
        MAX_TRIES=3

        # THE LOCK IS THE KERNEL'S, NOT OURS. `/usr/bin/lockf` ships with macOS and
        # takes a `flock(2)` lock, which the kernel releases when the holder dies
        # — INCLUDING on SIGKILL, where no trap can run. That makes a stale lock
        # structurally impossible, so the whole hand-written mutex this replaces
        # (mkdir + a pid file + a `kill -0` liveness probe + a "breaking stale
        # lock" branch) has nothing left to do.
        #
        # That code was not merely redundant, it was a reimplementation of a
        # DEPRECATED Apple utility: /usr/bin/shlock does link(2)+PID-liveness,
        # exactly the same algorithm, and its own man page points at lockf.
        #
        # `-t 0` means fail immediately rather than wait, and lockf then exits 75
        # (EX_TEMPFAIL) — measured. Any other status is the worker's own, passed
        # through untouched, so launchd's KeepAlive still sees real failures.
        #
        # Re-exec rather than wrap: the lock must cover this whole script, and the
        # env guard is what stops the re-exec recursing.
        if [ -d "$LOCK" ]; then
          # Migration: the previous implementation made $LOCK a DIRECTORY, and
          # lockf cannot take a lock on one. Left in place it would break every
          # worker start on the first activation after this change.
          rm -rf "$LOCK"
        fi
        if [ -z "''${MEDIA_QUEUE_LOCK_HELD:-}" ]; then
          export MEDIA_QUEUE_LOCK_HELD=1
          lock_rc=0
          /usr/bin/lockf -t 0 -k "$LOCK" "$0" "$@" || lock_rc=$?
          if [ "$lock_rc" -eq 75 ]; then
            log "another worker holds the lock — exiting"
            exit 0
          fi
          exit "$lock_rc"
        fi

        # Same reasoning one level down: a job the previous worker was holding
        # when it was killed is still sitting in `running-<pid>.job`. If that pid
        # is gone, the job MIGHT still be alive — check before assuming it isn't.
        #
        # ADOPT, DON'T ALWAYS DEMOTE. A `running-*.job` file with a dead
        # owner used to mean only one thing: the worker died, put the job
        # back. Since the worker now records the job's OWN pid in that
        # file (see `printf ... > "$running"` right after `child=$!`
        # below), a dead owner might still have a perfectly healthy,
        # paused job sitting behind it — MEASURED: this exact situation
        # produced 7 duplicate `media-describe` passes over one folder in
        # a single evening, each `activate` adding one more, because the
        # old code could only ever discard and restart. Adopt at most ONE
        # per worker start (this worker can only run one job at a time
        # anyway); any additional adoptable orphan is left completely
        # untouched for a LATER worker start to find, rather than risk two
        # adoptions racing to rename into the same `running-$$.job`.
        adopted_child=""
        adopted_class=""
        adopted_path=""
        adopted=0
        for orphan in "$STATE"/running-*.job; do
          [ -e "$orphan" ] || continue
          opid=''${orphan##*/running-}
          opid=''${opid%%.job}
          if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then
            continue
          fi

          items=()
          while IFS= read -r -d "" x; do items+=("$x"); done < "$orphan"
          ojclass=''${items[0]:-}
          ojpath=''${items[1]:-}
          ojchild=''${items[2]:-}

          if [ -n "$ojchild" ] && kill -0 "$ojchild" 2>/dev/null; then
            if [ "$adopted" -eq 0 ]; then
              log "adopting orphaned job '$ojpath' (pid $ojchild) — its worker $opid is gone, the job is not"
              if mv "$orphan" "$STATE/running-$$.job" 2>/dev/null; then
                adopted_child="$ojchild"
                adopted_class="$ojclass"
                adopted_path="$ojpath"
                adopted=1
              fi
            fi
            continue
          fi

          log "recovering orphaned job from pid $opid"
          # `$QUEUE_LOW`, NOT the tier this job started at: this is the
          # SYSTEM recovering from losing a worker, not the job's own
          # priority changing. A fresh request enqueued while this Mac was
          # busy cleaning up after a crash must not queue behind the
          # cleanup — see media-enqueue's `--priority` and the table this
          # mirrors in packages/media-queue.nix's own header comment.
          mv "$orphan" "$QUEUE_LOW/$(date +%s)-recovered-$opid.t1.job" 2>/dev/null || true
        done

        # And one level further: a job waiting out a retry backoff lives in
        # staging/, which launchd does NOT watch, and the timer that moves it back
        # is a backgrounded sleep. If that sleep dies — logout, reboot, launchd
        # reaping the process group — the job is stranded where nothing will ever
        # look at it again. Any retry job already older than a generous ceiling is
        # therefore reclaimed on the next worker start, which is the one moment we
        # know a worker exists to do it.
        for held in "$STAGE"/*-retry.t*.job; do
          [ -e "$held" ] || continue
          if [ -n "$(find "$held" -mmin +2 2>/dev/null)" ]; then
            log "reclaiming stranded retry job $(basename "$held")"
            # `$QUEUE_LOW` — same reasoning as the orphan recovery above:
            # the backoff TIMER died, not the job. Demoted for the same
            # reason, not because this job failed more than any other retry.
            mv "$held" "$QUEUE_LOW/$(date +%s)-reclaimed.t$MAX_TRIES.job" 2>/dev/null || true
          fi
        done

        running=""
        child=""
        tailer=""
        cleanup() {
          # The tailer first: it holds no lock and does no real work, but a
          # `tail -f` left running past its job is exactly the "no leaked
          # helpers" this trap exists to prevent. Plain `kill`, not `-$pid`:
          # unlike the job, it was never given its own session/process group
          # (it is started BEFORE the `setsid` dispatch below, on purpose,
          # so the job's own SIGTERM below never has to account for it).
          [ -n "$tailer" ] && kill "$tailer" 2>/dev/null || true
          # A PAUSED job is spared entirely — this is the other half of
          # adoption. Killing it here would destroy exactly the thing a
          # future worker could otherwise resume: an intact process with
          # its real pid already recorded in `$running`. Left untouched, it
          # is immediately MAINPID-adoptable (see the pid recorded right
          # after `child=$!` above, and the orphan-recovery loop's adoption
          # branch below) the moment some worker — this one restarting, or
          # the next `activate`'s — looks for it.
          st=""
          [ -n "$child" ] && st=$(/bin/ps -o stat= -p "$child" 2>/dev/null | tr -d ' ')
          case "$st" in
            T*) : ;;
            *)
              # Kill the encode FIRST. Without this the trap would not even run until
              # ffmpeg finished on its own, and launchd escalates SIGTERM to SIGKILL
              # long before a two-hour batch is done.
              # The whole PROCESS GROUP, not just the child: media-fix's own ffmpeg is
              # a GRANDchild, and killing only the middle process orphans an encode
              # that keeps burning CPU and leaves its temp file behind. `setsid`
              # below puts each job in its own session/group so the negative pid
              # reaches all of it — including media-transcode, whose trap then removes the
              # partial encode.
              [ -n "$child" ] && kill -TERM -"$child" 2>/dev/null || true
              # An interrupted RUNNING job goes BACK to a queue rather than
              # being lost: a logout mid-batch should cost one repeated
              # file, not the batch. `$QUEUE_LOW`, always — this worker
              # dying (activation, logout, `launchctl kill`) is exactly the
              # self-inflicted traffic that must not make a fresh request
              # wait. Deliberately NOT `$src_tier` here even for a job that
              # started high-priority: an interrupted job is one MORE
              # attempt already spent on system recovery, not a reason to
              # keep cutting in line ahead of new requests. A PAUSED job
              # (above) never reaches this branch, so this only ever fires
              # for a job that was actively burning CPU when it lost its
              # worker — nothing to adopt, same as always.
              if [ -n "$running" ] && [ -f "$running" ]; then
                mv "$running" "$QUEUE_LOW/$(date +%s)-requeued-$$.t1.job" 2>/dev/null || true
              fi
              ;;
          esac
          # The lock is NOT released here. It is a flock(2) held by the lockf
          # parent, and the kernel drops it when that process exits — which it
          # does whether we got here by a clean exit, a trap, or a SIGKILL that
          # never ran this function at all. Deleting the lock FILE here would be
          # worse than useless: it would unlink a path another worker may already
          # have opened, handing two workers a lock on two different inodes.
        }
        trap cleanup EXIT
        trap 'cleanup; exit 143' INT TERM

        changed=0
        skipped=0
        failures=0
        jobs=0
        reason=

        while :; do
          # AN ADOPTED JOB, IF ANY, ALWAYS GOES FIRST — set at most once,
          # by the orphan-recovery loop above, before this loop ever
          # starts. Cleared immediately so every later iteration falls
          # straight through to the normal dequeue below.
          if [ -n "$adopted_child" ]; then
            class="$adopted_class"
            path="$adopted_path"
            child="$adopted_child"
            running="$STATE/running-$$.job"
            adopted_child=""
            adopted_class=""
            adopted_path=""

            st=$(/bin/ps -o stat= -p "$child" 2>/dev/null | tr -d ' ')
            case "$st" in
              T*)
                # `-"$child"`, matching every other resume in this file:
                # a bare pid would only wake the job's own top-level
                # process, leaving a stopped grandchild (curl, exiftool)
                # frozen forever — `setsid` makes `$child` both the
                # session leader and the group id, so the negative form
                # reaches all of it.
                if kill -CONT -"$child" 2>/dev/null; then
                  log "resumed adopted job '$path' (pid $child)"
                fi
                ;;
            esac
            log "supervising adopted job $class '$path' (pid $child)"

            # Re-attach live progress the same way media-queue-status
            # finds a job's scratch file after the fact — its own open
            # stdout fd, since this worker never opened it itself.
            scratch=$(/usr/sbin/lsof -a -p "$child" -d 1 -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1)
            tailer=""
            if [ -n "$scratch" ] && [ -f "$scratch" ]; then
              tail -f -s 0.2 "$scratch" &
              tailer=$!
            fi

            # POLL, NOT `wait`: `$child` was reparented when its original
            # worker died, so it is not THIS shell's child, and POSIX
            # `wait` can only block on / reap a real child. That also
            # means its true exit status is gone forever — recoverable by
            # no one but its original parent, a limit even systemd's own
            # MAINPID mechanism shares (see this feature's own plan for
            # the citation). Treated as a TERMINAL outcome either way,
            # NEVER fed into the retry-with-backoff branch below: its real
            # attempt count is already unknowable, and a job that actually
            # failed gets caught by the tool's own idempotency on the next
            # real enqueue, not by this worker guessing at a retry.
            while kill -0 "$child" 2>/dev/null; do sleep 1; done
            if [ -n "$tailer" ]; then
              sleep 0.3
              kill "$tailer" 2>/dev/null || true
              tailer=""
            fi
            out=""
            [ -n "$scratch" ] && [ -f "$scratch" ] && out=$(cat "$scratch")
            child=""

            d=$(printf '%s\n' "$out" | grep -c ': done:' || true)
            s=$(printf '%s\n' "$out" | grep -cE ': (skip|OK):' || true)
            changed=$((changed + d))
            skipped=$((skipped + s))
            jobs=$((jobs + 1))
            if [ "$d" -eq 0 ] && [ -z "$reason" ]; then
              reason=$(printf '%s\n' "$out" | grep -m1 -E ': (skip|OK):' \
                | sed -E "s/^[^:]*: (skip|OK): '[^']*' *//; s/^(—|-) *//" || true)
            fi
            rm -f "$running"
            running=""
            continue
          fi

          # HIGH, THEN NORMAL, THEN LOW — the first non-empty tier wins, so
          # anything sitting in `queue-low/` (crash recovery, see the
          # requeue sites above and below) never delays a fresh request in
          # `queue/` or `queue-high/`. `src_tier` records which directory a
          # job actually came from, for free — the requeue sites below use
          # it to either PRESERVE that tier or deliberately override it.
          job=""
          src_tier=""
          for src_tier in "$QUEUE_HIGH" "$QUEUE" "$QUEUE_LOW"; do
            # NO `| head` HERE. Under `pipefail`, `head -1` exits after its line,
            # `sort` takes SIGPIPE, and the pipeline returns 141 — which errexit
            # turns into a dead worker. It only bites once the listing exceeds the
            # 64 KB pipe buffer, so it is invisible in testing and appears in
            # production: measured with 761 jobs queued, the worker drained 1-3 of
            # them per launch instead of the whole queue, and launchd paid a
            # restart between each. Taking the first line by parameter expansion
            # keeps `sort` writing to a variable, where it can finish and exit 0.
            job=$(find "$src_tier" -maxdepth 1 -name '*.job' -type f 2>/dev/null | sort)
            job=''${job%%$'\n'*}
            [ -n "$job" ] && break
          done
          [ -n "$job" ] || break

          base=''${job##*/}
          tries=''${base##*.t}
          tries=''${tries%%.job}
          case "$tries" in
            ""|*[!0-9]*) tries=1 ;;   # "" for the empty pattern: a bare shell
                                     # two-quote is unlexable in a Nix
                                     # indented string.
          esac

          # The pid is IN THE NAME so the next worker can tell a live job from
          # one whose owner was killed.
          running="$STATE/running-$$.job"
          # If the rename loses a race with another worker, just move on.
          mv "$job" "$running" 2>/dev/null || { running=""; continue; }

          items=()
          while IFS= read -r -d "" x; do items+=("$x"); done < "$running"
          class=''${items[0]:-}
          path=''${items[1]:-}

          if [ -z "$class" ] || [ -z "$path" ]; then
            log "malformed job '$base' — discarding"
            rm -f "$running"; running=""
            continue
          fi

          # LOW POWER MODE GATES STARTING NEW WORK. media-queue-power-monitor
          # (a separate StartInterval launchd agent, not this loop) is what
          # catches Low Power Mode turning on mid-batch; this check only
          # covers the moment right before a job starts, so a job about to
          # begin doesn't have to wait out that agent's own interval first.
          # Put back with a FRESH t1, the same reset `…-recovered-*.t1.job`
          # already uses, so deferring for power never costs a retry
          # attempt. `break`, not a sleep loop: `ThrottleInterval` already
          # retries this worker every ~10s, so this reuses launchd's own
          # mechanism instead of adding a private one.
          if [ "$(lowpower_active)" = "1" ]; then
            # `$src_tier`, PRESERVED: Low Power Mode is a global condition
            # outside this job's control, not a system crash — it must not
            # lose its place in line while waiting it out, the way the
            # crash-recovery sites elsewhere in this loop deliberately do.
            mv "$running" "$src_tier/$(date +%s)-lowpower.t1.job" 2>/dev/null || true
            running=""
            log "Low Power Mode is on — deferring '$path', not starting new work"
            break
          fi

          log "start $class '$path' (attempt $tries)"

          # Backgrounded and waited on, NOT `out=$(...)`: bash defers a trap
          # until the running foreground child returns, so a synchronous call
          # here would ignore SIGTERM for the length of an encode and get
          # SIGKILLed instead — losing the job and the lock with it. `wait` is
          # interruptible, so the trap fires at once.
          scratch=$(mktemp)
          # LIVE PROGRESS, WITHOUT TOUCHING THE JOB PIPELINE AT ALL. A job
          # that legitimately runs for hours used to be silent in this log
          # until it finished — MEASURED incident (2026-09-05): a healthy
          # 461-photo describe batch was misdiagnosed as hung for ~4 hours,
          # because nothing surfaced that it was still writing to `$scratch`
          # the whole time. `tail -f` on that same file is a SEPARATE
          # process from the job, so it cannot change `$!`, `rc`, or what
          # `setsid` groups — the four things a `| tee`/pipeline approach
          # would put at risk (see the comments below, still exactly as
          # measured). Started BEFORE the `setsid` dispatch below so it
          # stays in the WORKER's own process group, never the job's —
          # `kill -TERM -"$child"` below must never have to account for it.
          #
          # `-s 0.2`, NOT THE DEFAULT. macOS has no inotify, so GNU tail's
          # `-f` here falls back to polling — MEASURED: this is NOT the
          # "kqueue, near-instant" behaviour an earlier version of this
          # comment assumed without checking. The default poll interval is
          # 1.0s (`tail --help`), and a live 3-file test job repeatedly lost
          # its LAST `done:` line to that gap — the counters below stayed
          # correct (`$out` reads the file directly, not through the
          # tailer) but the live view missed it. `-s 0.2` closes that to a
          # window small enough for the grace `sleep` after `wait` to cover.
          tail -f -s 0.2 "$scratch" &
          tailer=$!
          # `setsid`, NOT `set -m`. Job control's own process-group
          # creation only protects against something ELSE running
          # alongside the job in the same group — it does NOT protect a
          # PAUSED job from the KERNEL itself. MEASURED, isolated,
          # worker-script-free: when a stopped process's group becomes
          # ORPHANED — its session's other process groups all exit, which
          # is exactly what happens the instant this worker dies — POSIX
          # mandates the kernel deliver SIGHUP then SIGCONT to it. Default
          # SIGHUP disposition is terminate, so a `set -m`-grouped (but
          # still same-SESSION) paused job was being killed by the KERNEL
          # the moment its worker's session died, regardless of anything
          # this script's own cleanup() trap did or didn't do — this is
          # what actually killed every "resume an orphaned job" attempt
          # this feature was built to fix, discovered only by isolating it
          # in a plain two-process test outside this file entirely.
          # `setsid` puts the job in a NEW SESSION, not just a new process
          # group — orphaned-process-group semantics apply only WITHIN a
          # session boundary, so a job in its own session can never be
          # orphaned by this worker's death. A new session's leader is,
          # by construction, also the sole member of a new process group
          # with the same id, so this still gives `kill -TERM -"$child"`
          # below the group it needs — `setsid` fully REPLACES `set -m`
          # here, not merely supplements it. (No `-f`/`--fork`: this
          # process is never already a group leader at this point — job
          # control is off — so `setsid` execs directly; `$!` is the job's
          # own real pid, not a forked wrapper's.)
          #
          # Dispatch by class rather than always calling media-fix: `describe`
          # is an ENRICHMENT, not a repair, so it has its own CLI. Both speak
          # the same done:/skip:/OK: grammar, so everything downstream — the
          # counters, the reason extraction, the notification — is unchanged.
          case "$class" in
            describe) setsid media-describe "$path" > "$scratch" 2>&1 & ;;
            *)        setsid media-fix "--$class" "$path" > "$scratch" 2>&1 & ;;
          esac
          child=$!
          # RECORD THE JOB'S REAL PID IN ITS OWN MARKER — the standard
          # pattern for supervising a process that might outlive the thing
          # that started it, the same shape as systemd's MAINPID: "the real
          # main process is not directly forked off by the service
          # manager." If THIS worker dies before the job does, the job
          # survives (reparented to launchd/init) but this rename is what
          # lets a FUTURE worker's startup find, verify, and adopt it
          # instead of requeuing a duplicate — see the orphan-recovery loop
          # above. Every reader treats a missing third field as "nothing to
          # adopt," so a job file written before this existed degrades to
          # exactly today's behavior — no migration needed.
          printf '%s\0' "$class" "$path" "$child" > "$running"

          rc=0
          wait "$child" || rc=$?
          child=""
          # Killed AFTER the job exits, not before: `wait` only returns once
          # the child's own fd on `$scratch` is closed, so every byte it
          # wrote is already on disk — the tailer just needs one more poll
          # to relay whatever it hasn't yet. `sleep 0.3` is deliberately
          # LONGER than the tailer's own `-s 0.2` interval, so at least one
          # full poll happens before it dies. MEASURED end to end (a live
          # 3-file test job, repeated): without this the counters stayed
          # correct regardless (`$out` reads the file directly, not through
          # the tailer) but the LAST `done:` line consistently never reached
          # the live log.
          out=$(cat "$scratch")
          sleep 0.3
          kill "$tailer" 2>/dev/null || true
          tailer=""
          rm -f "$scratch"
          # NOT re-printed: the tailer above already relayed every line of
          # `$out` to this same log, live, as the job produced it. Printing
          # it again here would double the log for every job — same total
          # information, just spread out over the job's runtime instead of
          # dumped all at once at the end. `$out` itself is still built,
          # unchanged, for the counters and reason-extraction below.

          d=$(printf '%s\n' "$out" | grep -c ': done:' || true)
          s=$(printf '%s\n' "$out" | grep -cE ': (skip|OK):' || true)
          # Counted ONCE PER JOB, not once per ATTEMPT. This loop retries a
          # failing job up to MAX_TRIES, and accumulating here meant a file that
          # succeeded on its third try was reported three times — "12 change(s)"
          # for four photos. Hold this attempt's numbers and fold them in only
          # when the job reaches a terminal outcome below.
          job_d=$d
          job_s=$s

          # Keep the FIRST reason a job declined to do anything, so a batch that
          # changed nothing can say why instead of just how many. The CLIs
          # decline for unrelated reasons — the target name is taken by a
          # different file, the bytes are already correct, it is not downloaded
          # from iCloud — and collapsing those into one number is what made a
          # correct refusal look like a no-op.
          #
          # The em-dash is stripped by ALTERNATION, never a bracket range. A
          # launchd job inherits no locale, so sed runs in the C locale, where
          # `—` is three bytes and `[—-]` is a malformed range that strips only
          # the FIRST of them — leaving two orphan bytes that the notification
          # rendered as `??`. Measured: `[—-]` leaves `M-^@M-^T` under LC_ALL=C
          # and is clean only under a UTF-8 locale the worker does not have.
          if [ "$d" -eq 0 ] && [ -z "$reason" ]; then
            reason=$(printf '%s\n' "$out" | grep -m1 -E ': (skip|OK):' \
              | sed -E "s/^[^:]*: (skip|OK): '[^']*' *//; s/^(—|-) *//" || true)
          fi

          # TERMINAL OUTCOMES fold the attempt's counts in; a requeue does not,
          # so a file that succeeds on attempt three is counted once, not three
          # times.
          if [ "$rc" -eq 0 ]; then
            changed=$((changed + job_d))
            skipped=$((skipped + job_s))
            jobs=$((jobs + 1))
            rm -f "$running"
          elif [ "$tries" -ge "$MAX_TRIES" ]; then
            log "giving up on '$path' after $tries attempts"
            changed=$((changed + job_d))
            skipped=$((skipped + job_s))
            jobs=$((jobs + 1))
            mv "$running" "$FAILED/$base" 2>/dev/null || rm -f "$running"
            failures=$((failures + 1))
          else
            # A FRESH timestamp, so the retry goes to the BACK of the queue.
            # Reusing the original would hand the same failing file straight
            # back and spin.
            #
            # HELD IN staging/ FOR A BACKOFF, not requeued immediately. Two
            # reasons, and the second is the one that bites:
            #   - Three attempts fired back-to-back are not a retry policy. The
            #     failures this can actually recover from are transient — Ollama
            #     restarting, a volume remounting — and none of them heal inside
            #     the microseconds an immediate requeue allows.
            #   - queue/ is what launchd WATCHES. A job sitting there waiting out
            #     a backoff keeps the directory non-empty, so launchd re-fires the
            #     agent continuously (ThrottleInterval only rate-limits it). Other
            #     people have hit exactly this and abandoned QueueDirectories over
            #     it. staging/ is not watched, so the wait is quiet.
            # The sleep is BACKGROUNDED and disowned so this worker can finish
            # its remaining jobs and exit; the move back is what re-arms launchd.
            next=$((tries + 1))
            backoff=$((next * next * 5))
            held="$STAGE/$(date +%s)-$$-retry.t$next.job"
            if mv "$running" "$held" 2>/dev/null; then
              log "requeueing '$path' for attempt $next after ''${backoff}s"
              # `$src_tier`, PRESERVED, not `$QUEUE`: this is the SAME
              # request failing transiently and already paying its own
              # backoff — unlike the crash-recovery sites above, it hasn't
              # done anything to deserve losing its original priority.
              # `$src_tier` is a plain variable, captured by this subshell
              # at fork time, so the main loop moving on to a DIFFERENT
              # job's `src_tier` afterward cannot change what this sleep
              # eventually moves the file back to.
              ( sleep "$backoff"
                mv "$held" "$src_tier/$(date +%s)-$$-retry.t$next.job" 2>/dev/null || true
              ) &
              disown 2>/dev/null || true
            else
              rm -f "$running"
            fi
          fi
          running=""
        done


        # The log line IS the report now. Notifications were removed entirely,
        # so there is no branching left to do: `reason` still exists because the
        # per-job loop lifts it, but nothing consumes it beyond this summary.
        log "idle — $changed changed, $skipped skipped, $failures failed''${reason:+ ($reason)}"
      '';
    })

    (writeShellApplication {
      name = "media-queue-pause";
      runtimeInputs = [ coreutils ];
      text = ''
        ${common}
        prog=media-queue-pause
        [ $# -eq 0 ] || { echo "usage: $prog" >&2; exit 1; }

        found=0
        # Read the job's real pid straight out of the marker file — the
        # THIRD field media-worker records right after forking it (see its
        # own comment on that). No liveness check on the file's OWNING
        # WORKER needed: an orphaned-but-alive job (its worker already
        # dead) is exactly as pausable as one with a live owner, since
        # `kill -STOP` targets the job's own process group directly.
        for running in "$STATE"/running-*.job; do
          [ -e "$running" ] || continue
          items=()
          while IFS= read -r -d "" x; do items+=("$x"); done < "$running"
          jpid=''${items[2]:-}
          [ -n "$jpid" ] || continue
          if kill -STOP -"$jpid" 2>/dev/null; then
            echo "$prog: paused pid $jpid (and its subprocesses)" >&2
            found=1
          fi
        done

        if [ "$found" -eq 0 ]; then
          echo "$prog: nothing running right now — queue is idle or between jobs" >&2
        fi
      '';
    })

    (writeShellApplication {
      name = "media-queue-resume";
      runtimeInputs = [ coreutils ];
      text = ''
        ${common}
        prog=media-queue-resume
        [ $# -eq 0 ] || { echo "usage: $prog" >&2; exit 1; }

        # A HARD REFUSAL, not a race against media-queue-power-monitor.
        # That agent runs on its own StartInterval and will just re-freeze
        # this on its next tick if Low Power Mode is still on, so resuming
        # anyway would look like it worked for a few seconds and then
        # silently undo itself — worse than refusing outright and saying
        # why. Checked directly here rather than via the power-paused
        # marker: "must be paused on low power" is meant as a rule with no
        # loophole, including for a job that happened to be paused
        # manually while Low Power Mode was already on.
        if [ "$(lowpower_active)" = "1" ]; then
          echo "$prog: refusing — Low Power Mode is on" >&2
          echo "$prog: turn it off first (System Settings > Battery, or 'sudo pmset -a lowpowermode 0'), then resume" >&2
          exit 1
        fi

        found=0
        # Same direct read as media-queue-pause: the job's real pid is the
        # marker file's third field, independent of whether its owning
        # worker is still alive.
        for running in "$STATE"/running-*.job; do
          [ -e "$running" ] || continue
          items=()
          while IFS= read -r -d "" x; do items+=("$x"); done < "$running"
          jpid=''${items[2]:-}
          [ -n "$jpid" ] || continue
          # CONT on a job that was never stopped is a harmless no-op, so this
          # never needs to first confirm the job was paused by us.
          if kill -CONT -"$jpid" 2>/dev/null; then
            echo "$prog: resumed pid $jpid" >&2
            found=1
          fi
        done

        if [ "$found" -eq 0 ]; then
          echo "$prog: nothing running right now — nothing to resume" >&2
        fi
      '';
    })

    media-queue-status

    (writeShellApplication {
      name = "media-queue-top";
      runtimeInputs = [
        viddy
        media-queue-status
      ];
      text = ''
        prog=media-queue-top
        [ $# -eq 0 ] || { echo "usage: $prog" >&2; exit 1; }
        # REUSED, NOT REBUILT: an earlier draft of this polled the queue
        # directories with `entr -dd` for instant, event-driven refresh
        # instead of a fixed interval — measured (2026-09-05) that entr
        # exits 1 ("No regular files to watch") the moment its file list is
        # EMPTY, which is exactly the common "queue idle" state, so a
        # wrapping restart loop would busy-spin at 100% CPU whenever
        # nothing is queued. Handling that safely needs its own poll-with-
        # backoff fallback — reinventing the interval loop `watch`/`viddy`
        # already are. `viddy` (Rust, a "modern watch") instead: robust on
        # an empty queue for free, plus diff-highlighting between ticks
        # (`-d`) so a `done:`/`error:` line lighting up reads like top's
        # own highlighted deltas, and its own pause/history keys — see
        # `viddy --help`. No new polling logic of this repo's own.
        exec viddy -n 2 -d media-queue-status
      '';
    })

    (writeShellApplication {
      name = "media-queue-power-monitor";
      runtimeInputs = [ coreutils ];
      text = ''
        ${common}
        prog=media-queue-power-monitor
        [ $# -eq 0 ] || { echo "usage: $prog" >&2; exit 1; }

        # ONE launchd StartInterval TICK, NOT A DAEMON. This is what a
        # `while sleep 20; do …; done &` subshell inside media-worker used
        # to do — polled its OWN job every 20s from a hand-rolled loop.
        # launchd's StartInterval already IS the standard way to run
        # something periodically; reusing it here means this script has no
        # loop of its own; it runs once, checks the current job, and exits.
        # That also removes an entire bug class: the old in-process
        # watchdog was a second direct child of the worker, indistinguishable
        # from the real job to `pgrep -P` — this agent isn't a child of the
        # worker at all, so no disambiguation is needed anywhere.
        for running in "$STATE"/running-*.job; do
          [ -e "$running" ] || continue
          items=()
          while IFS= read -r -d "" x; do items+=("$x"); done < "$running"
          path=''${items[1]:-unknown}
          # The job's real pid, direct from the marker file — no need for
          # its worker to be alive: an orphaned-but-running job still burns
          # real power and still needs pausing on Low Power Mode, whether
          # or not a worker has adopted it yet (see media-worker's own
          # adoption comment for what "yet" means here).
          jpid=''${items[2]:-}
          [ -n "$jpid" ] || continue

          marker="$STATE/power-paused-$jpid"
          if [ "$(lowpower_active)" = "1" ]; then
            if [ ! -f "$marker" ]; then
              # `T*` (already stopped) means a manual `media-queue-pause`
              # got here first — not ours, leave it alone, per the
              # marker being the only thing that makes auto-resume safe.
              st=$(/bin/ps -o stat= -p "$jpid" 2>/dev/null | tr -d ' ')
              case "$st" in
                T*) : ;;
                *)
                  if kill -STOP -"$jpid" 2>/dev/null; then
                    touch "$marker"
                    log "power: paused '$path' — Low Power Mode is on"
                  fi
                  ;;
              esac
            fi
          elif [ -f "$marker" ]; then
            if kill -CONT -"$jpid" 2>/dev/null; then
              log "power: resumed '$path' — Low Power Mode is off"
            fi
            rm -f "$marker"
          fi
        done
      '';
    })

  ];
  meta = {
    description = "Durable Finder-to-launchd work queue for the media toolkit: media-enqueue, media-worker, media-queue-pause, media-queue-resume, media-queue-status, media-queue-top, media-queue-power-monitor";
    mainProgram = "media-enqueue";
    platforms = lib.platforms.darwin;
  };
}
