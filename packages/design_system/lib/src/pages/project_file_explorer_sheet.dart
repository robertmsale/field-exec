import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/project_sessions_controller_base.dart';

class _Entry {
  final String relPath; // relative to project root
  final bool isDir;

  const _Entry({required this.relPath, required this.isDir});

  String get basename {
    final p = relPath.endsWith('/')
        ? relPath.substring(0, relPath.length - 1)
        : relPath;
    final idx = p.lastIndexOf('/');
    return idx >= 0 ? p.substring(idx + 1) : p;
  }
}

class ProjectFileExplorerSheet extends StatefulWidget {
  final ProjectSessionsControllerBase controller;

  const ProjectFileExplorerSheet({super.key, required this.controller});

  @override
  State<ProjectFileExplorerSheet> createState() =>
      _ProjectFileExplorerSheetState();
}

class _ProjectFileExplorerSheetState extends State<ProjectFileExplorerSheet> {
  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _joinPosix(String a, String b) {
    final left = a.replaceAll(RegExp(r'/+$'), '');
    final right = b.replaceAll(RegExp(r'^/+'), '');
    if (right.isEmpty) return left;
    if (left.isEmpty) return right;
    return '$left/$right';
  }

  String _relDir = '.';
  bool _showHidden = true;

  bool _loadingDir = false;
  String? _dirError;
  List<_Entry> _dirEntries = const [];

  final TextEditingController _search = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';
  List<_Entry> _searchResults = const [];
  bool _searching = false;
  String? _searchError;

