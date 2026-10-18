import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync.dart';
import 'i18n.dart';
import 'config.dart';

const String kTldTitle = 'Kartu Dosis Pekerja Radiasi (TLD)';
const List<String> kQuartersZh = ['1–3 月', '4–6 月', '7–9 月', '10–12 月'];
const List<String> kQuarters = [
  'Januari - Maret',
  'April - Juni',
  'Juli - September',
  'Oktober - Desember',
];

/// Status pekerja dan warnanya, sesuai keterangan di spreadsheet.
const Map<String, Color> kTldStatus = {
  'PPR Aktif': Color(0xFF00B050),
  'Pekerja Radiasi Gauging Aktif': Color(0xFF92D050),
  'Pekerja Radiasi XRF Aktif': Color(0xFFC6E0B4),
  'PPR Non Aktif': Color(0xFFFF0000),
  'Pekerja Radiasi Gauging Non Aktif': Color(0xFFFFFF00),
  'Pekerja Radiasi XRF Non Aktif': Color(0xFFA6A6A6),
};

const List<String> kTldRoles = ['PPR', 'Pekerja Radiasi Gauging', 'Pekerja Radiasi XRF'];

bool isActive(String status) => !status.endsWith('Non Aktif');
String roleOf(String status) =>
    status.replaceFirst(RegExp(r' (Non )?Aktif$'), '');
