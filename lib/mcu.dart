import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync.dart';
import 'tld.dart';
import 'i18n.dart';
import 'config.dart';

const String kMcuTitle = 'Kartu Pemantauan Kesehatan Pekerja';
const List<String> kMcuResults = ['FIT', 'Normal', 'Sehat'];

void _snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

String _two(int n) => n.toString().padLeft(2, '0');
String dmy(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
  return m == null ? iso : '${m.group(3)}/${m.group(2)}/${m.group(1)}';
}

String isoOf(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

class McuRec {
  String id;
  String year;
  String date; // yyyy-MM-dd, boleh kosong
  String result;
  String place;
  String note;
  McuRec({
    required this.id,
    this.year = '',
    this.date = '',
    this.result = '',
    this.place = '',
    this.note = '',
  });

  factory McuRec.fromJson(Map<String, dynamic> j) => McuRec(
        id: (j['id'] ?? '').toString(),
        year: (j['year'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        result: (j['result'] ?? '').toString(),
        place: (j['place'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'year': year,
        'date': date,
        'result': result,
        'place': place,
        'note': note,
      };
}

/// Pekerja diambil dari daftar yang sama dengan Kartu Dosis TLD.
class McuStore extends ChangeNotifier {
  final TldStore people = TldStore();
  SharedPreferences? p;
  Map<String, List<McuRec>> recs = {};
  Map<String, String> meta = {'docNo': '', 'docDate': '', 'rev': '', 'ppr': '', 'sheetUrl': ''};
  final sync = AutoSync('mcu_synced');
  String get lastError => sync.lastError;

  Future<void> load() async {
    await people.load();
    p = people.p;
    try {
      final m = jsonDecode(p!.getString('mcu') ?? '{}') as Map;
      recs = m.map((k, v) => MapEntry(
          k.toString(),
          (v as List)
              .map((e) => McuRec.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList()));
    } catch (_) {
      recs = {};
    }
    try {
      final m = jsonDecode(p!.getString('mcu_meta') ?? '{}') as Map;
      m.forEach((k, v) => meta[k.toString()] = v.toString());
    } catch (_) {}
    final d = meta['docNo'] ?? '';
    if (d.trim().isEmpty || d.contains('HYNC')) meta['docNo'] = '22/KKS-DI-SLRT/I/X/2026';
    if ((meta['ppr'] ?? '').isEmpty) meta['ppr'] = people.meta['ppr'] ?? '';
    if ((meta['sheetUrl'] ?? '').isEmpty) meta['sheetUrl'] = people.meta['sheetUrl'] ?? '';
    if (kRadSheetUrl.isNotEmpty) meta['sheetUrl'] = kRadSheetUrl;
    notifyListeners();
    autoSync();
  }

  List<McuRec> of(Worker w) {
    final l = recs[w.id] ?? [];
    l.sort((a, b) => '${a.year}${a.date}'.compareTo('${b.year}${b.date}'));
    return l;
  }

  McuRec? last(Worker w) {
    final l = of(w).where((r) => r.date.isNotEmpty || r.result.isNotEmpty).toList();
    return l.isEmpty ? null : l.last;
  }

  /// true bila MCU terakhir sudah lebih dari 1 tahun yang lalu (atau belum pernah).
  bool due(Worker w) {
    final r = last(w);
    if (r == null || r.date.isEmpty) return true;
    final d = DateTime.tryParse(r.date);
    if (d == null) return false;
    return DateTime.now().isAfter(DateTime(d.year + 1, d.month, d.day));
  }

  String lastPlace() {
    McuRec? best;
    for (final l in recs.values) {
      for (final r in l) {
        if (r.place.isEmpty) continue;
        if (best == null || r.date.compareTo(best.date) > 0) best = r;
      }
    }
    return best?.place ?? '';
  }

  Future<void> save() async {
    await p?.setString(
        'mcu', jsonEncode(recs.map((k, v) => MapEntry(k, v.map((r) => r.toJson()).toList()))));
    notifyListeners();
    autoSync();
  }

  Future<void> saveMeta() async {
    await p?.setString('mcu_meta', jsonEncode(meta));
    await sync.resetAll(p);
    notifyListeners();
    autoSync();
  }

  Map<String, dynamic> body(Worker w) => {
        'type': 'mcu',
        'meta': meta,
        'worker': w.toJson(),
        'records': of(w).map((r) => r.toJson()).toList(),
        'color': hexOf(kTldStatus[w.status] ?? const Color(0xFF999999)),
      };

  /// Kirim otomatis kartu yang berubah (hanya pekerja yang punya data).
  Future<void> autoSync() => sync.run(
      p,
      meta['sheetUrl'] ?? '',
      () => {
            for (final w in people.workers)
              if ((recs[w.id] ?? []).isNotEmpty || sync.wasSent(w.id)) w.id: body(w)
          },
      notifyListeners);

}

// ===================== Daftar pekerja =====================

class McuPage extends StatefulWidget {
  const McuPage({super.key});
  @override
  State<McuPage> createState() => _McuPageState();
}

class _McuPageState extends State<McuPage> {
  final store = McuStore();
  String q = '';
  String active = 'a';

  @override
  void initState() {
    super.initState();
    store.load();
  }

  Future<void> _editMeta() async {
    final c = {
      for (final k in ['docNo', 'docDate', 'rev', 'ppr'])
        k: TextEditingController(text: store.meta[k])
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Informasi dokumen (untuk spreadsheet) · 文件信息（用于表格）'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: c['docNo'], decoration: const InputDecoration(labelText: 'No. Dokumen · 文件编号')),
            TextField(controller: c['docDate'], decoration: const InputDecoration(labelText: 'Tgl. Dokumen · 文件日期')),
            TextField(controller: c['rev'], decoration: const InputDecoration(labelText: 'Rev. · 版本')),
            TextField(
                controller: c['ppr'],
                decoration: const InputDecoration(
                    labelText: 'Dibuat oleh (Petugas Proteksi Radiasi) · 编制人（辐射防护员）',
                    helperText: 'Hanya tampil di spreadsheet · 仅显示在表格中')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal 取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan 保存')),
        ],
      ),
    );
    if (ok == true) {
      c.forEach((k, v) => store.meta[k] = v.text.trim());
      await store.saveMeta();
    }
    for (final v in c.values) {
      v.dispose();
    }
  }

  Future<void> _addWorker() async {
    final res =
        await Navigator.of(context).push<Worker>(MaterialPageRoute(builder: (_) => const WorkerForm()));
    if (res == null) return;
    store.people.workers.add(res);
    await store.people.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final all = store.people.workers;
        final list = all.where((w) {
          if (active == 'a' && !isActive(w.status)) return false;
          if (active == 'n' && isActive(w.status)) return false;
          return q.isEmpty || w.name.toLowerCase().contains(q.toLowerCase());
        }).toList();
        final dueCount = all.where((w) => isActive(w.status) && store.due(w)).length;
        return Scaffold(
          appBar: AppBar(
            title: const Text(kMcuTitle),
            actions: [
              IconButton(
                  tooltip: 'Informasi dokumen · 文件信息',
                  icon: const Icon(Icons.description_outlined),
                  onPressed: _editMeta),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _addWorker,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Tambah pekerja · 添加人员'),
          ),
          body: store.p == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: [
                    if (dueCount > 0)
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFDE8E8),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$dueCount pekerja aktif belum MCU dalam 1 tahun terakhir.\n$dueCount 名在岗人员近 1 年未体检。',
                          style: const TextStyle(color: Color(0xFFB42318), fontWeight: FontWeight.w600),
                        ),
                      ),
                    TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Cari nama pekerja · 搜索人员姓名',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => q = v.trim()),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: '', label: Text('Semua 全部 (${all.length})')),
                        ButtonSegment(
                            value: 'a', label: Text('Aktif 在岗 (${all.where((w) => isActive(w.status)).length})')),
                        ButtonSegment(
                            value: 'n',
                            label: Text('Non Aktif 离岗 (${all.where((w) => !isActive(w.status)).length})')),
                      ],
                      selected: {active},
                      onSelectionChanged: (v) => setState(() => active = v.first),
                    ),
                    const SizedBox(height: 12),
                    if (all.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.outlineVariant),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(children: [
                          Icon(Icons.health_and_safety_outlined, size: 48, color: scheme.outline),
                          const SizedBox(height: 8),
                          const Text('Belum ada pekerja · 暂无人员', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            'Daftar pekerja sama dengan Kartu Dosis TLD. Tambahkan pekerja di sini '
                            'atau di menu Kartu Dosis, lalu isi hasil MCU tiap tahun.\n人员名单与 TLD 剂量卡相同。在此或剂量卡菜单添加人员，然后填写每年体检结果。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.outline),
                          ),
                        ]),
                      )
                    else if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('Tidak ada pekerja yang cocok. · 没有匹配的人员。')),
                      ),
                    for (final w in list) _tile(w),
                  ],
                ),
        );
      },
    );
  }

  Widget _tile(Worker w) {
    final scheme = Theme.of(context).colorScheme;
    final r = store.last(w);
    final due = isActive(w.status) && store.due(w);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => McuCardPage(store: store, worker: w)));
          setState(() {});
        },
        child: Row(children: [
          Container(width: 8, height: 72, color: kTldStatus[w.status]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(w.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              Text(
                r == null
                    ? 'Belum ada data MCU · 暂无体检数据'
                    : 'MCU terakhir · 上次体检 ${r.date.isEmpty ? r.year : dmy(r.date)} · ${r.result.isEmpty ? '-' : r.result}',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
              Text(bi(w.status), style: const TextStyle(fontSize: 12)),
            ]),
          ),
          if (due)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: const Color(0xFFFDE8E8), borderRadius: BorderRadius.circular(10)),
              child: const Text('Jadwal MCU · 需体检',
                  style: TextStyle(color: Color(0xFFB42318), fontSize: 11, fontWeight: FontWeight.bold)),
            ),
        ]),
      ),
    );
  }
}

