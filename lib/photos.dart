import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// Foto dokumentasi: disimpan di HP, lalu diunggah ke Google Drive
/// (folder "SLRT Apps - Spreadsheet/Foto/<jenis>") lewat web app yang sama.
/// Spreadsheet menyimpan link fotonya di kolom "Foto".
class Photos {
  static Map<String, String> _urls = {}; // path lokal -> link Drive
  static bool _loaded = false;

  /// Panggil sekali saat modul dibuka agar link foto lama terbaca.
  static Future<void> init() async {
    await _p();
  }

  static Future<SharedPreferences> _p() async {
    final p = await SharedPreferences.getInstance();
    if (!_loaded) {
      _loaded = true;
      try {
        _urls = Map<String, String>.from(jsonDecode(p.getString('photo_urls') ?? '{}') as Map);
      } catch (_) {
        _urls = {};
      }
    }
    return p;
  }

  /// Link Drive bila sudah terunggah (atau bila isinya memang sudah link).
  static String? urlOf(String path) => path.startsWith('http') ? path : _urls[path];

  /// Daftar link untuk dikirim ke spreadsheet (foto yang belum terunggah dilewati).
  static List<String> urls(Iterable<String> paths) =>
      paths.map(urlOf).whereType<String>().toList();

  /// Unggah semua foto yang belum punya link. Mengembalikan false bila ada yang gagal.
  static Future<bool> upload(Iterable<String> paths, String folder) async {
    final p = await _p();
    final url = kRadSheetUrl.trim();
    if (url.isEmpty) return false;
    var ok = true;
    for (final path in paths) {
      if (path.startsWith('http') || _urls.containsKey(path)) continue;
      final f = File(path);
      if (!await f.exists()) continue;
      try {
        final body = await _postJson(url, {
          'type': 'photo',
          'folder': folder,
          'name': path.split('/').last,
          'mime': 'image/jpeg',
          'data': base64Encode(await f.readAsBytes()),
        });
        final link = body == null ? null : (jsonDecode(body) as Map)['url']?.toString();
        if (link == null || link.isEmpty) {
          ok = false;
          continue;
        }
        _urls[path] = link;
        await p.setString('photo_urls', jsonEncode(_urls));
      } catch (_) {
        ok = false;
        break; // kemungkinan offline: coba lagi nanti
      }
    }
    return ok;
  }

  /// POST ke Apps Script lalu ikuti redirect (302) untuk membaca jawabannya.
  static Future<String?> _postJson(String url, Map<String, dynamic> data) async {
    final c = http.Client();
    try {
      var res = await c
          .post(Uri.parse(url),
              headers: {'Content-Type': 'text/plain;charset=utf-8'}, body: jsonEncode(data))
          .timeout(const Duration(seconds: 120));
      if (res.statusCode == 302 || res.statusCode == 303 || res.statusCode == 301) {
        final loc = res.headers['location'];
        if (loc == null) return null;
        res = await c.get(Uri.parse(loc)).timeout(const Duration(seconds: 60));
      }
      if (res.statusCode >= 400) return null;
      return res.body;
    } finally {
      c.close();
    }
  }

  /// Ambil foto dari kamera / galeri, kompres, dan simpan di folder aplikasi.
  static Future<String?> pick(BuildContext context) async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Kamera · 相机'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Galeri · 相册'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (src == null) return null;
    final x = await ImagePicker().pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 70);
    if (x == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/foto');
    if (!await folder.exists()) await folder.create(recursive: true);
    final path = '${folder.path}/IMG_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(x.path).copy(path);
    return path;
  }
}

/// Deretan foto + tombol tambah. Ketuk foto untuk melihat, tekan × untuk menghapus.
class PhotoField extends StatelessWidget {
  const PhotoField({super.key, required this.photos, required this.onChanged, this.label});
  final List<String> photos;
  final ValueChanged<List<String>> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget thumb(String p) {
      final img = p.startsWith('http')
          ? Image.network(p, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image))
          : Image.file(File(p), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image));
      return Stack(children: [
        GestureDetector(
          onTap: () => showDialog(
              context: context,
              builder: (_) => Dialog(child: InteractiveViewer(child: img))),
          child: ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: 72, height: 72, child: img)),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: InkWell(
            onTap: () => onChanged([...photos]..remove(p)),
            child: Container(
              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              padding: const EdgeInsets.all(2),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
        if (Photos.urlOf(p) != null)
          const Positioned(
              left: 3, bottom: 3, child: Icon(Icons.cloud_done, size: 14, color: Colors.white)),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label ?? 'Foto · 照片', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in photos) thumb(p),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            final p = await Photos.pick(context);
            if (p != null) onChanged([...photos, p]);
          },
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
                border: Border.all(color: scheme.outline), borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.add_a_photo_outlined, color: scheme.primary),
          ),
        ),
      ]),
    ]);
  }
}
