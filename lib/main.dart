import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const QiraatiApp());
}

class QiraatiApp extends StatelessWidget {
  const QiraatiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'قراءتي',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF5A2BC0)),
        builder: (c, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const BookScreen(),
      );
}

class Item {
  final String text;
  final double x, y, w, h;
  final bool draft;
  final String key;
  final String? audio;
  Item(this.text, this.x, this.y, this.w, this.h, this.draft, this.key, this.audio);
}

class Act {
  final String layer;
  final List<Item> items;
  Act(this.layer, this.items);
}

class BookPage {
  final String id, img;
  final int num;
  final double ratio;
  final List<Act> acts;
  BookPage(this.id, this.img, this.num, this.ratio, this.acts);
}

class BookScreen extends StatefulWidget {
  const BookScreen({super.key});
  @override
  State<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends State<BookScreen> with SingleTickerProviderStateMixin {
  final _tts = FlutterTts();
  final _ap = AudioPlayer();
  Map<String, String> _aud = {};
  late final AnimationController _ctrl;
  final _playing = ValueNotifier<Item?>(null);
  late SharedPreferences _prefs;
  List<BookPage> pages = [];
  bool _ready = false, _ui = true, _slow = false, _spell = false, _word = false;
  int cur = 0, _dir = 0, _token = 0;
  double _acc = 0;
  VoidCallback? _last;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _tts.setLanguage('ar-SA');
    _tts.awaitSpeakCompletion(true);
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _tts.stop();
    _ap.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final j = jsonDecode(await rootBundle.loadString('assets/content.json'));
    final b = (j['book'] ?? j) as Map;
    _aud = ((j['audio'] ?? {}) as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
    _prefs = await SharedPreferences.getInstance();
    for (final p in b['pages']) {
      final acts = <Act>[];
      final al = p['activities'] as List;
      for (var ai = 0; ai < al.length; ai++) {
        final a = al[ai];
        if ((a['type'] ?? 'listen') != 'listen') continue;
        final its = <Item>[];
        final il = a['items'] as List;
        for (var ii = 0; ii < il.length; ii++) {
          final m = il[ii];
          final k = '${p['id']}|$ai|$ii';
          its.add(Item((m['text'] ?? '').toString(), (m['x'] as num).toDouble(), (m['y'] as num).toDouble(),
              (m['w'] as num).toDouble(), (m['h'] as num).toDouble(), m['draft'] == true, k, m['audio']?.toString()));
        }
        acts.add(Act((a['layer'] ?? 'both').toString(), its));
      }
      double ratio;
      if (p['ratio'] != null) {
        ratio = (p['ratio'] as num).toDouble();
      } else {
        final bytes = (await rootBundle.load('assets/pages/${p['img']}.jpg')).buffer.asUint8List();
        final d = await ui.ImageDescriptor.encoded(await ui.ImmutableBuffer.fromUint8List(bytes));
        ratio = d.height / d.width;
      }
      pages.add(BookPage(p['id'].toString(), p['img'].toString(), p['num'] as int, ratio, acts));
    }
    cur = (_prefs.getInt('lastPage') ?? 0).clamp(0, pages.length - 1);
    setState(() => _ready = true);
  }

  List<Item> _items(BookPage p) =>
      p.acts.where((a) => a.layer == 'both' || (a.layer == 'word') == _word).expand((a) => a.items).toList();

  // ---------- speech ----------
  void _stop() {
    _token++;
    _tts.stop();
    _ap.stop();
    _playing.value = null;
  }

  Future<void> _say(String t, int my) async {
    if (my != _token || t.trim().isEmpty) return;
    await _tts.setSpeechRate(_slow ? 0.3 : 0.5);
    await _tts.speak(t);
  }

  Future<bool> _playAudio(Item it) async {
    final k = it.audio;
    if (k == null || k.isEmpty) return false;
    try {
      final d = _aud[k];
      final Source src = d != null ? BytesSource(base64Decode(d.substring(d.indexOf(',') + 1))) : AssetSource('audio/$k.mp3');
      await _ap.stop();
      final done = _ap.onPlayerComplete.first.timeout(const Duration(seconds: 30), onTimeout: () {});
      await _ap.play(src);
      await done;
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _play(Item it, int my) async {
    _playing.value = it;
    if (await _playAudio(it)) {
      if (my == _token) _playing.value = null;
      return;
    }
    if (my != _token) return;
    final t = it.draft ? it.text.replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '') : it.text;
    if (_spell) {
      for (final m in RegExp(r'[\u0621-\u064A][\u064B-\u065F\u0670\u0640]*').allMatches(it.text)) {
        if (my != _token) return;
        await _say(m.group(0)!, my);
      }
    }
    await _say(t, my);
    if (my == _token) _playing.value = null;
  }

  void _playOne(Item it) {
    _stop();
    final my = _token;
    _last = () => _playOne(it);
    _play(it, my);
  }

  Future<void> _readPage() async {
    _stop();
    final my = _token;
    _last = _readPage;
    for (final it in _items(pages[cur])) {
      if (my != _token) return;
      await _play(it, my);
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  // ---------- page turning ----------
  void _du(DragUpdateDetails d, double w) {
    if (_ctrl.isAnimating) return;
    if (_dir == 0) _stop();
    _acc += d.delta.dx;
    if (_acc > 0 && cur < pages.length - 1) {
      _dir = 1;
      _ctrl.value = (_acc / w).clamp(0.0, 1.0);
    } else if (_acc < 0 && cur > 0) {
      _dir = -1;
      _ctrl.value = (-_acc / w).clamp(0.0, 1.0);
    } else {
      _ctrl.value = 0;
    }
  }

  Future<void> _de() async {
    if (_dir == 0) {
      _acc = 0;
      return;
    }
    final d = _dir, ok = _ctrl.value > 0.3;
    await _ctrl.animateTo(ok ? 1 : 0, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    setState(() {
      if (ok) {
        cur += d;
        _prefs.setInt('lastPage', cur);
      }
    });
    _ctrl.value = 0;
    _dir = 0;
    _acc = 0;
  }

  Widget _flip(Widget child, double a, double s) => Transform(
        alignment: Alignment.centerRight,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0015)
          ..rotateY(a),
        child: Stack(fit: StackFit.expand, children: [
          child,
          IgnorePointer(child: Container(color: Colors.black.withOpacity(0.28 * s))),
        ]),
      );

  Widget _book() {
    final t = _ctrl.value;
    if (t == 0 || _dir == 0) return _page(cur, true);
    if (_dir > 0) {
      return Stack(fit: StackFit.expand, children: [_page(cur + 1, false), _flip(_page(cur, false), t * math.pi / 2, t)]);
    }
    return Stack(fit: StackFit.expand, children: [_page(cur, false), _flip(_page(cur - 1, false), (1 - t) * math.pi / 2, 1 - t)]);
  }

  Widget _page(int i, bool live) {
    final p = pages[i];
    final items = _items(p);
    return IgnorePointer(
      ignoring: !live,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _ui = !_ui),
        child: Container(
          color: const Color(0xFFFBF7EC),
          child: LayoutBuilder(builder: (c, b) {
            var w = b.maxWidth, h = w * p.ratio;
            if (h > b.maxHeight) {
              h = b.maxHeight;
              w = h / p.ratio;
            }
            return Center(
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(children: [
                  Positioned.fill(child: Image.asset('assets/pages/${p.img}.jpg', fit: BoxFit.fill, gaplessPlayback: true)),
                  for (final it in items)
                    Positioned(
                      left: it.x / 100 * w,
                      top: it.y / 100 * h,
                      width: it.w / 100 * w,
                      height: it.h / 100 * h,
                      child: ValueListenableBuilder<Item?>(
                        valueListenable: _playing,
                        builder: (c, cur, _) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _playOne(it),
                          child: Container(
                            decoration: BoxDecoration(
                              color: identical(cur, it) ? Colors.amber.withOpacity(0.45) : Colors.transparent,
                              border: identical(cur, it) ? Border.all(color: const Color(0xFFE0439B), width: 3) : null,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            );
          }),
        ),
      ),
    );
  }

  // ---------- controls ----------
  Widget _btn(String ic, String t, VoidCallback f, [bool on = false]) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: on ? Colors.amber : Colors.white,
          borderRadius: BorderRadius.circular(16),
          elevation: 3,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: f,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(ic, style: const TextStyle(fontSize: 24)),
                Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
        ),
      );

  Widget _bar() => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(99)),
            child: Text('صفحة ${pages[cur].num} من ${pages.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _btn('▶️', 'قراءة الصفحة', _readPage),
              _btn('🐢', 'قراءة بطيئة', () => setState(() => _slow = !_slow), _slow),
              _btn('🔁', 'إعادة', () {
                _stop();
                _last?.call();
              }),
              _btn('أ ب ت', 'تهجئة', () => setState(() => _spell = !_spell), _spell),
              _btn('🔊', 'صوت الكلمة', () {
                _stop();
                setState(() => _word = !_word);
              }, _word),
            ]),
          ),
          const SizedBox(height: 6),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      backgroundColor: const Color(0xFF3B2A1A),
      body: LayoutBuilder(builder: (c, box) {
        final w = box.maxWidth;
        return Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              onHorizontalDragUpdate: (d) => _du(d, w),
              onHorizontalDragEnd: (_) => _de(),
              child: AnimatedBuilder(animation: _ctrl, builder: (_, __) => _book()),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              opacity: _ui ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(ignoring: !_ui, child: _bar()),
            ),
          ),
        ]);
      }),
    );
  }
}
