import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync.dart';
import 'tld.dart';
import 'i18n.dart';
import 'config.dart';
import 'sources_util.dart';

const String kPdTitle = 'Kartu Dosis Pendose (Dosimeter Baca Langsung)';
const List<String> kPdUnits = ['µSv', 'mSv', 'mR'];
const List<String> kPdMonths = [
  'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli',
  'Agustus', 'September', 'Oktober', 'November', 'Desember'
];

void _snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

String _two(int n) => n.toString().padLeft(2, '0');
String _iso(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _dmy(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
  return m == null ? iso : '${m.group(3)}/${m.group(2)}/${m.group(1)}';
}

double? _num(String v) => double.tryParse(v.trim().replaceAll(',', '.'));
String _fmt(double? x) => x == null ? '' : fmtNum(x);

class PdRec {
  String id;
  String date;
  String activity;
  String start;
  String end;
  String note;
  PdRec({
    required this.id,
    this.date = '',
    this.activity = '',
    this.start = '',
    this.end = '',
    this.note = '',
  });

  /// Dosis = bacaan akhir - bacaan awal.
  double? get dose {
    final a = _num(start), b = _num(end);
    if (a == null || b == null) return null;
    return b - a;
  }

  String get year => date.length >= 4 ? date.substring(0, 4) : '';
  int get month => date.length >= 7 ? int.tryParse(date.substring(5, 7)) ?? 0 : 0;

  factory PdRec.fromJson(Map<String, dynamic> j) => PdRec(
        id: (j['id'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        activity: (j['activity'] ?? '').toString(),
        start: (j['start'] ?? '').toString(),
        end: (j['end'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'activity': activity,
        'start': start,
        'end': end,
        'note': note,
      };
}

class PdStore extends ChangeNotifier {
  final TldStore people = TldStore();
  SharedPreferences? p;
  Map<String, List<PdRec>> recs = {};
  List<String> tags = [];
  Map<String, String> meta = {
    'docNo': '',
    'docDate': '',
    'rev': '',
    'ppr': '',
    'sheetUrl': '',
    'unit': 'µSv',
  };
  final sync = AutoSync('pendose_synced');
  String get lastError => sync.lastError;

  Future<void> load() async {
    await people.load();
    p = people.p;
    try {
      final m = jsonDecode(p!.getString('pendose') ?? '{}') as Map;
      recs = m.map((k, v) => MapEntry(
          k.toString(),
          (v as List).map((e) => PdRec.fromJson(Map<String, dynamic>.from(e as Map))).toList()));
    } catch (_) {
      recs = {};
    }
    try {
      final m = jsonDecode(p!.getString('pendose_meta') ?? '{}') as Map;
      m.forEach((k, v) => meta[k.toString()] = v.toString());
    } catch (_) {}
    final d = meta['docNo'] ?? '';
    if (d.trim().isEmpty || d.contains('HYNC')) meta['docNo'] = '21/KDP-DI-SLRT/I/X/2026';
    if ((meta['ppr'] ?? '').isEmpty) meta['ppr'] = people.meta['ppr'] ?? '';
    if ((meta['sheetUrl'] ?? '').isEmpty) meta['sheetUrl'] = people.meta['sheetUrl'] ?? '';
    if (kRadSheetUrl.isNotEmpty) meta['sheetUrl'] = kRadSheetUrl;
    if (!kPdUnits.contains(meta['unit'])) meta['unit'] = 'µSv';
    try {
      tags = ((jsonDecode(await sourcesJson(p!)) as List)
              .map((e) => ((e as Map)['tag'] ?? '').toString())
              .where((t) => t.isNotEmpty))
          .toList();
    } catch (_) {
      tags = [];
    }
    notifyListeners();
    autoSync();
  }

  List<PdRec> of(Worker w) {
    final l = recs[w.id] ?? [];
    l.sort((a, b) => a.date.compareTo(b.date));
    return l;
  }

  double total(Worker w, {String? year, int? month}) => of(w)
      .where((r) => (year == null || r.year == year) && (month == null || r.month == month))
      .map((r) => r.dose)
      .whereType<double>()
      .fold(0.0, (a, b) => a + b);

  Future<void> save() async {
    await p?.setString(
        'pendose', jsonEncode(recs.map((k, v) => MapEntry(k, v.map((r) => r.toJson()).toList()))));
    notifyListeners();
    autoSync();
  }

  Future<void> saveMeta() async {
    await p?.setString('pendose_meta', jsonEncode(meta));
    await sync.resetAll(p);
    notifyListeners();
    autoSync();
  }

  Map<String, dynamic> body(Worker w) => {
        'type': 'pendose',
        'meta': meta,
        'worker': w.toJson(),
        'records': of(w).map((r) => {...r.toJson(), 'dose': r.dose}).toList(),
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

class PendosePage extends StatefulWidget {
  const PendosePage({super.key});
  @override
  State<PendosePage> createState() => _PendosePageState();
}

class _PendosePageState extends State<PendosePage> {
  final store = PdStore();
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
    var unit = store.meta['unit'] ?? 'µSv';
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
                  decoration: const InputDecoration(labelText: 'Dibuat oleh (Petugas Proteksi Radiasi) · 编制人（辐射防护员）')),
              const SizedBox(height: 12),
              const Align(alignment: Alignment.centerLeft, child: Text('Satuan bacaan pendose · 剂量计读数单位')),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [for (final u in kPdUnits) ButtonSegment(value: u, label: Text(u))],
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
        final now = DateTime.now();
        final unit = store.meta['unit'] ?? 'µSv';
        return Scaffold(
          appBar: AppBar(
            title: const Text('Kartu Dosis Pendose · 直读剂量计剂量卡'),
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
                    Text('Dosimeter baca langsung · satuan $unit · 直读剂量计',
                        style: TextStyle(fontSize: 12, color: scheme.outline)),
                    const SizedBox(height: 8),
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
                          Icon(Icons.speed_rounded, size: 48, color: scheme.outline),
                          const SizedBox(height: 8),
                          const Text('Belum ada pekerja · 暂无人员', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            'Daftar pekerja sama dengan Kartu Dosis TLD. Tambahkan pekerja, '
                            'lalu catat bacaan pendose setiap kali bekerja.\n人员名单与 TLD 剂量卡相同。添加人员后，每次工作记录剂量计读数。',
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
                                builder: (_) => PendoseCardPage(store: store, worker: w)));
                            setState(() {});
                          },
                          child: Row(children: [
                            Container(width: 8, height: 72, color: kTldStatus[w.status]),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(w.name,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                Text('${store.of(w).length} pencatatan · 条记录',
                                    style: TextStyle(fontSize: 12, color: scheme.outline)),
                                Text(bi(w.status), style: const TextStyle(fontSize: 12)),
                              ]),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text('${fmtNum(store.total(w, year: '${now.year}', month: now.month))} $unit',
                                    style: const TextStyle(fontWeight: FontWeight.bold)),
                                Text(kPdMonths[now.month - 1],
                                    style: TextStyle(fontSize: 11, color: scheme.outline)),
                                Text('Tahun 年: ${fmtNum(store.total(w, year: '${now.year}'))}',
                                    style: TextStyle(fontSize: 11, color: scheme.outline)),
                              ]),
                            ),
                          ]),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

// ===================== Kartu satu pekerja =====================

class PendoseCardPage extends StatefulWidget {
  final PdStore store;
  final Worker worker;
  const PendoseCardPage({super.key, required this.store, required this.worker});
  @override
  State<PendoseCardPage> createState() => _PendoseCardPageState();
}

class _PendoseCardPageState extends State<PendoseCardPage> {
  PdStore get store => widget.store;
  Worker get w => widget.worker;
  String year = '${DateTime.now().year}';

  Future<void> _edit([PdRec? r]) async {
    final l = store.of(w);
    final res = await Navigator.of(context).push<PdRec>(MaterialPageRoute(
        builder: (_) => PdForm(
              rec: r,
              unit: store.meta['unit'] ?? 'µSv',
              lastEnd: l.isEmpty ? '' : l.last.end,
            )));
    if (res == null) return;
    final list = store.recs.putIfAbsent(w.id, () => []);
    if (res.id == '__delete__') {
      list.removeWhere((x) => x.id == r?.id);
    } else {
      final i = list.indexWhere((x) => x.id == res.id);
      if (i >= 0) {
        list[i] = res;
      } else {
        list.add(res);
      }
      year = res.year.isEmpty ? year : res.year;
    }
    await store.save();
    setState(() {});
  }

  String _tsv() {
    final unit = store.meta['unit'] ?? 'µSv';
    final lines = <String>[
      kPdTitle.toUpperCase(),
      'Nama\t${w.name}',
      'Instansi/Fasilitas\t${w.inst}',
      'No. Dokumen\t${store.meta['docNo']}',
      'Tgl. Dokumen\t${store.meta['docDate']}',
      'Rev.\t${store.meta['rev']}',
      'Satuan\t$unit',
      '',
      ['No.', 'Tanggal', 'Bacaan awal', 'Bacaan akhir', 'Dosis', 'Keterangan'].join('\t'),
    ];
    final l = store.of(w);
    for (var i = 0; i < l.length; i++) {
      final r = l[i];
      lines.add([i + 1, _dmy(r.date), r.start, r.end, _fmt(r.dose), r.note].join('\t'));
    }
    final years = l.map((r) => r.year).where((y) => y.isNotEmpty).toSet().toList()..sort();
    lines.add('');
    for (final y in years) {
      lines.add('Total dosis $y\t${fmtNum(store.total(w, year: y))} $unit');
    }
    lines.addAll(['', 'Dibuat oleh,', store.meta['ppr'] ?? '', '(Petugas Proteksi Radiasi)']);
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final border = BorderSide(color: scheme.outlineVariant);
    final head = scheme.primaryContainer;
    final unit = store.meta['unit'] ?? 'µSv';
    final all = store.of(w);
    final years = {...all.map((r) => r.year).where((y) => y.isNotEmpty), '${DateTime.now().year}'}
        .toList()
      ..sort((a, b) => b.compareTo(a));
    if (!years.contains(year)) year = years.first;
    final l = all.where((r) => r.year == year).toList();
    final monthTotals = <int, double>{
      for (var m = 1; m <= 12; m++)
        if (l.any((r) => r.month == m)) m: store.total(w, year: year, month: m)
    };

    Widget cell(String t, double width, {bool bold = false, Color? bg, TextAlign align = TextAlign.center}) =>
        Container(
          width: width,
          constraints: const BoxConstraints(minHeight: 42),
          alignment: align == TextAlign.left ? Alignment.centerLeft : Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(color: bg, border: Border(right: border, bottom: border)),
          child: Text(t, textAlign: align, style: TextStyle(fontWeight: bold ? FontWeight.bold : null)),
        );
    const widths = [40.0, 96.0, 86.0, 86.0, 86.0, 180.0];

    return Scaffold(
      appBar: AppBar(title: Text(w.name, overflow: TextOverflow.ellipsis)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Catat bacaan · 记录读数'),
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
              child: Text('KARTU DOSIS PENDOSE\n(DOSIMETER BACA LANGSUNG)\n直读剂量计剂量卡',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ]),
          const SizedBox(height: 10),
          _kv('Nama · 姓名', w.name),
          _kv('Instansi/Fasilitas · 单位/设施', w.inst),
          _kv('Status · 状态', w.status),
          _kv('Satuan · 单位', unit),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<String>(
                value: year,
                decoration:
                    const InputDecoration(labelText: 'Tahun · 年份', border: OutlineInputBorder(), isDense: true),
                items: years.map((y) => DropdownMenuItem(value: y, child: Text(y))).toList(),
                onChanged: (v) => setState(() => year = v ?? year),
              ),
            ),
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('Total 合计 $year', style: TextStyle(fontSize: 12, color: scheme.outline)),
              Text('${fmtNum(store.total(w, year: year))} $unit',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ]),
          ]),
          if (monthTotals.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final e in monthTotals.entries)
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('${kPdMonths[e.key - 1].substring(0, 3)}: ${fmtNum(e.value)}'),
                ),
            ]),
          ],
          const SizedBox(height: 12),
          Text('Ketuk baris untuk mengubah atau menghapus · 点击行可修改或删除',
              style: TextStyle(fontSize: 12, color: scheme.outline)),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(
              decoration: BoxDecoration(border: Border(left: border, top: border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final h in [
                    ['No.\n序号', 0],
                    ['Tanggal\n日期', 1],
                    ['Bacaan awal\n初始读数', 2],
                    ['Bacaan akhir\n最终读数', 3],
                    ['Dosis ($unit)\n剂量', 4],
                    ['Keterangan\n备注', 5],
                  ])
                    cell(h[0] as String, widths[h[1] as int], bold: true, bg: head),
                ])),
                if (l.isEmpty)
                  Row(children: [
                    cell('', widths[0]),
                    cell('Belum ada pencatatan tahun $year. Tekan "Catat bacaan".\n$year 年暂无记录，请点击“记录读数”。',
                        widths.sublist(1).fold(0.0, (a, b) => a + b),
                        align: TextAlign.left),
                  ]),
                for (var i = 0; i < l.length; i++)
                  InkWell(
                    onTap: () => _edit(l[i]),
                    child: Row(children: [
                      cell('${i + 1}', widths[0]),
                      cell(_dmy(l[i].date), widths[1]),
                      cell(l[i].start, widths[2]),
                      cell(l[i].end, widths[3]),
                      cell(_fmt(l[i].dose), widths[4], bold: true),
                      cell(l[i].note, widths[5], align: TextAlign.left),
                    ]),
                  ),
                Row(children: [
                  cell('Total Dosis · 总剂量 $year', widths.sublist(0, 4).fold(0.0, (a, b) => a + b), bold: true),
                  cell(fmtNum(store.total(w, year: year)), widths[4], bold: true),
                  cell('', widths[5]),
                ]),
              ]),
            ),
          ),
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