// ===================== Kartu satu pekerja =====================

class McuCardPage extends StatefulWidget {
  final McuStore store;
  final Worker worker;
  const McuCardPage({super.key, required this.store, required this.worker});
  @override
  State<McuCardPage> createState() => _McuCardPageState();
}

class _McuCardPageState extends State<McuCardPage> {
  McuStore get store => widget.store;
  Worker get w => widget.worker;

  Future<void> _edit([McuRec? r]) async {
    final res = await Navigator.of(context).push<McuRec>(MaterialPageRoute(
        builder: (_) => McuForm(rec: r, defaultPlace: store.lastPlace(), list: store.of(w))));
    if (res == null) return;
    final l = store.recs.putIfAbsent(w.id, () => []);
    if (res.id == '__delete__') {
      l.removeWhere((x) => x.id == r?.id);
    } else {
      final i = l.indexWhere((x) => x.id == res.id);
      if (i >= 0) {
        l[i] = res;
      } else {
        l.add(res);
      }
    }
    await store.save();
    setState(() {});
  }

  String _tsv() {
    final l = store.of(w);
    final lines = <String>[
      kMcuTitle.toUpperCase(),
      'Nama\t${w.name}',
      'Instansi/Fasilitas\t${w.inst}',
      'No. Dokumen\t${store.meta['docNo']}',
      'Tgl. Dokumen\t${store.meta['docDate']}',
      'Rev.\t${store.meta['rev']}',
      '',
      [
        'No.',
        'Tahun Pemeriksaan Kesehatan (MCU)',
        'Tanggal Pemeriksaan Kesehatan (MCU)',
        'Resume Hasil Pemeriksaan Kesehatan (MCU) *',
        'Tempat Pelaksanaan (MCU)',
        'Keterangan'
      ].join('\t'),
    ];
    for (var i = 0; i < l.length; i++) {
      final r = l[i];
      lines.add([i + 1, r.year, dmy(r.date), r.result, r.place, r.note].join('\t'));
    }
    lines.addAll([
      '',
      '*) : Fit / Normal / Sehat',
      '',
      'Dibuat oleh,',
      store.meta['ppr'] ?? '',
      '(Petugas Proteksi Radiasi)',
    ]);
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final border = BorderSide(color: scheme.outlineVariant);
    final head = scheme.primaryContainer;
    final l = store.of(w);

    Widget cell(String t, double width,
            {bool bold = false, Color? bg, TextAlign align = TextAlign.center, double minH = 44}) =>
        Container(
          width: width,
          constraints: BoxConstraints(minHeight: minH),
          alignment: align == TextAlign.left ? Alignment.centerLeft : Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(color: bg, border: Border(right: border, bottom: border)),
          child: Text(t,
              textAlign: align, style: TextStyle(fontWeight: bold ? FontWeight.bold : null)),
        );

    final widths = [40.0, 110.0, 110.0, 110.0, 160.0, 200.0];
    final heads = [
      'No.\n序号',
      'Tahun Pemeriksaan Kesehatan (MCU)\n体检年份',
      'Tanggal Pemeriksaan Kesehatan (MCU)\n体检日期',
      'Resume Hasil Pemeriksaan Kesehatan (MCU) *\n体检结果摘要',
      'Tempat Pelaksanaan (MCU)\n体检地点',
      'Keterangan\n备注',
    ];
    final due = isActive(w.status) && store.due(w);

    return Scaffold(
      appBar: AppBar(title: Text(w.name, overflow: TextOverflow.ellipsis)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Tambah MCU · 添加体检'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
              child: Image.asset('assets/logo_mark.png', width: 76),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('KARTU PEMANTAUAN KESEHATAN PEKERJA\n工作人员健康监测卡',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ]),
          const SizedBox(height: 10),
          const SizedBox(height: 4),
          _kv('Nama · 姓名', w.name),
          _kv('Instansi/Fasilitas · 单位/设施', w.inst),
          _kv('Status · 状态', w.status),
          if (due)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l.isEmpty
                    ? 'Belum ada data MCU untuk pekerja ini.\n该人员暂无体检数据。'
                    : 'MCU terakhir sudah lebih dari 1 tahun. Jadwalkan pemeriksaan berikutnya.\n上次体检已超过 1 年，请安排下次体检。',
                style: const TextStyle(color: Color(0xFFB42318), fontWeight: FontWeight.w600),
              ),
            ),
          const SizedBox(height: 14),
          Text('Ketuk baris untuk mengubah atau menghapus data · 点击行可修改或删除',
              style: TextStyle(fontSize: 12, color: scheme.outline)),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(
              decoration: BoxDecoration(border: Border(left: border, top: border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < heads.length; i++)
                    cell(heads[i], widths[i], bold: true, bg: head, minH: 64),
                ])),
                if (l.isEmpty)
                  Row(children: [
                    cell('', widths[0]),
                    cell('Belum ada data. Tekan "Tambah MCU".\n暂无数据，请点击“添加体检”。',
                        widths.sublist(1).fold(0.0, (a, b) => a + b),
                        align: TextAlign.left),
                  ]),
                for (var i = 0; i < l.length; i++)
                  InkWell(
                    onTap: () => _edit(l[i]),
                    child: Row(children: [
                      cell('${i + 1}', widths[0]),
                      cell(l[i].year, widths[1]),
                      cell(dmy(l[i].date), widths[2]),
                      cell(l[i].result, widths[3], bold: true),
                      cell(l[i].place, widths[4]),
                      cell(l[i].note, widths[5], align: TextAlign.left),
                    ]),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          Text('*) : Fit / Normal / Sehat',
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: scheme.outline)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Salin untuk Excel · 复制到 Excel'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _tsv()));
                _snack(context, 'Kartu disalin. Tempel di Excel atau Google Sheets\n卡片已复制，可粘贴到 Excel 或 Google Sheets');
              },
            ),
            AnimatedBuilder(
              animation: store,
              builder: (context, _) {
                final none = (store.meta['sheetUrl'] ?? '').isEmpty;
                final wait = store.sync.pending > 0;
                final err = store.lastError.isNotEmpty;
                return OutlinedButton.icon(
                  icon: Icon(
                      none
                          ? Icons.cloud_off_outlined
                          : err
                              ? Icons.sync_problem
                              : wait
                                  ? Icons.sync
                                  : Icons.cloud_done_outlined,
                      color: err ? const Color(0xFFC8202E) : null),
                  label: Text(none
                      ? 'Spreadsheet belum tertanam · 未设置表格'
                      : err
                          ? 'Belum tersinkron · 未同步，重试'
                          : wait
                              ? 'Menyinkronkan… · 同步中…'
                              : 'Tersinkron otomatis · 已自动同步'),
                  onPressed: () {
                    if (none) {
                      _snack(context, 'Spreadsheet belum tertanam di aplikasi · 应用未设置表格');
                      return;
                    }
                    if (err) _snack(context, store.lastError);
                    store.autoSync();
                  },
                );
              },
            ),
          ]),
        ],
      ),
    );
  }

  Widget _kv(String k, String? v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 170, child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.outline))),
          Expanded(child: Text(': ${(v ?? '').isEmpty ? '-' : v}')),
        ]),
      );
}

