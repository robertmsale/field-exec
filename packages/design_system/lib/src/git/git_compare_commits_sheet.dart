import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/project_sessions_controller_base.dart';
import 'git_tools_sheet.dart';

class GitCompareCommitsSheet extends StatefulWidget {
  const GitCompareCommitsSheet({
    super.key,
    required this.run,
    required this.worktreeLabel,
    required this.worktreePath,
  });

  final Future<RunCommandResult> Function(String command) run;
  final String worktreeLabel;
  final String worktreePath;

  @override
  State<GitCompareCommitsSheet> createState() => _GitCompareCommitsSheetState();
}

class _GitCompareCommitsSheetState extends State<GitCompareCommitsSheet> {
  bool _loading = true;
  String? _error;

  List<_GitCommitRef> _commits = const [];

  _GitCommitRef? _base;
  _GitCommitRef? _head;

  final _baseController = TextEditingController();
  final _headController = TextEditingController();

  bool _runningCompare = false;
  List<_GitCompareFile> _files = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadCommits());
  }

  @override
  void dispose() {
    _baseController.dispose();
    _headController.dispose();
    super.dispose();
  }

  Future<void> _loadCommits() async {
    setState(() {
      _loading = true;
      _error = null;
      _files = const [];
    });

    try {
      final commits = await _gitLog();
      setState(() {
        _commits = commits;
        _head = commits.isNotEmpty ? commits.first : null;
        _base = commits.length > 1 ? commits[1] : (commits.isNotEmpty ? commits.first : null);
        _headController.text = _head?.sha ?? '';
        _baseController.text = _base?.sha ?? '';
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _commits = const [];
        _head = null;
        _base = null;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<_GitCommitRef>> _gitLog() async {
    final res = await widget.run(
      'git -C ${_shQuote(widget.worktreePath)} --no-pager log --oneline --decorate -n 200',
    );
    if (res.exitCode != 0) {
      final err = (res.stderr.trim().isEmpty ? res.stdout : res.stderr).trim();
      throw Exception(err.isEmpty ? 'git log failed.' : err);
    }

    final out = <_GitCommitRef>[];
    for (final line in res.stdout.split('\n')) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) continue;
      final firstSpace = trimmed.indexOf(' ');
      if (firstSpace <= 0) continue;
      final sha = trimmed.substring(0, firstSpace).trim();
      final rest = trimmed.substring(firstSpace + 1).trim();
      if (sha.isEmpty) continue;
      out.add(_GitCommitRef(sha: sha, label: rest));
    }
    return out;
  }

  String _rangeLabel(String base, String head) => '$base..$head';

  Future<void> _compare() async {
    final base = _baseController.text.trim();
    final head = _headController.text.trim();

    if (base.isEmpty || head.isEmpty) {
      setState(() {
        _error = 'Select both base and head commits.';
      });
      return;
    }

    setState(() {
      _runningCompare = true;
      _error = null;
      _files = const [];
    });

    try {
      final files = await _loadCompareFiles(base: base, head: head);
      setState(() => _files = files);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _runningCompare = false);
    }
  }

  Future<List<_GitCompareFile>> _loadCompareFiles({
    required String base,
    required String head,
  }) async {
    final numstatRes = await widget.run(
      'git -C ${_shQuote(widget.worktreePath)} --no-pager diff --numstat ${_shQuote(_rangeLabel(base, head))}',
    );
    final nameStatusRes = await widget.run(
      'git -C ${_shQuote(widget.worktreePath)} --no-pager diff --name-status ${_shQuote(_rangeLabel(base, head))}',
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
    final base = _baseController.text.trim();
    final head = _headController.text.trim();
    if (base.isEmpty || head.isEmpty) return;

    final range = _rangeLabel(base, head);

    final fileArg = (file.oldPath != null &&
            file.oldPath!.isNotEmpty &&
            file.oldPath != file.path)
        ? '${_shQuote(file.oldPath!)} ${_shQuote(file.path)}'
        : _shQuote(file.path);

    final res = await widget.run(
      'git -C ${_shQuote(widget.worktreePath)} --no-pager diff ${_shQuote(range)} -- $fileArg',
    );

    final diffText = (res.stdout.trimRight().isNotEmpty
            ? res.stdout
            : res.stderr)
        .trimRight();

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => GitDiffSheet(
        worktreeLabel: widget.worktreeLabel,
        worktreePath: widget.worktreePath,
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
              title: const Text('Compare commits'),
              subtitle: Text(widget.worktreeLabel),
              trailing: IconButton(
                tooltip: 'Reload commits',
                onPressed: _loading ? null : _loadCommits,
                icon: const Icon(Icons.refresh),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null && _commits.isEmpty
                      ? _ErrorState(message: _error!, onRetry: _loadCommits)
                      : Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              _CommitPicker(
                                label: 'Base',
                                commits: _commits,
                                selected: _base,
                                controller: _baseController,
                                onChanged: (c) {
                                  setState(() {
                                    _base = c;
                                    _baseController.text = c?.sha ?? '';
                                  });
                                },
                              ),
                              const SizedBox(height: 12),
                              _CommitPicker(
                                label: 'Head',
                                commits: _commits,
                                selected: _head,
                                controller: _headController,
                                onChanged: (c) {
                                  setState(() {
                                    _head = c;
                                    _headController.text = c?.sha ?? '';
                                  });
                                },
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _runningCompare ? null : _compare,
                                  icon: _runningCompare
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.difference),
                                  label: const Text('Compare'),
                                ),
                              ),
                              if (_error != null && _files.isEmpty) ...[
                                const SizedBox(height: 12),
                                _InlineError(message: _error!),
                              ],
                              const SizedBox(height: 12),
                              Expanded(
                                child: _files.isEmpty
                                    ? Center(
                                        child: Text(
                                          'Pick commits and compare to see changed files.',
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

class _CommitPicker extends StatelessWidget {
  const _CommitPicker({
    required this.label,
    required this.commits,
    required this.selected,
    required this.controller,
    required this.onChanged,
  });

  final String label;
  final List<_GitCommitRef> commits;
  final _GitCommitRef? selected;
  final TextEditingController controller;
  final ValueChanged<_GitCommitRef?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        DropdownButtonFormField<_GitCommitRef>(
          isExpanded: true,
          value: selected,
          items: commits
              .map(
                (c) => DropdownMenuItem(
                  value: c,
                  child: Text(
                    c.label.trim().isNotEmpty ? '${c.label} (${c.sha})' : c.sha,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(growable: false),
          onChanged: onChanged,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Or enter ref',
            hintText: 'HEAD~1, main, <sha>',
          ),
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

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

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

class _GitCommitRef {
  final String sha;
  final String label;

  const _GitCommitRef({required this.sha, required this.label});
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
