import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync.dart';
import 'tld.dart';
import 'config.dart';
import 'sources_util.dart';

/// Laporan Kerja PPR bulanan (format bilingual Indonesia / 中文).
const List<String> kJobTypes = [
  'Pemeriksaan检查',
  'Maintenance检修维护部',
  'Maintenance检修维护部 & Pemeriksaan检查',
];
const List<String> kLapMonths = [
  'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli',
  'Agustus', 'September', 'Oktober', 'November', 'Desember'
];
const Color _navy = Color(0xFF16295E);
const Color _red = Color(0xFFC8202E);

void _snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
String _two(int n) => n.toString().padLeft(2, '0');
String _iso(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _dmy(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
  return m == null ? iso : '${m.group(3)}/${m.group(2)}/${m.group(1)}';
}

String lapPeriod(String key) {
  final p = key.split('-');
  if (p.length < 2) return key;
  return '${kLapMonths[(int.tryParse(p[1]) ?? 1) - 1]} ${p[0]}';
}

class LapRec {
  String id;
  String date;
  String loc;
  String equipNo;
  String equipName;
  String job;
  String detail;
  List<String> workers;
  String note;
  /// true = dibuat otomatis dari Radiation Log (diperbarui otomatis sampai diedit manual).
  bool auto;
  LapRec({
    String? id,
    String? date,
    this.loc = '',
    this.equipNo = '',
    this.equipName = '',
    this.job = 'Pemeriksaan检查',
    this.detail = '',
    List<String>? workers,
    this.note = '-',
    this.auto = false,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        date = date ?? _iso(DateTime.now()),
        workers = workers ?? [];

  String get month => date.length >= 7 ? date.substring(0, 7) : date;

  factory LapRec.fromJson(Map<String, dynamic> j) => LapRec(
        id: (j['id'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        loc: (j['loc'] ?? '').toString(),
        equipNo: (j['equipNo'] ?? '').toString(),
        equipName: (j['equipName'] ?? '').toString(),
        job: (j['job'] ?? kJobTypes.first).toString(),
        detail: (j['detail'] ?? '').toString(),
        workers: ((j['workers'] as List?) ?? []).map((e) => e.toString()).toList(),
        note: (j['note'] ?? '-').toString(),
        auto: j['auto'] == true,
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'loc': loc,
        'equipNo': equipNo,
        'equipName': equipName,
        'job': job,
        'detail': detail,
        'workers': workers,
        'note': note,
        'auto': auto,
      };
  LapRec copy() => LapRec.fromJson(toJson());
}

class LapStore extends ChangeNotifier {
  final TldStore people = TldStore();
  SharedPreferences? p;
  List<LapRec> recs = [];
  List<String> tags = [];
  Map<String, String> meta = {'sheetUrl': ''};
  final sync = AutoSync('laporan_synced');
  String get lastError => sync.lastError;

  Future<void> load() async {
    await people.load();
    p = people.p;
    try {
      recs = (jsonDecode(p!.getString('laporan') ?? '[]') as List)
          .map((e) => LapRec.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      recs = [];
    }
    try {
      final m = jsonDecode(p!.getString('laporan_meta') ?? '{}') as Map;
      m.forEach((k, v) => meta[k.toString()] = v.toString());
    } catch (_) {}
    if ((meta['sheetUrl'] ?? '').isEmpty) meta['sheetUrl'] = people.meta['sheetUrl'] ?? '';
    if (kRadSheetUrl.isNotEmpty) meta['sheetUrl'] = kRadSheetUrl;
    try {
      tags = ((jsonDecode(await sourcesJson(p!)) as List)
              .map((e) => ((e as Map)['tag'] ?? '').toString())
              .where((t) => t.isNotEmpty))
          .toList();
    } catch (_) {
      tags = [];
    }
    if (autoOn) {
      _mergeAuto();
      await p?.setString('laporan', jsonEncode(recs.map((r) => r.toJson()).toList()));
    }
    notifyListeners();
    autoSync();
  }

  bool get autoOn => (meta['auto'] ?? '1') != '0';

  /// Id entri otomatis yang dihapus pengguna (tidak dibuat ulang).
  Set<String> get _dismissed => (meta['dismissed'] ?? '').split('|').where((e) => e.isNotEmpty).toSet();
  void dismiss(String id) {
    final d = _dismissed..add(id.replaceAll('|', '/'));
    meta['dismissed'] = d.join('|');
  }

  void _mergeAuto() {
    final gen = lapAutoFromRadiation(p!);
    final dis = _dismissed;
    final ids = gen.map((g) => g.id).toSet();
    // hapus entri otomatis yang sumbernya sudah tidak ada
    recs.removeWhere((r) => r.auto && !ids.contains(r.id));
    for (final g in gen) {
      if (dis.contains(g.id.replaceAll('|', '/'))) continue;
      final i = recs.indexWhere((r) => r.id == g.id);
      if (i < 0) {
        recs.add(g);
      } else if (recs[i].auto) {
        recs[i] = g; // belum pernah diedit manual -> perbarui
      }
    }
  }

  /// Dipanggil Radiation Log setiap kali log paparan/perawatan disimpan.
  static Future<void> refreshFromRadiation() async {
    try {
      await LapStore().load();
    } catch (_) {}
  }

  List<String> get months {
    final s = recs.map((r) => r.month).toSet();
    final now = DateTime.now();
    s.add('${now.year}-${_two(now.month)}');
    return s.toList()..sort((a, b) => b.compareTo(a));
  }

  List<LapRec> of(String month) =>
      recs.where((r) => r.month == month).toList()..sort((a, b) => a.date.compareTo(b.date));

  /// Nilai yang pernah dipakai (untuk saran isian).
  List<String> used(String Function(LapRec) f, [List<String> extra = const []]) {
    final s = <String>{...extra};
    for (final r in recs.reversed) {
      final v = f(r).trim();
      if (v.isNotEmpty && v != '-') s.add(v);
    }
    return s.toList();
  }

  List<String> get workerNames {
    final s = <String>{
      for (final w in people.workers)
        if (isActive(w.status)) w.name
    };
    for (final r in recs) {
      s.addAll(r.workers);
    }
    return s.where((e) => e.trim().isNotEmpty).toList();
  }

  Future<void> save() async {
    await p?.setString('laporan', jsonEncode(recs.map((r) => r.toJson()).toList()));
    notifyListeners();
    autoSync();
  }

  Future<void> saveMeta() async {
    if (autoOn) _mergeAuto();
    await p?.setString('laporan', jsonEncode(recs.map((r) => r.toJson()).toList()));
    await p?.setString('laporan_meta', jsonEncode(meta));
    await sync.resetAll(p);
    notifyListeners();
    autoSync();
  }

  Map<String, dynamic> body(String month) => {
        'type': 'laporan',
        'period': lapPeriod(month),
        'jobTypes': kJobTypes,
        'workers': workerNames,
        'rows': of(month).map((r) => {...r.toJson(), 'date': _dmy(r.date)}).toList(),
      };

  /// Satu tab per bulan; dikirim ulang otomatis setiap ada perubahan.
  Future<void> autoSync() => sync.run(
      p,
      meta['sheetUrl'] ?? '',
      () => {
            for (final m in recs.map((r) => r.month).toSet())
              m: body(m),
            for (final m in sync.sentIds)
              if (of(m).isEmpty) m: body(m),
          },
      notifyListeners);
}

// ===================== Daftar laporan per bulan =====================

class LaporanPage extends StatefulWidget {
  const LaporanPage({super.key});
  @override
  State<LaporanPage> createState() => _LaporanPageState();
}

class _LaporanPageState extends State<LaporanPage> {
  final store = LapStore();
  String month = '${DateTime.now().year}-${_two(DateTime.now().month)}';
  bool table = false;

  @override
  void initState() {
    super.initState();
    store.load();
  }

  Future<void> _settings() async {
    final c = TextEditingController(text: store.meta['sheetUrl']);
    var auto = store.autoOn;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('Pengaturan · 设置'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: auto,
            onChanged: (v) => setD(() => auto = v),
            title: const Text('Isi otomatis dari Radiation Log · 从辐射记录自动填写'),
            subtitle: const Text(
                'Log paparan, perawatan & buka/tutup sumber yang disimpan otomatis masuk ke laporan.\n保存的辐射与维护记录自动加入报告。'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal 取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan 保存')),
        ],
      )),
    );
    if (ok == true) {
      store.meta['auto'] = auto ? '1' : '0';
      await store.saveMeta();
    }
    c.dispose();
  }

  Future<void> _edit([LapRec? r]) async {
    final res = await Navigator.of(context).push<LapRec>(MaterialPageRoute(
        builder: (_) => LapForm(store: store, rec: r?.copy(), month: month)));
    if (res == null) return;
    if (res.id == '__delete__') {
      if (r != null && r.id.startsWith('auto|')) {
        store.dismiss(r.id);
        await store.p?.setString('laporan_meta', jsonEncode(store.meta));
      }
      store.recs.removeWhere((x) => x.id == r?.id);
    } else {
      // diubah manual -> tidak lagi ditimpa pengisian otomatis
      if (r == null || jsonEncode(r.toJson()) != jsonEncode(res.toJson())) res.auto = false;
      final i = store.recs.indexWhere((x) => x.id == res.id);
      if (i >= 0) {
        store.recs[i] = res;
      } else {
        store.recs.add(res);
      }
      month = res.month;
    }
    await store.save();
    if (mounted) _snack(context, 'Tersimpan · 已保存');
  }

  String _tsv(List<LapRec> l) {
    final b = StringBuffer(
        'No.\tTanggal\tLokasi\tNo Peralatan\tNama Peralatan\tJenis Pekerjaan\tRincian Tugas\tPemelihara\tKeterangan\n');
    for (var i = 0; i < l.length; i++) {
      final r = l[i];
      b.writeln([
        i + 1,
        _dmy(r.date),
        r.loc,
        r.equipNo,
        r.equipName,
        r.job,
        r.detail,
        r.workers.join(', '),
        r.note.isEmpty ? '-' : r.note
      ].join('\t'));
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final list = store.of(month);
        final none = (store.meta['sheetUrl'] ?? '').isEmpty;
        final err = store.lastError.isNotEmpty;
        final wait = store.sync.pending > 0;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Laporan Kerja PPR · PPR 工作报告'),
            actions: [
              IconButton(
                tooltip: table ? 'Tampilan kartu · 卡片视图' : 'Tampilan tabel · 表格视图',
                icon: Icon(table ? Icons.view_agenda_outlined : Icons.table_chart_outlined),
                onPressed: () => setState(() => table = !table),
              ),
              IconButton(
                  tooltip: 'Google Sheets · 谷歌表格', icon: const Icon(Icons.settings_outlined), onPressed: _settings),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add_task),
            label: const Text('Tambah pekerjaan · 添加工作'),
          ),
          body: store.p == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: [
                    Text('LAPORAN KERJA PPR BULAN ${lapPeriod(month).toUpperCase()}\nPPR 月度工作报告',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15, color: _navy, letterSpacing: .3)),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 38,
                      child: ListView(scrollDirection: Axis.horizontal, children: [
                        for (final m in store.months)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text('${lapPeriod(m)} (${store.of(m).length})'),
                              selected: m == month,
                              onSelected: (_) => setState(() => month = m),
                            ),
                          ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Icon(
                          none
                              ? Icons.cloud_off_outlined
                              : err
                                  ? Icons.sync_problem
                                  : wait
                                      ? Icons.sync
                                      : Icons.cloud_done_outlined,
                          size: 16,
                          color: err ? _red : scheme.outline),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          none
                              ? 'Spreadsheet belum tertanam di aplikasi · 应用未设置表格'
                              : err
                                  ? store.lastError
                                  : wait
                                      ? 'Menyinkronkan ke Google Sheets… · 正在同步…'
                                      : 'Tersinkron otomatis ke Google Sheets · 已自动同步',
                          style: TextStyle(fontSize: 12, color: err ? _red : scheme.outline),
                        ),
                      ),
                      if (err)
                        TextButton(onPressed: store.autoSync, child: const Text('Coba lagi · 重试')),
                    ]),
                    const SizedBox(height: 8),
                    if (list.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.outlineVariant),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(children: [
                          Icon(Icons.assignment_outlined, size: 48, color: scheme.outline),
                          const SizedBox(height: 8),
                          const Text('Belum ada pekerjaan bulan ini · 本月暂无工作',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text('Tekan "Tambah pekerjaan" untuk mencatat kegiatan PPR.\n点击“添加工作”记录 PPR 活动。',
                              textAlign: TextAlign.center, style: TextStyle(color: scheme.outline)),
                        ]),
                      )
                    else if (table)
                      _Table(list: list, onTap: _edit)
                    else
                      for (var i = 0; i < list.length; i++) _card(i, list[i], scheme),
                    if (list.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.copy),
                          label: const Text('Salin untuk Excel · 复制到 Excel'),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _tsv(list)));
                            _snack(context, 'Laporan ${lapPeriod(month)} disalin · 报告已复制');
                          },
                        ),
                      ),
                    ],
                  ],
                ),
        );
      },
    );
  }

  Widget _card(int i, LapRec r, ColorScheme scheme) {
    final both = r.job.contains('&');
    final maint = r.job.startsWith('Maintenance');
    final col = both ? const Color(0xFF7B3FA0) : (maint ? _red : _navy);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _edit(r),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                  radius: 13,
                  backgroundColor: _navy.withAlpha(26),
                  child: Text('${i + 1}', style: const TextStyle(fontSize: 12, color: _navy))),
              const SizedBox(width: 8),
              Text(_dmy(r.date), style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Lokasi 子项号 ${r.loc.isEmpty ? '-' : r.loc}',
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: col.withAlpha(26), borderRadius: BorderRadius.circular(20)),
                child: Text(both ? 'Maint. & Periksa 维护和检查' : (maint ? 'Maintenance 维护' : 'Pemeriksaan 检查'),
                    style: TextStyle(fontSize: 11, color: col, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Text('${r.equipName}${r.equipNo.isEmpty ? '' : ' · ${r.equipNo}'}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (r.auto)
                Tooltip(
                  message: 'Dibuat otomatis dari Radiation Log · 由辐射记录自动生成',
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.auto_awesome, size: 14, color: scheme.primary),
                    const SizedBox(width: 3),
                    Text('Otomatis 自动', style: TextStyle(fontSize: 11, color: scheme.primary)),
                  ]),
                ),
            ]),
            const SizedBox(height: 2),
            Text(r.detail),
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.groups_outlined, size: 16, color: scheme.outline),
              const SizedBox(width: 4),
              Expanded(
                  child: Text(r.workers.isEmpty ? '-' : r.workers.join(', '),
                      style: TextStyle(fontSize: 12, color: scheme.outline))),
              if (r.note.isNotEmpty && r.note != '-')
                Flexible(
                    child: Text(r.note,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.outline, fontStyle: FontStyle.italic))),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Tampilan tabel seperti di spreadsheet (bisa digeser ke samping).
