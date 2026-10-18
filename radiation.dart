import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'laporan.dart' show LapStore;
import 'bukatutup.dart';
import 'trefoil.dart';
import 'config.dart';

const Color kBlue = Color(0xFF16295E);
const Color kRed = Color(0xFFD92D20);
const Color kGreen = Color(0xFF16A34A);
const List<String> kMonths = [
  'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli',
  'Agustus', 'September', 'Oktober', 'November', 'Desember'
];
const String kTitle =
    'Radiation Exposure Monitoring Log Book on Industrial Gauging Utilization';


// ===================== Helper =====================

String two(int n) => n.toString().padLeft(2, '0');
String isoDate(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
String monthKey(DateTime d) => '${d.year}-${two(d.month)}';
String periodOfKey(String key) {
  final p = key.split('-');
  if (p.length < 2) return key;
  final m = int.tryParse(p[1]) ?? 1;
  return '${kMonths[(m - 1).clamp(0, 11)]} ${p[0]}';
}

String idDate(String iso) {
  final p = iso.split('-');
  if (p.length != 3) return iso;
  final m = int.tryParse(p[1]) ?? 1;
  return '${int.tryParse(p[2]) ?? p[2]} ${kMonths[(m - 1).clamp(0, 11)]} ${p[0]}';
}

String locOf(String tag) {
  final l = tag.split('-').first.trim();
  return l.isEmpty ? 'Lainnya' : l;
}

String detOf(String tag) {
  final l = locOf(tag);
  return tag.startsWith('$l-') ? tag.substring(l.length + 1) : tag;
}

String valOr(String v) => v.trim().isEmpty ? '*' : v.trim();

void snack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

Future<bool> confirm(BuildContext context, String msg,
    {String ok = 'Hapus'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(msg),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal 取消')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
      ],
    ),
  );
  return r ?? false;
}

// ===================== Data =====================

/// Versi daftar sumber bawaan. Ganti nilai ini bila assets/sources.json diperbarui
/// agar HP yang sudah terpasang ikut memakai daftar baru.
const String kSourcesVer = 'slrt-2026-10-17';

/// Kolom tambahan data sumber (sertifikat).
const List<List<String>> kSrcInfo = [
  ['holderSn', 'SN Holder · 源架序列号'],
  ['holderType', 'Type Holder (VEGA) · 源架型号'],
  ['capsuleSn', 'SN Kapsul · 源胶囊序列号'],
  ['type', 'Type Sumber · 源型号'],
  ['actOrder', 'Aktivitas Pesan (mCi) · 订购活度'],
  ['actReal', 'Aktivitas Riil (mCi) · 实际活度'],
  ['actMBq', 'Aktivitas Riil (MBq)'],
  ['actDate', 'Tgl Aktivitas (yyyy-mm-dd) · 活度日期'],
];

class Src {
  int order;
  String tag;
  String name;
  String side;
  Map<String, String> info;
  Src(this.order, this.tag, this.name, this.side, [Map<String, String>? info]) : info = info ?? {};

  factory Src.fromJson(Map<String, dynamic> j) => Src(
        (j['order'] as num?)?.toInt() ?? 0,
        (j['tag'] ?? '').toString(),
        (j['name'] ?? '').toString(),
        (j['side'] ?? 'KA').toString(),
        {
          for (final k in kSrcInfo)
            if ((j[k[0]] ?? '').toString().isNotEmpty) k[0]: j[k[0]].toString()
        },
      );
  Map<String, dynamic> toJson() =>
      {'order': order, 'tag': tag, 'name': name, 'side': side, ...info};
}

class Store extends ChangeNotifier {
  late SharedPreferences p;
  bool ready = false;
  List<Src> sources = [];

  /// Log per bulan: key "yyyy-MM" -> session map.
  Map<String, Map<String, dynamic>> sessions = {};
  Map<String, String> meta = {
    'docNo': '23/LBP-DI-SLRT/I/X/2026',
    'maintDocNo': '24/LBR-DI-SLRT/I/X/2026',
    'revDate': '2 Januari 2026',
    'rev': '01',
    'rbtDocNo': '29/RBT-DI-SLRT/I/X/2026',
    'rbtEff': 'Apr, 2026',
    'rbtRev': '00',
  };
  /// Rekaman buka/tutup sumber: {id, tag, open, close, person, note} (open/close = yyyy-MM-ddTHH:mm).
  List<Map<String, dynamic>> bt = [];
  /// Log perawatan per bulan: key "yyyy-MM" -> {rows: [...]}.
  Map<String, Map<String, dynamic>> maint = {};
  String sheetUrl = '';
  List<String> queue = [];
  String lastError = '';
  bool _busy = false;

  String loadError = '';

  /// Muat data; apa pun yang gagal tidak boleh membuat layar memuat terus.
  Future<void> load() async {
    try {
      await _load();
    } catch (e) {
      loadError = e.toString();
    } finally {
      ready = true;
      notifyListeners();
    }
    try {
      flush();
    } catch (_) {}
  }

