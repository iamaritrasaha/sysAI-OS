/// Pure schedule math for the Scheduler domain.
///
/// No I/O, no wall-clock reads — [computeNextTrigger] always takes `nowUtc`
/// as an explicit parameter so tests can inject arbitrary instants (DST
/// transitions, month/year boundaries) without sleeping and without a fake
/// clock abstraction layered over `DateTime.now()`.
library;

import 'package:timezone/timezone.dart' as tz;

import '../models/scheduled_automation.dart';

/// Resolves an IANA zone name to a [tz.Location], falling back to UTC for
/// an unknown/malformed name rather than throwing — a bad timezone string
/// must never crash the scheduler.
tz.Location resolveLocation(String ianaName) {
  try {
    return tz.getLocation(ianaName);
  } catch (_) {
    return tz.UTC;
  }
}

/// Computes the next UTC instant [automation] should fire, given [nowUtc]
/// as the current instant.
///
/// Returns null only for a [AutomationScheduleType.once] automation —
/// its single trigger instant lives directly in `nextTriggerAt` and is
/// never recomputed; once the caller has fired it, nothing further is
/// scheduled.
DateTime? computeNextTrigger(ScheduledAutomation automation, DateTime nowUtc) {
  switch (automation.scheduleType) {
    case AutomationScheduleType.once:
      return null;

    case AutomationScheduleType.interval:
      final minutes = (automation.scheduleExpression['minutes'] as num?)?.toInt() ?? 60;
      final step = Duration(minutes: minutes < 1 ? 1 : minutes);
      final anchor = (automation.lastTriggeredAt ?? automation.createdAt).toUtc();
      var next = anchor.add(step);
      // Catch-up: if the app was closed across several periods, advance in
      // fixed steps rather than firing once per missed period — this is
      // what keeps a missed "every hour" automation from queuing up dozens
      // of overdue Runs the moment the app reopens.
      while (!next.isAfter(nowUtc)) {
        next = next.add(step);
      }
      return next;

    case AutomationScheduleType.daily:
    case AutomationScheduleType.weekly:
      return _nextWallClockTrigger(automation, nowUtc);
  }
}

/// DST-aware daily/weekly wall-clock scheduling.
///
/// Returns the next UTC instant, strictly after [nowUtc], at which the
/// wall-clock time `hour:minute` (on `weekday`, for weekly) occurs in
/// `automation.timezone`. Out-of-range hour/minute/weekday values are
/// clamped rather than thrown — same "never crash the scheduler" posture
/// as [resolveLocation].
///
/// Calendar-day advancement is done in plain UTC (`DateTime.utc`, no
/// timezone involved) purely to find the correct civil date; the
/// wall-clock instant itself is always reconstructed from scratch via
/// `TZDateTime(location, year, month, day, hour, minute)` in the target
/// zone. This is deliberate — adding a 24h `Duration` directly to a
/// `TZDateTime` that spans a DST transition would carry the offset shift
/// into the result and land on the wrong wall-clock hour; reconstructing
/// from the civil date instead means the DST transition is absorbed by
/// `TZDateTime`'s own offset resolution for that date, not by arithmetic.
DateTime _nextWallClockTrigger(ScheduledAutomation automation, DateTime nowUtc) {
  final location = resolveLocation(automation.timezone);
  final expr = automation.scheduleExpression;
  final hour = ((expr['hour'] as num?)?.toInt() ?? 0).clamp(0, 23);
  final minute = ((expr['minute'] as num?)?.toInt() ?? 0).clamp(0, 59);
  final nowLocal = tz.TZDateTime.from(nowUtc, location);

  tz.TZDateTime candidateAt(int daysFromNow) {
    final civilDay = DateTime.utc(nowLocal.year, nowLocal.month, nowLocal.day)
        .add(Duration(days: daysFromNow));
    return tz.TZDateTime(location, civilDay.year, civilDay.month, civilDay.day, hour, minute);
  }

  if (automation.scheduleType == AutomationScheduleType.daily) {
    var candidate = candidateAt(0);
    if (!candidate.isAfter(nowLocal)) candidate = candidateAt(1);
    return candidate.toUtc();
  }

  // Weekly. 1=Mon..7=Sun, matching DateTime.monday..DateTime.sunday.
  final targetWeekday = ((expr['weekday'] as num?)?.toInt() ?? DateTime.monday).clamp(1, 7);
  for (var offset = 0; offset <= 7; offset++) {
    final candidate = candidateAt(offset);
    if (candidate.weekday == targetWeekday && candidate.isAfter(nowLocal)) {
      return candidate.toUtc();
    }
  }
  // Unreachable: offsets 0..7 cover every weekday at least once, and
  // offset 7 reproduces today's weekday a full week later — always after
  // `nowLocal` regardless of what time it is today.
  throw StateError('Could not compute next weekly trigger for weekday $targetWeekday');
}