String statusOf(String role, bool active) => '$role ${active ? 'Aktif' : 'Non Aktif'}';
String hexOf(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

Color statusText(String s) =>
    (s == 'PPR Aktif' || s == 'PPR Non Aktif') ? Colors.white : Colors.black;

/// Angka di depan nilai dosis, mis. "0.19±15%" -> 0.19.
double? doseNum(String v) {
  final m = RegExp(r'^\s*(-?\d+(?:[.,]\d+)?)').firstMatch(v);
  if (m == null) return null;
  return double.tryParse(m.group(1)!.replaceAll(',', '.'));
}

String fmtNum(double x) {
  var t = x.toStringAsFixed(3);
  t = t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return t;
}

void _snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

class Worker {
  String id;
  String name;
  String inst;
  String tld;
  String status;
  Map<String, List<String>> years; // "2025" -> 4 nilai triwulan
  List<String> notes; // keterangan per triwulan
  Worker({
    required this.id,
    this.name = '',
    this.inst = 'PT Sulawesi Recycling Technology / Gauging Industri',
    this.tld = '',
    this.status = 'Pekerja Radiasi Gauging Aktif',
    Map<String, List<String>>? years,
    List<String>? notes,
  })  : years = years ?? {},
        notes = notes ?? List.filled(4, '');

  List<String> get yearList => years.keys.toList()..sort();

  double totalOf(String y) =>
      (years[y] ?? []).map(doseNum).whereType<double>().fold(0.0, (a, b) => a + b);

  bool hasValue(String y) => (years[y] ?? []).any((v) => v.trim().isNotEmpty);

  factory Worker.fromJson(Map<String, dynamic> j) {
    final y = <String, List<String>>{};
    ((j['years'] as Map?) ?? {}).forEach((k, v) {
      final l = (v as List).map((e) => (e ?? '').toString()).toList();
      while (l.length < 4) {
        l.add('');
      }
      y[k.toString()] = l.sublist(0, 4);
    });
    final n = ((j['notes'] as List?) ?? []).map((e) => (e ?? '').toString()).toList();
    while (n.length < 4) {
      n.add('');
    }
    return Worker(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      inst: (j['inst'] ?? '').toString(),
      tld: (j['tld'] ?? '').toString(),
      status: kTldStatus.containsKey(j['status']) ? j['status'] as String : 'Pekerja Radiasi Gauging Aktif',
      years: y,
      notes: n.sublist(0, 4),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'inst': inst,
        'tld': tld,
        'status': status,
        'years': years,
        'notes': notes,
      };
}

class TldStore extends ChangeNotifier {
  SharedPreferences? p;
  List<Worker> workers = [];
  Map<String, String> meta = {
    'docNo': '',
    'docDate': '',
    'rev': '',
    'unit': 'mSv',
    'ppr': '',
    'sheetUrl': '',
  };
  final sync = AutoSync('tld_synced');
  String get lastError => sync.lastError;

  Future<void> load() async {
    p = await SharedPreferences.getInstance();
    try {
      workers = (jsonDecode(p!.getString('tld_workers') ?? '[]') as List)
          .map((e) => Worker.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      workers = [];
    }
    try {
      final m = jsonDecode(p!.getString('tld_meta') ?? '{}') as Map;
      m.forEach((k, v) => meta[k.toString()] = v.toString());
    } catch (_) {}
    final d = meta['docNo'] ?? '';
    if (d.trim().isEmpty || d.contains('HYNC')) meta['docNo'] = '20/KDT-DI-SLRT/I/X/2026';
    if ((meta['sheetUrl'] ?? '').isEmpty) {
      meta['sheetUrl'] = p!.getString('rad_sheet_url') ?? '';
    }
    if (kRadSheetUrl.isNotEmpty) meta['sheetUrl'] = kRadSheetUrl;
    notifyListeners();
    autoSync();
  }

  Future<void> save() async {
    await p?.setString('tld_workers', jsonEncode(workers.map((w) => w.toJson()).toList()));
    notifyListeners();
    autoSync();
  }

  Map<String, dynamic> body(Worker w) => {
        'type': 'tld',
        'meta': meta,
        'worker': w.toJson(),
        'color': hexOf(kTldStatus[w.status] ?? const Color(0xFF999999)),
      };

  /// Kirim otomatis semua kartu yang berubah ke Google Sheets (tab per pekerja).
  Future<void> autoSync() => sync.run(p, meta['sheetUrl'] ?? '',
      () => {for (final w in workers) w.id: body(w)}, notifyListeners);

  Future<void> saveMeta() async {
    await p?.setString('tld_meta', jsonEncode(meta));
    await sync.resetAll(p);
    notifyListeners();
    autoSync();
  }
}

// ===================== Daftar pekerja =====================

class TldPage extends StatefulWidget {
  const TldPage({super.key});
  @override
  State<TldPage> createState() => _TldPageState();
}

class _TldPageState extends State<TldPage> {
  final store = TldStore();
  String q = '';
  String status = '';
  String active = ''; // '', 'a', 'n'

  @override
  void initState() {
    super.initState();
    store.load();
  }

  Future<void> _editWorker([Worker? w]) async {
    final res = await Navigator.of(context).push<Worker>(
        MaterialPageRoute(builder: (_) => WorkerForm(worker: w)));
    if (res == null) return;
    final i = store.workers.indexWhere((x) => x.id == res.id);
    if (i >= 0) {
      store.workers[i] = res;
    } else {
      store.workers.add(res);
    }
    await store.save();
  }

  Future<void> _editMeta() async {
    final c = {
      for (final k in ['docNo', 'docDate', 'rev', 'ppr'])
        k: TextEditingController(text: store.meta[k])
    };
    var unit = store.meta['unit'] == 'mrem' ? 'mrem' : 'mSv';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
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
              const SizedBox(height: 12),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'mSv', label: Text('mSv')),
                  ButtonSegment(value: 'mrem', label: Text('mrem')),
                ],
                selected: {unit},
                onSelectionChanged: (v) => setD(() => unit = v.first),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal 取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan 保存')),
          ],
        ),
      ),
    );
    if (ok == true) {
      c.forEach((k, v) => store.meta[k] = v.text.trim());
      store.meta['unit'] = unit;
      await store.saveMeta();
    }
    for (final v in c.values) {
      v.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final list = store.workers.where((w) {
          if (status.isNotEmpty && w.status != status) return false;
          if (active == 'a' && !isActive(w.status)) return false;
          if (active == 'n' && isActive(w.status)) return false;
          if (q.isEmpty) return true;
          return '${w.name} ${w.tld}'.toLowerCase().contains(q.toLowerCase());
        }).toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text(kTldTitle),
            actions: [
              IconButton(
                  tooltip: 'Informasi dokumen · 文件信息',
                  icon: const Icon(Icons.description_outlined),
                  onPressed: _editMeta),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _editWorker(),
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Tambah pekerja · 添加人员'),
          ),
          body: store.p == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Cari nama atau nomor TLD · 搜索姓名或 TLD 编号',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => q = v.trim()),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: '', label: Text('Semua 全部 (${store.workers.length})')),
                        ButtonSegment(
                            value: 'a',
                            label: Text('Aktif 在岗 (${store.workers.where((w) => isActive(w.status)).length})')),
                        ButtonSegment(
                            value: 'n',
                            label: Text(
                                'Non Aktif 离岗 (${store.workers.where((w) => !isActive(w.status)).length})')),
                      ],
                      selected: {active},
                      onSelectionChanged: (v) => setState(() => active = v.first),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: status,
                      isExpanded: true,
                      decoration: const InputDecoration(
                          labelText: 'Status · 状态', border: OutlineInputBorder(), isDense: true),
                      items: [
                        DropdownMenuItem(value: '', child: Text('Semua status · 全部状态 (${store.workers.length})')),
                        for (final e in kTldStatus.entries)
                          DropdownMenuItem(
                            value: e.key,
                            child: Row(children: [
                              Container(width: 14, height: 14, color: e.value),
                              const SizedBox(width: 8),
                              Flexible(
                                  child: Text(
                                      '${bi(e.key)} (${store.workers.where((w) => w.status == e.key).length})',
                                      overflow: TextOverflow.ellipsis)),
                            ]),
                          ),
                      ],
                      onChanged: (v) => setState(() => status = v ?? ''),
                    ),
                    const SizedBox(height: 12),
                    if (store.workers.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.outlineVariant),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(children: [
                          Icon(Icons.badge_outlined, size: 48, color: scheme.outline),
                          const SizedBox(height: 8),
                          const Text('Belum ada pekerja radiasi · 暂无辐射工作人员',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            'Tekan "Tambah pekerja · 添加人员" untuk membuat kartu dosis. '
                            'Setiap pekerja punya satu kartu berisi dosis TLD per triwulan.\n点击“添加人员”创建剂量卡，每人一张季度 TLD 剂量卡。',
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
                    for (final w in list)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => WorkerCardPage(store: store, worker: w)));
                            setState(() {});
                          },
                          child: Row(children: [
                            Container(width: 8, height: 76, color: kTldStatus[w.status]),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(w.name,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                  Text('TLD ${w.tld.isEmpty ? '-' : w.tld}',
                                      style: TextStyle(color: scheme.outline, fontSize: 12)),
                                  const SizedBox(height: 4),
                                  Text(bi(w.status), style: const TextStyle(fontSize: 12)),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    w.yearList.isEmpty
                                        ? '-'
                                        : '${fmtNum(w.totalOf(w.yearList.last))} ${store.meta['unit']}',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  Text(w.yearList.isEmpty ? '' : 'Total 合计 ${w.yearList.last}',
                                      style: TextStyle(fontSize: 11, color: scheme.outline)),
                                ],
                              ),
                            ),
                          ]),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 10, runSpacing: 4, children: [
                      for (final e in kTldStatus.entries)
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(width: 12, height: 12, color: e.value),
                          const SizedBox(width: 4),
                          Text(bi(e.key), style: const TextStyle(fontSize: 11)),
                        ]),
                    ]),
                  ],
                ),
        );
      },
    );
  }
}