  Future<void> _load() async {
    p = await SharedPreferences.getInstance();
    // daftar sumber bawaan baru -> ganti daftar lama di HP (log lama tetap tersimpan)
    final oldVer = p.getString('sources_ver');
    final s = oldVer == kSourcesVer ? p.getString('sources') : null;
    try {
      final raw = s ?? await rootBundle.loadString('assets/sources.json');
      sources = (jsonDecode(raw) as List)
          .map((e) => Src.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      sources = [];
    }
    sources.sort((a, b) => a.order.compareTo(b.order));
    if (oldVer != kSourcesVer && sources.isNotEmpty) {
      await p.setString('sources', jsonEncode(sources.map((e) => e.toJson()).toList()));
      await p.setString('sources_ver', kSourcesVer);
    }
    try {
      final m = jsonDecode(p.getString('sessions') ?? '{}') as Map;
      sessions = m.map((k, v) =>
          MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)));
    } catch (_) {
      sessions = {};
    }
    try {
      final m = jsonDecode(p.getString('meta') ?? '{}') as Map;
      m.forEach((k, v) => meta[k.toString()] = v.toString());
    } catch (_) {}
    String fix(String? v, String def) =>
        (v == null || v.trim().isEmpty || v.contains('HYNC')) ? def : v;
    meta['docNo'] = fix(meta['docNo'], '23/LBP-DI-SLRT/I/X/2026');
    meta['maintDocNo'] = fix(meta['maintDocNo'], '24/LBR-DI-SLRT/I/X/2026');
    meta['rbtDocNo'] = fix(meta['rbtDocNo'], '29/RBT-DI-SLRT/I/X/2026');
    meta['rbtEff'] = fix(meta['rbtEff'], 'Apr, 2026');
    meta['rbtRev'] = fix(meta['rbtRev'], '00');
    try {
      bt = (jsonDecode(p.getString('bukatutup') ?? '[]') as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      bt = [];
    }
    try {
      final m = jsonDecode(p.getString('maint') ?? '{}') as Map;
      maint = m.map((k, v) =>
          MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)));
    } catch (_) {
      maint = {};
    }
    sheetUrl = kRadSheetUrl;
    try {
      if (sheetUrl.isEmpty) sheetUrl = p.getString('rad_sheet_url') ?? '';
    } catch (_) {}
    try {
      queue = p.getStringList('rad_queue') ?? [];
    } catch (_) {
      queue = [];
      await p.remove('rad_queue');
    }
  }

  Future<void> saveSources() async {
    sources.sort((a, b) => a.order.compareTo(b.order));
    await p.setString(
        'sources', jsonEncode(sources.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  Future<void> _saveSessions() =>
      p.setString('sessions', jsonEncode(sessions));

  /// Simpan rekaman buka/tutup lalu kirim triwulan yang berubah ke spreadsheet.
  Future<void> saveBt(Set<String> quarters) async {
    bt.sort((a, b) => (a['open'] ?? '').toString().compareTo((b['open'] ?? '').toString()));
    await p.setString('bukatutup', jsonEncode(bt));
    notifyListeners();
    for (final q in quarters) {
      enqueue('b:$q');
    }
    LapStore.refreshFromRadiation();
  }

  Future<void> saveMeta(Map<String, String> m) async {
    meta = {...meta, ...m};
    await p.setString('meta', jsonEncode(meta));
    notifyListeners();
  }

  List<String> get months => sessions.keys.toList()..sort((a, b) => b.compareTo(a));

  Future<void> saveRows(String key, String date, String rso,
      List<Map<String, dynamic>> newRows) async {
    final s = sessions[key] ?? {'rows': []};
    final map = <String, Map<String, dynamic>>{};
    for (final r in (s['rows'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      map[m['tag'].toString()] = m;
    }
    for (final r in newRows) {
      map[r['tag'].toString()] = r;
    }
    final ord = {for (final x in sources) x.tag: x.order};
    final rows = map.values.toList()
      ..sort((a, b) => (ord[a['tag']] ?? 99999).compareTo(ord[b['tag']] ?? 99999));
    final oldDate = (s['date'] ?? '').toString();
    sessions[key] = {
      'date': oldDate.compareTo(date) > 0 ? oldDate : date,
      'rso': rso,
      'rows': rows,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    await _saveSessions();
    notifyListeners();
    enqueue(key);
    LapStore.refreshFromRadiation();
  }

  Future<void> deleteMonth(String key) async {
    sessions.remove(key);
    await _saveSessions();
    notifyListeners();
    LapStore.refreshFromRadiation();
  }

  List<String> get maintMonths =>
      maint.keys.toList()..sort((a, b) => b.compareTo(a));

  Future<void> saveMaint(String key, List<Map<String, dynamic>> newRows) async {
    final s = maint[key] ?? {'rows': []};
    final map = <String, Map<String, dynamic>>{};
    for (final r in (s['rows'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      map[m['tag'].toString()] = m;
    }
    for (final r in newRows) {
      map[r['tag'].toString()] = r;
    }
    final ord = {for (final x in sources) x.tag: x.order};
    final rows = map.values.toList()
      ..sort((a, b) => (ord[a['tag']] ?? 99999).compareTo(ord[b['tag']] ?? 99999));
    maint[key] = {'rows': rows, 'ts': DateTime.now().millisecondsSinceEpoch};
    await p.setString('maint', jsonEncode(maint));
    notifyListeners();
    enqueue('m:$key');
    LapStore.refreshFromRadiation();
  }

  Future<void> deleteMaintMonth(String key) async {
    maint.remove(key);
    await p.setString('maint', jsonEncode(maint));
    notifyListeners();
    LapStore.refreshFromRadiation();
  }

  Future<void> setUrl(String u) async {
    sheetUrl = u.trim();
    await p.setString('rad_sheet_url', sheetUrl);
    lastError = '';
    notifyListeners();
    flush();
  }

  Future<void> enqueue(String key) async {
    if (sheetUrl.isEmpty) return;
    if (!queue.contains(key)) queue.add(key);
    await p.setStringList('rad_queue', queue);
    notifyListeners();
    flush();
  }

  Map<String, dynamic> payload(String key) {
    if (key.startsWith('b:')) {
      final q = key.substring(2);
      return {
        'type': 'bukatutup',
        'period': quarterLabel(q),
        'docNo': meta['rbtDocNo'],
        'eff': meta['rbtEff'],
        'rev': meta['rbtRev'],
        'rows': [
          for (final r in bt.where((r) => quarterOf((r['open'] ?? '').toString()) == q))
            {
              'tag': r['tag'] ?? '',
              'open': btDisp((r['open'] ?? '').toString()),
              'close': btDisp((r['close'] ?? '').toString()),
              'person': r['person'] ?? '',
              'note': r['note'] ?? '',
            }
        ],
      };
    }
    if (key.startsWith('m:')) {
      final k = key.substring(2);
      return {
        'type': 'maintenance',
        'docNo': meta['maintDocNo'],
        'period': periodOfKey(k),
        'rows': maint[k]?['rows'] ?? [],
      };
    }
    final s = sessions[key] ?? {};
    return {
      'date': s['date'] ?? '$key-01',
      'period': periodOfKey(key),
      'docNo': meta['docNo'],
      'revDate': meta['revDate'],
      'rev': meta['rev'],
      'rows': s['rows'] ?? [],
    };
  }

  Future<void> flush() async {
    if (_busy || sheetUrl.isEmpty || queue.isEmpty) return;
    _busy = true;
    notifyListeners();
    try {
      while (queue.isNotEmpty) {
        final key = queue.first;
        final exists = key.startsWith('b:')
            ? true
            : key.startsWith('m:')
                ? maint.containsKey(key.substring(2))
                : sessions.containsKey(key);
        if (exists) {
          final res = await http
              .post(Uri.parse(sheetUrl),
                  headers: {'Content-Type': 'text/plain;charset=utf-8'},
                  body: jsonEncode(payload(key)))
              .timeout(const Duration(seconds: 60));
          if (res.statusCode >= 400) {
            lastError =
                'Gagal kirim (HTTP ${res.statusCode}). Periksa alamat web app.\n发送失败，请检查 web app 地址。';
            break;
          }
        }
        queue.removeAt(0);
        await p.setStringList('rad_queue', queue);
        lastError = '';
      }
    } catch (_) {
      lastError = 'Belum terkirim: tidak ada koneksi atau alamat salah.\n未发送：无网络或地址错误。';
    }
    _busy = false;
    notifyListeners();
  }
}

// ===================== Aplikasi =====================

class RadiationApp extends StatelessWidget {
  const RadiationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radiation Log · 辐射记录',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: kBlue, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: kBlue,
          brightness: Brightness.dark,
          useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final store = Store();
  int tab = 0;

  @override
  void initState() {
    super.initState();
    store.load();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        if (!store.ready) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 12,
            title: Row(children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8)),
                child: Image.asset('assets/logo_mark.png', width: 66),
              ),
              const SizedBox(width: 10),
              Flexible(child: Text(const ['Catat Pemeriksaan · 记录检查', 'Log Book 记录簿', 'Buka/Tutup Sumber · 开/关', 'Sumber 放射源'][tab], overflow: TextOverflow.ellipsis)),
            ]),
          ),
          body: Column(children: [
            if (store.loadError.isNotEmpty)
              Container(
                width: double.infinity,
                color: const Color(0xFFFDECEC),
                padding: const EdgeInsets.all(8),
                child: Text('Sebagian data tidak terbaca · 部分数据无法读取: ${store.loadError}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFFB42318))),
              ),
            Expanded(child: IndexedStack(index: tab, children: [
              CatatPage(store: store),
              LogBookPage(store: store),
              BukaTutupPage(store: store),
              SumberPage(store: store),
            ])),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.edit_note), label: 'Catat 记录'),
              NavigationDestination(
                  icon: Icon(Icons.menu_book_outlined), label: 'Log Book 记录簿'),
              NavigationDestination(
                  icon: Icon(Icons.lock_open_outlined), label: 'Buka/Tutup 开/关'),
              NavigationDestination(
                  icon: TrefoilIcon(), label: 'Sumber 放射源'),
            ],
          ),
        );
      },
    );
  }
}

