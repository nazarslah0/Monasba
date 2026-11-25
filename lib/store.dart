import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'models.dart';

/// تحميل المحتوى: المدمج، أو ما استُورد/نُزّل من السحابة.
class Store {
  static Map<String, dynamic> _ratios = {}, _tgs = {};
  static bool _ok = false;

  static Future<void> _assets() async {
    if (_ok) return;
    try {
      _ratios = jsonDecode(await rootBundle.loadString('assets/ratios.json')) as Map<String, dynamic>;
    } catch (_) {}
    try {
      _tgs = jsonDecode(await rootBundle.loadString('assets/targets.json')) as Map<String, dynamic>;
    } catch (_) {}
    _ok = true;
  }

  static Future<BookData> parse(String txt) async {
    await _assets();
    return parseBook(jsonDecode(txt), _ratios, _tgs);
  }

  /// آخر ملاحظة/سبب من فحص السحابة (للتشخيص في القائمة المخفية).
  static String lastCloudNote = '';

  /// إصدار محتوى السحابة الحالي؛ يُضاف لروابط الصوت لمنع استخدام نسخة قديمة مخزّنة.
  static String version = '';

  /// بصمة بسيطة ثابتة للمحتوى المدمج لاكتشاف أنه تغيّر في نسخة جديدة من التطبيق.
  static String _sig(String s) {
    var h = 0x811C9DC5;
    for (var i = 0; i < s.length; i++) {
      h = ((h ^ s.codeUnitAt(i)) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${s.length}_$h';
  }

  static Future<BookData> load(SharedPreferences p) async {
    final bundled = await rootBundle.loadString('assets/content.json');
    // إذا تغيّر assets/content.json (بناء جديد للتطبيق) فالنسخة القديمة المحفوظة على الجهاز
    // كانت تتغلّب عليه فلا يظهر التعديل؛ هنا نتخلص منها ونعتمد المحتوى المدمج الجديد.
    final sig = _sig(bundled);
    final old = p.getString('bundledSig');
    if (old != sig) {
      if (p.getString('contentOverride') != null) {
        await p.remove('contentOverride');
        await p.remove('pinned');
        await p.remove('pinnedAt');
        await p.remove('cloudVersion');
        await p.setBool('adopt', true); // لا تستبدل المدمج الجديد بنسخة سحابة أقدم
      }
      await p.setString('bundledSig', sig);
    }
    version = p.getString('cloudVersion') ?? '';
    final o = p.getString('contentOverride');
    if (o != null) {
      try {
        return await parse(o);
      } catch (_) {}
    }
    return parse(bundled);
  }

  /// يفحص السحابة؛ إن وُجد إصدار جديد ينزّله ويعيد المحتوى الجديد.
  static Future<BookData?> checkCloud(SharedPreferences p, {bool force = false}) async {
    lastCloudNote = '';
    if (kCloudBase.isEmpty) {
      lastCloudNote = 'رابط السحابة kCloudBase فارغ في config.dart';
      return null;
    }
    try {
      final t = DateTime.now().millisecondsSinceEpoch;
      final mr = await http.get(Uri.parse('$kCloudBase/manifest.json?t=$t')).timeout(const Duration(seconds: 10));
      if (mr.statusCode != 200) {
        lastCloudNote = 'تعذّر قراءة manifest.json (رمز ${mr.statusCode}). تأكد من الرابط ومن تفعيل GitHub Pages للمستودع.';
        return null;
      }
      final v = jsonDecode(utf8.decode(mr.bodyBytes))['version'].toString();
      if (!force && p.getBool('adopt') == true) {
        await p.setString('cloudVersion', v);
        await p.remove('adopt');
        lastCloudNote = 'اعتُمد المحتوى المدمج الجديد؛ ستُطبَّق أي نسخة سحابة أحدث منه.';
        return null;
      }
      if (!force && p.getBool('pinned') == true) {
        // محتوى مستورد يدويًا: لا تستبدله إلا بنسخة سحابة نُشرت بعد الاستيراد.
        final at = p.getInt('pinnedAt') ?? 0;
        if ((int.tryParse(v) ?? 0) <= at) {
          lastCloudNote = 'محتوى مستورد يدويًا أحدث من السحابة (الإصدار $v).';
          return null;
        }
      }
      if (v == p.getString('cloudVersion') && !force) {
        lastCloudNote = 'المحتوى محدّث (إصدار السحابة $v). إن رفعت تعديلًا جديدًا تأكد من رفع manifest.json أيضًا.';
        return null;
      }
      final r = await http.get(Uri.parse('$kCloudBase/content.json?t=$t')).timeout(const Duration(seconds: 40));
      if (r.statusCode != 200) {
        lastCloudNote = 'تعذّر قراءة content.json (رمز ${r.statusCode}).';
        return null;
      }
      final txt = utf8.decode(r.bodyBytes);
      final d = await parse(txt);
      final ok = await p.setString('contentOverride', txt);
      if (!ok) throw Exception('تعذّر حفظ المحتوى على الجهاز');
      await p.setString('cloudVersion', v);
      version = v;
      await p.remove('pinned');
      await p.remove('pinnedAt');
      lastCloudNote = 'تم التحديث من السحابة (إصدار $v).';
      return d;
    } catch (e) {
      lastCloudNote = 'فشل التحديث: $e';
      return null;
    }
  }

  static Future<void> reset(SharedPreferences p) async {
    await p.remove('contentOverride');
    await p.remove('pinned');
    await p.remove('pinnedAt');
    await p.remove('cloudVersion');
    await p.remove('adopt');
  }
}
