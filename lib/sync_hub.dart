import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'auth.dart';
import 'config.dart';
import 'laporan.dart' show LapStore;
import 'photos.dart';
import 'radiation.dart' show kSourcesVer;
import 'sources_util.dart';
import 'statistik.dart' show statSync;

/// Sinkron data antar HP lewat web app (Apps Script) yang sama.
///
/// Setiap data (satu pengukuran density, satu baris paparan, satu rekaman
/// buka/tutup, dst.) dikirim sebagai satu "item" ke file
/// "SLRT - Data Sinkron Antar HP". HP lain menarik item yang berubah sejak
/// sinkron terakhirnya, jadi pekerjaan si A otomatis muncul di HP si B.
///
/// Sinkron hanya berjalan saat tidak ada menu yang terbuka (di Beranda),
/// supaya data yang sedang diedit di sebuah form tidak tertimpa.
class Hub {
  static bool moduleOpen = false;
  static bool busy = false;
  static String lastError = '';
  static DateTime? lastOk;
  static int lastPulled = 0;
  static final _listeners = <void Function()>{};
  static Timer? _timer;

  static void listen(void Function() f) => _listeners.add(f);
  static void unlisten(void Function() f) => _listeners.remove(f);
  static void _notify() {
    for (final f in [..._listeners]) {
      try {
        f();
      } catch (_) {}
    }
  }

