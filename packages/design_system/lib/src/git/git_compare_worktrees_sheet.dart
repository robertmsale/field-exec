import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/project_sessions_controller_base.dart';
import 'git_tools_sheet.dart';

class GitCompareWorktreesSheet extends StatefulWidget {
  const GitCompareWorktreesSheet({
    super.key,
    required this.run,
    required this.worktrees,
    this.initialAPath,
    this.initialBPath,
  });

  final Future<RunCommandResult> Function(String command) run;
  final List<GitWorktreeRef> worktrees;
  final String? initialAPath;
  final String? initialBPath;

  @override
  State<GitCompareWorktreesSheet> createState() =>
      _GitCompareWorktreesSheetState();
}

class _GitCompareWorktreesSheetState extends State<GitCompareWorktreesSheet> {
  GitWorktreeRef? _a;
  GitWorktreeRef? _b;

  bool _runningCompare = false;
  String? _error;
  List<_GitCompareFile> _files = const [];

  String? _shaA;
  String? _shaB;

  @override
  void initState() {
    super.initState();
    _a = _pickInitial(widget.initialAPath) ??
        (widget.worktrees.isNotEmpty ? widget.worktrees.first : null);
    _b = _pickInitial(widget.initialBPath) ??
        (widget.worktrees.length > 1 ? widget.worktrees[1] : _a);
  }

  GitWorktreeRef? _pickInitial(String? path) {
    final p = (path ?? '').trim();
    if (p.isEmpty) return null;
    for (final wt in widget.worktrees) {
      if (wt.path == p) return wt;
    }
    return null;
  }

  Future<String> _revParseHead(String worktreePath) async {
    final res = await widget.run(
      'git -C ${_shQuote(worktreePath)} rev-parse HEAD',
    );
    if (res.exitCode != 0) {
      final err = (res.stderr.trim().isEmpty ? res.stdout : res.stderr).trim();
      throw Exception(err.isEmpty ? 'git rev-parse HEAD failed.' : err);
    }
    final sha = res.stdout.trim().split('\n').first.trim();
    if (sha.isEmpty) throw Exception('git rev-parse returned empty SHA.');
    return sha;
  }

  String _rangeLabel(String a, String b) => '$a..$b';

  Future<void> _compare() async {
    final a = _a;
    final b = _b;
    if (a == null || b == null) {
      setState(() => _error = 'Select two worktrees.');
      return;
    }
    if (a.path == b.path) {
      setState(() => _error = 'Pick two different worktrees.');
      return;
    }

    setState(() {
      _runningCompare = true;
      _error = null;
      _files = const [];
      _shaA = null;
      _shaB = null;
    });

    try {
      final shaA = await _revParseHead(a.path);
      final shaB = await _revParseHead(b.path);
      final files = await _loadCompareFiles(
        runFromPath: a.path,
        base: shaA,
        head: shaB,
      );
      setState(() {
        _shaA = shaA;
        _shaB = shaB;
        _files = files;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _runningCompare = false);
    }
  }

  Future<List<_GitCompareFile>> _loadCompareFiles({
    required String runFromPath,
    required String base,
    required String head,
  }) async {
    final range = _rangeLabel(base, head);
    final numstatRes = await widget.run(
      'git -C ${_shQuote(runFromPath)} --no-pager diff --numstat ${_shQuote(range)}',
    );
    final nameStatusRes = await widget.run(
      'git -C ${_shQuote(runFromPath)} --no-pager diff --name-status ${_shQuote(range)}',
    );

    if (numstatRes.exitCode != 0 && nameStatusRes.exitCode != 0) {
      final err = (nameStatusRes.stderr.trim().isEmpty
              ? nameStatusRes.stdout
              : nameStatusRes.stderr)
          .trim();
      throw Exception(err.isEmpty ? 'git diff failed.' : err);
    }

    final stats = <String, _GitNumstat>{};
    for (final line in numstatRes.stdout.split('\n')) {
      final parts = line.split('\t');
      if (parts.length < 3) continue;
      final adds = int.tryParse(parts[0]) ?? 0;
      final dels = int.tryParse(parts[1]) ?? 0;
      final path = parts.sublist(2).join('\t').trim();
      if (path.isEmpty) continue;
      stats[path] = _GitNumstat(additions: adds, deletions: dels);
    }

    final files = <_GitCompareFile>[];
    for (final line in nameStatusRes.stdout.split('\n')) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('\t');
      if (parts.length < 2) continue;
      final code = parts[0];
      if (code.startsWith('R') && parts.length >= 3) {
        final oldPath = parts[1];
        final newPath = parts[2];
        final s = stats[newPath] ?? stats['$oldPath => $newPath'];
        files.add(
          _GitCompareFile(
            statusCode: code,
            path: newPath,
            oldPath: oldPath,
            additions: s?.additions ?? 0,
            deletions: s?.deletions ?? 0,
          ),
        );
      } else {
        final path = parts[1];
        final s = stats[path];
        files.add(
          _GitCompareFile(
            statusCode: code,
            path: path,
            oldPath: null,
            additions: s?.additions ?? 0,
            deletions: s?.deletions ?? 0,
          ),
        );
      }
    }

    return files;
  }