/// Dua kolom pilihan: lokasi dan detektor.
class Picker extends StatelessWidget {
  final List<String> tags;
  final String loc;
  final String det;
  final bool showDet;
  final Set<String> marked;
  final void Function(String loc, String det) onChanged;
  const Picker({
    super.key,
    required this.tags,
    required this.loc,
    required this.det,
    required this.onChanged,
    this.showDet = true,
    this.marked = const {},
  });

  @override
  Widget build(BuildContext context) {
    final locs = tags.map(locOf).toSet().toList()..sort();
    final dets = loc.isEmpty ? <String>[] : tags.where((t) => locOf(t) == loc).toList();
    final locField = DropdownButtonFormField<String>(
      value: locs.contains(loc) ? loc : '',
      isExpanded: true,
      decoration: const InputDecoration(
          labelText: 'Pilih lokasi · 选择位置', border: OutlineInputBorder(), isDense: true),
      items: [
        const DropdownMenuItem(value: '', child: Text('Semua lokasi · 全部位置')),
        ...locs.map((l) => DropdownMenuItem(value: l, child: Text(l))),
      ],
      onChanged: (v) => onChanged(v ?? '', ''),
    );
    if (!showDet) return locField;
    final detField = DropdownButtonFormField<String>(
      value: dets.contains(det) ? det : '',
      isExpanded: true,
      decoration: const InputDecoration(
          labelText: 'Pilih detektor · 选择探测器', border: OutlineInputBorder(), isDense: true),
      items: [
        DropdownMenuItem(
            value: '',
            child: Text(loc.isEmpty
                ? 'Pilih lokasi dulu · 请先选择位置'
                : 'Semua detektor · 全部探测器 (${dets.length})')),
        ...dets.map((t) => DropdownMenuItem(
            value: t,
            child: Text('${detOf(t)}${marked.contains(t) ? '  ✓' : ''}'))),
      ],
      onChanged: loc.isEmpty ? null : (v) => onChanged(loc, v ?? ''),
    );
    return Row(children: [
      Expanded(child: locField),
      const SizedBox(width: 8),
      Expanded(child: detField),
    ]);
  }
}

// ===================== Catat =====================

class RowState {
  String side;
  String st = 'ok'; // ok, *, -
  final surface = TextEditingController();
  final meter = TextEditingController();
  final worker = TextEditingController();
  final rso = TextEditingController();
  bool dirty = false;
  RowState(this.side);
  void dispose() {
    surface.dispose();
    meter.dispose();
    worker.dispose();
    rso.dispose();
  }
}

class CatatPage extends StatefulWidget {
  final Store store;
  const CatatPage({super.key, required this.store});
  @override
  State<CatatPage> createState() => _CatatPageState();
}

class _CatatPageState extends State<CatatPage> {
  DateTime date = DateTime.now();
  final rsoDefault = TextEditingController();
  final Map<String, RowState> rows = {};
  final Map<String, MaintRow> mrows = {};
  String loc = '';
  String det = '';

  @override
  void initState() {
    super.initState();
    final p = widget.store.p;
    loc = p.getString('loc') ?? '';
    det = p.getString('det') ?? '';
    rsoDefault.text = p.getString('rso_default') ?? '';
  }

  @override
  void dispose() {
    rsoDefault.dispose();
    for (final r in rows.values) {
      r.dispose();
    }
    super.dispose();
  }

  String lastSide(Src s) {
    for (final k in widget.store.months) {
      for (final r in (widget.store.sessions[k]!['rows'] as List? ?? [])) {
        final m = r as Map;
        if (m['tag'] == s.tag && (m['side'] ?? '').toString().isNotEmpty) {
          return m['side'].toString();
        }
      }
    }
    return s.side;
  }

  RowState rowOf(Src s) => rows.putIfAbsent(s.tag, () => RowState(lastSide(s)));

  MaintRow mRowOf(Src s) => mrows.putIfAbsent(s.tag, () {
        final r = MaintRow();
        for (final e in (widget.store.maint[monthKey(date)]?['rows'] as List? ?? [])) {
          final m = e as Map;
          if (m['tag'] != s.tag) continue;
          for (final c in kChecks) {
            final v = (m[c[0]] ?? '').toString();
            r.st[c[0]] = v == '√' ? 'ok' : (v == 'X' ? 'x' : (v == '*' ? '*' : ''));
          }
          r.note.text = (m['note'] ?? '').toString();
        }
        return r;
      });

  void setPick(String l, String d) {
    setState(() {
      loc = l;
      det = d;
    });
    widget.store.p.setString('loc', loc);
    widget.store.p.setString('det', det);
  }

  Widget _val(RowState r, TextEditingController c, String label, bool locked) {
    return TextField(
      controller: locked ? TextEditingController(text: r.st == '-' ? '-' : '*') : c,
      enabled: !locked,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.right,
      decoration: InputDecoration(
          labelText: label,
          hintText: '*',
          isDense: true,
          border: const OutlineInputBorder()),
      onChanged: (_) => r.dirty = true,
    );
  }

