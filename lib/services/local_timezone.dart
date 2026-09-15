/// Detects the host's IANA timezone name — no new plugin dependency,
/// consistent with how [NotificationService] shells out to `notify-send`
/// rather than pulling in a platform-channel package for something the
/// host OS already exposes directly.
library;

import 'dart:io';

/// Best-effort detection of the system's IANA timezone name (e.g.
/// `"Australia/Sydney"`). Falls back to `'UTC'` — never throws, never
/// blocks the Scheduler on a misconfigured or unusual host.
Future<String> detectLocalTimezone() async {
  try {
    final file = File('/etc/timezone');
    if (await file.exists()) {
      final name = (await file.readAsString()).trim();
      if (name.isNotEmpty) return name;
    }
  } catch (_) {}

  try {
    final result = await Process.run('timedatectl', ['show', '-p', 'Timezone', '--value']);
    if (result.exitCode == 0) {
      final name = (result.stdout as String).trim();
      if (name.isNotEmpty) return name;
    }
  } catch (_) {}

  return 'UTC';
}

/// A curated, common subset of IANA zones for the Automations schedule
/// editor. The Scheduler domain itself (`schedule_calculator.dart`)
/// supports any valid IANA name — this list is a UI convenience, not a
/// backend restriction; a name detected via [detectLocalTimezone] that
/// isn't in this list is still added to the dropdown so the user's actual
/// zone is never silently substituted.
const List<String> kCommonTimezones = [
  'UTC',
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Los_Angeles',
  'America/Sao_Paulo',
  'Europe/London',
  'Europe/Paris',
  'Europe/Berlin',
  'Europe/Moscow',
  'Africa/Cairo',
  'Africa/Johannesburg',
  'Asia/Dubai',
  'Asia/Kolkata',
  'Asia/Shanghai',
  'Asia/Tokyo',
  'Asia/Singapore',
  'Australia/Sydney',
  'Australia/Perth',
  'Pacific/Auckland',
];
