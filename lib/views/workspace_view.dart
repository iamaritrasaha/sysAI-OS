/// SysAI OS Workspace View — Agentic Workspace Environment
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/artifact.dart';
import '../models/run.dart';
import '../providers/app_providers.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/state_panels.dart';

class WorkspaceView extends ConsumerStatefulWidget {
  /// Navigates to Run Detail for the Run that produced a given artifact.
  final void Function(String runId)? onOpenRun;

  const WorkspaceView({super.key, this.onOpenRun});

  @override
  ConsumerState<WorkspaceView> createState() => _WorkspaceViewState();
}

class _WorkspaceViewState extends ConsumerState<WorkspaceView> {
  late final String _workspacePath;
  String _currentSubpath = '.';
  List<Map<String, dynamic>> _files = [];
  bool _loading = true;

  Map<String, dynamic>? _selectedFileContent;
  String? _selectedFilePath;
  bool _readingFile = false;

  @override
  void initState() {
    super.initState();
    _workspacePath = Directory.current.path;
    _loadWorkspace();
  }

  Future<void> _loadWorkspace([String subpath = '.']) async {
    setState(() {
      _loading = true;
      _currentSubpath = subpath;
    });

    final bridge = ref.read(bridgeServiceProvider);
    if (bridge.isReady) {
      try {
        final entries = await bridge.listWorkspaceFiles(path: subpath);
        if (mounted) {
          setState(() {
            _files = entries;
            _loading = false;
          });
          return;
        }
      } catch (_) {}
    }

    // Fallback: Local directory read
    try {
      final targetDir = Directory(p.join(_workspacePath, subpath == '.' ? '' : subpath));
      final entries = targetDir.listSync(followLinks: false);
      final list = <Map<String, dynamic>>[];
      for (final e in entries) {
        final name = p.basename(e.path);
        final isDir = e is Directory;
        list.add({
          'name': name,
          'path': p.relative(e.path, from: _workspacePath),
          'is_dir': isDir,
          'size': isDir ? 0 : (e as File).lengthSync(),
        });
      }
      list.sort((a, b) {
        if (a['is_dir'] == true && b['is_dir'] != true) return -1;
        if (a['is_dir'] != true && b['is_dir'] == true) return 1;
        return (a['name'] as String).compareTo(b['name'] as String);
      });
      if (mounted) {
        setState(() {
          _files = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _inspectFile(String relPath) async {
    setState(() {
      _selectedFilePath = relPath;
      _readingFile = true;
    });

    final bridge = ref.read(bridgeServiceProvider);
    if (bridge.isReady) {
      try {
        final res = await bridge.readWorkspaceFile(relPath);
        if (mounted) {
          setState(() {
            _selectedFileContent = res;
            _readingFile = false;
          });
          _showFilePreviewDialog();
          return;
        }
      } catch (_) {}
    }

    // Fallback local read
    try {
      final f = File(p.join(_workspacePath, relPath));
      if (await f.exists()) {
        final text = await f.readAsString();
        if (mounted) {
          setState(() {
            _selectedFileContent = {
              'path': relPath,
              'content': text,
              'size': text.length,
            };
            _readingFile = false;
          });
          _showFilePreviewDialog();
          return;
        }
      }
    } catch (_) {}

    if (mounted) setState(() => _readingFile = false);
  }

  void _showFilePreviewDialog() {
    if (_selectedFileContent == null) return;
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.code, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _selectedFilePath ?? 'File Preview',
                style: AppText.path.copyWith(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: (MediaQuery.of(context).size.width - 80).clamp(240, 700),
          child: SingleChildScrollView(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: onSurface.withAlpha(12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                _selectedFileContent!['content'] as String? ?? 'Empty or binary file',
                style: AppText.terminal,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final surface = theme.colorScheme.surface;
    final primary = theme.colorScheme.primary;

    final runs = ref.watch(runListProvider).valueOrNull ?? [];
    final allArtifacts = <Artifact>[];
    for (final r in runs) {
      allArtifacts.addAll(r.artifacts);
    }

    return Scaffold(
      backgroundColor: surface,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Workspace', style: AppText.pageTitle.copyWith(color: onSurface)),
                      const SizedBox(height: 3),
                      Text(
                        'What this Run operates on, and what it changed',
                        style: AppText.bodySecondary.copyWith(color: onSurface.withAlpha(140)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: () => _loadWorkspace(_currentSubpath),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primary,
                    side: BorderSide(color: primary.withAlpha(80)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // ── Active Workspace Info ────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                color: onSurface.withAlpha(6),
                borderRadius: Radii.mdR,
                border: Border.all(color: onSurface.withAlpha(18)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.folder_open, size: IconSizes.lg, color: primary),
                      const SizedBox(width: Space.sm),
                      Text('REPOSITORY ROOT', style: AppText.label.copyWith(color: primary)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xff8fd67a).withAlpha(30),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.shield_outlined, size: 11, color: Color(0xff8fd67a)),
                            const SizedBox(width: 4),
                            Text('Sandboxed', style: AppText.badge.copyWith(color: const Color(0xff8fd67a))),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  SelectableText(_workspacePath, style: AppText.path.copyWith(fontSize: 13, color: onSurface.withAlpha(220))),
                ],
              ),
            ),

            const SizedBox(height: Space.xl),

            // ── Workspace Artifacts ──────────────────────────────────────
            Text('CHANGES & ARTIFACTS (${allArtifacts.length})',
                style: AppText.label.copyWith(color: onSurface.withAlpha(120))),
            const SizedBox(height: Space.sm),
            if (allArtifacts.isEmpty)
              const EmptyStatePanel(
                icon: Icons.inventory_2_outlined,
                message: 'No files changed or generated yet. Artifacts a Run produces will appear here.',
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: onSurface.withAlpha(6),
                  borderRadius: Radii.mdR,
                  border: Border.all(color: onSurface.withAlpha(15)),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: allArtifacts.length.clamp(0, 8),
                    separatorBuilder: (context, index) =>
                        Divider(height: 1, color: onSurface.withAlpha(10)),
                    itemBuilder: (context, index) {
                      final art = allArtifacts[index];
                      Run? owner;
                      for (final r in runs) {
                        if (r.id == art.runId) {
                          owner = r;
                          break;
                        }
                      }
                      return ListTile(
                        dense: true,
                        onTap: (owner != null && widget.onOpenRun != null)
                            ? () => widget.onOpenRun!(owner!.id)
                            : null,
                        leading: Icon(
                          art.type == ArtifactType.file
                              ? Icons.insert_drive_file_outlined
                              : Icons.assessment_outlined,
                          size: IconSizes.md,
                          color: const Color(0xffe056fd),
                        ),
                        title: Text(art.title, style: AppText.bodyStrong.copyWith(fontSize: 13, color: onSurface)),
                        subtitle: Row(
                          children: [
                            if (art.path != null)
                              Flexible(
                                child: Text(art.path!,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.path.copyWith(fontSize: 11, color: onSurface.withAlpha(120))),
                              ),
                            if (art.path != null && owner != null)
                              Text('  ·  ', style: AppText.metadata.copyWith(color: onSurface.withAlpha(90))),
                            if (owner != null)
                              Flexible(
                                child: Text('from ${owner.title}',
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.metadata.copyWith(color: primary.withAlpha(210))),
                              ),
                          ],
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xffe056fd).withAlpha(20),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(art.type.displayLabel.toUpperCase(),
                              style: AppText.badge.copyWith(color: const Color(0xffe056fd))),
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (allArtifacts.length > 8) ...[
              const SizedBox(height: Space.xs),
              Text('+ ${allArtifacts.length - 8} more across Runs',
                  style: AppText.metadata.copyWith(color: onSurface.withAlpha(120))),
            ],
            const SizedBox(height: Space.xxl),

            // ── File System Browser ──────────────────────────────────────
            Row(
              children: [
                Text('FILES', style: AppText.label.copyWith(color: onSurface.withAlpha(120))),
                const SizedBox(width: Space.md),
                if (_currentSubpath != '.') ...[
                  InkWell(
                    onTap: () => _loadWorkspace('.'),
                    child: Text('root', style: AppText.path.copyWith(color: primary)),
                  ),
                  Text(' / ', style: AppText.path.copyWith(color: onSurface.withAlpha(80))),
                  Text(_currentSubpath, style: AppText.path.copyWith(color: onSurface.withAlpha(180))),
                ],
              ],
            ),
            const SizedBox(height: Space.sm),
            if (_readingFile) ...[
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: Space.sm),
            ],
            if (_loading)
              const LoadingStatePanel(message: 'Reading workspace…')
            else if (_files.isEmpty)
              const EmptyStatePanel(
                icon: Icons.folder_off_outlined,
                message: 'This directory is empty.',
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: onSurface.withAlpha(6),
                  borderRadius: Radii.mdR,
                  border: Border.all(color: onSurface.withAlpha(15)),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _files.length,
                    separatorBuilder: (context, index) =>
                        Divider(height: 1, color: onSurface.withAlpha(10)),
                    itemBuilder: (context, index) {
                      final item = _files[index];
                      final name = item['name'] as String? ?? '';
                      final isDir = item['is_dir'] as bool? ?? false;
                      final path = item['path'] as String? ?? name;
                      final size = item['size'] as int? ?? 0;

                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isDir ? Icons.folder : Icons.insert_drive_file_outlined,
                          size: IconSizes.md,
                          color: isDir ? primary : onSurface.withAlpha(120),
                        ),
                        title: Text(
                          name,
                          style: AppText.path.copyWith(
                            fontSize: 12.5,
                            fontWeight: isDir ? FontWeight.w600 : FontWeight.w400,
                            color: onSurface.withAlpha(isDir ? 210 : 160),
                          ),
                        ),
                        trailing: isDir
                            ? Icon(Icons.chevron_right, size: IconSizes.md, color: onSurface.withAlpha(80))
                            : Text(_formatSize(size),
                                style: AppText.metadata.copyWith(color: onSurface.withAlpha(100))),
                        onTap: () {
                          if (isDir) {
                            _loadWorkspace(path);
                          } else {
                            _inspectFile(path);
                          }
                        },
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
