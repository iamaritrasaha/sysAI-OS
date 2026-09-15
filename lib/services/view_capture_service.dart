/// Render-tree capture — the answer to "no OS screenshot tool is
/// available" for anything SysAI OS renders itself. Wrap a view in a
/// `RepaintBoundary` with a `GlobalKey`, then [captureBoundaryPng] turns
/// its current render output into PNG bytes via Flutter's own
/// `RenderRepaintBoundary.toImage()` — no external tool, no dependency on
/// the host having `scrot`/`grim`/etc. installed. Used for the Computer
/// test surface and, more generally, as the basis for ad hoc visual-QA
/// captures of any screen during manual review.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// Renders the widget behind [key] (which must be attached to a
/// `RepaintBoundary`) to PNG bytes. Returns null if the boundary isn't
/// currently mounted/laid out — never throws.
Future<Uint8List?> captureBoundaryPng(GlobalKey key, {double pixelRatio = 1.0}) async {
  try {
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return null;
    final image = await renderObject.toImage(pixelRatio: pixelRatio);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// Saves [pngBytes] under `<workspaceRoot>/.sysai_os/captures/` and
/// returns the path relative to [workspaceRoot] — the same directory
/// convention the bridge's own OS-level screenshot capture already uses
/// (`bridge/capabilities/computer.py::handle_computer_capture`), so both
/// capture mechanisms produce artifacts in one place.
Future<String> saveCapture(String workspaceRoot, Uint8List pngBytes, {String prefix = 'capture'}) async {
  final dir = Directory(p.join(workspaceRoot, '.sysai_os', 'captures'));
  await dir.create(recursive: true);
  final fileName = '$prefix-${DateTime.now().millisecondsSinceEpoch}.png';
  final file = File(p.join(dir.path, fileName));
  await file.writeAsBytes(pngBytes);
  return p.join('.sysai_os', 'captures', fileName);
}
