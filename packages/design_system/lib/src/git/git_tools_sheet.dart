import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controllers/project_sessions_controller_base.dart';

class GitToolsSheet extends StatefulWidget {
  const GitToolsSheet({
    super.key,
    required this.run,
    required this.projectPathLabel,
  });

  final Future<RunCommandResult> Function(String command) run;
  final String projectPathLabel;

  @override
  State<GitToolsSheet> createState() => _GitToolsSheetState();
}

class _GitToolsSheetState extends State<GitToolsSheet>
    with TickerProviderStateMixin {
  bool _loading = true;
  String? _error;
  List<_GitWorktreeStatus> _worktrees = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final worktrees = await _loadWorktrees();
      final statuses = <_GitWorktreeStatus>[];
      for (final wt in worktrees) {
        statuses.add(await _loadWorktreeStatus(wt));
      }
      setState(() {
        _worktrees = statuses;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _worktrees = const [];
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<List<_GitWorktreeInfo>> _loadWorktrees() async {
    final res = await widget.run('git worktree list --porcelain');
    if (res.exitCode != 0) {
      final err = (res.stderr.trim().isEmpty ? res.stdout : res.stderr).trim();
      throw Exception(err.isEmpty ? 'git worktree list failed.' : err);
    }

    final lines = res.stdout.split('\n');
    final out = <_GitWorktreeInfo>[];

    String? path;
    String? head;
    String? branch;
    bool detached = false;

    void flush() {
      final p = path;
      if (p == null || p.trim().isEmpty) return;
      out.add(
        _GitWorktreeInfo(
          path: p.trim(),
          head: (head ?? '').trim(),
          branch: branch?.trim(),
          detached: detached,
        ),
      );
    }

    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        flush();
        path = null;
        head = null;
        branch = null;
        detached = false;
        continue;
      }
      if (line.startsWith('worktree ')) {
        path = line.substring('worktree '.length);
        continue;
      }
      if (line.startsWith('HEAD ')) {
        head = line.substring('HEAD '.length);
        continue;
      }
      if (line.startsWith('branch ')) {
        branch = line.substring('branch '.length);
        continue;
      }
      if (line == 'detached') {
        detached = true;
        continue;
      }
    }
    flush();

    if (out.isEmpty) {
      throw Exception('No git worktrees detected. Is this a git repo?');
    }
    return out;
  }

  Future<_GitWorktreeStatus> _loadWorktreeStatus(_GitWorktreeInfo wt) async {
    final statusRes = await widget.run('git -C ${_shQuote(wt.path)} status --porcelain');
    if (statusRes.exitCode != 0) {
      final err = (statusRes.stderr.trim().isEmpty ? statusRes.stdout : statusRes.stderr).trim();
      throw Exception(err.isEmpty ? 'git status failed for ${wt.path}.' : err);
    }

    final files = statusRes.stdout
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .map(_GitFileChange.parsePorcelainLine)
        .whereType<_GitFileChange>()
        .toList(growable: false);

    final stats = await _loadNumstat(wt.path);

    final enriched = files.map((f) {
      final s = stats[f.path];
      return f.copyWith(
        additions: s?.additions ?? 0,
        deletions: s?.deletions ?? 0,
      );
    }).toList(growable: false);

    return _GitWorktreeStatus(
      info: wt,
      files: enriched,
    );
  }

  Future<Map<String, _GitNumstat>> _loadNumstat(String worktreePath) async {
    final combined = <String, _GitNumstat>{};

    Future<void> merge(String cmd) async {
      final res = await widget.run(cmd);
      if (res.exitCode != 0) return;
      for (final line in res.stdout.split('\n')) {
        final parts = line.split('\t');
        if (parts.length < 3) continue;
        final adds = int.tryParse(parts[0]) ?? 0;
        final dels = int.tryParse(parts[1]) ?? 0;
        final path = parts.sublist(2).join('\t').trim();
        if (path.isEmpty) continue;
        final prev = combined[path];
        combined[path] = _GitNumstat(
          additions: (prev?.additions ?? 0) + adds,
          deletions: (prev?.deletions ?? 0) + dels,
        );
      }
    }

    await merge('git -C ${_shQuote(worktreePath)} --no-pager diff --numstat');
    await merge(
      'git -C ${_shQuote(worktreePath)} --no-pager diff --cached --numstat',
    );

    return combined;
  }

  Future<void> _openFileDiff(BuildContext context, _GitWorktreeStatus wt, _GitFileChange file) async {
    final diff = await _loadFileDiff(worktreePath: wt.info.path, change: file);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => GitDiffSheet(
        worktreeLabel: wt.tabLabel,
        worktreePath: wt.info.path,
        filePath: file.path,
        statusCode: file.statusCode,
        diffText: diff,
      ),
    );
  }

  Future<String> _loadFileDiff({
    required String worktreePath,
    required _GitFileChange change,
  }) async {
    final path = change.path;
    final oldPath = change.oldPath;

    final status = change.statusCode;
    final staged = status.length >= 2 ? status[0] != ' ' : false;
    final unstaged = status.length >= 2 ? status[1] != ' ' : false;
    final untracked = status.startsWith('??');

    final segments = <String>[];

    Future<void> add(String label, String cmd) async {
      final res = await widget.run(cmd);
      final out = res.stdout.trimRight();
      final err = res.stderr.trimRight();
      if (res.exitCode != 0 && out.isEmpty) {
        segments.add('### $label\n$err');
        return;
      }
      if (out.trim().isEmpty) return;
      segments.add('### $label\n$out');
    }

    final fileArg = oldPath != null && oldPath.isNotEmpty && oldPath != path
        ? '${_shQuote(oldPath)} ${_shQuote(path)}'
        : _shQuote(path);

    if (untracked) {
      await add(
        'Untracked',
        'git -C ${_shQuote(worktreePath)} --no-pager diff --no-index /dev/null -- $fileArg',
      );
    } else {
      if (staged) {
        await add(
          'Staged',
          'git -C ${_shQuote(worktreePath)} --no-pager diff --cached -- $fileArg',
        );
      }
      if (unstaged) {
        await add(
          'Unstaged',
          'git -C ${_shQuote(worktreePath)} --no-pager diff -- $fileArg',
        );
      }
      if (!staged && !unstaged) {
        // Fallback for edge cases (e.g. type changes).
        await add(
          'Diff',
          'git -C ${_shQuote(worktreePath)} --no-pager diff -- $fileArg',
        );
      }
    }

    if (segments.isEmpty) {
      return '';
    }

    return segments.join('\n\n');
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
              title: const Text('Git'),
              subtitle: Text(widget.projectPathLabel),
              trailing: IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _GitErrorState(
                          message: _error!,
                          onRetry: _refresh,
                        )
                      : _worktrees.isEmpty
                          ? const _GitEmptyState()
                          : DefaultTabController(
                              length: _worktrees.length,
                              child: Column(
                                children: [
                                  TabBar(
                                    isScrollable: true,
                                    tabs: [
                                      for (final wt in _worktrees)
                                        Tab(
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(wt.tabLabel),
                                              if (wt.isDirty)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(left: 6),
                                                  child: Icon(
                                                    Icons.circle,
                                                    size: 10,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .tertiary,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: TabBarView(
                                      children: [
                                        for (final wt in _worktrees)
                                          _GitWorktreeTab(
                                            worktree: wt,
                                            onOpenFile: (f) =>
                                                _openFileDiff(context, wt, f),
                                          ),
                                      ],
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

class _GitWorktreeTab extends StatelessWidget {
  const _GitWorktreeTab({
    required this.worktree,
    required this.onOpenFile,
  });

  final _GitWorktreeStatus worktree;
  final void Function(_GitFileChange file) onOpenFile;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _WorktreeHeader(worktree: worktree),
        const SizedBox(height: 8),
        Expanded(
          child: worktree.files.isEmpty
              ? Center(
                  child: Text(
                    'No local changes detected.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.separated(
                  itemCount: worktree.files.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final file = worktree.files[index];
                    final subtitle = [
                      file.statusCode.trim().isEmpty ? '?' : file.statusCode.trim(),
                      if (file.additions > 0 || file.deletions > 0)
                        '+${file.additions} -${file.deletions}',
                    ].join(' • ');
                    return ListTile(
                      title: Text(file.path),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(subtitle),
                          if (file.oldPath != null && file.oldPath!.isNotEmpty)
                            Text(
                              'Renamed from ${file.oldPath}',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                        ],
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => onOpenFile(file),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _WorktreeHeader extends StatelessWidget {
  const _WorktreeHeader({required this.worktree});

  final _GitWorktreeStatus worktree;

  @override
  Widget build(BuildContext context) {
    final info = worktree.info;
    final cs = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info.path,
              style: Theme.of(context).textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (info.branch != null && info.branch!.isNotEmpty)
                  Chip(label: Text(_prettyBranch(info.branch!))),
                Chip(label: Text(info.detached ? 'Detached' : 'Attached')),
                if (info.head.isNotEmpty)
                  Chip(
                    label: Text(
                      info.head.length > 10 ? info.head.substring(0, 10) : info.head,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                Chip(
                  avatar: Icon(
                    worktree.isDirty ? Icons.warning_amber : Icons.check_circle,
                    size: 18,
                    color: worktree.isDirty ? cs.tertiary : cs.primary,
                  ),
                  label: Text(worktree.isDirty ? 'Dirty' : 'Clean'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _prettyBranch(String raw) {
    if (raw.startsWith('refs/heads/')) return raw.substring('refs/heads/'.length);
    return raw;
  }
}

class _GitErrorState extends StatelessWidget {
  const _GitErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline),
            const SizedBox(height: 12),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GitEmptyState extends StatelessWidget {
  const _GitEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No worktrees detected yet.',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class GitDiffSheet extends StatelessWidget {
  const GitDiffSheet({
    super.key,
    required this.worktreeLabel,
    required this.worktreePath,
    required this.filePath,
    required this.statusCode,
    required this.diffText,
  });

  final String worktreeLabel;
  final String worktreePath;
  final String filePath;
  final String statusCode;
  final String diffText;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.85;
    final cs = Theme.of(context).colorScheme;

    final hunks = _GitDiffHunk.parse(diffText);
    final additions = _countLines(diffText, '+');
    final deletions = _countLines(diffText, '-');

    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'RobotoMono',
          height: 1.25,
        ) ??
        const TextStyle(fontFamily: 'RobotoMono', fontSize: 12, height: 1.25);

    return SafeArea(
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            filePath,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$worktreeLabel • $statusCode',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          Text(
                            worktreePath,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    _StatChip(
                      label: 'Additions',
                      value: '+$additions',
                      color: cs.tertiary,
                    ),
                    _StatChip(
                      label: 'Deletions',
                      value: '-$deletions',
                      color: cs.error,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: hunks.isEmpty
                    ? Center(
                        child: Text(
                          diffText.trim().isEmpty
                              ? 'No diff to display.'
                              : 'Failed to parse diff.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        itemCount: hunks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final hunk = hunks[index];
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  color: cs.surfaceContainerHighest,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    hunk.header,
                                    style: mono.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                ),
                                const Divider(height: 1),
                                for (final line in hunk.lines)
                                  Container(
                                    color: _lineBg(context, line),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 2,
                                    ),
                                    child: Text(
                                      line.isEmpty ? ' ' : line,
                                      style: mono.copyWith(color: _lineFg(context, line)),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static int _countLines(String diff, String prefix) {
    if (diff.trim().isEmpty) return 0;
    var count = 0;
    for (final line in diff.split('\n')) {
      if (!line.startsWith(prefix)) continue;
      if (line.startsWith('+++') || line.startsWith('---')) continue;
      count++;
    }
    return count;
  }

  static Color? _lineBg(BuildContext context, String line) {
    final cs = Theme.of(context).colorScheme;
    if (line.startsWith('+') && !line.startsWith('+++')) {
      return cs.tertiary.withValues(alpha: 0.10);
    }
    if (line.startsWith('-') && !line.startsWith('---')) {
      return cs.error.withValues(alpha: 0.10);
    }
    if (line.startsWith('@@')) {
      return cs.surfaceContainerHigh;
    }
    return null;
  }

  static Color? _lineFg(BuildContext context, String line) {
    final cs = Theme.of(context).colorScheme;
    if (line.startsWith('+') && !line.startsWith('+++')) {
      return cs.tertiary;
    }
    if (line.startsWith('-') && !line.startsWith('---')) {
      return cs.error;
    }
    if (line.startsWith('@@')) {
      return cs.onSurface;
    }
    return null;
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

class _GitWorktreeInfo {
  final String path;
  final String head;
  final String? branch;
  final bool detached;

  const _GitWorktreeInfo({
    required this.path,
    required this.head,
    required this.branch,
    required this.detached,
  });

  String get label {
    final b = branch;
    if (b != null && b.isNotEmpty) {
      final pretty = b.startsWith('refs/heads/') ? b.substring('refs/heads/'.length) : b;
      return pretty;
    }
    final parts = path.split('/');
    return parts.isEmpty ? path : parts.last;
  }
}

class _GitWorktreeStatus {
  final _GitWorktreeInfo info;
  final List<_GitFileChange> files;

  const _GitWorktreeStatus({
    required this.info,
    required this.files,
  });

  bool get isDirty => files.isNotEmpty;

  String get tabLabel {
    final s = info.label.trim();
    if (s.isEmpty) return 'Worktree';
    return s.length > 24 ? '${s.substring(0, 24)}…' : s;
  }
}

class _GitNumstat {
  final int additions;
  final int deletions;

  const _GitNumstat({required this.additions, required this.deletions});
}

class _GitFileChange {
  final String statusCode;
  final String path;
  final String? oldPath;
  final int additions;
  final int deletions;

  const _GitFileChange({
    required this.statusCode,
    required this.path,
    required this.oldPath,
    required this.additions,
    required this.deletions,
  });

  _GitFileChange copyWith({
    int? additions,
    int? deletions,
  }) {
    return _GitFileChange(
      statusCode: statusCode,
      path: path,
      oldPath: oldPath,
      additions: additions ?? this.additions,
      deletions: deletions ?? this.deletions,
    );
  }

  static _GitFileChange? parsePorcelainLine(String line) {
    if (line.length < 3) return null;
    final status = line.substring(0, math.min(2, line.length));
    final rest = line.length >= 4 ? line.substring(3) : '';
    if (rest.trim().isEmpty) return null;

    String path = rest;
    String? oldPath;
    final arrow = rest.indexOf(' -> ');
    if (arrow != -1) {
      oldPath = rest.substring(0, arrow);
      path = rest.substring(arrow + ' -> '.length);
    }

    return _GitFileChange(
      statusCode: status,
      path: path.trim(),
      oldPath: oldPath?.trim(),
      additions: 0,
      deletions: 0,
    );
  }
}

class _GitDiffHunk {
  final String header;
  final List<String> lines;

  const _GitDiffHunk({required this.header, required this.lines});

  static List<_GitDiffHunk> parse(String diffText) {
    final raw = diffText.trimRight();
    if (raw.isEmpty) return const [];

    final lines = raw.split('\n');
    final hunks = <_GitDiffHunk>[];

    var header = 'Diff';
    var buf = <String>[];

    void flush() {
      if (buf.isEmpty) return;
      hunks.add(_GitDiffHunk(header: header, lines: buf));
      buf = <String>[];
    }

    for (final line in lines) {
      if (line.startsWith('@@')) {
        flush();
        header = line;
        continue;
      }
      buf.add(line);
    }
    flush();
    return hunks;
  }
}

String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

