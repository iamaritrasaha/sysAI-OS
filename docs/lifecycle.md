# Persistent Runtime Lifecycle

SysAI OS has two desktop processes: the Flutter UI client and the persistent
Python runtime. The runtime owns Run execution, the scheduler, capabilities,
approval waits, child processes, browser work, notifications, and its
canonical `runtime_*` SQLite tables. Flutter owns presentation state and a
compatibility cache for the existing V5 Dart repository.

## Startup and reconnect

Flutter first connects to the per-user Unix socket. If no runtime answers,
it starts `bridge/sysai_os_runtime.py` detached and retries until the socket
is ready. Starting a second desktop window reuses the same socket and lock;
it does not create a second scheduler. A disconnected client reports
`reconnecting`/`offline` and applies bounded backoff. Reopening the UI
reconnects to the same service and refreshes Runs, automations, approvals,
notifications, and active event streams.

## Close semantics

Closing the Flutter window disconnects only that client. Active Runs,
terminal child processes, browser requests, approval waits, and scheduled
work continue. Runtime events are persisted with a stable `event_id`. On
reconnect the UI asks for events after its last cursor, then remains on a live
subscription. The UI can explicitly call `runtime.shutdown`; ordinary window
close never does so.

## Scheduler

The scheduler loop runs in the runtime every second. Automations are claimed
with a durable unique `(automation_id, occurrence_key)` guard. A due
automation creates an ordinary Run and starts the existing runner. Results
and attention notifications remain visible when Flutter is reopened. One-time
triggers retain the Phase 4 15-minute grace policy.

## Approvals and Computer targets

An approval request is persisted before the Run waits. Runtime-side desktop
notification is best-effort; lack of a notification daemon never changes the
decision. Reconnecting Flutter can resolve the same approval ID, and only an
explicit user resolution resumes the Run.

`ComputerView` registers the SysAI-owned test surface while mounted and
unregisters it on dispose. The runtime never pretends that an unavailable
Flutter render target exists. A controlled action waits for registration and
then performs the existing request/result round-trip, with cancellation
remaining available from IPC.

## Database and recovery

The persistent runtime is the primary writer for background execution state.
The old Dart V5 tables are intentionally left untouched for migration
compatibility and current UI cache behavior. IPC state is stored in additive
`runtime_*` tables, so SQLite `user_version` remains V5. A future migration
can consolidate the compatibility cache once all application surfaces use
the runtime API.

If the runtime itself crashes, its lock and socket are released by the OS; the
next start can replace stale socket state. Active work from that crashed
process is not silently resumed; existing interruption/checkpoint semantics
remain the recovery boundary. Explicit shutdown stops the scheduler, persists
state, and releases the socket/lock.

## Future service managers

Development does not require systemd. The runtime's socket, lock, signal
handling, and explicit shutdown boundary are structured so a future
`systemd --user` unit can launch it without changing the Flutter protocol.
