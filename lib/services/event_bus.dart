import 'dart:async';

import '../models/run.dart';

/// A lightweight publish/subscribe bus for [RunEvent]s.
///
/// The bus uses a broadcast [StreamController] so that multiple listeners
/// (UI widgets, loggers, persistence layers) can subscribe independently.
///
/// ## Usage
///
/// ```dart
/// // Emit an event from anywhere in the app:
/// RunEventBus.instance.emit(RunEvent(
///   type: 'log',
///   timestamp: DateTime.now(),
///   message: 'Agent started',
/// ));
///
/// // Listen to all events:
/// RunEventBus.instance.stream.listen((event) { ... });
///
/// // Listen only to events for a specific run:
/// RunEventBus.instance.forRun(runId).listen((event) { ... });
/// ```
class RunEventBus {
  // -------------------------------------------------------------------------
  // Singleton
  // -------------------------------------------------------------------------

  RunEventBus._();

  /// The global singleton instance of [RunEventBus].
  static final RunEventBus instance = RunEventBus._();

  // -------------------------------------------------------------------------
  // Internal state
  // -------------------------------------------------------------------------

  final StreamController<RunEvent> _controller =
      StreamController<RunEvent>.broadcast();

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// A broadcast stream of all [RunEvent]s emitted by this bus.
  ///
  /// Multiple listeners may subscribe simultaneously.  Late subscribers will
  /// only receive events emitted *after* they subscribe.
  Stream<RunEvent> get stream => _controller.stream;

  /// Emits [event] to all current subscribers.
  ///
  /// Safe to call from any isolate that shares this object (single-isolate
  /// apps only — Dart isolates do not share memory).
  void emit(RunEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  /// Returns a filtered stream that only delivers [RunEvent]s whose
  /// [RunEvent.taskId] (or a `runId` entry in [RunEvent.data]) matches
  /// [runId].
  ///
  /// The filter checks [RunEvent.data]`['runId']` first, then falls back to
  /// [RunEvent.taskId] prefix matching (events scoped to `'<runId>/<taskId>'`
  /// are also included).
  ///
  /// If you need a stricter or different filter, subscribe to [stream] and
  /// apply your own `where` clause.
  Stream<RunEvent> forRun(String runId) {
    return _controller.stream.where((event) {
      // Explicit runId in the data payload.
      final dataRunId = event.data?['runId'];
      if (dataRunId is String) {
        return dataRunId == runId;
      }
      // Fallback: taskId starts with the runId prefix (e.g. '<runId>/task-1').
      final tid = event.taskId;
      if (tid != null) {
        return tid == runId || tid.startsWith('$runId/');
      }
      return false;
    });
  }

  /// Closes the underlying [StreamController] and releases resources.
  ///
  /// After calling [dispose], no further events can be emitted or received.
  void dispose() {
    _controller.close();
  }
}
