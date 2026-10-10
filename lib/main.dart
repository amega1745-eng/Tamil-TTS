import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

void main() => runApp(const TamilVoiceApp());

class TamilVoiceApp extends StatelessWidget {
  const TamilVoiceApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: 'Tamil Voice',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.deepPurple,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}

/// Uses the same Hugging Face Space as the website. Voice fixed to Tamil female.
class EdgeTts {
  static const _base = 'https://innoai-edge-tts-text-to-speech.hf.space';
  static const _voice = 'ta-IN-PallaviNeural - ta-IN (Female)';

  /// Split unlimited text into small pieces.
  static List<String> split(String text, {int maxChars = 500}) {
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

  static Future<Uint8List> _chunk(String text, int rate, int pitch) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      // 1) Send the request
      final post = await client.postUrl(Uri.parse('$_base/gradio_api/call/tts_interface'));
      post.headers.contentType = ContentType.json;
      post.add(utf8.encode(jsonEncode({
        'data': [text, _voice, rate, pitch]
      })));
      final pr = await post.close().timeout(const Duration(seconds: 120));
      final pBody = await pr.transform(utf8.decoder).join();
      if (pr.statusCode != 200) {
        throw Exception('Server not available (HTTP ${pr.statusCode})');
      }
      final eventId = (jsonDecode(pBody) as Map)['event_id'];
      if (eventId == null) throw Exception('No event id from server');

      // 2) Read the result
      final get = await client.getUrl(Uri.parse('$_base/gradio_api/call/tts_interface/$eventId'));
      final gr = await get.close().timeout(const Duration(seconds: 120));
      final body = await gr.transform(utf8.decoder).join().timeout(const Duration(seconds: 180));

      String? event;
      String? result;
      String? error;
      for (final raw in body.split('\n')) {
        final line = raw.trim();
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          final d = line.substring(5).trim();
          if (event == 'complete') result = d;
          if (event == 'error') error = d;
        }
      }
      if (result == null) throw Exception(error ?? 'No audio returned by server');

      final list = jsonDecode(result) as List;
      final file = list.isNotEmpty ? list[0] : null;
      if (file == null || file is! Map) throw Exception('Server returned no audio');
      final url = (file['url'] as String?) ?? '$_base/gradio_api/file=${file['path']}';

      // 3) Download the MP3
      final dl = await client.getUrl(Uri.parse(url));
      final dr = await dl.close().timeout(const Duration(seconds: 120));
      if (dr.statusCode != 200) throw Exception('Audio download failed (HTTP ${dr.statusCode})');
      final b = BytesBuilder();
      await for (final d in dr.timeout(const Duration(seconds: 120))) {
        b.add(d);
      }
      return b.toBytes();
    } finally {
      client.close(force: true);
    }
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
      for (var attempt = 0; attempt < 5 && data == null; attempt++) {
        try {
          final d = await _chunk(chunks[i], rate, pitch);
          if (d.isNotEmpty) {
            data = d;
          } else {
            lastErr = Exception('Empty audio received');
          }
        } catch (e) {
          lastErr = e;
          await Future.delayed(const Duration(seconds: 3));
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

  /// Keeps the app's network alive while you use other apps.
  Future<void> _startKeepAlive() async {
    try {
      final p = await FlutterForegroundTask.checkNotificationPermission();
      if (p != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'tamil_voice_convert',
          channelName: 'Audio conversion',
          channelDescription: 'Shown while Tamil text is being converted to audio.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      await FlutterForegroundTask.startService(
        serviceId: 301,
        notificationTitle: 'Tamil Voice',
        notificationText: 'Converting text to audio...',
      );
    } catch (_) {
      // If this fails the app still works while it stays open.
    }
  }

  Future<void> _stopKeepAlive() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
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
      _status = 'Generating audio... (the first time may take up to a minute)';
    });
    await _startKeepAlive();
    try {
      final bytes = await EdgeTts.synthesize(
        _text.text,
        _rate.round(),
        _pitch.round(),
        onProgress: (d, t) {
          if (mounted) setState(() => _status = 'Generating audio... $d / $t parts done');
        },
      );
      if (mounted) {
        setState(() {
          _audio = bytes;
          _status = 'Done! You can play or download the MP3.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Error: $e\nCheck your internet and try again.');
    } finally {
      await _stopKeepAlive();
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tamil Text to Speech'),
        actions: [
          IconButton(
            tooltip: 'Dark / Light mode',
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () =>
                themeNotifier.value = isDark ? ThemeMode.light : ThemeMode.dark,
          ),
        ],
      ),
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
              max: 50,
              divisions: 100,
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
