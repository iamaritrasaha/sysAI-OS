import 'package:flutter_test/flutter_test.dart';
import 'package:sysai/models/scheduled_automation.dart';
import 'package:sysai/services/schedule_calculator.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

ScheduledAutomation _automation({
  required AutomationScheduleType type,
  Map<String, dynamic> expr = const {},
  String timezone = 'UTC',
  DateTime? lastTriggeredAt,
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime.utc(2026, 1, 1);
  return ScheduledAutomation(
    id: 'a1',
    title: 't',
    goal: 'g',
    workspacePath: '/tmp/ws',
    scheduleType: type,
    scheduleExpression: expr,
    timezone: timezone,
    createdAt: now,
    updatedAt: now,
    lastTriggeredAt: lastTriggeredAt,
  );
}

/// Scans a real IANA zone's transition table for the first DST transition
/// of the requested kind after [afterUtc], returning the *local calendar
/// date* it lands on. Deliberately not hardcoding a specific year's DST
/// boundary date by hand — that class of mistake is exactly what this test
/// exists to catch, so it should not be baked into the test's own fixture.
DateTime _findTransitionDate(tz.Location loc, DateTime afterUtc, {required bool springForward}) {
  final afterMs = afterUtc.millisecondsSinceEpoch;
  for (var i = 1; i < loc.transitionAt.length; i++) {
    if (loc.transitionAt[i] <= afterMs) continue;
    final prevOffset = loc.zones[loc.transitionZone[i - 1]].offset;
    final nextOffset = loc.zones[loc.transitionZone[i]].offset;
    final isSpringForward = nextOffset > prevOffset;
    if (isSpringForward == springForward) {
      final local = tz.TZDateTime.fromMillisecondsSinceEpoch(loc, loc.transitionAt[i]);
      return DateTime.utc(local.year, local.month, local.day);
    }
  }
  fail('No ${springForward ? 'spring-forward' : 'fall-back'} transition found after $afterUtc');
}

void main() {
  setUpAll(() => tz_data.initializeTimeZones());

  group('once', () {
    test('never recomputed — the single instant lives in nextTriggerAt', () {
      final a = _automation(type: AutomationScheduleType.once);
      expect(computeNextTrigger(a, DateTime.utc(2026, 1, 1)), isNull);
    });
  });

  group('interval', () {
    test('anchors to lastTriggeredAt + minutes', () {
      final a = _automation(
        type: AutomationScheduleType.interval,
        expr: {'minutes': 60},
        lastTriggeredAt: DateTime.utc(2026, 1, 1, 10, 0),
      );
      final next = computeNextTrigger(a, DateTime.utc(2026, 1, 1, 10, 30));
      expect(next, DateTime.utc(2026, 1, 1, 11, 0));
    });

    test('falls back to createdAt when never triggered', () {
      final a = _automation(
        type: AutomationScheduleType.interval,
        expr: {'minutes': 360},
        createdAt: DateTime.utc(2026, 1, 1, 0, 0),
      );
      final next = computeNextTrigger(a, DateTime.utc(2026, 1, 1, 1, 0));
      expect(next, DateTime.utc(2026, 1, 1, 6, 0));
    });

    test('catches up through multiple missed periods without firing each one', () {
      final a = _automation(
        type: AutomationScheduleType.interval,
        expr: {'minutes': 60},
        lastTriggeredAt: DateTime.utc(2026, 1, 1, 0, 0),
      );
      // 5+ hourly periods have elapsed since lastTriggeredAt.
      final now = DateTime.utc(2026, 1, 1, 5, 15);
      final next = computeNextTrigger(a, now)!;
      expect(next.isAfter(now), isTrue);
      expect(next, DateTime.utc(2026, 1, 1, 6, 0));
    });
  });

  group('daily', () {
    test('later today fires today', () {
      final a = _automation(type: AutomationScheduleType.daily, expr: {'hour': 15, 'minute': 0});
      final now = DateTime.utc(2026, 3, 10, 9, 0);
      expect(computeNextTrigger(a, now), DateTime.utc(2026, 3, 10, 15, 0));
    });

    test('after target time today rolls to tomorrow', () {
      final a = _automation(type: AutomationScheduleType.daily, expr: {'hour': 9, 'minute': 0});
      final now = DateTime.utc(2026, 3, 10, 15, 0);
      expect(computeNextTrigger(a, now), DateTime.utc(2026, 3, 11, 9, 0));
    });

    test('result is always strictly after now, including at the exact boundary', () {
      final a = _automation(type: AutomationScheduleType.daily, expr: {'hour': 9, 'minute': 0});
      final now = DateTime.utc(2026, 3, 10, 9, 0);
      final next = computeNextTrigger(a, now)!;
      expect(next.isAfter(now), isTrue);
      expect(next, DateTime.utc(2026, 3, 11, 9, 0));
    });

    test('invalid (out-of-range) hour and minute are clamped, not thrown', () {
      final a = _automation(type: AutomationScheduleType.daily, expr: {'hour': 99, 'minute': -5});
      final now = DateTime.utc(2026, 3, 10, 0, 0);
      DateTime? next;
      expect(() => next = computeNextTrigger(a, now), returnsNormally);
      expect(next!.hour, 23);
      expect(next!.minute, 0);
    });
  });

  group('weekly', () {
    test('future weekday later this week', () {
      final now = DateTime.utc(2026, 3, 10, 8, 0); // whatever weekday this is
      final targetWeekday = (now.weekday % 7) + 1; // tomorrow's weekday
      final a = _automation(
        type: AutomationScheduleType.weekly,
        expr: {'hour': 9, 'minute': 0, 'weekday': targetWeekday},
      );
      final next = computeNextTrigger(a, now)!;
      expect(next.isAfter(now), isTrue);
      expect(next.weekday, targetWeekday);
      expect(next.difference(now).inDays <= 7, isTrue);
    });

    test('same weekday, before target time today, fires today', () {
      final now = DateTime.utc(2026, 3, 10, 8, 0);
      final a = _automation(
        type: AutomationScheduleType.weekly,
        expr: {'hour': 9, 'minute': 0, 'weekday': now.weekday},
      );
      final next = computeNextTrigger(a, now)!;
      expect(next, DateTime.utc(now.year, now.month, now.day, 9, 0));
    });

    test('same weekday, after target time today, rolls a full week', () {
      final now = DateTime.utc(2026, 3, 10, 8, 0);
      final a = _automation(
        type: AutomationScheduleType.weekly,
        expr: {'hour': 7, 'minute': 0, 'weekday': now.weekday},
      );
      final next = computeNextTrigger(a, now)!;
      expect(next.weekday, now.weekday);
      expect(next, DateTime.utc(now.year, now.month, now.day, 7, 0).add(const Duration(days: 7)));
    });

    test('invalid weekday is clamped into range, never thrown', () {
      final a = _automation(
        type: AutomationScheduleType.weekly,
        expr: {'hour': 9, 'minute': 0, 'weekday': 42},
      );
      DateTime? next;
      expect(() => next = computeNextTrigger(a, DateTime.utc(2026, 3, 10)), returnsNormally);
      expect(next!.weekday, inInclusiveRange(1, 7));
    });
  });

  group('UTC / no-DST zone', () {
    test('daily math is exact — no offset shifting possible', () {
      final a = _automation(type: AutomationScheduleType.daily, expr: {'hour': 12, 'minute': 0}, timezone: 'UTC');
      final now = DateTime.utc(2026, 6, 1, 6, 0);
      final next = computeNextTrigger(a, now)!;
      expect(next.difference(now), const Duration(hours: 6));
    });
  });

  group('DST — America/New_York', () {
    final loc = () {
      tz_data.initializeTimeZones();
      return tz.getLocation('America/New_York');
    }();

    test('spring-forward: the civil day the clocks jump loses an hour of absolute time', () {
      final transitionDate = _findTransitionDate(loc, DateTime.utc(2020, 1, 1), springForward: true);
      // 09:00 local is always a valid, unambiguous wall-clock time (US
      // spring-forward transitions happen at 02:00 local) — anchoring the
      // schedule there keeps this test about the *day-to-day gap*, not
      // about resolving an ambiguous/nonexistent instant.
      final a = _automation(
        type: AutomationScheduleType.daily,
        expr: {'hour': 9, 'minute': 0},
        timezone: 'America/New_York',
      );
      final dayBefore = transitionDate.subtract(const Duration(days: 1));
      final beforeTrigger = tz.TZDateTime(loc, dayBefore.year, dayBefore.month, dayBefore.day, 9, 30).toUtc();

      final next = computeNextTrigger(a, beforeTrigger)!;
      expect(next.isAfter(beforeTrigger), isTrue);

      final expectedLocal = tz.TZDateTime(loc, transitionDate.year, transitionDate.month, transitionDate.day, 9, 0);
      expect(next, expectedLocal.toUtc());

      // The defining DST assertion: a naive "+24h Duration" implementation
      // would report exactly 24h between consecutive 9am firings. Across a
      // spring-forward day, the real absolute gap is 23h.
      final prevTriggerUtc = tz.TZDateTime(loc, dayBefore.year, dayBefore.month, dayBefore.day, 9, 0).toUtc();
      expect(next.difference(prevTriggerUtc), const Duration(hours: 23));
    });

    test('fall-back: the civil day the clocks repeat gains an hour of absolute time', () {
      final transitionDate = _findTransitionDate(loc, DateTime.utc(2020, 1, 1), springForward: false);
      final a = _automation(
        type: AutomationScheduleType.daily,
        expr: {'hour': 9, 'minute': 0},
        timezone: 'America/New_York',
      );
      final dayBefore = transitionDate.subtract(const Duration(days: 1));
      final beforeTrigger = tz.TZDateTime(loc, dayBefore.year, dayBefore.month, dayBefore.day, 9, 30).toUtc();

      final next = computeNextTrigger(a, beforeTrigger)!;
      expect(next.isAfter(beforeTrigger), isTrue);

      final prevTriggerUtc = tz.TZDateTime(loc, dayBefore.year, dayBefore.month, dayBefore.day, 9, 0).toUtc();
      expect(next.difference(prevTriggerUtc), const Duration(hours: 25));
    });
  });
}
