import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

Stream<String> utf8Lines(Stream<List<int>> byteStream) async* {
  final decoder = Utf8Decoder(allowMalformed: true);
  var pending = '';

  await for (final chunk in byteStream) {
    pending += decoder.convert(Uint8List.fromList(chunk));
    var idx = pending.indexOf('\n');
    while (idx != -1) {
      final line = pending.substring(0, idx).trimRight();
      yield line;
      pending = pending.substring(idx + 1);
      idx = pending.indexOf('\n');
    }
  }

  final tail = pending.trim();
  if (tail.isNotEmpty) yield tail;
}

Stream<Map<String, Object?>> jsonlObjects(Stream<List<int>> byteStream) async* {
  await for (final line in utf8Lines(byteStream)) {
    if (line.isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        yield decoded.cast<String, Object?>();
      }
    } catch (_) {
      // ignore non-json lines
    }
  }
}