  Widget _sec(IconData icon, String t, [Widget? trailing]) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Row(children: [
          menuIcon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Text(t,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary)),
          const Spacer(),
          if (trailing != null) trailing,
        ]),
      );

  Widget _card(Src s, bool done, bool mDone) {
    final r = rowOf(s);
    final mr = mRowOf(s);
    final lockA = r.st != 'ok';
    final lockW = r.st == '-';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.tag,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    Text(
                        [
                          s.name,
                          if (done) '✓ paparan 辐射',
                          if (mDone) '✓ perawatan 维护',
                        ].join(' · '),
                        style: TextStyle(
                            fontSize: 12,
                            color: (done || mDone)
                                ? kGreen
                                : Theme.of(context).colorScheme.outline)),
                  ],
                ),
              ),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'KA', label: Text('KA')),
                  ButtonSegment(value: 'KI', label: Text('KI')),
                  ButtonSegment(value: 'B', label: Text('B')),
                ],
                selected: {r.side},
                onSelectionChanged: (v) => setState(() {
                  r.side = v.first;
                  r.dirty = true;
                }),
              ),
            ]),
            _sec(kTrefoil, 'Paparan radiasi (μSv/jam) · 辐射剂量率'),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'ok', label: Text('Diukur 已测')),
                ButtonSegment(value: '*', label: Text('* Sulit 难达')),
                ButtonSegment(value: '-', label: Text('- Belum 未装')),
              ],
              selected: {r.st},
              onSelectionChanged: (v) => setState(() {
                r.st = v.first;
                r.dirty = true;
              }),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _val(r, r.surface, 'Container Surface', lockA)),
              const SizedBox(width: 6),
              Expanded(child: _val(r, r.meter, '1 meter', lockA)),
              const SizedBox(width: 6),
              Expanded(child: _val(r, r.worker, "Workers' Area", lockW)),
            ]),
            _sec(
                Icons.build_circle_outlined,
                'Perawatan rutin · 日常维护',
                TextButton.icon(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => setState(() {
                    for (final c in kChecks) {
                      mr.st[c[0]] = 'ok';
                    }
                    mr.dirty = true;
                  }),
                  icon: const Icon(Icons.done_all, size: 18),
                  label: const Text('Semua bagus · 全部良好'),
                )),
            for (final c in kChecks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Text(c[1])),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    emptySelectionAllowed: true,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: const [
                      ButtonSegment(value: 'ok', label: Text('√ Bagus 良好')),
                      ButtonSegment(value: 'x', label: Text('X Rusak 损坏')),
                      ButtonSegment(value: '*', label: Text('*')),
                    ],
                    selected: {if ((mr.st[c[0]] ?? '').isNotEmpty) mr.st[c[0]]!},
                    onSelectionChanged: (v) => setState(() {
                      mr.st[c[0]] = v.isEmpty ? '' : v.first;
                      mr.dirty = true;
                    }),
                  ),
                ]),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: mr.note,
              decoration: const InputDecoration(
                  labelText: 'Note · 备注', isDense: true, border: OutlineInputBorder()),
              onChanged: (_) => mr.dirty = true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: r.rso,
              decoration: InputDecoration(
                labelText: 'RSO / Worker · 辐射安全员/工作人员',
                hintText: rsoDefault.text.isEmpty
                    ? 'Ikuti default · 使用默认'
                    : 'Ikuti default · 使用默认 (${rsoDefault.text})',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Text('Pemeriksaan perawatan yang tidak dipilih tercatat sebagai *.\n未选择的维护检查项记录为 *。',
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final store = widget.store;
    final dirty = store.sources.where((s) => rows[s.tag]?.dirty ?? false).toList();
    final mDirty = store.sources.where((s) => mrows[s.tag]?.dirty ?? false).toList();
    if (dirty.isEmpty && mDirty.isEmpty) {
      snack(context, 'Belum ada nilai paparan atau pemeriksaan perawatan yang diisi\n尚未填写辐射值或维护检查');
      return;
    }
    final def = rsoDefault.text.trim();
    String who(Src s) {
      final t = rows[s.tag]?.rso.text.trim() ?? '';
      return t.isEmpty ? def : t;
    }

    final key = monthKey(date);
    final iso = isoDate(date);
    if (dirty.isNotEmpty) {
      final newRows = dirty.map((s) {
        final r = rows[s.tag]!;
        String v(TextEditingController c, bool worker) {
          if (r.st == '-') return '-';
          if (r.st == '*' && !worker) return '*';
          return valOr(c.text);
        }

        return <String, dynamic>{
          'tag': s.tag,
          'name': s.name,
          'date': iso,
          'side': r.side,
          'surface': v(r.surface, false),
          'meter': v(r.meter, false),
          'worker': v(r.worker, true),
          'rso': who(s),
        };
      }).toList();
      await store.saveRows(key, iso, def, newRows);
    }
    var bad = 0;
    if (mDirty.isNotEmpty) {
      final mNew = mDirty.map((s) {
        final r = mrows[s.tag]!;
        return <String, dynamic>{
          'tag': s.tag,
          'date': iso,
          for (final c in kChecks) c[0]: symOf(r.st[c[0]] ?? ''),
          'note': r.note.text.trim(),
          'worker': who(s),
        };
      }).toList();
      bad = mNew.where((r) => kChecks.any((c) => r[c[0]] == 'X')).length;
      await store.saveMaint(key, mNew);
    }
    for (final s in {...dirty, ...mDirty}) {
      rows.remove(s.tag);
      mrows.remove(s.tag);
    }
    if (!mounted) return;
    var next = '';
    if (det.isNotEmpty) {
      final list =
          store.sources.where((x) => locOf(x.tag) == loc).map((x) => x.tag).toList();
      final i = list.indexOf(det);
      if (i >= 0 && i + 1 < list.length) next = list[i + 1];
      setPick(loc, next);
    }
    setState(() {});
    snack(
        context,
        'Tersimpan · 已保存: ${dirty.length} paparan, ${mDirty.length} perawatan (${periodOfKey(key)})'
        '${bad > 0 ? ' · $bad kondisi tidak bagus' : ''}'
        '${next.isNotEmpty ? '. Lanjut ke ${detOf(next)}' : ''}');
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final key = monthKey(date);
    final done = <String>{
      for (final r in (store.sessions[key]?['rows'] as List? ?? []))
        (r as Map)['tag'].toString()
    };
    final mDone = <String>{
      for (final r in (store.maint[key]?['rows'] as List? ?? []))
        (r as Map)['tag'].toString()
    };
    final vis = store.sources
        .where((s) =>
            (loc.isEmpty || locOf(s.tag) == loc) &&
            (det.isEmpty || s.tag == det))
        .toList();
    final muted = Theme.of(context).colorScheme.outline;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text(idDate(isoDate(date))),
              onPressed: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: date,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (d != null) {
                  setState(() {
                    date = d;
                    mrows.clear();
                  });
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: rsoDefault,
              decoration: const InputDecoration(
                  labelText: 'RSO / Worker default · 默认辐射安全员/工作人员',
                  isDense: true,
                  border: OutlineInputBorder()),
              onChanged: (v) {
                store.p.setString('rso_default', v);
                setState(() {});
              },
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Picker(
          tags: store.sources.map((s) => s.tag).toList(),
          loc: loc,
          det: det,
          marked: done.intersection(mDone),
          onChanged: setPick,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Periode · 期间 ${periodOfKey(key)} · Paparan ${done.length}/${store.sources.length} · '
            'Perawatan ${mDone.length}/${store.sources.length}. '
            'Nilai paparan kosong tercatat sebagai *.\n空白辐射值记录为 *。',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ),
        if (vis.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Tidak ada sumber untuk pilihan ini. · 此选择下没有放射源。')),
          ),
        for (final s in vis) _card(s, done.contains(s.tag), mDone.contains(s.tag)),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.save),
          label: const Text('Simpan paparan + perawatan · 保存辐射+维护'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ===================== Log Book =====================

class LogPage extends StatefulWidget {
  final Store store;
  const LogPage({super.key, required this.store});
  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  String? month;
  String loc = '';

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final months = store.months;
    if (months.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Belum ada log. Catat pengukuran pertama di menu Catat.\n暂无记录，请在“记录”菜单进行首次测量。',
              textAlign: TextAlign.center),
        ),
      );
    }
    final key = (month != null && months.contains(month)) ? month! : months.first;
    final s = store.sessions[key]!;
    final all = (s['rows'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final rows = all.where((r) => loc.isEmpty || locOf(r['tag'].toString()) == loc).toList();
    final meta = store.meta;
    final muted = Theme.of(context).colorScheme.outline;
    final border = BorderSide(color: Theme.of(context).dividerColor);

    Widget cell(String t, {bool bold = false, TextAlign align = TextAlign.center, double w = 80}) =>
        Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(border: Border(right: border, bottom: border)),
          child: Text(t,
              textAlign: align,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.bold : null)),
        );

    String copyText() {
      final lines = <String>[
        ['No.', 'Tag Number', 'Sisi', 'Container Surface', '1 meter Distance',
            "Workers' Area", 'Radiation Safety Officer'].join('\t')
      ];
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        lines.add([
          i + 1, r['tag'], '(${r['side'] ?? 'KA'})', r['surface'], r['meter'],
          r['worker'], r['rso'] ?? ''
        ].join('\t'));
      }
      return lines.join('\n');
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: key,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Periode · 期间', border: OutlineInputBorder(), isDense: true),
              items: months
                  .map((k) => DropdownMenuItem(value: k, child: Text(periodOfKey(k))))
                  .toList(),
              onChanged: (v) => setState(() => month = v),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Picker(
              tags: all.map((r) => r['tag'].toString()).toList(),
              loc: loc,
              det: '',
              showDet: false,
              onChanged: (l, _) => setState(() => loc = l),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6)),
                    child: Image.asset('assets/logo_mark.png', width: 78),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(kTitle,
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ]),
                const SizedBox(height: 8),
                Text('Period : ${periodOfKey(key)}'),
                const SizedBox(height: 4),
                Text('Terakhir diukur: ${idDate((s['date'] ?? '').toString())}',
                    style: TextStyle(fontSize: 12, color: muted)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            decoration: BoxDecoration(border: Border(left: border, top: border)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    cell('No.\n序号', bold: true, w: 44),
                    cell('Tag Number\n位号', bold: true, w: 140),
                    cell('Container Surface\n容器表面', bold: true, w: 130),
                    cell('1 meter Distance\n距离 1 米', bold: true, w: 90),
                    cell("Workers' Area\n工作区域", bold: true, w: 90),
                    cell('Radiation Safety Officer\n辐射安全员', bold: true, w: 160),
                  ])),
                ),
                for (var i = 0; i < rows.length; i++)
                  Row(children: [
                    cell('${i + 1}', w: 44),
                    cell(rows[i]['tag'].toString(), w: 140),
                    cell('(${rows[i]['side'] ?? 'KA'})  ${rows[i]['surface'] ?? ''}',
                        w: 130, align: TextAlign.left),
                    cell((rows[i]['meter'] ?? '').toString(), w: 90),
                    cell((rows[i]['worker'] ?? '').toString(), w: 90),
                    cell((rows[i]['rso'] ?? '').toString(), w: 160),
                  ]),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '- : radioactive source not installed/operational yet\n'
            '* : radioactive sources are difficult to reach',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Salin untuk Excel · 复制到 Excel'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: copyText()));
              snack(context, 'Disalin. Tempel di tab Input Google Sheets\n已复制，请粘贴到 Google Sheets 的 Input 标签页');
            },
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('Kirim ke Sheets · 发送到表格'),
            onPressed: store.sheetUrl.isEmpty
                ? null
                : () {
                    store.enqueue(key);
                    snack(context, 'Mengirim · 发送中 ${periodOfKey(key)}…');
                  },
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline, color: kRed),
            label: const Text('Hapus log · 删除记录', style: TextStyle(color: kRed)),
            onPressed: () async {
              if (await confirm(context,
                  'Hapus log ${periodOfKey(key)} dari HP ini? Data di Google Sheets tidak ikut terhapus.\n从本手机删除该记录？Google Sheets 中的数据不会被删除。')) {
                store.deleteMonth(key);
              }
            },
          ),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ===================== Sumber & Pengaturan =====================