  bool _indexing = false;
  String? _indexError;
  Map<String, bool>? _index; // relPath -> isDir

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
    unawaited(_loadDir());
    unawaited(_buildIndexInBackground());
  }

  @override
  void dispose() {
    try {
      _searchDebounce?.cancel();
    } catch (_) {}
    _search.dispose();
    super.dispose();
  }

  String _projectAbsPath() => widget.controller.args.project.path;

  String _absolutePathForRel(String relPath) {
    final root = _projectAbsPath();
    final cleanRoot = root.replaceAll(RegExp(r'/+$'), '');
    final cleanRel = relPath.trim();
    if (cleanRel.isEmpty || cleanRel == '.') return cleanRoot;
    return _joinPosix(cleanRoot, cleanRel);
  }

  Future<void> _copyPath(String relPath) async {
    final abs = _absolutePathForRel(relPath);
    await Clipboard.setData(ClipboardData(text: abs));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Copied: $abs')));
  }

  Future<void> _loadDir() async {
    setState(() {
      _loadingDir = true;
      _dirError = null;
    });
    try {
      final path = _relDir.trim().isEmpty ? '.' : _relDir.trim();
      final cmd = 'ls -a1p -- ${_shQuote(path)} 2>/dev/null || true';
      final res = await widget.controller.runShellCommand(cmd);
      final out = (res.stdout).split('\n').map((l) => l.trimRight()).toList();
      final entries = <_Entry>[];
      for (final raw in out) {
        if (raw.isEmpty) continue;
        if (raw == '.' || raw == '..') continue;
        final isDir = raw.endsWith('/');
        final name = isDir ? raw.substring(0, raw.length - 1) : raw;
        if (name.isEmpty) continue;
        if (!_showHidden && name.startsWith('.')) continue;
        final rel = (path == '.' || path.isEmpty)
            ? name
            : _joinPosix(path, name);
        entries.add(_Entry(relPath: rel, isDir: isDir));
      }

      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.basename.toLowerCase().compareTo(b.basename.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _dirEntries = entries;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dirError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingDir = false;
        });
      } else {
        _loadingDir = false;
      }
    }
  }

  String _parentDir(String relDir) {
    final p = relDir.trim();
    if (p.isEmpty || p == '.' || p == '/') return '.';
    final clean = p.replaceAll(RegExp(r'/+$'), '');
    final idx = clean.lastIndexOf('/');
    if (idx <= 0) return '.';
    return clean.substring(0, idx);
  }

  Future<void> _enterDir(String relPath) async {
    setState(() {
      _relDir = relPath.trim().isEmpty ? '.' : relPath.trim();
      _query = '';
      _search.text = '';
      _searchResults = const [];
      _searchError = null;
    });
    await _loadDir();
  }

  static int? _fuzzyScore(String text, String query) {
    final t = text.toLowerCase();
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return 0;

    var ti = 0;
    var last = -1;
    var score = 0;
    for (var i = 0; i < q.length; i++) {
      final ch = q[i];
      final idx = t.indexOf(ch, ti);
      if (idx < 0) return null;
      if (last == -1) {
        score += idx * 2;
      } else {
        score += (idx - last - 1);
      }
      score += (idx - ti);
      last = idx;
      ti = idx + 1;
    }
    score += (t.length - q.length);
    return score;
  }

  void _onSearchChanged() {
    final next = _search.text.trim();
    if (next == _query) return;
    _query = next;
    try {
      _searchDebounce?.cancel();
    } catch (_) {}
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      unawaited(_runSearch());
    });
  }

  Future<void> _buildIndexInBackground() async {
    if (_indexing) return;
    setState(() {
      _indexing = true;
      _indexError = null;
    });
    try {
      // Keep this bounded so we don't time out or allocate too much.
      const maxDepth = 10;
      const maxLines = 20000;

      const prune =
          r'\( -name .git -o -name .field_exec -o -name .dart_tool -o -name build -o -name Pods -o -name .gradle \) -prune -o';

      final dirsCmd = [
        'find . -maxdepth $maxDepth $prune -type d -print',
        r"| sed 's|^\./||'",
        r"| sed '/^\.$/d'",
        '| head -n $maxLines',
      ].join(' ');
      final filesCmd = [
        'find . -maxdepth $maxDepth $prune -type f -print',
        r"| sed 's|^\./||'",
        '| head -n $maxLines',
      ].join(' ');

      final dirsRes = await widget.controller.runShellCommand(dirsCmd);
      final filesRes = await widget.controller.runShellCommand(filesCmd);

      final idx = <String, bool>{};
      for (final line in dirsRes.stdout.split('\n')) {
        final rel = line.trim();
        if (rel.isEmpty || rel == '.') continue;
        idx[rel] = true;
      }
      for (final line in filesRes.stdout.split('\n')) {
        final rel = line.trim();
        if (rel.isEmpty || rel == '.') continue;
        idx[rel] = false;
      }

      if (!mounted) return;
      setState(() {
        _index = idx;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _indexError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _indexing = false;
        });
      } else {
        _indexing = false;
      }
    }
  }

  Future<void> _runSearch() async {
    final q = _query.trim();
    if (q.isEmpty) {
      setState(() {
        _searchResults = const [];
        _searchError = null;
        _searching = false;
      });
      return;
    }

    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final idx = _index;
      if (idx == null || idx.isEmpty) {
        // If indexing failed or hasn't finished, fall back to a basic substring
        // search using find (still useful for remote).
        final escaped = q.replaceAll('*', r'\*');
        final cmd = [
          r'find . -maxdepth 10',
          r'\( -name .git -o -name .field_exec -o -name .dart_tool -o -name build -o -name Pods -o -name .gradle \) -prune -o',
          r'\( -type f -o -type d \)',
          '-iname ${_shQuote('*$escaped*')}',
          '-print',
          r"| sed 's|^\./||'",
          '| head -n 300',
        ].join(' ');
        final res = await widget.controller.runShellCommand(cmd);
        final found = <_Entry>[];
        for (final line in res.stdout.split('\n')) {
          final rel = line.trim();
          if (rel.isEmpty || rel == '.') continue;
          final base = rel.contains('/')
              ? rel.substring(rel.lastIndexOf('/') + 1)
              : rel;
          if (!_showHidden && base.startsWith('.')) continue;
          found.add(_Entry(relPath: rel, isDir: false));
        }
        if (!mounted) return;
        setState(() {
          _searchResults = found;
        });
        return;
      }

      final scored = <({int score, _Entry entry})>[];
      idx.forEach((rel, isDir) {
        final base = rel.contains('/')
            ? rel.substring(rel.lastIndexOf('/') + 1)
            : rel;
        if (!_showHidden && base.startsWith('.')) return;
        final s = _fuzzyScore(base, q);
        if (s == null) return;
        scored.add((score: s, entry: _Entry(relPath: rel, isDir: isDir)));
      });
      scored.sort((a, b) {
        final c = a.score.compareTo(b.score);
        if (c != 0) return c;
        return a.entry.relPath.compareTo(b.entry.relPath);
      });
      final top = scored.take(200).map((e) => e.entry).toList(growable: false);
      if (!mounted) return;
      setState(() {
        _searchResults = top;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _searching = false;
        });
      } else {
        _searching = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final projectLabel = widget.controller.args.project.path;
    final title = 'Files';
    final showingSearch = _query.trim().isNotEmpty;

    final pathLabel = (_relDir == '.' || _relDir.trim().isEmpty)
        ? '.'
        : _relDir;
    final indexStatus = _indexing
        ? 'Indexing…'
        : (_index != null)
        ? 'Indexed'
        : (_indexError != null)
        ? 'Index failed'
        : 'Index pending';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        projectLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Copy project path',
                  onPressed: () => unawaited(_copyPath('.')),
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Fuzzy find by filename…',
                      border: const OutlineInputBorder(),
                      suffixIcon: (_query.trim().isEmpty)
                          ? null
                          : IconButton(
                              tooltip: 'Clear',
                              onPressed: () {
                                _search.clear();
                                setState(() {
                                  _query = '';
                                  _searchResults = const [];
                                  _searchError = null;
                                });
                              },
                              icon: const Icon(Icons.clear),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  children: [
                    Text(
                      'Hidden',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Switch(
                      value: _showHidden,
                      onChanged: (v) {
                        setState(() => _showHidden = v);
                        if (showingSearch) {
                          unawaited(_runSearch());
                        } else {
                          unawaited(_loadDir());
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  tooltip: 'Up',
                  onPressed: (_relDir == '.' || _relDir.trim().isEmpty)
                      ? null
                      : () => unawaited(_enterDir(_parentDir(_relDir))),
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: Text(
                    showingSearch ? 'Search results' : 'Dir: $pathLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                Text(
                  indexStatus,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () {
                    if (showingSearch) {
                      unawaited(_runSearch());
                    } else {
                      unawaited(_loadDir());
                    }
                  },
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: Builder(
                builder: (_) {
                  if (showingSearch) {
                    if (_searching) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (_searchError != null) {
                      return _errorBox('Search failed: $_searchError');
                    }
                    if (_searchResults.isEmpty) {
                      return const Center(child: Text('No matches.'));
                    }
                    return _entriesList(_searchResults);
                  }

                  if (_loadingDir) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (_dirError != null) {
                    return _errorBox('List failed: $_dirError');
                  }
                  if (_dirEntries.isEmpty) {
                    return const Center(child: Text('Empty directory.'));
                  }
                  return _entriesList(_dirEntries);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBox(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    );
  }

  Widget _entriesList(List<_Entry> items) {
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final e = items[i];
        return ListTile(
          dense: true,
          leading: Icon(
            e.isDir ? Icons.folder : Icons.insert_drive_file,
            size: 18,
          ),
          title: Text(e.basename, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            e.relPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: 'Copy path',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => unawaited(_copyPath(e.relPath)),
          ),
          onTap: () {
            if (e.isDir) {
              unawaited(_enterDir(e.relPath));
              return;
            }
            unawaited(_copyPath(e.relPath));
          },
          onLongPress: () => unawaited(_copyPath(e.relPath)),
        );
      },
    );
  }
}