class _Table extends StatelessWidget {
  const _Table({required this.list, required this.onTap});
  final List<LapRec> list;
  final void Function(LapRec) onTap;

  @override
  Widget build(BuildContext context) {
    const head = Color(0xFFE7E6E6);
    const w = [36.0, 86.0, 60.0, 130.0, 130.0, 210.0, 240.0, 130.0, 90.0];
    const zh = ['No.', '日期', '子项号', '位号', '设备名称', '任务类型', '检修内容', '检修人', '备注'];
    const id = [
      '',
      'Tanggal',
      'Lokasi',
      'No Peralatan',
      'Nama Peralatan',
      'Jenis Pekerjaan',
      'Rincian Tugas',
      'Pemelihara',
      'Keterangan'
    ];
    Widget cell(String t, double width, {bool bold = false, Color? bg}) => Container(
          width: width,
          constraints: const BoxConstraints(minHeight: 30),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            border: const Border(
                right: BorderSide(color: Colors.black54, width: .6),
                bottom: BorderSide(color: Colors.black54, width: .6)),
          ),
          child: Text(t,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: const BoxDecoration(
            border: Border(
                left: BorderSide(color: Colors.black54, width: .6),
                top: BorderSide(color: Colors.black54, width: .6))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [for (var i = 0; i < 9; i++) cell(zh[i], w[i], bold: true, bg: head)]),
          Row(children: [for (var i = 0; i < 9; i++) cell(id[i], w[i], bold: true, bg: head)]),
          for (var n = 0; n < list.length; n++)
            InkWell(
              onTap: () => onTap(list[n]),
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final (i, t) in [
                    '${n + 1}',
                    _dmy(list[n].date),
                    list[n].loc,
                    list[n].equipNo,
                    list[n].equipName,
                    list[n].job,
                    list[n].detail,
                    list[n].workers.join(', '),
                    list[n].note.isEmpty ? '-' : list[n].note,
                  ].indexed)
                    cell(t, w[i]),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

// ===================== Form pekerjaan =====================

class LapForm extends StatefulWidget {
  const LapForm({super.key, required this.store, this.rec, required this.month});
  final LapStore store;
  final LapRec? rec;
  final String month;
  @override
  State<LapForm> createState() => _LapFormState();
}

class _LapFormState extends State<LapForm> {
  late LapRec r;
  late final TextEditingController loc, no, name, detail, note;
  final extra = TextEditingController();
  final Map<String, FocusNode> _focus = {};
  static const String kOther = '__other__';
  static const List<String> kEquipNames = ['Density Gauging', 'Level Gauging', 'XRF'];
  String locSel = ''; // lokasi dari daftar sumber, atau kOther (isi manual)
  Set<String> sel = {}; // tag yang dipilih
  String nameSel = '';
  bool nameTouched = false;

  /// "303-DIT-0101,0201; 101-DX-0001" -> {303-DIT-0101, 303-DIT-0201, 101-DX-0001}
  Set<String> _expand(String v) {
    final out = <String>{};
    for (final g in v.split(';')) {
      final t = g.trim();
      if (t.isEmpty) continue;
      final parts = t.split(',');
      final first = parts.first.trim();
      out.add(first);
      final i = first.lastIndexOf('-');
      final pre = i > 0 ? first.substring(0, i + 1) : '';
      for (final p in parts.skip(1)) {
        final x = p.trim();
        if (x.isNotEmpty) out.add(x.contains('-') ? x : '$pre$x');
      }
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final cur = '${now.year}-${_two(now.month)}';
    r = widget.rec ??
        LapRec(
          date: widget.month == cur ? _iso(now) : '${widget.month}-01',
          workers: _lastWorkers(),
        );
    loc = TextEditingController(text: r.loc);
    no = TextEditingController(text: r.equipNo);
    name = TextEditingController(text: r.equipName);
    detail = TextEditingController(text: r.detail);
    note = TextEditingController(text: r.note);
    final locs = widget.store.tags.map(_locOf).toSet();
    if (r.loc.isEmpty) {
      locSel = '';
    } else if (locs.contains(r.loc)) {
      locSel = r.loc;
      final want = _expand(r.equipNo);
      sel = widget.store.tags
          .where((t) => _locOf(t) == r.loc && (want.contains(t) || want.contains(t.substring(r.loc.length + 1))))
          .toSet();
      if (sel.isEmpty && r.equipNo.isNotEmpty) locSel = kOther;
    } else {
      locSel = kOther;
    }
    nameSel = r.equipName.isEmpty ? '' : (kEquipNames.contains(r.equipName) ? r.equipName : kOther);
    nameTouched = r.equipName.isNotEmpty;
  }

  void _toggleTag(String t, bool on) {
    setState(() {
      on ? sel.add(t) : sel.remove(t);
      if (!nameTouched && sel.isNotEmpty) {
        final n = _equipName(sel.toList());
        nameSel = kEquipNames.contains(n) ? n : kOther;
        if (nameSel == kOther) name.text = n;
      }
    });
  }

  List<String> _lastWorkers() {
    final l = [...widget.store.recs]..sort((a, b) => a.date.compareTo(b.date));
    return l.isEmpty ? [] : [...l.last.workers];
  }

  @override
  void dispose() {
    for (final c in [loc, no, name, detail, note, extra]) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Widget _auto(String label, TextEditingController c, List<String> options,
      {int lines = 1, String? hint, ValueChanged<String>? onPick}) {
    final focus = _focus.putIfAbsent(label, () => FocusNode());
    return RawAutocomplete<String>(
      textEditingController: c,
      focusNode: focus,
      optionsBuilder: (v) {
        final q = v.text.toLowerCase();
        return options.where((o) => o.toLowerCase().contains(q) && o != v.text).take(8);
      },
      onSelected: (v) => onPick?.call(v),
      fieldViewBuilder: (ctx, ctl, f, onSubmit) => TextField(
        controller: ctl,
        focusNode: f,
        minLines: lines,
        maxLines: lines == 1 ? 1 : 5,
        decoration: InputDecoration(
            labelText: label, hintText: hint, border: const OutlineInputBorder()),
      ),
      optionsViewBuilder: (ctx, onSel, opts) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 340),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final o in opts)
                  ListTile(dense: true, title: Text(o), onTap: () => onSel(o)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Saat memilih no peralatan yang pernah dipakai, isi lokasi & nama peralatan otomatis.
  void _fillFromNo(String v) {
    final prev = widget.store.recs.where((x) => x.equipNo == v).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    if (prev.isEmpty) return;
    setState(() {
      if (loc.text.isEmpty) loc.text = prev.last.loc;
      if (name.text.isEmpty) name.text = prev.last.equipName;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    final names = {...s.workerNames, ...r.workers}.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.rec == null ? 'Tambah pekerjaan · 添加工作' : 'Ubah pekerjaan · 修改工作'),
        actions: [
          if (widget.rec != null)
            IconButton(
              tooltip: 'Hapus 删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    content: const Text('Hapus pekerjaan ini? · 删除此工作？'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal 取消')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus 删除')),
                    ],
                  ),
                );
                if (ok == true && context.mounted) Navigator.pop(context, LapRec(id: '__delete__'));
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (r.auto)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                  color: _navy.withAlpha(18), borderRadius: BorderRadius.circular(10)),
              child: const Text(
                  'Entri ini dibuat otomatis dari Log Book Paparan/Perawatan/Buka-Tutup Sumber. Jika Anda mengubah dan menyimpannya, '
                  'entri menjadi manual dan tidak ditimpa lagi.\n'
                  '此条目由辐射/维护记录自动生成。修改并保存后将变为手动条目，不再被自动覆盖。',
                  style: TextStyle(fontSize: 12)),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: const Text('Tanggal · 日期'),
            subtitle: Text(_dmy(r.date)),
            trailing: const Icon(Icons.edit_calendar_outlined),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: DateTime.tryParse(r.date) ?? DateTime.now(),
                firstDate: DateTime(2015),
                lastDate: DateTime(2100),
              );
              if (d != null) setState(() => r.date = _iso(d));
            },
          ),
          const SizedBox(height: 8),
          Builder(builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            final locs = s.tags.map(_locOf).toSet().toList()..sort();
            final tagsHere = s.tags.where((t) => _locOf(t) == locSel).toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DropdownButtonFormField<String>(
                value: locSel.isEmpty ? null : locSel,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Lokasi · 子项号', border: OutlineInputBorder()),
                items: [
                  for (final l in locs)
                    DropdownMenuItem(
                        value: l, child: Text('$l  (${s.tags.where((t) => _locOf(t) == l).length} sumber)')),
                  const DropdownMenuItem(value: kOther, child: Text('Other · 其他 (isi manual)')),
                ],
                onChanged: (v) => setState(() {
                  if (v != locSel) sel = {};
                  locSel = v ?? '';
                }),
              ),
              const SizedBox(height: 10),
              if (locSel == kOther) ...[
                _auto('Lokasi lainnya · 其他位置', loc, s.used((x) => x.loc), hint: 'mis. 203-3'),
                const SizedBox(height: 10),
                _auto('No Peralatan · 位号', no, s.used((x) => x.equipNo), hint: 'mis. 125'),
              ] else if (locSel.isNotEmpty) ...[
                Row(children: [
                  const Expanded(
                      child: Text('No Peralatan · 位号 (pilih satu atau lebih)',
                          style: TextStyle(fontWeight: FontWeight.w600))),
                  TextButton(
                    onPressed: () {
                      if (sel.length == tagsHere.length) {
                        setState(() => sel = {});
                      } else {
                        for (final t in tagsHere) {
                          _toggleTag(t, true);
                        }
                      }
                    },
                    child: Text(sel.length == tagsHere.length && tagsHere.isNotEmpty ? 'Hapus pilihan 清除' : 'Pilih semua 全选'),
                  ),
                ]),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final t in tagsHere)
                    FilterChip(
                      label: Text(t.startsWith('$locSel-') ? t.substring(locSel.length + 1) : t),
                      selected: sel.contains(t),
                      onSelected: (v) => _toggleTag(t, v),
                    ),
                ]),
                if (sel.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('→ ${lapDetNames(s.tags.where(sel.contains).toList())}',
                        style: TextStyle(fontSize: 12, color: scheme.outline)),
                  ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: nameSel.isEmpty ? null : nameSel,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Nama Peralatan · 设备名称', border: OutlineInputBorder()),
                items: [
                  for (final n in kEquipNames) DropdownMenuItem(value: n, child: Text(n)),
                  const DropdownMenuItem(value: kOther, child: Text('Other · 其他 (isi manual)')),
                ],
                onChanged: (v) => setState(() {
                  nameSel = v ?? '';
                  nameTouched = true;
                }),
              ),
              if (nameSel == kOther) ...[
                const SizedBox(height: 10),
                _auto('Nama Peralatan lainnya · 其他设备名称', name,
                    s.used((x) => x.equipName).where((e) => !kEquipNames.contains(e)).toList(),
                    hint: 'mis. MHWirth'),
              ],
            ]);
          }),
          const SizedBox(height: 14),
          const Text('Jenis Pekerjaan · 任务类型', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          for (final j in kJobTypes)
            RadioListTile<String>(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: j,
              groupValue: r.job,
              title: Text(j),
              onChanged: (v) => setState(() => r.job = v ?? j),
            ),
          const SizedBox(height: 6),
          _auto('Rincian Tugas · 检修内容', detail, s.used((x) => x.detail), lines: 2),
          const SizedBox(height: 14),
          const Text('Pemelihara · 检修人', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final n in names)
              FilterChip(
                label: Text(n),
                selected: r.workers.contains(n),
                onSelected: (v) => setState(() {
                  if (v) {
                    r.workers.add(n);
                  } else {
                    r.workers.remove(n);
                  }
                }),
              ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: TextField(
                controller: extra,
                decoration: const InputDecoration(
                    isDense: true, labelText: 'Tambah nama lain · 添加其他人员', border: OutlineInputBorder()),
                onSubmitted: (_) => _addName(),
              ),
            ),
            IconButton(onPressed: _addName, icon: const Icon(Icons.person_add_alt)),
          ]),
          const SizedBox(height: 14),
          TextField(
            controller: note,
            decoration: const InputDecoration(labelText: 'Keterangan · 备注', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            icon: const Icon(Icons.save_outlined),
            label: const Text('Simpan 保存'),
            onPressed: () {
              if (locSel.isNotEmpty && locSel != kOther) {
                loc.text = locSel;
                no.text = lapDetNames(s.tags.where(sel.contains).toList());
              }
              if (nameSel.isNotEmpty && nameSel != kOther) name.text = nameSel;
              if (nameSel.isEmpty) name.text = '';
              if (no.text.trim().isEmpty && name.text.trim().isEmpty && detail.text.trim().isEmpty) {
                _snack(context, 'Isi minimal No/Nama Peralatan atau Rincian Tugas.\n请至少填写设备位号/名称或检修内容。');
                return;
              }
              r
                ..loc = loc.text.trim()
                ..equipNo = no.text.trim()
                ..equipName = name.text.trim()
                ..detail = detail.text.trim()
                ..note = note.text.trim().isEmpty ? '-' : note.text.trim();
              Navigator.pop(context, r);
            },
          ),
        ],
      ),
    );
  }

  void _addName() {
    final n = extra.text.trim();
    if (n.isEmpty) return;
    setState(() {
      if (!r.workers.contains(n)) r.workers.add(n);
      extra.clear();
    });
  }
}


