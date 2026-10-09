import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';

void main() => runApp(const TamilVoiceApp());

class TamilVoiceApp extends StatelessWidget {
  const TamilVoiceApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tamil Voice',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// Edge TTS client (same service the website uses). Voice is fixed to Tamil female.
class EdgeTts {
  static const _token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _voice = 'ta-IN-PallaviNeural';
  static const _chromium = '143.0.3650.75';

  static String _gec() {
    var t = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 11644473600;
    t -= t % 300;
    final ticks = t * 10000000;
    return sha256.convert(ascii.encode('$ticks$_token')).toString().toUpperCase();
  }

  static String _id() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  static String _timestamp() {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final n = DateTime.now().toUtc();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${days[n.weekday - 1]} ${months[n.month - 1]} ${p(n.day)} ${n.year} '
        '${p(n.hour)}:${p(n.minute)}:${p(n.second)} GMT+0000 (Coordinated Universal Time)';
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// Split unlimited text into small pieces the service accepts.
  static List<String> split(String text, {int maxChars = 700}) {
    final clean = text.replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), ' ');
    final parts = clean.split(RegExp(r'(?<=[.!?।\n])'));
    final chunks = <String>[];
    var cur = StringBuffer();
    void flush() {
      final s = cur.toString();
      if (s.trim().isNotEmpty) chunks.add(s);
      cur = StringBuffer();
    }

    for (final part in parts) {
      if (part.length > maxChars) {
        flush();
        for (var i = 0; i < part.length; i += maxChars) {
          final end = min(i + maxChars, part.length);
          final s = part.substring(i, end);
          if (s.trim().isNotEmpty) chunks.add(s);
        }
        continue;
      }
      if (cur.length + part.length > maxChars) flush();
      cur.write(part);
    }
    flush();
    return chunks;
  }

  static Future<Uint8List> _synthChunk(String text, int rate, int pitch) async {
    final url = 'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
        '?TrustedClientToken=$_token&ConnectionId=${_id()}'
        '&Sec-MS-GEC=${_gec()}&Sec-MS-GEC-Version=1-$_chromium';

    final ws = await WebSocket.connect(url, headers: {
      'Pragma': 'no-cache',
      'Cache-Control': 'no-cache',
      'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/${_chromium.split('.').first}.0.0.0 Safari/537.36 Edg/${_chromium.split('.').first}.0.0.0',
      'Accept-Language': 'en-US,en;q=0.9',
    }).timeout(const Duration(seconds: 20));

    final out = BytesBuilder();
    final done = Completer<void>();

    ws.listen((msg) {
      if (msg is String) {
        if (msg.contains('Path:turn.end') && !done.isCompleted) done.complete();
      } else if (msg is List<int>) {
        final b = Uint8List.fromList(msg);
        if (b.length < 2) return;
        final hl = (b[0] << 8) | b[1];
        if (b.length < 2 + hl) return;
        final header = utf8.decode(b.sublist(2, 2 + hl), allowMalformed: true);
        if (header.contains('Path:audio')) out.add(b.sublist(2 + hl));
      }
    }, onError: (e) {
      if (!done.isCompleted) done.completeError(e);
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    });

    final ts = _timestamp();
    ws.add('X-Timestamp:$ts\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false",'
        '"wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n');

    final rateStr = '${rate >= 0 ? '+' : ''}$rate%';
    final pitchStr = '${pitch >= 0 ? '+' : ''}${pitch}Hz';
    final ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='ta-IN'>"
        "<voice name='$_voice'><prosody pitch='$pitchStr' rate='$rateStr' volume='+0%'>"
        '${_escape(text)}</prosody></voice></speak>';
    ws.add('X-RequestId:${_id()}\r\nContent-Type:application/ssml+xml\r\n'
        'X-Timestamp:${ts}Z\r\nPath:ssml\r\n\r\n$ssml');

    try {
      await done.future.timeout(const Duration(seconds: 60));
    } finally {
      await ws.close();
    }
    return out.toBytes();
  }

