import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'i18n.dart';

const List<String> kDocCats = [
  'Regulasi',
  'Izin BAPETEN',
  'SOP',
  'Program & Laporan',
  'Lainnya',
];

const Map<String, IconData> kCatIcons = {
  'Regulasi': Icons.gavel_rounded,
  'Izin BAPETEN': Icons.verified_rounded,
  'SOP': Icons.rule_rounded,
  'Program & Laporan': Icons.assignment_rounded,
  'Lainnya': Icons.folder_rounded,
};

class Doc {
  String id;
  String title;
  String number;
  String category;
  String date;
  String url;
  String file;
  String fileName;
  String note;
  Doc({
    required this.id,
    this.title = '',
    this.number = '',
    this.category = 'Regulasi',
    this.date = '',
    this.url = '',
    this.file = '',
    this.fileName = '',
    this.note = '',
  });

  factory Doc.fromJson(Map<String, dynamic> j) => Doc(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        number: (j['number'] ?? '').toString(),
        category: (j['category'] ?? 'Lainnya').toString(),
        date: (j['date'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        file: (j['file'] ?? '').toString(),
        fileName: (j['fileName'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'number': number,
        'category': category,
        'date': date,
        'url': url,
        'file': file,
        'fileName': fileName,
        'note': note,
      };
}

void _snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

class DocumentsPage extends StatefulWidget {
  const DocumentsPage({super.key});
  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

class _DocumentsPageState extends State<DocumentsPage> {
  SharedPreferences? p;
  List<Doc> docs = [];
  String cat = '';
  String q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    p = await SharedPreferences.getInstance();
    try {
      docs = (jsonDecode(p!.getString('documents') ?? '[]') as List)
          .map((e) => Doc.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      docs = [];
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    await p?.setString('documents', jsonEncode(docs.map((d) => d.toJson()).toList()));
    if (mounted) setState(() {});
  }

  Future<void> _open(Doc d) async {
    if (d.file.isNotEmpty && File(d.file).existsSync()) {
      final r = await OpenFilex.open(d.file);
      if (r.type != ResultType.done && mounted) {
        _snack(context, 'Tidak ada aplikasi untuk membuka file ini (${r.message}).\n没有可打开此文件的应用。');
      }
      return;
    }
    if (d.url.isNotEmpty) {
      final u = Uri.tryParse(d.url.startsWith('http') ? d.url : 'https://${d.url}');
      if (u == null || !await launchUrl(u, mode: LaunchMode.externalApplication)) {
        if (mounted) _snack(context, 'Tautan tidak bisa dibuka. · 无法打开链接。');
      }
      return;
    }
    _snack(context, 'Dokumen ini belum punya file atau tautan.\n此文件尚无附件或链接。');
  }

  Future<void> _edit([Doc? d]) async {
    final res = await Navigator.of(context).push<Doc>(
      MaterialPageRoute(builder: (_) => DocForm(doc: d)),
    );
    if (res == null) return;
    final i = docs.indexWhere((x) => x.id == res.id);
    if (i >= 0) {
      docs[i] = res;
    } else {
      docs.insert(0, res);
    }
    await _save();
  }

  Future<void> _delete(Doc d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('Hapus “${d.title}”? · 删除“${d.title}”？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal 取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus 删除')),
        ],
      ),
    );
    if (ok != true) return;
    if (d.file.isNotEmpty) {
      try {
        File(d.file).deleteSync();
      } catch (_) {}
    }
    docs.removeWhere((x) => x.id == d.id);
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = docs.where((d) {
      if (cat.isNotEmpty && d.category != cat) return false;
      if (q.isEmpty) return true;
      final s = '${d.title} ${d.number} ${d.note}'.toLowerCase();
      return s.contains(q.toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Dokumen & Regulasi · 文件与法规')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Tambah dokumen · 添加文件'),
      ),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Cari judul, nomor, atau catatan · 搜索标题、编号或备注',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => q = v.trim()),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text('Semua 全部 (${docs.length})'),
                        selected: cat.isEmpty,
                        onSelected: (_) => setState(() => cat = ''),
                      ),
                    ),
                    for (final c in kDocCats)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text('${bi(c)} (${docs.where((d) => d.category == c).length})'),
                          selected: cat == c,
                          onSelected: (_) => setState(() => cat = c),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 12),
                if (docs.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.outlineVariant),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(children: [
                      Icon(Icons.folder_open_rounded, size: 48, color: scheme.outline),
                      const SizedBox(height: 8),
                      const Text('Belum ada dokumen · 暂无文件',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        'Tekan "Tambah dokumen" untuk menyimpan regulasi, izin BAPETEN, '
                        'atau SOP. Lampirkan file PDF dari HP atau tempel tautan Google Drive.\n点击“添加文件”保存法规、BAPETEN 许可证或 SOP。可附加手机中的 PDF 或粘贴 Google Drive 链接。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.outline),
                      ),
                    ]),
                  )
                else if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('Tidak ada dokumen yang cocok. · 没有匹配的文件。')),
                  ),
                for (final d in list)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: scheme.primaryContainer,
                        child: Icon(kCatIcons[d.category] ?? Icons.folder_rounded,
                            color: scheme.onPrimaryContainer),
                      ),
                      title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text([
                        if (d.number.isNotEmpty) d.number,
                        d.category,
                        if (d.date.isNotEmpty) d.date,
                        if (d.file.isNotEmpty) 'File: ${d.fileName}' else if (d.url.isNotEmpty) 'Tautan',
                      ].join(' · ')),
                      onTap: () => _open(d),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) => v == 'edit' ? _edit(d) : _delete(d),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit 编辑')),
                          PopupMenuItem(value: 'del', child: Text('Hapus 删除')),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class DocForm extends StatefulWidget {
  final Doc? doc;
  const DocForm({super.key, this.doc});
  @override
  State<DocForm> createState() => _DocFormState();
}