class SumberPage extends StatefulWidget {
  final Store store;
  const SumberPage({super.key, required this.store});
  @override
  State<SumberPage> createState() => _SumberPageState();
}

class _SumberPageState extends State<SumberPage> {
  String loc = '';
  String det = '';
  final docNo = TextEditingController();
  final revDate = TextEditingController();
  final maintDocNo = TextEditingController();
  final rev = TextEditingController();
  final url = TextEditingController();
  final rbtDocNo = TextEditingController();
  final rbtEff = TextEditingController();
  final rbtRev = TextEditingController();

  @override
  void initState() {
    super.initState();
    final m = widget.store.meta;
    docNo.text = m['docNo'] ?? '';
    revDate.text = m['revDate'] ?? '';
    maintDocNo.text = m['maintDocNo'] ?? '';
    rev.text = m['rev'] ?? '';
    url.text = widget.store.sheetUrl;
    rbtDocNo.text = m['rbtDocNo'] ?? '';
    rbtEff.text = m['rbtEff'] ?? '';
    rbtRev.text = m['rbtRev'] ?? '';
  }

  @override
  void dispose() {
    for (final c in [docNo, revDate, rev, url, maintDocNo, rbtDocNo, rbtEff, rbtRev]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _edit(Src? s) async {
    final store = widget.store;
    final res = await Navigator.of(context).push<Src>(MaterialPageRoute(
        builder: (_) => SrcForm(
            src: s,
            others: store.sources.where((x) => !identical(x, s)).map((x) => x.tag).toSet(),
            nextOrder: store.sources.fold<int>(0, (m, x) => x.order > m ? x.order : m) + 1)));
    if (res == null) return;
    if (res.tag == '__delete__') {
      store.sources.remove(s);
    } else if (s == null) {
      store.sources.add(res);
    } else {
      s
        ..order = res.order
        ..tag = res.tag
        ..name = res.name
        ..side = res.side
        ..info = res.info;
    }
    await store.saveSources();
    if (mounted) snack(context, res.tag == '__delete__' ? 'Sumber dihapus · 已删除' : 'Sumber disimpan · 已保存');
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final list = store.sources
        .where((s) =>
            (loc.isEmpty || locOf(s.tag) == loc) &&
            (det.isEmpty || s.tag == det))
        .toList();
    final muted = Theme.of(context).colorScheme.outline;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Picker(
          tags: store.sources.map((s) => s.tag).toList(),
          loc: loc,
          det: det,
          onChanged: (l, d) => setState(() {
            loc = l;
            det = d;
          }),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: Text('Daftar sumber · 放射源列表 (${list.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold))),
          FilledButton.tonalIcon(
              onPressed: () => _edit(null),
              icon: const Icon(Icons.add),
              label: const Text('Tambah sumber · 添加')),
        ]),
        Text('Ketuk kartu untuk mengedit · 点击卡片编辑',
            style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 4),
        for (final s in list)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              title: Text(s.tag, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([
                '${s.name} · (${s.side})',
                if ((s.info['actReal'] ?? '').isNotEmpty)
                  '${s.info['actReal']} mCi${(s.info['actMBq'] ?? '').isEmpty ? '' : ' / ${s.info['actMBq']} MBq'}'
                      '${(s.info['actDate'] ?? '').isEmpty ? '' : ' (${s.info['actDate']})'}',
                if ((s.info['holderSn'] ?? '').isNotEmpty)
                  'Holder ${s.info['holderType'] ?? ''} ${s.info['holderSn']} · Kapsul ${s.info['capsuleSn'] ?? '-'}',
              ].join('\n')),
              onTap: () => _edit(s),
              isThreeLine: s.info.isNotEmpty,
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (await confirm(context, 'Hapus ${s.tag}? · 删除？')) {
                    store.sources.remove(s);
                    await store.saveSources();
                  }
                },
              ),
            ),
          ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Informasi dokumen · 文件信息',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Text('Hanya tampil di spreadsheet · 仅显示在表格中',
                    style: TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                TextField(
                    controller: docNo,
                    decoration: const InputDecoration(
                        labelText: 'No. Dokumen Logbook Paparan (LBP) · 辐射记录簿文件编号', isDense: true)),
                TextField(
                    controller: maintDocNo,
                    decoration: const InputDecoration(
                        labelText: 'No. Dokumen Logbook Perawatan (LBR) · 维护记录簿文件编号', isDense: true)),
                TextField(
                    controller: revDate,
                    decoration: const InputDecoration(
                        labelText: 'Rev. Date · 修订日期', isDense: true)),
                TextField(
                    controller: rev,
                    decoration:
                        const InputDecoration(labelText: 'Rev. · 版本', isDense: true)),
                TextField(
                    controller: rbtDocNo,
                    decoration: const InputDecoration(
                        labelText: 'No. Dok Rekaman Buka/Tutup (RBT) · 开/关记录文件编号', isDense: true)),
                Row(children: [
                  Expanded(
                    child: TextField(
                        controller: rbtEff,
                        decoration: const InputDecoration(
                            labelText: 'Tanggal Eff. (RBT) · 生效日期', isDense: true)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                        controller: rbtRev,
                        decoration: const InputDecoration(
                            labelText: 'No. Revisi (RBT) · 版本', isDense: true)),
                  ),
                ]),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: () {
                      store.saveMeta({
                        'docNo': docNo.text.trim(),
                        'maintDocNo': maintDocNo.text.trim(),
                        'revDate': revDate.text.trim(),
                        'rev': rev.text.trim().isEmpty ? '-' : rev.text.trim(),
                        'rbtDocNo': rbtDocNo.text.trim(),
                        'rbtEff': rbtEff.text.trim(),
                        'rbtRev': rbtRev.text.trim().isEmpty ? '00' : rbtRev.text.trim(),
                      });
                      snack(context, 'Informasi dokumen disimpan · 文件信息已保存');
                    },
                    child: const Text('Simpan informasi dokumen · 保存文件信息'),
                  ),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Google Sheets · 谷歌表格',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  store.sheetUrl.isEmpty
                      ? 'Spreadsheet belum tertanam di aplikasi · 应用未设置表格'
                      : 'Terhubung · 已连接 — Antrean kirim · 待发送: ${store.queue.length}',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                if (store.lastError.isNotEmpty)
                  Text(store.lastError,
                      style: const TextStyle(fontSize: 12, color: kRed)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  OutlinedButton(
                    onPressed: store.sheetUrl.isEmpty || store.sessions.isEmpty
                        ? null
                        : () {
                            for (final k in store.sessions.keys) {
                              store.enqueue(k);
                            }
                            snack(context, 'Mengirim semua log… · 正在发送全部记录…');
                          },
                    child: const Text('Kirim semua log · 发送全部记录'),
                  ),
                ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}


// ===================== Perawatan rutin (Routine Maintenance) =====================

const String kMaintTitle = 'Gauging Instrument Routine Maintenance Log Book';
const Map<String, String> kChecksZh = {
  'shutter': '快门',
  'bolt': '螺栓',
  'sign': '辐射警示牌',
  'cable': '软电缆',
  'water': '漏水',
};
const List<List<String>> kChecks = [
  ['shutter', 'Shutter'],
  ['bolt', 'Bolt'],
  ['sign', 'Radiation Signboard'],
  ['cable', 'Flexible Cable'],
  ['water', 'Water Leakage'],
];
const Color kGoodBlue = Color(0xFF1F4FE0);
const Color kWarnYellow = Color(0xFFFFE600);

String symOf(String st) => st == 'ok' ? '√' : (st == 'x' ? 'X' : '*');

Color statusBg(String st) =>
    st == 'ok' ? kGoodBlue : (st == 'x' ? kRed : kWarnYellow);
Color statusFg(String st) => st == '*' ? Colors.black : Colors.white;

class MaintRow {
  final Map<String, String> st = {for (final c in kChecks) c[0]: ''};
  final note = TextEditingController();
  final worker = TextEditingController();
  bool dirty = false;
}

class MaintPage extends StatefulWidget {
  final Store store;
  final bool logOnly;
  const MaintPage({super.key, required this.store, this.logOnly = false});
  @override
  State<MaintPage> createState() => _MaintPageState();
}

class _MaintPageState extends State<MaintPage> {
  int mode = 0; // 0 catat, 1 log
  DateTime date = DateTime.now();
  final workerDefault = TextEditingController();
  final Map<String, MaintRow> rows = {};
  String loc = '';
  String det = '';
  String? logMonth;
  String logLoc = '';

