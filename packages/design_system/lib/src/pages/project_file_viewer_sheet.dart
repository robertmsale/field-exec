import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/project_sessions_controller_base.dart';

class ProjectFileViewerSheet extends StatefulWidget {
  final ProjectSessionsControllerBase controller;
  final String relPath;

  const ProjectFileViewerSheet({
    super.key,
    required this.controller,
    required this.relPath,
  });

  @override
  State<ProjectFileViewerSheet> createState() => _ProjectFileViewerSheetState();
}

class _ProjectFileViewerSheetState extends State<ProjectFileViewerSheet> {
  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _joinPosix(String a, String b) {
    final left = a.replaceAll(RegExp(r'/+$'), '');
    final right = b.replaceAll(RegExp(r'^/+'), '');
    if (right.isEmpty) return left;
    if (left.isEmpty) return right;
    return '$left/$right';
  }

  bool _loading = true;
  String? _error;
  List<String> _lines = const [];
  bool _truncated = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  String _projectAbsPath() => widget.controller.args.project.path;

  String _absolutePathForRel(String relPath) {
    final root = _projectAbsPath();
    final cleanRoot = root.replaceAll(RegExp(r'/+$'), '');
    final cleanRel = relPath.trim();
    if (cleanRel.isEmpty || cleanRel == '.') return cleanRoot;
    return _joinPosix(cleanRoot, cleanRel);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      const maxLines = 4000;
      // Pull one extra line so we can indicate truncation.
      final cmd = "sed -n '1,${maxLines + 1}p' -- ${_shQuote(widget.relPath)}";
      final res = await widget.controller.runShellCommand(cmd);
      final raw = (res.stdout.trimRight().isNotEmpty ? res.stdout : res.stderr)
          .trimRight();
      final split = raw.isEmpty ? <String>[] : raw.split('\n');

      var truncated = false;
      var lines = split;
      if (split.length > maxLines) {
        truncated = true;
        lines = split.take(maxLines).toList(growable: false);
      }

      if (!mounted) return;
      setState(() {
        _lines = lines;
        _truncated = truncated;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _lines = const [];
        _truncated = false;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      } else {
        _loading = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.85;
    final cs = Theme.of(context).colorScheme;

    const monoFallback = <String>[
      'ui-monospace',
      'SF Mono',
      'Menlo',
      'Monaco',
      'Consolas',
      'Liberation Mono',
      'Courier New',
      'monospace',
    ];
    final mono =
        Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: monoFallback,
          height: 1.25,
        ) ??
        const TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: monoFallback,
          fontSize: 12,
          height: 1.25,
        );

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
                            widget.relPath,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _absolutePathForRel(widget.relPath),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Reload',
                      icon: const Icon(Icons.refresh),
                      onPressed: _loading ? null : () => unawaited(_load()),
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
              if (_truncated)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Showing first 4000 lines.',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : (_error != null)
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(_error!, textAlign: TextAlign.center),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final minWidth = constraints.maxWidth;
                          return SingleChildScrollView(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(minWidth: minWidth),
                                child: SelectionArea(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      0,
                                      12,
                                      12,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        for (
                                          var index = 0;
                                          index < _lines.length;
                                          index++
                                        )
                                          _FileLine(
                                            lineNo: index + 1,
                                            text: _lines[index],
                                            minWidth: minWidth,
                                            mono: mono,
                                            lineNoColor: cs.onSurfaceVariant,
                                          ),
                                      ],
                                    ),
                                  ),
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
}

class _FileLine extends StatelessWidget {
  final int lineNo;
  final String text;
  final double minWidth;
  final TextStyle mono;
  final Color lineNoColor;

  const _FileLine({
    required this.lineNo,
    required this.text,
    required this.minWidth,
    required this.mono,
    required this.lineNoColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minWidth: minWidth),
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              '$lineNo',
              textAlign: TextAlign.right,
              style: mono.copyWith(color: lineNoColor),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: mono, softWrap: false)),
        ],
      ),
    );
  }
}