  Future<void> _openFileDiff(_GitCompareFile file) async {
    final a = _a;
    final shaA = _shaA;
    final shaB = _shaB;
    if (a == null || shaA == null || shaB == null) return;

    final range = _rangeLabel(shaA, shaB);
    final fileArg = (file.oldPath != null &&
            file.oldPath!.isNotEmpty &&
            file.oldPath != file.path)
        ? '${_shQuote(file.oldPath!)} ${_shQuote(file.path)}'
        : _shQuote(file.path);

    final res = await widget.run(
      'git -C ${_shQuote(a.path)} --no-pager diff ${_shQuote(range)} -- $fileArg',
    );

    final diffText = (res.stdout.trimRight().isNotEmpty ? res.stdout : res.stderr)
        .trimRight();

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => GitDiffSheet(
        worktreeLabel: a.label,
        worktreePath: a.path,
        filePath: file.path,
        statusCode: range,
        diff: GitFileDiff(staged: '', unstaged: diffText, untracked: ''),
        viewLabels: const {GitDiffView.unstaged: 'Diff'},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.9;

    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            ListTile(
              title: const Text('Compare worktrees'),
              subtitle: Text('${widget.worktrees.length} worktrees'),
            ),
            const Divider(height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _WorktreePicker(
                            label: 'Worktree A',
                            worktrees: widget.worktrees,
                            selected: _a,
                            onChanged: (v) => setState(() => _a = v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _WorktreePicker(
                            label: 'Worktree B',
                            worktrees: widget.worktrees,
                            selected: _b,
                            onChanged: (v) => setState(() => _b = v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: _runningCompare ? null : _compare,
                          icon: _runningCompare
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.compare_arrows),
                          label: const Text('Compare'),
                        ),
                      ],
                    ),
                    if (_shaA != null && _shaB != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${_shaA!.substring(0, 7)}..${_shaB!.substring(0, 7)}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ],
                    if (_error != null && _files.isEmpty) ...[
                      const SizedBox(height: 12),
                      _InlineError(message: _error!),
                    ],
                    const SizedBox(height: 12),
                    Expanded(
                      child: _files.isEmpty
                          ? Center(
                              child: Text(
                                'Compare two worktrees to see changed files.',
                                style: Theme.of(context).textTheme.bodyMedium,
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView.separated(
                              itemCount: _files.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final f = _files[index];
                                final subtitle = [
                                  f.statusCode,
                                  if (f.additions > 0 || f.deletions > 0)
                                    '+${f.additions} -${f.deletions}',
                                ].join(' • ');
                                return ListTile(
                                  title: Text(f.path),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(subtitle),
                                      if (f.oldPath != null && f.oldPath!.isNotEmpty)
                                        Text(
                                          'Renamed from ${f.oldPath}',
                                          style: Theme.of(context).textTheme.labelSmall,
                                        ),
                                    ],
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _openFileDiff(f),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorktreePicker extends StatelessWidget {
  const _WorktreePicker({
    required this.label,
    required this.worktrees,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<GitWorktreeRef> worktrees;
  final GitWorktreeRef? selected;
  final ValueChanged<GitWorktreeRef?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        DropdownButtonFormField<GitWorktreeRef>(
          isExpanded: true,
          value: selected,
          items: worktrees
              .map(
                (w) => DropdownMenuItem(
                  value: w,
                  child: Text(
                    '${w.label} • ${w.path}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(growable: false),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onErrorContainer,
            ),
      ),
    );
  }
}

class _GitCompareFile {
  final String statusCode;
  final String path;
  final String? oldPath;
  final int additions;
  final int deletions;

  const _GitCompareFile({
    required this.statusCode,
    required this.path,
    required this.oldPath,
    required this.additions,
    required this.deletions,
  });
}

class _GitNumstat {
  final int additions;
  final int deletions;

  const _GitNumstat({required this.additions, required this.deletions});
}

String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

