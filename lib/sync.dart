import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Sinkron otomatis kartu per pekerja ke Google Sheets.
///
/// Setiap kali data disimpan, kartu yang isinya berubah sejak kiriman
/// terakhir dikirim ulang (tab pekerja di spreadsheet diperbarui).
/// Bila HP sedang offline, kartu tetap ditandai belum terkirim dan
/// dicoba lagi saat data disimpan berikutnya atau saat menu dibuka.
class AutoSync {
  AutoSync(this.key);

  /// Kunci SharedPreferences untuk menyimpan isi kiriman terakhir.
  final String key;
  Map<String, String> _sent = {};
  bool _loaded = false;
  bool _busy = false;
  bool _again = false;
  int pending = 0;
  String lastError = '';

  void _load(SharedPreferences p) {
    if (_loaded) return;
    _loaded = true;
    try {
      final m = jsonDecode(p.getString(key) ?? '{}') as Map;
      _sent = m.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      _sent = {};
    }
  }

  /// Lupakan semua kiriman (mis. nomor dokumen diubah) agar semua kartu dikirim ulang.
  Future<void> resetAll(SharedPreferences? p) async {
    _sent = {};
    await p?.setString(key, '{}');
  }

  bool wasSent(String id) => _sent.containsKey(id);
  List<String> get sentIds => _sent.keys.toList();

  /// [cards]: id pekerja -> isi kiriman (JSON). [onChange] dipanggil saat status berubah.
  Future<void> run(SharedPreferences? p, String url, Map<String, Map<String, dynamic>> Function() cards,
      void Function() onChange) async {
    if (p == null) return;
    _load(p);
    if (url.trim().isEmpty) {
      pending = 0;
      return;
    }
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        final todo = <String, String>{};
        cards().forEach((id, body) {
          final s = jsonEncode(body);
          if (_sent[id] != s) todo[id] = s;
        });
        pending = todo.length;
        onChange();
        for (final e in todo.entries) {
          try {
            final res = await http
                .post(Uri.parse(url.trim()),
                    headers: {'Content-Type': 'text/plain;charset=utf-8'}, body: e.value)
                .timeout(const Duration(seconds: 60));
            if (res.statusCode >= 400) {
              lastError = 'Belum tersinkron (HTTP ${res.statusCode}). Periksa alamat web app.\n未同步，请检查 web app 地址。';
              _again = false;
              break;
            }
            _sent[e.key] = e.value;
            await p.setString(key, jsonEncode(_sent));
            pending--;
            lastError = '';
            onChange();
          } catch (_) {
            lastError = 'Tersimpan di HP. Belum tersinkron (offline) - dikirim otomatis nanti.\n已保存在手机，尚未同步（离线），稍后自动发送。';
            _again = false;
            break;
          }
        }
      } while (_again);
    } finally {
      _busy = false;
      onChange();
    }
  }
}
