import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'audio_service.dart';
import 'config.dart';
import 'models.dart';
import 'store.dart';

const kAccent = Color(0xFF6C3FD1);
const kPaper = Color(0xFFFBF7EC);
const kDesk = Color(0xFF2E2418);

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});
  @override
  State<ReaderScreen> createState() => _ReaderState();
}

class _ReaderState extends State<ReaderScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _audio = AudioService();
  late final AnimationController _ctrl;
  late SharedPreferences _prefs;
  final _playing = ValueNotifier<Item?>(null);
  Timer? _poll;
  bool _checking = false;
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);

  List<BookPage> pages = [];
  bool _ready = false, _ui = true, _slow = false, _spell = false, _word = false, _draw = false;
  String? _err, _toast;
  int cur = 0, _dir = 0, _token = 0, _color = 0xFFE53935;
  double _acc = 0;
  Stroke? _live;
  VoidCallback? _last;
  final Map<String, List<Stroke>> _ink = {};
  final Map<String, Set<int>> _solved = {};

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(const Duration(minutes: 3), (_) => _autoCheck());
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoCheck();
  }

  /// فحص السحابة تلقائيًا: عند الفتح، وعند الرجوع للتطبيق، وكل 3 دقائق أثناء استخدامه.
  Future<void> _autoCheck() async {
    if (_checking || !_ready) return;
    if (DateTime.now().difference(_lastCheck).inSeconds < 20) return;
    _checking = true;
    _lastCheck = DateTime.now();
    try {
      final n = await Store.checkCloud(_prefs);
      if (n != null && mounted) {
        await _audio.clearCache();
        _setBook(n);
        _msg('✅ تم تحديث المحتوى');
      }
    } finally {
      _checking = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _ctrl.dispose();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      await _audio.init();
      final d = await Store.load(_prefs);
      pages = d.pages;
      _audio.setEmbedded(d.audio);
      _loadInk();
      cur = (_prefs.getInt('lastPage') ?? 0).clamp(0, pages.length - 1);
      setState(() => _ready = true);
      _prefetch();
      _autoCheck();
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  void _setBook(BookData d) {
    final id = pages.isNotEmpty ? pages[cur].id : null;
    setState(() {
      pages = d.pages;
      final i = id == null ? -1 : pages.indexWhere((p) => p.id == id);
      cur = i < 0 ? 0 : i;
    });
    _audio.setEmbedded(d.audio);
    _prefetch();
  }

  void _loadInk() {
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
    } catch (_) {}
  }

  void _prefetch() {
    final keys = <String>[];
    for (var i = cur; i <= math.min(pages.length - 1, cur + kPrefetch); i++) {
      for (final a in pages[i].acts) {
        for (final it in a.items) {
          if (it.audio != null) keys.add(it.audio!);
        }
      }
    }
    _audio.prefetch(keys);
  }

  // ---------- القراءة ----------
  List<Act> _acts(BookPage p) => p.acts.where((a) => a.layer == 'both' || (a.layer == 'word') == _word).toList();

  void _stop() {
    _token++;
    _audio.stop();
    _playing.value = null;
  }

  Future<void> _run(List<Item> list) async {
    _stop();
    final my = _token;
    for (final it in list) {
      if (my != _token) return;
      _playing.value = it;
      await _audio.speak(it, slow: _slow, spell: _spell);
      if (my != _token) return;
      if (_audio.lastError != null) _msg('⚠️ ${_audio.lastError}');
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (my == _token) _playing.value = null;
  }

  void _playOne(Item it) {
    _last = () => _playOne(it);
    _run([it]);
  }

  void _readPage() {
    _last = _readPage;
    _run(_acts(pages[cur]).expand((a) => a.items).toList());
  }

  void _readAct(Act a) {
    _last = () => _readAct(a);
    _run(a.items);
  }

  void _goTo(int i) {
    _stop();
    setState(() => cur = i.clamp(0, pages.length - 1));
    _prefs.setInt('lastPage', cur);
    _prefetch();
  }

  void _msg(String t) {
    setState(() => _toast = t);
    Future.delayed(Duration(milliseconds: 1500 + t.length * 40), () {
      if (mounted && _toast == t) setState(() => _toast = null);
    });
  }

  // ---------- الرسم والتحقق ----------
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
      if (bb.width > 3 && bb.height > 3 && gap < 0.35 * math.max(bb.width, bb.height)) {
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
          _msg(done.length >= p.targets.length ? '🎉 أحسنت! أكملت النشاط' : '⭐ أحسنت!');
          _audio.say('أحسنت');
        } else {
          keep = false;
          _msg('❌ حاول مرة أخرى');
          _audio.say('حاول مرة أخرى');
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

  // ---------- قلب الصفحات ----------
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
    if (ok) _prefetch();
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
    final acts = _acts(p);
    final items = acts.expand((a) => a.items).toList();
    return IgnorePointer(
      ignoring: !live,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _ui = !_ui),
        child: Container(
          color: kPaper,
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
                        builder: (c, now, _) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _playOne(it),
                          child: Container(
                            decoration: BoxDecoration(
                              color: identical(now, it) ? Colors.amber.withOpacity(0.45) : Colors.transparent,
                              border: identical(now, it) ? Border.all(color: const Color(0xFFE0439B), width: 3) : null,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned.fill(
                      child: IgnorePointer(child: CustomPaint(painter: InkPainter([...(_ink[p.id] ?? []), if (live && _live != null) _live!])))),
                  if (live && _ui && !_draw)
                    for (final a in acts)
                      if (a.items.length >= 2)
                        Positioned(
                          left: math.max(2.0, math.min(w - 46.0, a.box.left / 100 * w)),
                          top: math.max(2.0, math.min(h - 46.0, a.box.top / 100 * h - 22)),
                          child: _actBtn(a),
                        ),
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

  Widget _actBtn(Act a) => Material(
        color: kAccent,
        shape: const CircleBorder(),
        elevation: 4,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _readAct(a),
          child: const SizedBox(width: 40, height: 40, child: Icon(Icons.headphones, color: Colors.white, size: 24)),
        ),
      );

  // ---------- الأزرار ----------
  Widget _btn(String ic, String t, VoidCallback f, {bool on = false, bool primary = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Material(
          color: primary ? kAccent : (on ? Colors.amber : Colors.white),
          borderRadius: BorderRadius.circular(18),
          elevation: 3,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: f,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: primary ? 20 : 14, vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(ic, style: const TextStyle(fontSize: 26)),
                Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary ? Colors.white : Colors.black87)),
              ]),
            ),
          ),
        ),
      );

  Widget _bar() => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.92), borderRadius: BorderRadius.circular(26), boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black26)]),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            GestureDetector(
              onLongPress: _admin,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('صفحة ${pages[cur].num} من ${pages.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            if (_draw)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final c in [0xFFE53935, 0xFF1E88E5, 0xFF43A047, 0xFF212121])
                    GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 36,
                        height: 36,
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
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _btn('🎧', 'اقرأ الصفحة', _readPage, primary: true),
                _btn('🐢', 'بطيء', () => setState(() => _slow = !_slow), on: _slow),
                _btn('✏️', 'رسم', () {
                  _stop();
                  setState(() => _draw = !_draw);
                }, on: _draw),
                _btn('☰', 'المزيد', _more),
              ]),
            ),
          ]),
        ),
      );

  void _more() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Text(_spell ? '✅' : '⬜', style: const TextStyle(fontSize: 22)),
            title: const Text('تهجئة الحروف قبل الكلمة'),
            onTap: () {
              Navigator.pop(ctx);
              setState(() => _spell = !_spell);
            },
          ),
          ListTile(
            leading: Text(_word ? '✅' : '⬜', style: const TextStyle(fontSize: 22)),
            title: const Text('عرض الكلمات المفردة'),
            onTap: () {
              Navigator.pop(ctx);
              _stop();
              setState(() => _word = !_word);
            },
          ),
          ListTile(
            leading: const Text('🔁', style: TextStyle(fontSize: 22)),
            title: const Text('أعد آخر قراءة'),
            onTap: () {
              Navigator.pop(ctx);
              _last?.call();
            },
          ),
          ListTile(
            leading: const Text('🔢', style: TextStyle(fontSize: 22)),
            title: const Text('اذهب إلى صفحة...'),
            onTap: () {
              Navigator.pop(ctx);
              _gotoDialog();
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _gotoDialog() async {
    final c = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('رقم الصفحة'),
        content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true, style: const TextStyle(fontSize: 24)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('اذهب')),
        ],
      ),
    );
    final n = int.tryParse(r ?? '');
    if (n == null) return;
    final i = pages.indexWhere((p) => p.num == n);
    if (i >= 0) {
      _goTo(i);
    } else {
      _msg('لا توجد صفحة $n');
    }
  }

  // ---------- قائمة المطوّر المخفية ----------
  Future<void> _admin() async {
    final c = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('الرقم السري'),
        content: TextField(controller: c, obscureText: true, keyboardType: TextInputType.number, autofocus: true),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('دخول'))],
      ),
    );
    if (pin != kAdminPin || !mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Text('☁️', style: TextStyle(fontSize: 22)),
            title: const Text('تحديث من السحابة الآن'),
            onTap: () async {
              Navigator.pop(ctx);
              final d = await Store.checkCloud(_prefs, force: true);
              if (d != null) {
                await _audio.clearCache();
                _setBook(d);
                _msg('✅ تم التحديث');
              } else if (mounted) {
                showDialog(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('نتيجة الفحص'),
                    content: SelectableText(Store.lastCloudNote.isEmpty ? 'لا يوجد تحديث أو لا اتصال' : Store.lastCloudNote),
                    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('حسنًا'))],
                  ),
                );
              }
            },
          ),
          ListTile(
            leading: const Text('↩️', style: TextStyle(fontSize: 22)),
            title: const Text('العودة إلى المحتوى المدمج'),
            onTap: () async {
              Navigator.pop(ctx);
              await Store.reset(_prefs);
              _setBook(await Store.load(_prefs));
              _msg('تمت العودة للمحتوى المدمج');
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_err != null) {
      return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: SelectableText('خطأ في تحميل المحتوى:\n$_err', style: const TextStyle(fontSize: 18)))));
    }
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      backgroundColor: kDesk,
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
                  child: Text(_toast!, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: kAccent)),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(opacity: _ui ? 1 : 0, duration: const Duration(milliseconds: 200), child: IgnorePointer(ignoring: !_ui, child: _bar())),
          ),
        ]);
      }),
    );
  }
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
