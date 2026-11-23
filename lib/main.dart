import 'dart:convert';
import 'dart:math' as math;
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
  final List<Rect> targets;
  BookPage(this.id, this.img, this.num, this.ratio, this.acts, this.targets);
}

class Stroke {
  final int c;
  final List<Offset> p;
  Stroke(this.c, this.p);
}

class InkPainter extends CustomPainter {
  final List<Stroke> strokes;
  InkPainter(this.strokes);
  @override
  void paint(Canvas canvas, Size s) {
    for (final st in strokes) {
      final pt = Paint()
        ..color = Color(st.c)
        ..strokeWidth = s.width * 0.008 + 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (var i = 0; i < st.p.length; i++) {
        final o = Offset(st.p[i].dx * s.width, st.p[i].dy * s.height);
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(path, pt);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
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
  bool _draw = false;
  int _color = 0xFFE53935;
  Stroke? _live;
  String? _toast;
  Map<String, List<Stroke>> _ink = {};
  Map<String, Set<int>> _solved = {};

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

  String? _err;

  Future<void> _load() async {
    try {
      await _load0();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  Future<void> _load0() async {
    Map<String, dynamic> ratios = {}, tgs = {};
    try {
      ratios = jsonDecode(await rootBundle.loadString('assets/ratios.json')) as Map<String, dynamic>;
    } catch (e) {}
    try {
      tgs = jsonDecode(await rootBundle.loadString('assets/targets.json')) as Map<String, dynamic>;
    } catch (e) {}
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
      final double ratio = ((p['ratio'] ?? ratios[p['img']] ?? 1.4128) as num).toDouble();
      final tg = <Rect>[
        for (final t in ((p['targets'] ?? tgs[p['id']]) as List? ?? []))
          Rect.fromLTWH((t['x'] as num).toDouble(), (t['y'] as num).toDouble(), (t['w'] as num).toDouble(), (t['h'] as num).toDouble())
      ];
      pages.add(BookPage(p['id'].toString(), p['img'].toString(), p['num'] as int, ratio, acts, tg));
    }
    try {
      (jsonDecode(_prefs.getString('ink') ?? '{}') as Map).forEach((k, v) {
        _ink[k.toString()] = [
          for (final st in v as List)
            Stroke(st['c'] as int, [
              for (var i = 0; i + 1 < (st['p'] as List).length; i += 2) Offset((st['p'][i] as num).toDouble(), (st['p'][i + 1] as num).toDouble())
            ])
        ];
      });
      (jsonDecode(_prefs.getString('solved') ?? '{}') as Map).forEach((k, v) {
        _solved[k.toString()] = {for (final i in v as List) i as int};
      });
    } catch (e) {}
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

  // ---------- drawing & checking ----------
  void _msg(String t) {
    setState(() => _toast = t);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && _toast == t) setState(() => _toast = null);
    });
  }

  Future<void> _saveInk() async {
    final m = {
      for (final e in _ink.entries)
        e.key: [
          for (final st in e.value)
            {
              'c': st.c,
              'p': [for (final o in st.p) ...[double.parse(o.dx.toStringAsFixed(3)), double.parse(o.dy.toStringAsFixed(3))]]
            }
        ]
    };
    await _prefs.setString('ink', jsonEncode(m));
    await _prefs.setString('solved', jsonEncode({for (final e in _solved.entries) e.key: e.value.toList()}));
  }

  void _ps(Offset o, double w, double h) => setState(() => _live = Stroke(_color, [Offset(o.dx / w, o.dy / h)]));
  void _pu(Offset o, double w, double h) {
    _live?.p.add(Offset((o.dx / w).clamp(0.0, 1.0), (o.dy / h).clamp(0.0, 1.0)));
    setState(() {});
  }

  void _pe(BookPage p) {
    final s = _live;
    _live = null;
    if (s == null) return;
    var keep = true;
    if (p.targets.isNotEmpty && s.p.length > 8) {
      final xs = s.p.map((o) => o.dx * 100), ys = s.p.map((o) => o.dy * 100);
      final bb = Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
      final gap = (Offset(s.p.first.dx * 100, s.p.first.dy * 100) - Offset(s.p.last.dx * 100, s.p.last.dy * 100)).distance;
      final closed = bb.width > 3 && bb.height > 3 && gap < 0.35 * math.max(bb.width, bb.height);
      if (closed) {
        var hit = -1;
        for (var i = 0; i < p.targets.length; i++) {
          final t = p.targets[i], it = bb.intersect(t);
          if (it.width > 0 && it.height > 0 && it.width * it.height / (t.width * t.height) > 0.7 && bb.width * bb.height <= t.width * t.height * 8) {
            hit = i;
            break;
          }
        }
        if (hit >= 0) {
          final done = (_solved[p.id] ??= {})..add(hit);
          final all = done.length >= p.targets.length;
          _msg(all ? '🎉 أحسنت! أكملت النشاط' : '⭐ أحسنت!');
          _tts.speak('أحسنت');
        } else {
          keep = false;
          _msg('❌ حاول مرة أخرى');
          _tts.speak('حاول مرة أخرى');
        }
      }
    }
    if (keep) (_ink[p.id] ??= []).add(s);
    setState(() {});
    _saveInk();
  }

  void _undo() {
    final l = _ink[pages[cur].id];
    if (l != null && l.isNotEmpty) setState(() => l.removeLast());
    _saveInk();
  }

  void _clear() {
    setState(() {
      _ink.remove(pages[cur].id);
      _solved.remove(pages[cur].id);
    });
    _saveInk();
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
                  Positioned.fill(
                      child: IgnorePointer(
                          child: CustomPaint(painter: InkPainter([...(_ink[p.id] ?? []), if (live && _live != null) _live!])))),
                  if (live && _draw)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) => _ps(d.localPosition, w, h),
                        onPanUpdate: (d) => _pu(d.localPosition, w, h),
                        onPanEnd: (_) => _pe(p),
                        child: const SizedBox.expand(),
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
          if (_draw)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final c in [0xFFE53935, 0xFF1E88E5, 0xFF43A047, 0xFF212121])
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 38,
                      height: 38,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle, border: Border.all(color: _color == c ? Colors.amber : Colors.white, width: 4)),
                    ),
                  ),
                _btn('↩️', 'تراجع', _undo),
                _btn('🗑️', 'مسح', _clear),
              ]),
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
              _btn('✏️', 'رسم', () {
                _stop();
                setState(() => _draw = !_draw);
              }, _draw),
            ]),
          ),
          const SizedBox(height: 6),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (_err != null) {
      return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: SelectableText('خطأ في تحميل المحتوى:\n$_err', style: const TextStyle(fontSize: 18)))));
    }
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      backgroundColor: const Color(0xFF3B2A1A),
      body: LayoutBuilder(builder: (c, box) {
        final w = box.maxWidth;
        return Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              onHorizontalDragUpdate: _draw ? null : (d) => _du(d, w),
              onHorizontalDragEnd: _draw ? null : (_) => _de(),
              child: AnimatedBuilder(animation: _ctrl, builder: (_, __) => _book()),
            ),
          ),
          if (_toast != null)
            Center(
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26), border: Border.all(color: const Color(0xFFFFD23F), width: 5)),
                  child: Text(_toast!, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Color(0xFF5A2BC0))),
                ),
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