  @override
  void initState() {
    super.initState();
    final p = widget.store.p;
    workerDefault.text = p.getString('maint_worker') ?? '';
    loc = p.getString('maint_loc') ?? '';
    det = p.getString('maint_det') ?? '';
  }

  @override
  void dispose() {
    workerDefault.dispose();
    super.dispose();
  }

  void setPick(String l, String d) {
    setState(() {
      loc = l;
      det = d;
    });
    widget.store.p.setString('maint_loc', loc);
    widget.store.p.setString('maint_det', det);
  }

  MaintRow rowOf(Src s, Map<String, Map<String, dynamic>> existing) {
    return rows.putIfAbsent(s.tag, () {
      final r = MaintRow();
      final e = existing[s.tag];
      if (e != null) {
        for (final c in kChecks) {
          final v = (e[c[0]] ?? '').toString();
          r.st[c[0]] = v == '√' ? 'ok' : (v == 'X' ? 'x' : (v == '*' ? '*' : ''));
        }
        r.note.text = (e['note'] ?? '').toString();
        final w = (e['worker'] ?? '').toString();
        if (w != workerDefault.text.trim()) r.worker.text = w;
      }
      return r;
    });
  }

  Future<void> _save() async {
    final store = widget.store;
    final dirty = store.sources.where((s) => rows[s.tag]?.dirty ?? false).toList();
    if (dirty.isEmpty) {
      snack(context, 'Belum ada pemeriksaan yang diisi · 尚未填写检查');
      return;
    }
    final def = workerDefault.text.trim();
    final iso = isoDate(date);
    final newRows = dirty.map((s) {
      final r = rows[s.tag]!;
      return <String, dynamic>{
        'tag': s.tag,
        'date': iso,
        for (final c in kChecks) c[0]: symOf(r.st[c[0]] ?? ''),
        'note': r.note.text.trim(),
        'worker': r.worker.text.trim().isEmpty ? def : r.worker.text.trim(),
      };
    }).toList();
    final key = monthKey(date);
    await store.saveMaint(key, newRows);
    for (final s in dirty) {
      rows.remove(s.tag);
    }
    if (!mounted) return;
    var next = '';
    if (det.isNotEmpty) {
      final list = store.sources.where((x) => locOf(x.tag) == loc).map((x) => x.tag).toList();
      final i = list.indexOf(det);
      if (i >= 0 && i + 1 < list.length) next = list[i + 1];
      setPick(loc, next);
    }
    setState(() {});
    final bad = newRows.where((r) => kChecks.any((c) => r[c[0]] == 'X')).length;
    snack(
        context,
        '${dirty.length} sumber tersimpan ke log perawatan ${periodOfKey(key)} · 已保存'
        '${bad > 0 ? ' · $bad dengan kondisi tidak bagus' : ''}'
        '${next.isNotEmpty ? '. Lanjut ke ${detOf(next)}' : ''}');
  }