// ===================== Pengisian otomatis dari Radiation Log =====================

const Map<String, String> _checkName = {
  'shutter': 'Shutter',
  'bolt': 'Bolt',
  'sign': 'Radiation Signboard',
  'cable': 'Flexible Cable',
  'water': 'Water Leakage',
};

String _locOf(String tag) {
  final l = tag.split('-').first.trim();
  return l.isEmpty ? '-' : l;
}

/// "303-DIT-0101","303-DIT-0201" -> "303-DIT-0101,0201"
String lapCompressTags(List<String> tags) {
  final groups = <String, List<String>>{};
  for (final t in tags) {
    final i = t.lastIndexOf('-');
    final pre = i > 0 ? t.substring(0, i) : '';
    groups.putIfAbsent(pre, () => []).add(i > 0 ? t.substring(i + 1) : t);
  }
  return groups.entries
      .map((e) => e.key.isEmpty ? e.value.join(',') : '${e.key}-${e.value.join(',')}')
      .join('; ');
}

/// "102-DX-0002A","102-DX-0002B" -> "DX-0002A,0002B" (nama peralatan tanpa kode wilayah)
String lapDetNames(List<String> tags) {
  final dets = tags.map((t) {
    final l = _locOf(t);
    return t.startsWith('$l-') ? t.substring(l.length + 1) : t;
  }).toList();
  return lapCompressTags(dets);
}