class _DocFormState extends State<DocForm> {
  late final Doc d = widget.doc == null
      ? Doc(id: DateTime.now().microsecondsSinceEpoch.toString())
      : Doc.fromJson(widget.doc!.toJson());
  late final title = TextEditingController(text: d.title);
  late final number = TextEditingController(text: d.number);
  late final date = TextEditingController(text: d.date);
  late final url = TextEditingController(text: d.url);
  late final note = TextEditingController(text: d.note);

  @override
  void dispose() {
    for (final c in [title, number, date, url, note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final r = await FilePicker.platform.pickFiles(withData: false);
      final f = r?.files.single;
      if (f == null || f.path == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/dokumen');
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final dest = '${folder.path}/${d.id}_${f.name}';
      await File(f.path!).copy(dest);
      if (d.file.isNotEmpty && d.file != dest) {
        try {
          File(d.file).deleteSync();
        } catch (_) {}
      }
      setState(() {
        d.file = dest;
        d.fileName = f.name;
        if (title.text.trim().isEmpty) {
          title.text = f.name.replaceAll(RegExp(r'\.[^.]+$'), '');
        }
      });
    } catch (e) {
      if (mounted) _snack(context, 'File tidak bisa diambil. · 无法获取文件。');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.doc == null ? 'Tambah dokumen · 添加文件' : 'Edit dokumen · 编辑文件')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: title,
            decoration: const InputDecoration(
                labelText: 'Judul dokumen · 文件标题', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: kDocCats.contains(d.category) ? d.category : 'Lainnya',
            decoration:
                const InputDecoration(labelText: 'Kategori · 类别', border: OutlineInputBorder()),
            items: kDocCats.map((c) => DropdownMenuItem(value: c, child: Text(bi(c)))).toList(),
            onChanged: (v) => d.category = v ?? 'Lainnya',
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: number,
                decoration: const InputDecoration(
                    labelText: 'Nomor (opsional) · 编号（可选）', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: date,
                decoration: const InputDecoration(
                    labelText: 'Tanggal / berlaku s.d. · 日期 / 有效期至', border: OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.attach_file),
            label: Text(d.file.isEmpty ? 'Lampirkan file dari HP · 从手机附加文件' : 'Ganti file · 更换文件: ${d.fileName}'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Atau tautan (Google Drive, JDIH, dll.) · 或链接',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
                labelText: 'Catatan (opsional) · 备注（可选）', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (title.text.trim().isEmpty) {
                _snack(context, 'Judul wajib diisi · 标题为必填项');
                return;
              }
              d
                ..title = title.text.trim()
                ..number = number.text.trim()
                ..date = date.text.trim()
                ..url = url.text.trim()
                ..note = note.text.trim();
              Navigator.pop(context, d);
            },
            child: const Text('Simpan 保存'),
          ),
        ],
      ),
    );
  }
}