// ===================== Form satu pencatatan =====================

class PdForm extends StatefulWidget {
  final PdRec? rec;
  final String unit;
  final String lastEnd;
  const PdForm({
    super.key,
    this.rec,
    required this.unit,
    this.lastEnd = '',
  });
  @override
  State<PdForm> createState() => _PdFormState();
}

class _PdFormState extends State<PdForm> {
  late final PdRec r = widget.rec == null
      ? PdRec(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          date: _iso(DateTime.now()),
          start: widget.lastEnd)
      : PdRec.fromJson(widget.rec!.toJson());
  late final start = TextEditingController(text: r.start);
  late final end = TextEditingController(text: r.end);
  late final note = TextEditingController(text: r.note);

  @override
  void dispose() {
    for (final c in [start, end, note]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.rec != null;
    final a = _num(start.text), b = _num(end.text);
    final dose = (a != null && b != null) ? b - a : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit pencatatan · 编辑记录' : 'Catat bacaan pendose · 记录剂量计读数'),
        actions: [
          if (editing)
            IconButton(
              tooltip: 'Hapus 删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    content: const Text('Hapus pencatatan ini? · 删除此记录？'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal 取消')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus 删除')),
                    ],
                  ),
                );
                if (ok == true && context.mounted) Navigator.pop(context, PdRec(id: '__delete__'));
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text('Tanggal · 日期: ${_dmy(r.date)}'),
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: DateTime.tryParse(r.date) ?? DateTime.now(),
                firstDate: DateTime(2015),
                lastDate: DateTime(2100),
              );
              if (d != null) setState(() => r.date = _iso(d));
            },
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: start,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'Bacaan awal · 初始读数 (${widget.unit})', border: const OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: end,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'Bacaan akhir · 最终读数 (${widget.unit})', border: const OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Text('Dosis'),
              const Spacer(),
              Text(dose == null ? '-' : '${fmtNum(dose)} ${widget.unit}',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: dose != null && dose < 0 ? const Color(0xFFB42318) : null)),
            ]),
          ),
          if (dose != null && dose < 0)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Bacaan akhir lebih kecil dari bacaan awal. Periksa kembali angkanya.\n最终读数小于初始读数，请重新检查。',
                  style: TextStyle(color: Color(0xFFB42318))),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Keterangan · 备注', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              if (end.text.trim().isEmpty) {
                _snack(context, 'Bacaan akhir wajib diisi · 最终读数为必填项');
                return;
              }
              r
                ..start = start.text.trim().isEmpty ? '0' : start.text.trim()
                ..end = end.text.trim()
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