String _equipName(List<String> tags) {
  final s = <String>{};
  for (final t in tags) {
    final p = t.split('-');
    final c = p.length > 1 ? p[1].toUpperCase() : '';
    s.add(c.startsWith('D')
        ? 'Density Gauging'
        : c.startsWith('L')
            ? 'Level Gauging'
            : 'Gauging');
  }
  return s.join(' / ');
}

List<String> _names(String v) => v
    .split(RegExp(r'[,/&;]'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty && e != '-' && e != '*')
    .toList();

/// Buat entri laporan dari log paparan & perawatan: satu entri per tanggal per lokasi.
List<LapRec> lapAutoFromRadiation(SharedPreferences p) {
  Map<String, dynamic> read(String k) {
    try {
      return Map<String, dynamic>.from(jsonDecode(p.getString(k) ?? '{}') as Map);
    } catch (_) {
      return {};
    }
  }

  final order = <String, int>{};
  try {
    for (final e in (jsonDecode(p.getString('sources') ?? '[]') as List)) {
      final m = e as Map;
      order[(m['tag'] ?? '').toString()] = (m['order'] as num?)?.toInt() ?? 9999;
    }
  } catch (_) {}

  // key: tanggal|lokasi
  final exp = <String, Set<String>>{};
  final mnt = <String, Set<String>>{};
  final who = <String, Set<String>>{};
  final issues = <String, List<String>>{};
  final notes = <String, List<String>>{};
  String isoOf(dynamic v, String fallback) {
    final d = (v ?? '').toString();
    return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d) ? d : fallback;
  }

  read('sessions').forEach((month, v) {
    final ses = Map<String, dynamic>.from(v as Map);
    final sd = isoOf(ses['date'], '$month-01');
    for (final r in (ses['rows'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      final tag = (m['tag'] ?? '').toString();
      if (tag.isEmpty) continue;
      if ((m['surface'] ?? '') == '-' && (m['meter'] ?? '') == '-') continue; // belum terpasang
      final k = '${isoOf(m['date'], sd)}|${_locOf(tag)}';
      exp.putIfAbsent(k, () => {}).add(tag);
      who.putIfAbsent(k, () => {}).addAll(_names((m['rso'] ?? '').toString()));
    }
  });
  read('maint').forEach((month, v) {
    final mm = Map<String, dynamic>.from(v as Map);
    for (final r in (mm['rows'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      final tag = (m['tag'] ?? '').toString();
      if (tag.isEmpty) continue;
      final k = '${isoOf(m['date'], '$month-01')}|${_locOf(tag)}';
      mnt.putIfAbsent(k, () => {}).add(tag);
      who.putIfAbsent(k, () => {}).addAll(_names((m['worker'] ?? '').toString()));
      final bad = _checkName.entries.where((c) => m[c.key] == 'X').map((c) => c.value).toList();
      final short = tag.contains('-') ? tag.substring(tag.lastIndexOf('-') + 1) : tag;
      if (bad.isNotEmpty) issues.putIfAbsent(k, () => []).add('$short: ${bad.join(', ')}');
      final note = (m['note'] ?? '').toString().trim();
      if (note.isNotEmpty) notes.putIfAbsent(k, () => []).add('$short: $note');
    }
  });

  // Rekaman buka/tutup sumber: dikelompokkan per tanggal buka & lokasi
  // bt: semua tag yang dikerjakan; btMark: tag -> 'Buka/Tutup' (hari sama), 'Buka' atau 'Tutup' (beda hari)
  final bt = <String, Set<String>>{};
  final btMark = <String, Map<String, String>>{};
  try {
    for (final e in (jsonDecode(p.getString('bukatutup') ?? '[]') as List)) {
      final m = Map<String, dynamic>.from(e as Map);
      final tag = (m['tag'] ?? '').toString();
      final open = (m['open'] ?? '').toString();
      if (tag.isEmpty || open.length < 10) continue;
      final close = (m['close'] ?? '').toString();
      final oDay = open.substring(0, 10);
      final cDay = close.length >= 10 ? close.substring(0, 10) : '';
      void put(String day, String mark) {
        final k = '$day|${_locOf(tag)}';
        bt.putIfAbsent(k, () => {}).add(tag);
        btMark.putIfAbsent(k, () => {})[tag] = mark;
        who.putIfAbsent(k, () => {}).addAll(_names((m['person'] ?? '').toString()));
      }

      if (cDay == oDay) {
        put(oDay, 'Buka/Tutup'); // dibuka & ditutup di hari yang sama
      } else {
        put(oDay, 'Buka');
        if (cDay.isNotEmpty) put(cDay, 'Tutup');
      }
    }
  } catch (_) {}

  final out = <LapRec>[];
  for (final k in {...exp.keys, ...mnt.keys, ...bt.keys}) {
    final date = k.split('|')[0];
    final loc = k.split('|')[1];
    final e = exp[k] ?? {};
    final m = mnt[k] ?? {};
    final b = bt[k] ?? {};
    final tags = {...e, ...m, ...b}.toList()
      ..sort((a, b) => (order[a] ?? 9999).compareTo(order[b] ?? 9999));
    final maintLike = m.isNotEmpty || b.isNotEmpty;
    final job = e.isNotEmpty && maintLike
        ? kJobTypes[2]
        : (maintLike ? kJobTypes[1] : kJobTypes[0]);
    final detail = [
      if (e.isNotEmpty) 'Pengukuran paparan radiasi (${e.length} sumber)',
      if (m.isNotEmpty) 'Pemeriksaan perawatan rutin gauging (${m.length} sumber)',
      for (final mk in ['Buka/Tutup', 'Buka', 'Tutup'])
        if ((btMark[k] ?? {}).values.contains(mk))
          '${mk == 'Buka/Tutup' ? 'Buka/tutup' : mk} sumber radioaktif (${(btMark[k] ?? {}).values.where((v) => v == mk).length} sumber)',
    ].join(' & ');
    final src = [
      if (e.isNotEmpty) 'Log Book Paparan',
      if (m.isNotEmpty) 'Log Book Perawatan',
    ].join(' & ');
    final iss = issues[k] ?? [];
    final nts = notes[k] ?? [];
    final note = [
      if (src.isNotEmpty) 'Otomatis dari $src',
      if (m.isNotEmpty) iss.isEmpty ? 'kondisi bagus' : 'Tidak bagus: ${iss.join('; ')}',
      if (nts.isNotEmpty) 'Catatan: ${nts.join('; ')}',
      for (final mk in ['Buka/Tutup', 'Buka', 'Tutup'])
        if ((btMark[k] ?? {}).values.contains(mk)) mk,
    ].join(' · ');
    out.add(LapRec(
      id: 'auto|$k',
      date: date,
      loc: loc,
      equipNo: lapDetNames(tags),
      equipName: _equipName(tags),
      job: job,
      detail: detail,
      workers: (who[k] ?? {}).toList(),
      note: note,
      auto: true,
    ));
  }
  return out;
}