// ===================== Kartu dosis satu pekerja =====================

class WorkerCardPage extends StatefulWidget {
  final TldStore store;
  final Worker worker;
  const WorkerCardPage({super.key, required this.store, required this.worker});
  @override
  State<WorkerCardPage> createState() => _WorkerCardPageState();
}

class _WorkerCardPageState extends State<WorkerCardPage> {
  Worker get w => widget.worker;
  TldStore get store => widget.store;

  Future<String?> _ask(String title, String value, {bool number = false}) async {
    final c = TextEditingController(text: value);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          decoration: InputDecoration(
              hintText: number ? 'mis. 0 atau 0.19±15%' : '', border: const OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal 取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Simpan 保存')),
        ],
      ),
    );
    c.dispose();
    return r;
  }

  Future<void> _addYear() async {
    final ys = w.yearList;
    final next = ys.isEmpty ? DateTime.now().year : int.parse(ys.last) + 1;
    final r = await _ask('Tambah tahun · 添加年份', '$next', number: true);
    final y = int.tryParse((r ?? '').trim());
    if (y == null || w.years.containsKey('$y')) return;
    w.years['$y'] = List.filled(4, '');
    await store.save();
    setState(() {});
  }

  Future<void> _removeYear(String y) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('Hapus kolom tahun $y beserta nilainya?\n删除 $y 年列及其数值？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal 取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus 删除')),
        ],
      ),
    );
    if (ok != true) return;
    w.years.remove(y);
    await store.save();
    setState(() {});
  }

  String _tsv() {
    final ys = w.yearList;
    final lines = <String>[
      kTldTitle,
      'Nama\t${w.name}',
      'Instansi/Fasilitas\t${w.inst}',
      'Nomor TLD\t${w.tld}',
      'Status\t${w.status}',
      'Satuan\t${store.meta['unit']}',
      '',
      ['No.', 'Periode Pemakaian', ...ys, 'Keterangan'].join('\t'),
    ];
    for (var i = 0; i < 4; i++) {
      lines.add([i + 1, kQuarters[i], ...ys.map((y) => w.years[y]![i]), w.notes[i]].join('\t'));
    }
    lines.add(['', 'Total Penerimaan Dosis', ...ys.map((y) => w.hasValue(y) ? fmtNum(w.totalOf(y)) : '')]
        .join('\t'));
    lines.addAll([
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
    final ys = w.yearList;
    final unit = store.meta['unit'] ?? 'mSv';

    Widget cell(String t,
            {double width = 82,
            bool bold = false,
            Color? bg,
            Color? fg,
            bool italic = false,
            TextAlign align = TextAlign.center,
            VoidCallback? onTap,
            double minH = 40}) =>
        InkWell(
          onTap: onTap,
          child: Container(
            width: width,
            constraints: BoxConstraints(minHeight: minH),
            alignment: align == TextAlign.left ? Alignment.centerLeft : Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(color: bg, border: Border(right: border, bottom: border)),
            child: Text(t,
                textAlign: align,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.bold : null,
                    fontStyle: italic ? FontStyle.italic : null,
                    color: fg)),
          ),
        );

    final over = unit == 'mSv' ? ys.where((y) => w.totalOf(y) > 20).toList() : <String>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(w.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Edit identitas · 编辑身份信息',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final res = await Navigator.of(context)
                  .push<Worker>(MaterialPageRoute(builder: (_) => WorkerForm(worker: w)));
              if (res == null) return;
              w
                ..name = res.name
                ..inst = res.inst
                ..tld = res.tld
                ..status = res.status;
              await store.save();
              setState(() {});
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'del') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    content: Text('Hapus kartu dosis ${w.name}?\n删除 ${w.name} 的剂量卡？'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal 取消')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus 删除')),
                    ],
                  ),
                );
                if (ok == true) {
                  store.workers.removeWhere((x) => x.id == w.id);
                  await store.save();
                  if (context.mounted) Navigator.pop(context);
                }
              }
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'del', child: Text('Hapus pekerja · 删除人员'))],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
              child: Image.asset('assets/logo_mark.png', width: 76),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('KARTU DOSIS PEKERJA RADIASI (TLD)\n辐射工作人员剂量卡',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ]),
          const SizedBox(height: 10),
          const SizedBox(height: 4),
          _kv('Nama · 姓名', w.name),
          _kv('Instansi/Fasilitas · 单位/设施', w.inst),
          _kv('Nomor TLD · TLD 编号', w.tld),
          _kv('Satuan · 单位', unit),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              SizedBox(width: 170, child: Text('Status · 状态', style: TextStyle(color: scheme.outline))),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: kTldStatus[w.status], borderRadius: BorderRadius.circular(12)),
                  child: Text(bi(w.status),
                      style: TextStyle(
                          color: statusText(w.status), fontWeight: FontWeight.w600, fontSize: 12)),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 130, top: 6),
            child: Align(
             alignment: Alignment.centerLeft,
             child: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: true, label: Text('Aktif 在岗')),
                ButtonSegment(value: false, label: Text('Non Aktif 离岗')),
              ],
              selected: {isActive(w.status)},
              onSelectionChanged: (v) async {
                setState(() => w.status = statusOf(roleOf(w.status), v.first));
                await store.save();
              },
            ),
            ),
          ),
          const SizedBox(height: 14),
          Text('Tahun Penerimaan · ketuk sel untuk mengisi atau mengubah nilai\n接受年份 · 点击单元格填写或修改数值',
              style: TextStyle(fontSize: 12, color: scheme.outline)),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(
              decoration: BoxDecoration(border: Border(left: border, top: border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  cell('No.\n序号', width: 40, bold: true, bg: head),
                  cell('Periode Pemakaian\n使用期间', width: 140, bold: true, bg: head),
                  for (final y in ys)
                    cell('$y 年', bold: true, bg: head, onTap: () => _removeYear(y)),
                  cell('+ Tahun\n添加年份', width: 76, bg: head, fg: scheme.primary, bold: true, onTap: _addYear),
                  cell('Keterangan\n备注', width: 200, bold: true, bg: head),
                ])),
                for (var i = 0; i < 4; i++)
                  IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    cell('${i + 1}', width: 40),
                    cell('${kQuarters[i]}\n${kQuartersZh[i]}', width: 140),
                    for (final y in ys)
                      cell(w.years[y]![i], onTap: () async {
                        final r = await _ask('${kQuarters[i]} $y ($unit)', w.years[y]![i], number: true);
                        if (r == null) return;
                        w.years[y]![i] = r.trim();
                        await store.save();
                        setState(() {});
                      }),
                    cell('', width: 76),
                    cell(w.notes[i], width: 200, align: TextAlign.left, onTap: () async {
                      final r = await _ask('Keterangan ${kQuarters[i]}', w.notes[i]);
                      if (r == null) return;
                      w.notes[i] = r.trim();
                      await store.save();
                      setState(() {});
                    }),
                  ])),
                IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  cell('Total Penerimaan Dosis\n累计接受剂量', width: 180, bold: true, italic: true, minH: 48),
                  for (final y in ys)
                    cell(w.hasValue(y) ? fmtNum(w.totalOf(y)) : '',
                        bold: true,
                        minH: 48,
                        bg: over.contains(y) ? const Color(0xFFFDE8E8) : null,
                        fg: over.contains(y) ? const Color(0xFFB42318) : null),
                  cell('', width: 76, minH: 48),
                  cell('', width: 200, minH: 48),
                ])),
              ]),
            ),
          ),
          if (over.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Total dosis tahun ${over.join(', ')} melebihi 20 mSv. Periksa kembali nilai dan tindak lanjutnya.\n${over.join('、')} 年总剂量超过 20 mSv，请复核数值并采取后续措施。',
                style: const TextStyle(color: Color(0xFFB42318), fontWeight: FontWeight.w600),
              ),
            ),
          const SizedBox(height: 6),
          Text('Ketuk judul tahun untuk menghapus kolom tahun tersebut.\n点击年份标题可删除该年份列。',
              style: TextStyle(fontSize: 11, color: scheme.outline)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Salin untuk Excel · 复制到 Excel'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _tsv()));
                _snack(context, 'Kartu dosis disalin. Tempel di Excel atau Google Sheets\n剂量卡已复制，可粘贴到 Excel 或 Google Sheets');
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
              width: 170,
              child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.outline))),
          Expanded(child: Text(': ${(v ?? '').isEmpty ? '-' : v}')),
        ]),
      );
}