// ===================== Form satu pemeriksaan =====================

class McuForm extends StatefulWidget {
  final McuRec? rec;
  final String defaultPlace;
  final List<McuRec> list;
  const McuForm({super.key, this.rec, this.defaultPlace = '', this.list = const []});
  @override
  State<McuForm> createState() => _McuFormState();
}

class _McuFormState extends State<McuForm> {
  late final McuRec r = widget.rec == null
      ? McuRec(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          year: '${DateTime.now().year}',
          place: widget.defaultPlace)
      : McuRec.fromJson(widget.rec!.toJson());
  late final year = TextEditingController(text: r.year);
  late final result = TextEditingController(text: r.result);
  late final place = TextEditingController(text: r.place);
  late final note = TextEditingController(text: r.note);

  @override
  void dispose() {
    for (final c in [year, result, place, note]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.rec != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit pemeriksaan · 编辑体检' : 'Tambah pemeriksaan (MCU) · 添加体检'),
        actions: [
          if (editing)
            IconButton(
              tooltip: 'Hapus 删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    content: const Text('Hapus data pemeriksaan ini? · 删除此体检数据？'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal 取消')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus 删除')),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  Navigator.pop(context, McuRec(id: '__delete__'));
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(r.date.isEmpty ? 'Pilih tanggal pemeriksaan · 选择体检日期' : 'Tanggal · 日期: ${dmy(r.date)}'),
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: DateTime.tryParse(r.date) ?? DateTime.now(),
                firstDate: DateTime(2015),
                lastDate: DateTime(2100),
              );
              if (d != null) {
                setState(() {
                  r.date = isoOf(d);
                  year.text = '${d.year}';
                });
              }
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: year,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Tahun Pemeriksaan Kesehatan (MCU) · 体检年份', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          const Text('Resume Hasil Pemeriksaan Kesehatan (MCU) · 体检结果',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final o in kMcuResults)
              ChoiceChip(
                label: Text(bi(o)),
                selected: result.text == o,
                onSelected: (_) => setState(() => result.text = o),
              ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: result,
            decoration: const InputDecoration(
                labelText: 'Atau tulis hasil lain · 或填写其他结果', isDense: true, border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: place,
            decoration:
                const InputDecoration(labelText: 'Tempat Pelaksanaan (MCU) · 体检地点', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Keterangan · 备注', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (year.text.trim().isEmpty) {
                _snack(context, 'Tahun pemeriksaan wajib diisi · 体检年份为必填项');
                return;
              }
              r
                ..year = year.text.trim()
                ..result = result.text.trim()
                ..place = place.text.trim()
                ..note = note.text.trim();
              Navigator.pop(context, r);
            },
            child: const Text('Simpan 保存'),
          ),
        ],
      ),
    );
  }
}
