import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tz_data;

import 'adwaita.dart';
import 'views/shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Loads the IANA tzdata bundled with package:timezone — required before
  // any Scheduler DST-aware next-trigger calculation (schedule_calculator.dart).
  tz_data.initializeTimeZones();
  runApp(
    const ProviderScope(
      child: SysAIApp(),
    ),
  );
}

/// SysAI OS Desktop Application root widget.
class SysAIApp extends StatelessWidget {
  const SysAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SysAI OS',
      debugShowCheckedModeBanner: false,
      theme: adwaitaLightTheme(),
      darkTheme: adwaitaDarkTheme(),
      themeMode: ThemeMode.dark,
      home: const SysAIOSShell(),
    );
  }
}