  Widget _legend() {
    Widget item(String st, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 26,
            height: 20,
            alignment: Alignment.center,
            color: statusBg(st),
            child: Text(symOf(st),
                style: TextStyle(color: statusFg(st), fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]);
    return Wrap(spacing: 14, runSpacing: 6, children: [
      item('*', 'Belum/tidak dapat diperiksa · 未/无法检查'),
      item('ok', 'Kondisi bagus · 状况良好'),
      item('x', 'Kondisi tidak bagus · 状况不良'),
    ]);
  }

  Widget _card(Src s, MaintRow r, bool done) {
    final muted = Theme.of(context).colorScheme.outline;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.tag, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text(done ? '${s.name} · ✓ sudah diperiksa bulan ini 本月已检查' : s.name,
                      style: TextStyle(fontSize: 12, color: done ? kGreen : muted)),
                ]),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  for (final c in kChecks) {
                    r.st[c[0]] = 'ok';
                  }
                  r.dirty = true;
                }),
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('Semua bagus · 全部良好'),
              ),
            ]),
            const SizedBox(height: 6),
            for (final c in kChecks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Text(c[1])),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    emptySelectionAllowed: true,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: const [
                      ButtonSegment(value: 'ok', label: Text('√ Bagus 良好')),
                      ButtonSegment(value: 'x', label: Text('X Rusak 损坏')),
                      ButtonSegment(value: '*', label: Text('*')),
                    ],
                    selected: {if ((r.st[c[0]] ?? '').isNotEmpty) r.st[c[0]]!},
                    onSelectionChanged: (v) => setState(() {
                      r.st[c[0]] = v.isEmpty ? '' : v.first;
                      r.dirty = true;
                    }),
                  ),
                ]),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: r.note,
              decoration: const InputDecoration(
                  labelText: 'Note · 备注', isDense: true, border: OutlineInputBorder()),
              onChanged: (_) => r.dirty = true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: r.worker,
              decoration: InputDecoration(
                labelText: 'Worker · 工作人员',
                hintText: workerDefault.text.isEmpty ? 'Ikuti worker default · 使用默认工作人员' : workerDefault.text,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => r.dirty = true,
            ),
            const SizedBox(height: 4),
            Text('Yang tidak dipilih tercatat sebagai * (belum diperiksa).\n未选择的项记录为 *（未检查）。',
                style: TextStyle(fontSize: 11, color: muted)),
          ],
        ),
      ),
    );
  }

  Widget _catat() {
    final store = widget.store;
    final key = monthKey(date);
    final existing = <String, Map<String, dynamic>>{
      for (final r in (store.maint[key]?['rows'] as List? ?? []))
        (r as Map)['tag'].toString(): Map<String, dynamic>.from(r)
    };
    final vis = store.sources
        .where((s) => (loc.isEmpty || locOf(s.tag) == loc) && (det.isEmpty || s.tag == det))
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text(idDate(isoDate(date))),
              onPressed: () async {
                final d = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100));
                if (d != null) {
                  setState(() {
                    date = d;
                    rows.clear();
                  });
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: workerDefault,
              decoration: const InputDecoration(
                  labelText: 'Worker default · 默认工作人员', isDense: true, border: OutlineInputBorder()),
              onChanged: (v) {
                store.p.setString('maint_worker', v);
                setState(() {});
              },
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Picker(
          tags: store.sources.map((s) => s.tag).toList(),
          loc: loc,
          det: det,
          marked: existing.keys.toSet(),
          onChanged: setPick,
        ),
        const SizedBox(height: 10),
        _legend(),
        const SizedBox(height: 4),
        Text('Periode · 期间: ${periodOfKey(key)} (${existing.length} sumber diperiksa)',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 10),
        if (vis.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Tidak ada sumber untuk pilihan ini. · 此选择下没有放射源。')),
          ),
        for (final s in vis) _card(s, rowOf(s, existing), existing.containsKey(s.tag)),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.save),
          label: const Text('Simpan ke Maintenance Log · 保存到维护记录'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _log() {
    final store = widget.store;
    final months = store.maintMonths;
    if (months.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Belum ada log perawatan. Catat pemeriksaan pertama di tab Catat.\n暂无维护记录，请在“记录”标签进行首次检查。',
              textAlign: TextAlign.center),
        ),
      );
    }
    final key = (logMonth != null && months.contains(logMonth)) ? logMonth! : months.first;
    final all = (store.maint[key]!['rows'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final list = all.where((r) => logLoc.isEmpty || locOf(r['tag'].toString()) == logLoc).toList();
    final border = BorderSide(color: Theme.of(context).dividerColor);

    Widget cell(String t, double w, {bool bold = false, Color? bg, Color? fg, bool left = false}) =>
        Container(
          width: w,
          constraints: const BoxConstraints(minHeight: 34),
          alignment: left ? Alignment.centerLeft : Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(color: bg, border: Border(right: border, bottom: border)),
          child: Text(t,
              textAlign: left ? TextAlign.left : TextAlign.center,
              style: TextStyle(fontWeight: bold ? FontWeight.bold : null, color: fg)),
        );
    String stOf(String sym) => sym == '√' ? 'ok' : (sym == 'X' ? 'x' : '*');

    String tsv() {
      final out = <String>[
        ['No.', 'Tag', 'Date', ...kChecks.map((c) => c[1]), 'Note', 'Worker'].join('\t')
      ];
      for (var i = 0; i < list.length; i++) {
        final r = list[i];
        out.add([
          i + 1,
          r['tag'],
          idDate((r['date'] ?? '').toString()),
          ...kChecks.map((c) => r[c[0]] ?? '*'),
          (r['note'] ?? '').toString().replaceAll('\n', ' '),
          r['worker'] ?? ''
        ].join('\t'));
      }
      return out.join('\n');
    }

    final bad = list.where((r) => kChecks.any((c) => r[c[0]] == 'X')).length;
    final head = Theme.of(context).colorScheme.primaryContainer;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: key,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Periode · 期间', border: OutlineInputBorder(), isDense: true),
              items: months
                  .map((k) => DropdownMenuItem(value: k, child: Text(periodOfKey(k))))
                  .toList(),
              onChanged: (v) => setState(() => logMonth = v),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Picker(
              tags: all.map((r) => r['tag'].toString()).toList(),
              loc: logLoc,
              det: '',
              showDet: false,
              onChanged: (l, _) => setState(() => logLoc = l),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration:
                BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
            child: Image.asset('assets/logo_mark.png', width: 74),
          ),
          const SizedBox(width: 10),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text(kMaintTitle, style: TextStyle(fontWeight: FontWeight.bold)),
                Text('Periode : ${periodOfKey(key)}', style: const TextStyle(fontSize: 12)),
              ])),
        ]),
        const SizedBox(height: 8),
        _legend(),
        const SizedBox(height: 6),
        Text('${list.length} sumber diperiksa · $bad dengan kondisi tidak bagus\n已检查 ${list.length} 个源 · $bad 个状况不良',
            style: TextStyle(fontSize: 12, color: bad > 0 ? kRed : Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            decoration: BoxDecoration(border: Border(left: border, top: border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                cell('No.\n序号', 40, bold: true, bg: head),
                cell('Tag\n位号', 130, bold: true, bg: head),
                cell('Date\n日期', 110, bold: true, bg: head),
                for (final c in kChecks) cell('${c[1]}\n${kChecksZh[c[0]] ?? ''}', 86, bold: true, bg: head),
                cell('Note\n备注', 200, bold: true, bg: head),
                cell('Worker\n工作人员', 140, bold: true, bg: head),
              ])),
              for (var i = 0; i < list.length; i++)
                Row(children: [
                  cell('${i + 1}', 40),
                  cell(list[i]['tag'].toString(), 130),
                  cell(idDate((list[i]['date'] ?? '').toString()), 110),
                  for (final c in kChecks)
                    cell((list[i][c[0]] ?? '*').toString(), 86,
                        bold: true,
                        bg: statusBg(stOf((list[i][c[0]] ?? '*').toString())),
                        fg: statusFg(stOf((list[i][c[0]] ?? '*').toString()))),
                  cell((list[i]['note'] ?? '').toString(), 200, left: true),
                  cell((list[i]['worker'] ?? '').toString(), 140),
                ]),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Salin untuk Excel · 复制到 Excel'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: tsv()));
              snack(context, 'Disalin. Tempel di tab Input Google Sheets\n已复制，请粘贴到 Google Sheets 的 Input 标签页');
            },
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('Kirim ke Sheets · 发送到表格'),
            onPressed: store.sheetUrl.isEmpty
                ? null
                : () {
                    store.enqueue('m:$key');
                    snack(context, 'Mengirim · 发送中 maintenance ${periodOfKey(key)}…');
                  },
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline, color: kRed),
            label: const Text('Hapus log · 删除记录', style: TextStyle(color: kRed)),
            onPressed: () async {
              if (await confirm(context,
                  'Hapus log perawatan ${periodOfKey(key)} dari HP ini? Data di Google Sheets tidak ikut terhapus.\n从本手机删除该维护记录？Google Sheets 中的数据不会被删除。')) {
                store.deleteMaintMonth(key);
              }
            },
          ),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.logOnly) return _log();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('Catat 记录'), icon: Icon(Icons.edit_note)),
            ButtonSegment(value: 1, label: Text('Log 记录'), icon: Icon(Icons.table_chart_outlined)),
          ],
          selected: {mode},
          onSelectionChanged: (v) => setState(() => mode = v.first),
        ),
      ),
      Expanded(child: mode == 0 ? _catat() : _log()),
    ]);
  }
}


