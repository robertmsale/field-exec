import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controllers/project_sessions_controller_base.dart';
import 'git_compare_commits_sheet.dart';
import 'git_compare_worktrees_sheet.dart';

class GitWorktreeRef {
  final String label;
  final String path;

  const GitWorktreeRef({required this.label, required this.path});
}

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
  List<GitWorktreeRef> _worktreeRefs = const [];

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
      final statuses = await _loadWorktreeStatusesBatched();
      setState(() {
        _worktrees = statuses;
        _worktreeRefs = statuses
            .map((w) => GitWorktreeRef(label: w.info.label, path: w.info.path))
            .toList(growable: false);
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _worktrees = const [];
        _worktreeRefs = const [];
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  static String _b64Decode(String s) {
    if (s.trim().isEmpty) return '';
    return utf8.decode(base64.decode(s.trim()));
  }

  Future<List<_GitWorktreeStatus>> _loadWorktreeStatusesBatched() async {
    const marker = 'FIELDEXEC_GIT_BATCH_V1';

    final script =
        '''
$marker=1
set -e

b64() {
  printf %s "\$1" | base64 | tr -d '\\n'
}

echo "#$marker"

# Emit one line per worktree: path<TAB>head<TAB>branch<TAB>detachedFlag
git worktree list --porcelain | awk 'BEGIN{RS="";FS="\\n"}{
  path=""; head=""; branch=""; detached=0;
  for (i=1;i<=NF;i++){
    line=\$i;
    if (index(line,"worktree ")==1) { path=substr(line,9); }
    else if (index(line,"HEAD ")==1) { head=substr(line,6); }
    else if (index(line,"branch ")==1) { branch=substr(line,8); }
    else if (line=="detached") { detached=1; }
  }
  if (length(path)>0) {
    printf "%s\\t%s\\t%s\\t%d\\n", path, head, branch, detached;
  }
}' | while IFS="\$(printf '\\t')" read -r wt_path wt_head wt_branch wt_detached; do
  [ -n "\$wt_path" ] || continue

  printf 'WT\\t%s\\t%s\\t%s\\t%s\\n' "\$(b64 "\$wt_path")" "\$(b64 "\$wt_head")" "\$(b64 "\$wt_branch")" "\$wt_detached"

  git -C "\$wt_path" status --porcelain | while IFS= read -r line; do
    [ -n "\$line" ] || continue
    printf 'S\\t%s\\t%s\\n' "\$(b64 "\$wt_path")" "\$(b64 "\$line")"
  done

  (git -C "\$wt_path" --no-pager diff --numstat || true) | while IFS="\$(printf '\\t')" read -r adds dels file; do
    [ -n "\$file" ] || continue
    printf 'N\\t%s\\t0\\t%s\\t%s\\t%s\\n' "\$(b64 "\$wt_path")" "\$adds" "\$dels" "\$(b64 "\$file")"
  done

  (git -C "\$wt_path" --no-pager diff --cached --numstat || true) | while IFS="\$(printf '\\t')" read -r adds dels file; do
    [ -n "\$file" ] || continue
    printf 'N\\t%s\\t1\\t%s\\t%s\\t%s\\n' "\$(b64 "\$wt_path")" "\$adds" "\$dels" "\$(b64 "\$file")"
  done
done
''';

    final res = await widget.run(script);
    if (res.exitCode != 0) {
      final err = (res.stderr.trim().isEmpty ? res.stdout : res.stderr).trim();
      throw Exception(err.isEmpty ? 'git batch query failed.' : err);
    }

    final worktreeOrder = <String>[];
    final worktreeInfo = <String, _GitWorktreeInfo>{};
    final statusLines = <String, List<String>>{};
    final numstat = <String, Map<String, _GitNumstat>>{};

    for (final raw in res.stdout.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) continue;

      final parts = line.split('\t');
      if (parts.isEmpty) continue;
      final tag = parts[0];

      if (tag == 'WT') {
        final path = parts.length >= 2 ? _b64Decode(parts[1]) : '';
        final head = parts.length >= 3 ? _b64Decode(parts[2]) : '';
        final branchRaw = parts.length >= 4 ? _b64Decode(parts[3]) : '';
        final detached = (parts.length >= 5 ? parts[4].trim() : '') == '1';

        if (path.trim().isEmpty) continue;
        if (!worktreeInfo.containsKey(path)) {
          worktreeOrder.add(path);
        }
        worktreeInfo[path] = _GitWorktreeInfo(
          path: path,
          head: head,
          branch: branchRaw.trim().isEmpty ? null : branchRaw,
          detached: detached,
        );
        continue;
      }

      if (tag == 'S') {
        final path = parts.length >= 2 ? _b64Decode(parts[1]) : '';
        final status = parts.length >= 3 ? _b64Decode(parts[2]) : '';
        if (path.trim().isEmpty || status.trim().isEmpty) continue;
        (statusLines[path] ??= <String>[]).add(status);
        continue;
      }

      if (tag == 'N') {
        final path = parts.length >= 2 ? _b64Decode(parts[1]) : '';
        final addsRaw = parts.length >= 4 ? parts[3].trim() : '';
        final delsRaw = parts.length >= 5 ? parts[4].trim() : '';
        final file = parts.length >= 6 ? _b64Decode(parts[5]) : '';
        if (path.trim().isEmpty || file.trim().isEmpty) continue;

        final adds = int.tryParse(addsRaw) ?? 0;
        final dels = int.tryParse(delsRaw) ?? 0;

        final byFile = numstat[path] ??= <String, _GitNumstat>{};
        final prev = byFile[file];
        byFile[file] = _GitNumstat(
          additions: (prev?.additions ?? 0) + adds,
          deletions: (prev?.deletions ?? 0) + dels,
        );
        continue;
      }
    }

    if (worktreeOrder.isEmpty) {
      throw Exception('No git worktrees detected. Is this a git repo?');
    }

    final out = <_GitWorktreeStatus>[];
    for (final path in worktreeOrder) {
      final info = worktreeInfo[path];
      if (info == null) continue;

      final files = (statusLines[path] ?? const <String>[])
          .map((l) => l.trimRight())
          .where((l) => l.isNotEmpty)
          .map(_GitFileChange.parsePorcelainLine)
          .whereType<_GitFileChange>()
          .toList(growable: false);

      final stats = numstat[path] ?? const <String, _GitNumstat>{};
      final enriched = files
          .map((f) {
            final s = stats[f.path];
            return f.copyWith(
              additions: s?.additions ?? 0,
              deletions: s?.deletions ?? 0,
            );
          })
          .toList(growable: false);

      out.add(_GitWorktreeStatus(info: info, files: enriched));
    }

    return out;
  }

  Future<void> _openFileDiff(
    BuildContext context,
    _GitWorktreeStatus wt,
    _GitFileChange file,
  ) async {
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
        diff: diff,
      ),
    );
  }

  Future<GitFileDiff> _loadFileDiff({
    required String worktreePath,
    required _GitFileChange change,
  }) async {
    final path = change.path;
    final oldPath = change.oldPath;

    final status = change.statusCode;
    final staged = status.length >= 2 ? status[0] != ' ' : false;
    final unstaged = status.length >= 2 ? status[1] != ' ' : false;
    final untracked = status.startsWith('??');

    Future<String> runDiff(String cmd) async {
      final res = await widget.run(cmd);
      final out = res.stdout.trimRight();
      if (out.trim().isNotEmpty) return out;
      return res.stderr.trimRight();
    }

    final fileArg = oldPath != null && oldPath.isNotEmpty && oldPath != path
        ? '${_shQuote(oldPath)} ${_shQuote(path)}'
        : _shQuote(path);

    var stagedText = '';
    var unstagedText = '';
    var untrackedText = '';

    if (untracked) {
      untrackedText = await runDiff(
        'git -C ${_shQuote(worktreePath)} --no-pager diff --no-index /dev/null -- $fileArg',
      );
    } else {
      if (staged) {
        stagedText = await runDiff(
          'git -C ${_shQuote(worktreePath)} --no-pager diff --cached -- $fileArg',
        );
      }
      if (unstaged) {
        unstagedText = await runDiff(
          'git -C ${_shQuote(worktreePath)} --no-pager diff -- $fileArg',
        );
      }
      if (!staged && !unstaged) {
        // Fallback for edge cases (e.g. type changes).
        unstagedText = await runDiff(
          'git -C ${_shQuote(worktreePath)} --no-pager diff -- $fileArg',
        );
      }
    }

    return GitFileDiff(
      staged: stagedText,
      unstaged: unstagedText,
      untracked: untrackedText,
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
              title: const Text('Git'),
              subtitle: Text(widget.projectPathLabel),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    tooltip: 'Compare worktrees',
                    onPressed: _loading || _worktreeRefs.length < 2
                        ? null
                        : () async {
                            await showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              showDragHandle: true,
                              builder: (_) => GitCompareWorktreesSheet(
                                run: widget.run,
                                worktrees: _worktreeRefs,
                              ),
                            );
                          },
                    icon: const Icon(Icons.compare_arrows),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _loading ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _GitErrorState(message: _error!, onRetry: _refresh)
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
                                          padding: const EdgeInsets.only(
                                            left: 6,
                                          ),
                                          child: Icon(
                                            Icons.circle,
                                            size: 10,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.tertiary,
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
                                    run: widget.run,
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
    required this.run,
  });

  final _GitWorktreeStatus worktree;
  final void Function(_GitFileChange file) onOpenFile;
  final Future<RunCommandResult> Function(String command) run;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _WorktreeHeader(worktree: worktree, run: run),
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
                      file.statusCode.trim().isEmpty
                          ? '?'
                          : file.statusCode.trim(),
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
  const _WorktreeHeader({required this.worktree, required this.run});

  final _GitWorktreeStatus worktree;
  final Future<RunCommandResult> Function(String command) run;

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
            Row(
              children: [
                Expanded(
                  child: Text(
                    info.path,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Compare commits',
                  onPressed: () async {
                    await showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => GitCompareCommitsSheet(
                        run: run,
                        worktreeLabel: worktree.tabLabel,
                        worktreePath: info.path,
                      ),
                    );
                  },
                  icon: const Icon(Icons.compare_arrows),
                ),
              ],
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
                      info.head.length > 10
                          ? info.head.substring(0, 10)
                          : info.head,
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
    if (raw.startsWith('refs/heads/'))
      return raw.substring('refs/heads/'.length);
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

enum GitDiffView { unstaged, staged, untracked, all }

class GitDiffSheet extends StatefulWidget {
  const GitDiffSheet({
    super.key,
    required this.worktreeLabel,
    required this.worktreePath,
    required this.filePath,
    required this.statusCode,
    required this.diff,
    this.viewLabels,
  });

  final String worktreeLabel;
  final String worktreePath;
  final String filePath;
  final String statusCode;
  final GitFileDiff diff;
  final Map<GitDiffView, String>? viewLabels;

  @override
  State<GitDiffSheet> createState() => _GitDiffSheetState();
}

class _GitDiffSheetState extends State<GitDiffSheet> {
  late GitDiffView _view;
  final _expanded = <String>{};
  final _hunkKeys = <String, GlobalKey>{};

  GlobalKey _keyFor(String id) => _hunkKeys.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    _view = _defaultView(widget.diff);
  }

  @override
  void didUpdateWidget(covariant GitDiffSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diff != widget.diff) {
      _expanded.clear();
      _view = _defaultView(widget.diff);
    }
  }

  GitDiffView _defaultView(GitFileDiff diff) {
    if (diff.unstaged.trim().isNotEmpty) return GitDiffView.unstaged;
    if (diff.staged.trim().isNotEmpty) return GitDiffView.staged;
    if (diff.untracked.trim().isNotEmpty) return GitDiffView.untracked;
    return GitDiffView.all;
  }

  void _setView(GitDiffView view) {
    if (_view == view) return;
    setState(() => _view = view);
  }

  void _setAllExpanded(bool expanded, Iterable<_HunkRef> hunks) {
    setState(() {
      _expanded.clear();
      if (!expanded) return;
      for (final h in hunks) {
        _expanded.add(h.key);
      }
    });
  }

  Future<void> _pickAndScrollToHunk(List<_HunkRef> hunks) async {
    if (hunks.isEmpty) return;

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: hunks.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final ref = hunks[index];
              final title = _view == GitDiffView.all
                  ? '${ref.section.title} • ${ref.hunk.header}'
                  : ref.hunk.header;
              return ListTile(
                dense: true,
                leading: const Icon(Icons.segment, size: 18),
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pop(ref.key),
              );
            },
          ),
        );
      },
    );

    if (picked == null) return;
    await Future<void>.delayed(Duration.zero);
    final ctx = _hunkKeys[picked]?.currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      alignment: 0.1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.85;
    final cs = Theme.of(context).colorScheme;

    final sections = _sections(widget.diff);
    final activeSections = _view == GitDiffView.all
        ? sections
        : sections.where((s) => s.view == _view).toList(growable: false);

    final hunks = <_HunkRef>[];
    for (final section in activeSections) {
      hunks.addAll(
        section.hunks.map((h) => _HunkRef(section: section, hunk: h)),
      );
    }

    final additions = activeSections.fold<int>(
      0,
      (sum, s) => sum + _countLines(s.diffText, '+'),
    );
    final deletions = activeSections.fold<int>(
      0,
      (sum, s) => sum + _countLines(s.diffText, '-'),
    );

    final mono =
        Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'RobotoMono',
          height: 1.25,
        ) ??
        const TextStyle(fontFamily: 'RobotoMono', fontSize: 12, height: 1.25);

    return SafeArea(
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
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
                            widget.filePath,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${widget.worktreeLabel} • ${widget.statusCode}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          Text(
                            widget.worktreePath,
                            style: Theme.of(context).textTheme.labelSmall
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
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<GitDiffView>(
                      showSelectedIcon: false,
                      segments: [
                        if (widget.diff.unstaged.trim().isNotEmpty)
                          ButtonSegment(
                            value: GitDiffView.unstaged,
                            label: Text(
                              widget.viewLabels?[GitDiffView.unstaged] ??
                                  'Unstaged',
                            ),
                          ),
                        if (widget.diff.staged.trim().isNotEmpty)
                          ButtonSegment(
                            value: GitDiffView.staged,
                            label: Text(
                              widget.viewLabels?[GitDiffView.staged] ??
                                  'Staged',
                            ),
                          ),
                        if (widget.diff.untracked.trim().isNotEmpty)
                          ButtonSegment(
                            value: GitDiffView.untracked,
                            label: Text(
                              widget.viewLabels?[GitDiffView.untracked] ??
                                  'Untracked',
                            ),
                          ),
                        const ButtonSegment(
                          value: GitDiffView.all,
                          label: Text('All'),
                        ),
                      ],
                      selected: {_view},
                      onSelectionChanged: (set) {
                        final next = set.isEmpty ? GitDiffView.all : set.first;
                        _setView(next);
                      },
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Expand all',
                      onPressed: hunks.isEmpty
                          ? null
                          : () => _setAllExpanded(true, hunks),
                      icon: const Icon(Icons.unfold_more),
                    ),
                    IconButton(
                      tooltip: 'Collapse all',
                      onPressed: hunks.isEmpty
                          ? null
                          : () => _setAllExpanded(false, hunks),
                      icon: const Icon(Icons.unfold_less),
                    ),
                    IconButton(
                      tooltip: 'Jump to hunk',
                      onPressed: hunks.isEmpty
                          ? null
                          : () => _pickAndScrollToHunk(hunks),
                      icon: const Icon(Icons.list),
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
                          widget.diff.isEmpty
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
                          final ref = hunks[index];
                          final hunk = ref.hunk;
                          final expanded = _expanded.contains(ref.key);
                          final stats = hunk.stats;

                          final title = [
                            if (_view == GitDiffView.all) ref.section.title,
                            hunk.header,
                            if (stats.additions > 0 || stats.deletions > 0)
                              '(+${stats.additions} -${stats.deletions})',
                          ].join(' • ');

                          return KeyedSubtree(
                            key: _keyFor(ref.key),
                            child: Card(
                              clipBehavior: Clip.antiAlias,
                              child: Theme(
                                data: Theme.of(
                                  context,
                                ).copyWith(dividerColor: Colors.transparent),
                                child: ExpansionTile(
                                  initiallyExpanded: expanded,
                                  onExpansionChanged: (v) {
                                    setState(() {
                                      if (v) {
                                        _expanded.add(ref.key);
                                      } else {
                                        _expanded.remove(ref.key);
                                      }
                                    });
                                  },
                                  title: Text(
                                    title,
                                    style: mono.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  backgroundColor: cs.surfaceContainerLow,
                                  collapsedBackgroundColor:
                                      cs.surfaceContainerHighest,
                                  childrenPadding: EdgeInsets.zero,
                                  children: [
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
                                          style: mono.copyWith(
                                            color: _lineFg(context, line),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
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

  static List<_DiffSection> _sections(GitFileDiff diff) {
    final sections = <_DiffSection>[];
    if (diff.unstaged.trim().isNotEmpty) {
      sections.add(
        _DiffSection(
          view: GitDiffView.unstaged,
          title: 'Unstaged',
          diffText: diff.unstaged,
        ),
      );
    }
    if (diff.staged.trim().isNotEmpty) {
      sections.add(
        _DiffSection(
          view: GitDiffView.staged,
          title: 'Staged',
          diffText: diff.staged,
        ),
      );
    }
    if (diff.untracked.trim().isNotEmpty) {
      sections.add(
        _DiffSection(
          view: GitDiffView.untracked,
          title: 'Untracked',
          diffText: diff.untracked,
        ),
      );
    }
    return sections;
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
      final pretty = b.startsWith('refs/heads/')
          ? b.substring('refs/heads/'.length)
          : b;
      return pretty;
    }
    final parts = path.split('/');
    return parts.isEmpty ? path : parts.last;
  }
}

class _GitWorktreeStatus {
  final _GitWorktreeInfo info;
  final List<_GitFileChange> files;

  const _GitWorktreeStatus({required this.info, required this.files});

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

  _GitFileChange copyWith({int? additions, int? deletions}) {
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
  final _GitDiffStats stats;

  const _GitDiffHunk({
    required this.header,
    required this.lines,
    required this.stats,
  });

  static List<_GitDiffHunk> parse(String diffText) {
    final raw = diffText.trimRight();
    if (raw.isEmpty) return const [];

    final lines = raw.split('\n');
    final hunks = <_GitDiffHunk>[];

    var header = 'File header';
    var buf = <String>[];
    var inHunks = false;

    void flush() {
      if (buf.isEmpty) return;
      hunks.add(
        _GitDiffHunk(
          header: header,
          lines: buf,
          stats: _GitDiffStats.fromLines(buf),
        ),
      );
      buf = <String>[];
    }

    for (final line in lines) {
      if (line.startsWith('@@')) {
        flush();
        header = line;
        inHunks = true;
        continue;
      }
      buf.add(line);
    }
    flush();

    if (!inHunks && hunks.isNotEmpty) {
      // No @@ hunks found; keep a single "Diff" section for binary/other formats.
      final only = hunks.first;
      return [
        _GitDiffHunk(header: 'Diff', lines: only.lines, stats: only.stats),
      ];
    }
    return hunks;
  }
}

String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

class GitFileDiff {
  final String staged;
  final String unstaged;
  final String untracked;

  const GitFileDiff({
    required this.staged,
    required this.unstaged,
    required this.untracked,
  });

  bool get isEmpty =>
      staged.trim().isEmpty &&
      unstaged.trim().isEmpty &&
      untracked.trim().isEmpty;
}

class _GitDiffStats {
  final int additions;
  final int deletions;

  const _GitDiffStats({required this.additions, required this.deletions});

  static _GitDiffStats fromLines(List<String> lines) {
    var adds = 0;
    var dels = 0;
    for (final line in lines) {
      if (line.startsWith('+++') || line.startsWith('---')) continue;
      if (line.startsWith('+')) adds++;
      if (line.startsWith('-')) dels++;
    }
    return _GitDiffStats(additions: adds, deletions: dels);
  }
}

class _DiffSection {
  final GitDiffView view;
  final String title;
  final String diffText;

  const _DiffSection({
    required this.view,
    required this.title,
    required this.diffText,
  });

  List<_GitDiffHunk> get hunks => _GitDiffHunk.parse(diffText);
}

class _HunkRef {
  final _DiffSection section;
  final _GitDiffHunk hunk;

  const _HunkRef({required this.section, required this.hunk});

  String get key => '${section.title}::${hunk.header}::${hunk.lines.length}';
}