  static Future<Uint8List> synthesize(
    String text,
    int rate,
    int pitch, {
    void Function(int done, int total)? onProgress,
  }) async {
    final chunks = split(text);
    if (chunks.isEmpty) throw Exception('Please enter some text.');
    final all = BytesBuilder();
    for (var i = 0; i < chunks.length; i++) {
      onProgress?.call(i, chunks.length);
      Uint8List? data;
      Object? lastErr;
      for (var attempt = 0; attempt < 3 && data == null; attempt++) {
        try {
          final d = await _synthChunk(chunks[i], rate, pitch);
          if (d.isNotEmpty) {
            data = d;
          } else {
            lastErr = Exception('Empty audio received');
          }
        } catch (e) {
          lastErr = e;
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      if (data == null) throw Exception('Failed on part ${i + 1}/${chunks.length}: $lastErr');
      all.add(data);
    }
    onProgress?.call(chunks.length, chunks.length);
    return all.toBytes();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _text = TextEditingController();
  final _player = AudioPlayer();
  double _rate = 0;
  double _pitch = 0;
  bool _busy = false;
  bool _playing = false;
  String _status = '';
  Uint8List? _audio;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    FocusScope.of(context).unfocus();
    if (_text.text.trim().isEmpty) {
      setState(() => _status = 'Please enter Tamil text first.');
      return;
    }
    await _player.stop();
    setState(() {
      _busy = true;
      _playing = false;
      _audio = null;
      _status = 'Generating audio...';
    });
    try {
      final bytes = await EdgeTts.synthesize(
        _text.text,
        _rate.round(),
        _pitch.round(),
        onProgress: (d, t) {
          if (mounted) setState(() => _status = 'Generating audio... $d / $t parts done');
        },
      );
      setState(() {
        _audio = bytes;
        _status = 'Done! You can play or download the MP3.';
      });
    } catch (e) {
      setState(() => _status = 'Error: $e\nCheck your internet and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePlay() async {
    if (_audio == null) return;
    if (_playing) {
      await _player.stop();
      setState(() => _playing = false);
    } else {
      await _player.play(BytesSource(_audio!));
      setState(() => _playing = true);
    }
  }

  Future<void> _download() async {
    if (_audio == null) return;
    try {
      final name = 'tamil_voice_${DateTime.now().millisecondsSinceEpoch}.mp3';
      final path = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(data: _audio!, fileName: name, mimeTypesFilter: ['audio/mpeg']),
      );
      setState(() => _status = path == null ? 'Save cancelled.' : 'Saved successfully as MP3.');
    } catch (e) {
      setState(() => _status = 'Save error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tamil Text to Speech')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _text,
              minLines: 8,
              maxLines: 14,
              decoration: const InputDecoration(
                labelText: 'Enter Tamil text',
                hintText: 'இங்கே தமிழ் உரையை உள்ளிடவும்',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            const Text('Voice: Tamil (India) – Female (Pallavi)',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Text('Speech Rate: ${_rate.round()}%'),
            Slider(
              value: _rate,
              min: -50,
              max: 100,
              divisions: 150,
              onChanged: _busy ? null : (v) => setState(() => _rate = v),
            ),
            Text('Pitch: ${_pitch.round()} Hz'),
            Slider(
              value: _pitch,
              min: -20,
              max: 20,
              divisions: 40,
              onChanged: _busy ? null : (v) => setState(() => _pitch = v),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _generate,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.record_voice_over),
              label: Text(_busy ? 'Generating...' : 'Generate Audio'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
            const SizedBox(height: 12),
            if (_status.isNotEmpty) Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (_audio != null)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _togglePlay,
                      icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                      label: Text(_playing ? 'Stop' : 'Play'),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _download,
                      icon: const Icon(Icons.download),
                      label: const Text('Download MP3'),
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