/// Log Book dengan dua pilihan: Paparan dan Perawatan.
class LogBookPage extends StatefulWidget {
  final Store store;
  const LogBookPage({super.key, required this.store});
  @override
  State<LogBookPage> createState() => _LogBookPageState();
}

class _LogBookPageState extends State<LogBookPage> {
  int view = 0;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('Paparan 辐射'), icon: TrefoilIcon(size: 18)),
            ButtonSegment(
                value: 1, label: Text('Perawatan 维护'), icon: Icon(Icons.build_circle_outlined)),
          ],
          selected: {view},
          onSelectionChanged: (v) => setState(() => view = v.first),
        ),
      ),
      Expanded(
        child: IndexedStack(index: view, children: [
          LogPage(store: widget.store),
          MaintPage(store: widget.store, logOnly: true),
        ]),
      ),
    ]);
  }
}


// ===================== Form tambah / edit sumber =====================

class SrcForm extends StatefulWidget {
  const SrcForm({super.key, this.src, required this.others, required this.nextOrder});
  final Src? src;
  final Set<String> others;
  final int nextOrder;
  @override
  State<SrcForm> createState() => _SrcFormState();
}

class _SrcFormState extends State<SrcForm> {
  late final TextEditingController tag, name, order;
  late final Map<String, TextEditingController> info;
  String side = 'KA';
  String err = '';

  @override
  void initState() {
    super.initState();
    final s = widget.src;
    tag = TextEditingController(text: s?.tag ?? '');
    name = TextEditingController(text: s?.name ?? 'Cs-137');
    order = TextEditingController(text: '${s?.order ?? widget.nextOrder}');
    side = s?.side ?? 'KA';
    info = {
      for (final k in kSrcInfo)
        k[0]: TextEditingController(
            text: s?.info[k[0]] ?? (k[0] == 'holderType' ? 'SE82' : (k[0] == 'type' ? 'Cs7.P13' : '')))
    };
  }

  @override
  void dispose() {
    for (final c in [tag, name, order, ...info.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _mciChanged(String v) {
    final x = double.tryParse(v.replaceAll(',', '.'));
    if (x != null) info['actMBq']!.text = (x * 37).toStringAsFixed(0);
  }

  Widget _f(String key, {TextInputType? kb, ValueChanged<String>? onChanged, String? hint}) {
    final label = kSrcInfo.firstWhere((k) => k[0] == key)[1];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: info[key],
        keyboardType: kb,
        onChanged: onChanged,
        decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, border: const OutlineInputBorder()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.src != null;
    const kbNum = TextInputType.numberWithOptions(decimal: true);
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit sumber · 编辑放射源' : 'Tambah sumber · 添加放射源'),
        actions: [
          if (editing)
            IconButton(
              tooltip: 'Hapus 删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirm(context, 'Hapus ${widget.src!.tag}? Log lama tetap tersimpan.\n删除该放射源？旧记录仍保留。') &&
                    context.mounted) {
                  Navigator.pop(context, Src(0, '__delete__', '', ''));
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const Text('Identitas · 基本信息', style: TextStyle(fontWeight: FontWeight.bold, color: kBlue)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: tag,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                    labelText: 'Tag Number · 位号', hintText: 'mis. 102-DX-0101', isDense: true, border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: order,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Urutan · 顺序', isDense: true, border: OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Isotop · 同位素', isDense: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          const Text('Sisi pengukuran · 测量侧', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'KA', label: Text('KA (kanan)')),
              ButtonSegment(value: 'KI', label: Text('KI (kiri)')),
              ButtonSegment(value: 'B', label: Text('B')),
            ],
            selected: {side},
            onSelectionChanged: (v) => setState(() => side = v.first),
          ),
          const SizedBox(height: 16),
          const Text('Holder & kapsul · 源架与胶囊', style: TextStyle(fontWeight: FontWeight.bold, color: kBlue)),
          const SizedBox(height: 8),
          _f('holderSn', kb: TextInputType.number, hint: 'mis. 81134051'),
          _f('holderType', hint: 'SE82'),
          _f('capsuleSn', hint: 'mis. AD0053/23'),
          _f('type', hint: 'Cs7.P13'),
          const SizedBox(height: 6),
          const Text('Aktivitas (sertifikat) · 活度（证书）', style: TextStyle(fontWeight: FontWeight.bold, color: kBlue)),
          const SizedBox(height: 8),
          _f('actOrder', kb: kbNum, hint: '3 atau 5'),
          Row(children: [
            Expanded(child: _f('actReal', kb: kbNum, onChanged: _mciChanged)),
            const SizedBox(width: 8),
            Expanded(child: _f('actMBq', kb: kbNum)),
          ]),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: DateTime.tryParse(info['actDate']!.text) ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (d != null) setState(() => info['actDate']!.text = isoDate(d));
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Tgl Aktivitas · 活度日期', isDense: true, border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.edit_calendar_outlined)),
                child: Text(info['actDate']!.text.isEmpty ? '-' : idDate(info['actDate']!.text)),
              ),
            ),
          ),
          const Text('MBq dihitung otomatis dari mCi (1 mCi = 37 MBq) dan tetap bisa diubah.\nMBq 按 mCi 自动换算，可手动修改。',
              style: TextStyle(fontSize: 11)),
          if (err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(err, style: const TextStyle(color: kRed, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 18),
          FilledButton.icon(
            icon: const Icon(Icons.save_outlined),
            label: const Text('Simpan 保存'),
            onPressed: () {
              final t = tag.text.trim();
              if (t.isEmpty) {
                setState(() => err = 'Tag Number wajib diisi · 位号为必填项');
                return;
              }
              if (widget.others.contains(t)) {
                setState(() => err = 'Tag $t sudah dipakai sumber lain · 位号已被使用');
                return;
              }
              Navigator.pop(
                  context,
                  Src(
                    int.tryParse(order.text.trim()) ?? widget.nextOrder,
                    t,
                    name.text.trim().isEmpty ? 'Cs-137' : name.text.trim(),
                    side,
                    {
                      for (final e in info.entries)
                        if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim()
                    },
                  ));
            },
          ),
        ],
      ),
    );
  }
}
