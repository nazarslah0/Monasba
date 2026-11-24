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

  static Future<BookData> load(SharedPreferences p) async {
    final o = p.getString('contentOverride');
    if (o != null) {
      try {
        return await parse(o);
      } catch (_) {}
    }
    return parse(await rootBundle.loadString('assets/content.json'));
  }

  /// يفحص السحابة؛ إن وُجد إصدار جديد ينزّله ويعيد المحتوى الجديد.
  static Future<BookData?> checkCloud(SharedPreferences p, {bool force = false}) async {
    if (kCloudBase.isEmpty || (p.getBool('pinned') == true && !force)) return null;
    try {
      final t = DateTime.now().millisecondsSinceEpoch;
      final mr = await http.get(Uri.parse('$kCloudBase/manifest.json?t=$t')).timeout(const Duration(seconds: 10));
      if (mr.statusCode != 200) return null;
      final v = jsonDecode(utf8.decode(mr.bodyBytes))['version'].toString();
      if (v == p.getString('cloudVersion') && !force) return null;
      final r = await http.get(Uri.parse('$kCloudBase/content.json?t=$t')).timeout(const Duration(seconds: 40));
      if (r.statusCode != 200) return null;
      final txt = utf8.decode(r.bodyBytes);
      final d = await parse(txt);
      await p.setString('contentOverride', txt);
      await p.setString('cloudVersion', v);
      await p.remove('pinned');
      return d;
    } catch (_) {
      return null;
    }
  }

  static Future<void> reset(SharedPreferences p) async {
    await p.remove('contentOverride');
    await p.remove('pinned');
    await p.remove('cloudVersion');
  }
}
