import 'package:flutter/material.dart';

class Item {
  final String text;
  final double x, y, w, h;
  final bool draft;
  final String? audio;
  Item(this.text, this.x, this.y, this.w, this.h, this.draft, this.audio);
}

class Act {
  final String id, title, layer;
  final List<Item> items;
  Act(this.id, this.title, this.layer, this.items);

  /// المستطيل الذي يجمع عناصر النشاط (بالنسبة المئوية من الصفحة).
  Rect get box {
    var l = 100.0, t = 100.0, r = 0.0, b = 0.0;
    for (final i in items) {
      if (i.x < l) l = i.x;
      if (i.y < t) t = i.y;
      if (i.x + i.w > r) r = i.x + i.w;
      if (i.y + i.h > b) b = i.y + i.h;
    }
    return Rect.fromLTRB(l, t, r, b);
  }
}

/// زر سماعة قابل للتحديد من لوحة التحكم: موضعه (نسبة مئوية من الصفحة) ومن أي رقم صوت إلى أي رقم يقرأ.
class Player {
  final double x, y;
  final int from, to;
  Player(this.x, this.y, this.from, this.to);
}

class BookPage {
  final String id, img;
  final int num;
  final double ratio;
  final List<Act> acts;
  final List<Rect> targets;
  final List<Player> players;
  BookPage(this.id, this.img, this.num, this.ratio, this.acts, this.targets, this.players);
}

class Stroke {
  final int c;
  final List<Offset> p;
  Stroke(this.c, this.p);
}

class BookData {
  final List<BookPage> pages;
  final Map<String, String> audio; // أصوات مدمجة قديمة (data URL)
  BookData(this.pages, this.audio);
}

BookData parseBook(dynamic j, Map<String, dynamic> ratios, Map<String, dynamic> tgs) {
  final b = (j['book'] ?? j) as Map;
  final aud = ((j['audio'] ?? {}) as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
  final pages = <BookPage>[];
  for (final p in b['pages']) {
    final acts = <Act>[];
    for (final a in (p['activities'] as List)) {
      if ((a['type'] ?? 'listen') != 'listen') continue;
      final its = <Item>[
        for (final m in (a['items'] as List))
          Item((m['text'] ?? '').toString(), (m['x'] as num).toDouble(), (m['y'] as num).toDouble(), (m['w'] as num).toDouble(),
              (m['h'] as num).toDouble(), m['draft'] == true, m['audio']?.toString())
      ];
      acts.add(Act((a['id'] ?? '').toString(), (a['title'] ?? '').toString(), (a['layer'] ?? 'both').toString(), its));
    }
    final ratio = ((p['ratio'] ?? ratios[p['img']] ?? 1.4128) as num).toDouble();
    final tg = <Rect>[
      for (final t in ((p['targets'] ?? tgs[p['id']]) as List? ?? []))
        Rect.fromLTWH((t['x'] as num).toDouble(), (t['y'] as num).toDouble(), (t['w'] as num).toDouble(), (t['h'] as num).toDouble())
    ];
    final pls = <Player>[
      for (final m in ((p['players'] as List?) ?? []))
        Player((m['x'] as num).toDouble(), (m['y'] as num).toDouble(), (m['from'] as num).toInt(), (m['to'] as num).toInt())
    ];
    pages.add(BookPage(p['id'].toString(), p['img'].toString(), p['num'] as int, ratio, acts, tg, pls));
  }
  return BookData(pages, aud);
}