  /// Sinkron berkala (tiap 2 menit) selama aplikasi terbuka di Beranda.
  /// Tiap 1 menit: di Beranda = kirim + tarik; saat menu terbuka = hanya kirim
  /// hasil yang sudah disimpan (isian form yang sedang diketik tidak disentuh).
  static void startTimer() {
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      sync(pushOnly: moduleOpen);
    });
  }

  static String get status {
    if (busy) return 'Menyinkronkan antar HP… · 正在同步';
    if (lastError.isNotEmpty) return lastError;
    if (lastOk == null) return 'Belum sinkron antar HP · 尚未同步';
    final t = lastOk!;
    final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return 'Tersinkron antar HP $hm · 已同步${lastPulled > 0 ? ' · $lastPulled data baru' : ''}';
  }

  // ---------------- definisi data yang disinkron ----------------

  static const _cols = <_Col>[
    _Col('density', 'riwayat', _Kind.list, key: 'ts', folder: 'Density'),
    _Col('bukatutup', 'bukatutup', _Kind.list, key: 'id', folder: 'Buka Tutup'),
    _Col('laporan', 'laporan', _Kind.list, key: 'id', folder: 'Laporan Kerja', skipAuto: true),
    _Col('sources', 'sources', _Kind.list, key: 'tag', folder: 'Sumber', noDelete: true),
    _Col('tld', 'tld_workers', _Kind.list, key: 'id', folder: 'TLD'),
    _Col('sessions', 'sessions', _Kind.month, folder: 'Paparan'),
    _Col('maint', 'maint', _Kind.month, folder: 'Perawatan'),
    _Col('pendose', 'pendose', _Kind.map, folder: 'Pendose'),
    _Col('mcu', 'mcu', _Kind.map, folder: 'MCU'),
  ];

  static String _fnv(String s) {
    var h = 0x811c9dc5;
    for (final c in utf8.encode(s)) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }

  static Future<String> _device(SharedPreferences p) async {
    var d = p.getString('hub_device') ?? '';
    if (d.isEmpty) {
      final r = math.Random();
      d = List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
      await p.setString('hub_device', d);
    }
    return d;
  }

  // ---------------- baca data lokal ----------------

  /// [forPush]: data sumber bawaan (belum pernah diubah di HP ini) tidak
  /// dikirim, supaya tidak menimpa data sumber yang sudah diedit di HP lain.
  static Future<dynamic> _readRaw(SharedPreferences p, _Col c, {bool forPush = false}) async {
    try {
      if (c.name == 'sources') {
        if (forPush && (p.getString('sources') == null || p.getString('sources_ver') != kSourcesVer)) return [];
        return jsonDecode(await sourcesJson(p));
      }
      final s = p.getString(c.pref);
      if (s == null) return c.kind == _Kind.list ? [] : {};
      return jsonDecode(s);
    } catch (_) {
      return c.kind == _Kind.list ? [] : {};
    }
  }

  /// Data lokal -> item per kunci (bentuk mentah).
  static Map<String, dynamic> _flatten(_Col c, dynamic raw) {
    final out = <String, dynamic>{};
    if (c.kind == _Kind.list) {
      for (final e in (raw is List ? raw : const [])) {
        if (e is! Map) continue;
        if (c.skipAuto && e['auto'] == true) continue; // laporan otomatis dibuat ulang di tiap HP
        final k = (e[c.key] ?? '').toString();
        if (k.isEmpty) continue;
        out[k] = e;
      }
    } else if (c.kind == _Kind.map) {
      if (raw is Map) raw.forEach((k, v) => out[k.toString()] = v);
    } else {
      if (raw is Map) {
        raw.forEach((month, s) {
          if (s is! Map) return;
          final meta = Map<String, dynamic>.from(s)..remove('rows');
          for (final r in (s['rows'] as List? ?? const [])) {
            if (r is! Map) continue;
            final tag = (r['tag'] ?? '').toString();
            if (tag.isEmpty) continue;
            out['$month|$tag'] = {'m': meta, 'r': r};
          }
        });
      }
    }
    return out;
  }

  /// Ganti path foto lokal dengan link Drive (bila sudah terunggah).
  static dynamic _resolve(dynamic v) {
    if (v is Map) {
      return v.map<String, dynamic>((k, x) {
        if (k == 'photos' && x is List) {
          return MapEntry(k.toString(), x.map((e) => Photos.urlOf(e.toString()) ?? e.toString()).toList());
        }
        return MapEntry(k.toString(), _resolve(x));
      });
    }
    if (v is List) return v.map(_resolve).toList();
    return v;
  }

  static void _localPhotos(dynamic v, List<String> out) {
    if (v is Map) {
      v.forEach((k, x) {
        if (k == 'photos' && x is List) {
          for (final e in x) {
            final s = e.toString();
            if (!s.startsWith('http')) out.add(s);
          }
        } else {
          _localPhotos(x, out);
        }
      });
    } else if (v is List) {
      for (final x in v) {
        _localPhotos(x, out);
      }
    }
  }

  // ---------------- tulis data hasil tarikan ----------------

  static Future<void> _apply(SharedPreferences p, _Col c, List<Map<String, dynamic>> items, Set<String> skip) async {
    final raw = await _readRaw(p, c);
    if (c.kind == _Kind.list) {
      final list = (raw is List ? raw : []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      for (final it in items) {
        final k = it['key'].toString();
        if (skip.contains(k)) continue;
        list.removeWhere((e) => (e[c.key] ?? '').toString() == k);
        if (it['deleted'] == true) continue;
        final d = it['data'];
        if (d is! Map) continue;
        final m = Map<String, dynamic>.from(d);
        if (c.name == 'sources') {
          if (m.remove('_ver') != kSourcesVer) continue; // data sumber versi lama
        }
        list.add(m);
      }
      if (c.name == 'density') {
        list.sort((a, b) => ((b['ts'] as num?) ?? 0).compareTo((a['ts'] as num?) ?? 0));
      } else if (c.name == 'sources') {
        list.sort((a, b) => ((a['order'] as num?) ?? 9999).compareTo((b['order'] as num?) ?? 9999));
      }
      await p.setString(c.pref, jsonEncode(list));
      if (c.name == 'sources') await p.setString('sources_ver', kSourcesVer);
    } else if (c.kind == _Kind.map) {
      final m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      for (final it in items) {
        final k = it['key'].toString();
        if (skip.contains(k)) continue;
        if (it['deleted'] == true) {
          m.remove(k);
        } else {
          m[k] = it['data'];
        }
      }
      await p.setString(c.pref, jsonEncode(m));
    } else {
      final m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      final order = <String, int>{};
      try {
        for (final e in (jsonDecode(await sourcesJson(p)) as List)) {
          order[((e as Map)['tag'] ?? '').toString()] = (e['order'] as num?)?.toInt() ?? 9999;
        }
      } catch (_) {}
      for (final it in items) {
        final k = it['key'].toString();
        if (skip.contains(k)) continue;
        final i = k.indexOf('|');
        if (i < 0) continue;
        final month = k.substring(0, i), tag = k.substring(i + 1);
        final s = Map<String, dynamic>.from((m[month] as Map?) ?? {'rows': []});
        final rows = ((s['rows'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((e) => (e['tag'] ?? '').toString() != tag)
            .toList();
        if (it['deleted'] != true) {
          final d = it['data'];
          if (d is Map && d['r'] is Map) {
            rows.add(Map<String, dynamic>.from(d['r'] as Map));
            final meta = d['m'] is Map ? Map<String, dynamic>.from(d['m'] as Map) : <String, dynamic>{};
            final od = (s['date'] ?? '').toString(), nd = (meta['date'] ?? '').toString();
            if (nd.compareTo(od) > 0) s['date'] = nd;
            meta.forEach((mk, mv) {
              if (mk != 'date' && (s[mk] == null || s[mk].toString().isEmpty)) s[mk] = mv;
            });
          }
        }
        rows.sort((a, b) => (order[a['tag']] ?? 99999).compareTo(order[b['tag']] ?? 99999));
        if (rows.isEmpty) {
          m.remove(month);
        } else {
          s['rows'] = rows;
          m[month] = s;
        }
      }
      await p.setString(c.pref, jsonEncode(m));
    }
  }

  // ---------------- sinkron ----------------

  /// [readOnly]: dipanggil dari halaman yang hanya membaca data (Statistik),
  /// jadi boleh sinkron walaupun halaman itu sedang terbuka.
  /// [pushOnly]: hanya mengirim hasil yang sudah tersimpan di HP ini, tanpa
  /// mengubah data di HP (aman dijalankan saat sebuah form sedang terbuka).
  static Future<bool> sync({bool readOnly = false, bool pushOnly = false}) async {
    final url = kRadSheetUrl.trim();
    if (busy || (moduleOpen && !readOnly && !pushOnly) || url.isEmpty) return false;
    busy = true;
    _notify();
    try {
      final p = await SharedPreferences.getInstance();
      await Photos.init();
      final device = await _device(p);
      final since = p.getInt('hub_rev') ?? 0;
      Map<String, dynamic> snap;
      try {
        snap = Map<String, dynamic>.from(jsonDecode(p.getString('hub_snap') ?? '{}') as Map);
      } catch (_) {
        snap = {};
      }

      // 1) cari data yang berubah / terhapus sejak sinkron terakhir
      final push = <Map<String, dynamic>>[];
      final pushed = <String, Set<String>>{};
      final pushedHash = <String, Map<String, String?>>{}; // null = terhapus
      for (final c in _cols) {
        final items = _flatten(c, await _readRaw(p, c, forPush: true));
        final old = Map<String, dynamic>.from((snap[c.name] as Map?) ?? {});
        final changed = <String>[];
        items.forEach((k, v) {
          if (old[k] != _fnv(jsonEncode(_resolve(v)))) changed.add(k);
        });
        // unggah foto yang belum punya link supaya HP lain bisa melihatnya
        final pics = <String>[];
        for (final k in changed) {
          _localPhotos(items[k], pics);
        }
        if (pics.isNotEmpty) await Photos.upload(pics, c.folder);
        for (final k in changed) {
          var d = _resolve(items[k]);
          pushedHash.putIfAbsent(c.name, () => {})[k] = _fnv(jsonEncode(d));
          if (c.name == 'sources') d = {...(d as Map), '_ver': kSourcesVer};
          push.add({'col': c.name, 'key': k, 'data': d});
          pushed.putIfAbsent(c.name, () => {}).add(k);
        }
        if (!c.noDelete) {
          for (final k in old.keys) {
            if (!items.containsKey(k)) {
              push.add({'col': c.name, 'key': k, 'deleted': true});
              pushed.putIfAbsent(c.name, () => {}).add(k);
              pushedHash.putIfAbsent(c.name, () => {})[k] = null;
            }
          }
        }
      }

      // 2) kirim bertahap, lalu tarik data dari HP lain
      final by = Auth.name;
      for (var i = 0; i < push.length; i += 150) {
        final chunk = push.sublist(i, math.min(i + 150, push.length));
        final r = await Photos.postJson(
            url, {'type': 'sync', 'device': device, 'by': by, 'push': chunk, 'since': -1});
        if (r == null || !r.replaceAll(' ', '').contains('"ok":true')) throw Exception('push');
      }
      if (pushOnly) {
        // catat yang sudah terkirim saja; data dari HP lain ditarik nanti di Beranda
        pushedHash.forEach((col, m) {
          final o = Map<String, dynamic>.from((snap[col] as Map?) ?? {});
          m.forEach((k, h) {
            if (h == null) {
              o.remove(k);
            } else {
              o[k] = h;
            }
          });
          snap[col] = o;
        });
        if (push.isNotEmpty) await p.setString('hub_snap', jsonEncode(snap));
        lastError = '';
        return true;
      }
      final res = await Photos.postJson(url, {'type': 'sync', 'device': device, 'by': by, 'push': [], 'since': since});
      if (res == null) throw Exception('pull');
      final body = jsonDecode(res) as Map;
      if (body['ok'] != true) throw Exception(body['error'] ?? 'pull');
      final got = ((body['items'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

      // 3) terapkan data dari HP lain
      var applied = 0;
      for (final c in _cols) {
        final mine = got.where((e) => e['col'] == c.name && e['device'] != device).toList();
        if (mine.isEmpty) continue;
        await _apply(p, c, mine, pushed[c.name] ?? {});
        applied += mine.length;
      }

      // 4) catat kondisi terakhir
      final newSnap = <String, dynamic>{};
      for (final c in _cols) {
        final items = _flatten(c, await _readRaw(p, c, forPush: true));
        newSnap[c.name] = items.map((k, v) => MapEntry(k, _fnv(jsonEncode(_resolve(v)))));
      }
      await p.setString('hub_snap', jsonEncode(newSnap));
      await p.setInt('hub_rev', (body['rev'] as num?)?.toInt() ?? since);

      if (applied > 0) {
        await LapStore.refreshFromRadiation(); // laporan otomatis dari data baru
        statSync(); // statistik di spreadsheet = gabungan semua HP
      }
      lastPulled = applied;
      lastOk = DateTime.now();
      lastError = '';
      return true;
    } catch (_) {
      lastError = 'Sinkron antar HP tertunda (offline / web app belum diperbarui) · 同步暂停';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }
}

enum _Kind { list, month, map }

class _Col {
  final String name, pref, key, folder;
  final _Kind kind;
  final bool skipAuto, noDelete;
  const _Col(this.name, this.pref, this.kind,
      {this.key = '', this.folder = 'Lainnya', this.skipAuto = false, this.noDelete = false});
}
