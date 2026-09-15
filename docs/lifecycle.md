# Background Execution Lifecycle

This document states, precisely, what "runs in the background" means in
SysAI OS today — no more than what's actually implemented.

## What is true

- **Window open or minimized**: the Scheduler's central timer
  (`SchedulerService`, one `Timer.periodic` every 30 seconds) and any
  in-flight `Run` continue executing. Minimizing the window, switching to
  a different nav tab, or navigating away from Run Detail does not stop
  anything — Runs are driven entirely by the provider graph
  (`RunExecutor`), not by any widget being on screen. This is intentional
  and already covered by `test/providers/background_run_test.dart`.
- **App process terminated** (quit, killed, machine restarts): the
  Scheduler's timer stops, along with everything else in the process. Any
  Run that was actively executing is left in a non-terminal state in the
  database; on the next launch, `RunRepository.recoverInterruptedRuns()`
  transitions it to `interrupted` and surfaces a notification — it is not
  silently resumed or lost.
- **A missed scheduled automation** is caught by the one immediate
  `processDueAutomations()` pass `SchedulerService.start()` runs before
  its periodic timer begins — this is the entire mechanism behind
  "automations still fire (within policy) after the app was closed past
  their trigger time." See the missed-trigger policy in
  `docs/ARCHITECTURE.md` §8.

## What is not true, and not claimed

- **This is not a daemon.** There is no separate long-lived process, no
  system service, no ability to fire a scheduled automation while SysAI OS
  itself is not running. "Persistent Automations" means the *schedule* is
  durable (SQLite survives a restart) and self-corrects on the next
  launch — not that execution happens while the app is closed.
- **Controlled Computer Use** actions against the SysAI-owned test surface
  require the Flutter process to be alive to execute them (the Python
  bridge cannot act on the widget tree on its own) — same boundary as
  every other capability.

## Why a single process, for now

Everything above runs inside one Flutter process plus its one Python
bridge subprocess. Splitting the Scheduler/Run-execution/notification
machinery into a separate long-lived runtime service (with Flutter purely
as a client) is architecturally plausible — nothing here obviously
precludes it — but doing that split is a substantial rewrite of how the
app starts, not a Phase 4-sized change. It is not attempted here and is
recorded as a candidate for a future phase, not because it's hard to
imagine, but because doing it well (process supervision, IPC between the
UI and the service, migrating state ownership) deserves to be its own
scoped piece of work rather than a side effect of adding a scheduler.
