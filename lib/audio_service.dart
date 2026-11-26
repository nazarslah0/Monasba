import 'dart:async';
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
import 'store.dart';

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

  /// آخر سبب لفشل تشغيل تسجيل (يُعرض على الشاشة للتشخيص).
  String? lastError;
  String _dlNote = '';

  /// سرعة تشغيل التسجيلات عند ضغط زر 🐢 (1.0 = عادي).
  static const double kSlowRate = 0.65;

  // تقدّم النطق الآلي (0..1) لتأشير الكلمات.
  void Function(double)? _ttsProg;
  int _ttsLen = 0;
  Completer<void>? _cur; // ينهي انتظار التشغيل فور الإيقاف

  Future<void> init() async {
    _tts.setLanguage('ar-SA');
    _tts.awaitSpeakCompletion(true);
    try {
      _tts.setProgressHandler((String text, int start, int end, String word) {
        if (_ttsLen > 0) _ttsProg?.call((end / _ttsLen).clamp(0.0, 1.0));
      });
    } catch (_) {}
    try {
      final m = await AssetManifest.loadFromAssetBundle(rootBundle);
      _bundled = m.listAssets().where((a) => a.startsWith('assets/audio/')).toSet();
    } catch (_) {}
  }

  void setEmbedded(Map<String, String> m) => _embedded = m;

  String _url(String k) => '$kCloudBase/audio/$k.mp3?v=${Store.version}';

  /// يمسح الأصوات المحفوظة على الجهاز (تُنزَّل من جديد عند الحاجة) بعد أي تحديث للمحتوى.
  Future<void> clearCache() async {
    _q.clear();
    if (kIsWeb) return;
    try {
      await _file('_');
      for (final e in _dir!.listSync()) {
        if (e is File) e.deleteSync();
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    _gen++;
    _ttsProg = null;
    if (_cur != null && !_cur!.isCompleted) _cur!.complete();
    await _tts.stop();
    await _ap.stop();
  }

  Future<void> say(String t) async {
    await _tts.setSpeechRate(0.5);
    _tts.speak(t);
  }

  /// [onProgress] تُستدعى بنسبة التقدّم (0..1) أثناء القراءة لتأشير الكلمة الحالية.
  Future<void> speak(Item it, {bool slow = false, bool spell = false, void Function(double)? onProgress}) async {
    final g = _gen;
    lastError = null;
    if (await _playRecorded(it.audio, slow, onProgress)) return;
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
    if (t.trim().isNotEmpty) {
      _ttsLen = t.length;
      _ttsProg = spell ? null : onProgress;
      await _tts.speak(t);
      _ttsProg = null;
    }
  }

  Future<File?> _file(String k) async {
    if (kIsWeb) return null;
    _dir ??= Directory('${(await getApplicationDocumentsDirectory()).path}/audio_cache')..createSync(recursive: true);
    return File('${_dir!.path}/$k.mp3');
  }

  Future<bool> _playRecorded(String? k, bool slow, void Function(double)? onProgress) async {
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
          if (f != null) {
            // ننزّل الملف كاملًا قبل التشغيل (أضمن من البث)، وننتظر إن كان قيد التنزيل مسبقًا.
            await _download(k);
            for (var i = 0; i < 100 && _busy.contains(k); i++) {
              await Future.delayed(const Duration(milliseconds: 200));
            }
            if (await f.exists()) src = DeviceFileSource(f.path);
          } else {
            src = UrlSource(_url(k));
          }
        }
      }
      if (src == null) {
        lastError = 'لم يُنزَّل الصوت $k.mp3 $_dlNote';
        return false;
      }
      await _ap.stop();
      Duration total = Duration.zero;
      final subs = <StreamSubscription>[
        _ap.onDurationChanged.listen((d) => total = d),
        _ap.onPositionChanged.listen((p) {
          if (onProgress != null && total.inMilliseconds > 0) {
            onProgress((p.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0));
          }
        }),
      ];
      try {
        final c = Completer<void>();
        _cur = c;
        subs.add(_ap.onPlayerComplete.listen((_) {
          if (!c.isCompleted) c.complete();
        }));
        final done = c.future.timeout(const Duration(seconds: 120), onTimeout: () {});
        // زر 🐢 يعمل الآن على التسجيلات أيضًا (كان يعمل على النطق الآلي فقط).
        await _ap.setSource(src);
        await _ap.setPlaybackRate(slow ? kSlowRate : 1.0);
        await _ap.resume();
        await done;
      } finally {
        for (final s in subs) {
          s.cancel();
        }
      }
      return true;
    } catch (e) {
      lastError = 'تعذّر تشغيل $k: $e';
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
      final r = await http.get(Uri.parse(_url(k))).timeout(const Duration(seconds: 30));
      if (r.statusCode == 200 && r.bodyBytes.length > 500) {
        await f.writeAsBytes(r.bodyBytes, flush: true);
        _dlNote = '';
      } else {
        _dlNote = '(رمز ${r.statusCode}، ${r.bodyBytes.length} بايت من ${kCloudBase}/audio/$k.mp3)';
      }
    } catch (e) {
      _dlNote = '(فشل الاتصال: $e)';
    } finally {
      _busy.remove(k);
    }
  }

  void dispose() {
    _tts.stop();
    _ap.dispose();
  }
}
