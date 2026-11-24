import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'config.dart';
import 'models.dart';

/// الصوت: تسجيل مدمج ← ملف محفوظ من السحابة ← رابط السحابة ← النطق الآلي.
class AudioService {
  final _tts = FlutterTts();
  final _ap = AudioPlayer();
  Map<String, String> _embedded = {};
  Set<String> _bundled = {};
  Directory? _dir;
  int _gen = 0;
  final _q = <String>[];
  final _busy = <String>{};
  int _active = 0;

  Future<void> init() async {
    _tts.setLanguage('ar-SA');
    _tts.awaitSpeakCompletion(true);
    try {
      final m = await AssetManifest.loadFromAssetBundle(rootBundle);
      _bundled = m.listAssets().where((a) => a.startsWith('assets/audio/')).toSet();
    } catch (_) {}
  }

  void setEmbedded(Map<String, String> m) => _embedded = m;

  Future<void> stop() async {
    _gen++;
    await _tts.stop();
    await _ap.stop();
  }

  Future<void> say(String t) async {
    await _tts.setSpeechRate(0.5);
    _tts.speak(t);
  }

  Future<void> speak(Item it, {bool slow = false, bool spell = false}) async {
    final g = _gen;
    if (await _playRecorded(it.audio)) return;
    if (g != _gen) return;
    await _tts.setSpeechRate(slow ? 0.3 : 0.5);
    if (spell) {
      for (final m in RegExp(r'[\u0621-\u064A][\u064B-\u065F\u0670\u0640]*').allMatches(it.text)) {
        if (g != _gen) return;
        await _tts.speak(m.group(0)!);
      }
    }
    if (g != _gen) return;
    final t = it.draft ? it.text.replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '') : it.text;
    if (t.trim().isNotEmpty) await _tts.speak(t);
  }

  Future<File?> _file(String k) async {
    if (kIsWeb) return null;
    _dir ??= Directory('${(await getApplicationDocumentsDirectory()).path}/audio_cache')..createSync(recursive: true);
    return File('${_dir!.path}/$k.mp3');
  }

  Future<bool> _playRecorded(String? k) async {
    if (k == null || k.isEmpty) return false;
    try {
      Source? src;
      final d = _embedded[k];
      if (d != null) {
        src = BytesSource(base64Decode(d.substring(d.indexOf(',') + 1)));
      } else if (_bundled.contains('assets/audio/$k.mp3')) {
        src = AssetSource('audio/$k.mp3');
      } else {
        final f = await _file(k);
        if (f != null && await f.exists()) {
          src = DeviceFileSource(f.path);
        } else if (kCloudBase.isNotEmpty) {
          src = UrlSource('$kCloudBase/audio/$k.mp3');
          _enqueue(k);
        }
      }
      if (src == null) return false;
      await _ap.stop();
      final done = _ap.onPlayerComplete.first.timeout(const Duration(seconds: 40), onTimeout: () {});
      await _ap.play(src);
      await done;
      return true;
    } catch (_) {
      return false;
    }
  }

  // ----- تحميل مسبق من السحابة -----
  void prefetch(Iterable<String> keys) {
    for (final k in keys) {
      if (_embedded.containsKey(k) || _bundled.contains('assets/audio/$k.mp3')) continue;
      _enqueue(k);
    }
  }

  void _enqueue(String k) {
    if (kCloudBase.isEmpty || kIsWeb || _q.contains(k) || _busy.contains(k)) return;
    _q.add(k);
    _pump();
  }

  void _pump() {
    while (_active < 3 && _q.isNotEmpty) {
      final k = _q.removeAt(0);
      _active++;
      _download(k).whenComplete(() {
        _active--;
        _pump();
      });
    }
  }

  Future<void> _download(String k) async {
    if (!_busy.add(k)) return;
    try {
      final f = await _file(k);
      if (f == null || await f.exists()) return;
      final r = await http.get(Uri.parse('$kCloudBase/audio/$k.mp3')).timeout(const Duration(seconds: 30));
      if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) await f.writeAsBytes(r.bodyBytes, flush: true);
    } catch (_) {
    } finally {
      _busy.remove(k);
    }
  }

  void dispose() {
    _tts.stop();
    _ap.dispose();
  }
}