// ===================== Form identitas pekerja =====================

class WorkerForm extends StatefulWidget {
  final Worker? worker;
  const WorkerForm({super.key, this.worker});
  @override
  State<WorkerForm> createState() => _WorkerFormState();
}

class _WorkerFormState extends State<WorkerForm> {
  late final Worker w = widget.worker == null
      ? (() {
          final now = DateTime.now().year;
          return Worker(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            years: {for (var y = now - 4; y <= now; y++) '$y': List.filled(4, '')},
          );
        })()
      : Worker.fromJson(widget.worker!.toJson());
  late final name = TextEditingController(text: w.name);
  late final inst = TextEditingController(text: w.inst);
  late final tld = TextEditingController(text: w.tld);

  @override
  void dispose() {
    name.dispose();
    inst.dispose();
    tld.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.worker == null ? 'Tambah pekerja · 添加人员' : 'Edit identitas · 编辑身份信息')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Nama · 姓名', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: inst,
              decoration:
                  const InputDecoration(labelText: 'Instansi/Fasilitas · 单位/设施', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: tld,
              decoration: const InputDecoration(
                  labelText: 'Nomor TLD · TLD 编号', hintText: 'mis. 009 / 2582 034 T', border: OutlineInputBorder())),
          const SizedBox(height: 16),
          const Text('Jabatan · 职务', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          for (final r in kTldRoles)
            RadioListTile<String>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: r,
              groupValue: roleOf(w.status),
              onChanged: (v) =>
                  setState(() => w.status = statusOf(v ?? r, isActive(w.status))),
              title: Text(bi(r)),
            ),
          const SizedBox(height: 8),
          const Text('Status · 状态', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, label: Text('Aktif 在岗'), icon: Icon(Icons.check_circle_outline)),
              ButtonSegment(value: false, label: Text('Non Aktif 离岗'), icon: Icon(Icons.pause_circle_outline)),
            ],
            selected: {isActive(w.status)},
            onSelectionChanged: (v) =>
                setState(() => w.status = statusOf(roleOf(w.status), v.first)),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Container(width: 18, height: 18, color: kTldStatus[w.status]),
            const SizedBox(width: 8),
            Expanded(child: Text(bi(w.status))),
          ]),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty) {
                _snack(context, 'Nama wajib diisi · 姓名为必填项');
                return;
              }
              w
                ..name = name.text.trim()
                ..inst = inst.text.trim()
                ..tld = tld.text.trim();
              Navigator.pop(context, w);
            },
            child: const Text('Simpan 保存'),
          ),
        ],
      ),
    );
  }
}
