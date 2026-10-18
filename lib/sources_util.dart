import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'radiation.dart' show kSourcesVer;

/// Daftar sumber terbaru (JSON). Bila HP masih menyimpan daftar versi lama,
/// pakai daftar bawaan aplikasi (assets/sources.json).
Future<String> sourcesJson(SharedPreferences p) async {
  try {
    final s = p.getString('sources');
    if (s != null && p.getString('sources_ver') == kSourcesVer) return s;
  } catch (_) {}
  try {
    return await rootBundle.loadString('assets/sources.json');
  } catch (_) {
    return '[]';
  }
}
