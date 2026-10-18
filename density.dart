import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';

const double kTol = 4.0; // batas selisih detektor (%)
const Color kBlue = Color(0xFF2563EB);
const Color kRed = Color(0xFFD92D20);
const Color kGreen = Color(0xFF16A34A);
const Color kYellow = Color(0xFFFFE94D);
const Color kOrange = Color(0x33FFA03C);


// ===================== Helper =====================

double? numOf(dynamic x) => (x is num && x.isFinite) ? x.toDouble() : null;

List<double?> list3(dynamic a) => List<double?>.generate(
    3, (i) => (a is List && i < a.length) ? numOf(a[i]) : null);

double? avgOf(Iterable<double?> xs) {
  final v = xs.whereType<double>().toList();
  if (v.isEmpty) return null;
  return v.reduce((a, b) => a + b) / v.length;
}

double? sdOf(Iterable<double?> xs) {
  final v = xs.whereType<double>().toList();
  if (v.length < 2) return null;
  final m = v.reduce((a, b) => a + b) / v.length;
  final s = v.fold<double>(0, (p, x) => p + (x - m) * (x - m));
  return math.sqrt(s / (v.length - 1));
}

double? errOf(double? a, double? b) =>
    (a != null && b != null && a > 0) ? (b - a) / a * 100 : null;

String fx(double? x, [int d = 2]) => x == null ? '–' : x.toStringAsFixed(d);

String pct(double? x, {bool sign = false}) => x == null
    ? '–'
    : '${sign && x > 0 ? '+' : ''}${x.toStringAsFixed(2)}%';

String two(int n) => n.toString().padLeft(2, '0');
String fmtDate(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';
String fmtDateTime(DateTime d) =>
    '${fmtDate(d)} ${two(d.hour)}:${two(d.minute)}';

double? parseNum(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

String csvCell(Object? x) => '"${(x ?? '').toString().replaceAll('"', '""')}"';

void snack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

Future<bool> confirm(BuildContext context, String msg) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(msg),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal 取消')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus 删除')),
      ],
    ),
  );
  return r ?? false;
}

// ===================== Data =====================

/// Satu catatan pengukuran. Kunci JSON sama dengan versi web,
/// jadi skrip Google Sheets (Code.gs) tetap bisa dipakai.
class Rec {
  final Map<String, dynamic> j;
  Rec(this.j);

  int get ts => (j['ts'] as num?)?.toInt() ?? 0;
  DateTime get date => DateTime.fromMillisecondsSinceEpoch(ts);
  String get tag => (j['n'] ?? '').toString();
  String get cb => (j['cb'] ?? '').toString();
  double? get w => numOf(j['w']);
  double? get dac => numOf(j['dac']);
  List<double?> get m => list3(j['m']);
  List<double?> get v => list3(j['v']);
  List<double?> get d => list3(j['d']);
  List<double?> get c => list3(j['c']);
  List<double?> get dt => list3(j['dt']);
  double? get mean => numOf(j['mean']);
  double? get cmean => numOf(j['cmean']);
  double? get dtmean => numOf(j['dtmean']);

  List<double?> get errs => List.generate(3, (i) => errOf(d[i], dt[i]));
  double? get avgAbsErr => avgOf(errs.map((e) => e?.abs()));

  bool get bad {
    final es = [...errs, errOf(mean, dtmean)];
    return es.any((e) => e != null && e.abs() > kTol);
  }

  String get monthKey => '${date.year}-${two(date.month)}';
}

class Store extends ChangeNotifier {
  late SharedPreferences p;
  bool ready = false;
  List<Rec> recs = [];
  String sheetUrl = '';
  List<Map<String, dynamic>> queue = [];
  String lastError = '';
  bool _busy = false;

  String loadError = '';

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
    try {
      recs = (jsonDecode(p.getString('riwayat') ?? '[]') as List)
          .map((e) => Rec(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      recs = [];
    }
    sheetUrl = kDensSheetUrl;
    try {
      if (sheetUrl.isEmpty) sheetUrl = p.getString('dens_sheet_url') ?? '';
    } catch (_) {}
    try {
      queue = (jsonDecode(p.getString('dens_queue') ?? '[]') as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      queue = [];
    }
  }

  Future<void> _saveRecs() =>
      p.setString('riwayat', jsonEncode(recs.map((r) => r.j).toList()));
  Future<void> _saveQueue() => p.setString('dens_queue', jsonEncode(queue));

  Future<void> add(Rec r) async {
    recs.insert(0, r);
    await _saveRecs();
    notifyListeners();
    if (sheetUrl.isNotEmpty) {
      queue.add(r.j);
      await _saveQueue();
      flush();
    }
  }

  Future<void> remove(Rec r) async {
    recs.remove(r);
    await _saveRecs();
    notifyListeners();
  }

  Future<void> clearAll() async {
    recs = [];
    await _saveRecs();
    notifyListeners();
  }

  Future<void> setUrl(String u) async {
    sheetUrl = u.trim();
    await p.setString('dens_sheet_url', sheetUrl);
    lastError = '';
    notifyListeners();
    flush();
  }

  Future<void> sendAll() async {
    queue.addAll(recs.reversed.map((r) => r.j));
    await _saveQueue();
    notifyListeners();
    flush();
  }

  /// Kirim antrean ke Google Apps Script. Baris yang sama tidak
  /// akan dobel karena Code.gs memeriksa ID (ts).
  Future<void> flush() async {
    if (_busy || sheetUrl.isEmpty || queue.isEmpty) return;
    _busy = true;
    notifyListeners();
    try {
      while (queue.isNotEmpty) {
        final res = await http
            .post(Uri.parse(sheetUrl),
                headers: {'Content-Type': 'text/plain;charset=utf-8'},
                body: jsonEncode(queue.first))
            .timeout(const Duration(seconds: 30));
        // Apps Script menjawab 200 atau 302 (redirect) bila berhasil.
        if (res.statusCode >= 400) {
          lastError = 'Gagal kirim (HTTP ${res.statusCode}). Periksa alamat web app.\n发送失败，请检查 web app 地址。';
          break;
        }
        queue.removeAt(0);
        await _saveQueue();
        lastError = '';
      }
    } catch (_) {
      lastError = 'Belum terkirim: tidak ada koneksi atau alamat salah.\n未发送：无网络或地址错误。';
    }
    _busy = false;
    notifyListeners();
  }
}

String riwayatCsv(List<Rec> recs) {
  final head = [
    'Waktu', 'Tag Number', 'Bejana (g)',
    'Massa total 1 (g)', 'Massa total 2 (g)', 'Massa total 3 (g)',
    'Volume (mL)',
    'rho actual 1', 'rho actual 2', 'rho actual 3', 'Rata-rata rho actual',
    'cts1', 'cts2', 'cts3', 'Rata-rata cts',
    'rho DCS 1', 'rho DCS 2', 'rho DCS 3', 'Rata-rata rho DCS',
    'Error 1 (%)', 'Error 2 (%)', 'Error 3 (%)',
    'Status', 'Check By', 'Density Aft Calib',
  ];
  String n(double? x) => x == null ? '' : x.toStringAsFixed(2);
  final rows = recs.map((r) => [
        fmtDateTime(r.date), r.tag, n(r.w),
        ...r.m.map(n), n(r.v[0]),
        ...r.d.map(n), n(r.mean),
        ...r.c.map(n), n(r.cmean),
        ...r.dt.map(n), n(r.dtmean),
        ...r.errs.map(n),
        r.bad ? 'Kalibrasi' : 'OK', r.cb, n(r.dac),
      ].map(csvCell).join(','));
  return [head.map(csvCell).join(','), ...rows].join('\n');
}

// ===================== Aplikasi =====================

class DensitasApp extends StatelessWidget {
  const DensitasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Density SLRT',
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
            title: Text(const ['Ukur 测量', 'Riwayat 历史', 'Rekap 汇总'][tab]),
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
              UkurPage(store: store, onSaved: () => setState(() => tab = 1)),
              RiwayatPage(store: store),
              RekapPage(store: store),
            ])),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.science_outlined), label: 'Ukur 测量'),
              NavigationDestination(
                  icon: Icon(Icons.history), label: 'Riwayat 历史'),
              NavigationDestination(
                  icon: Icon(Icons.bar_chart), label: 'Rekap 汇总'),
            ],
          ),
        );
      },
    );
  }
}

// ===================== Layar Ukur =====================

class UkurPage extends StatefulWidget {
  final Store store;
  final VoidCallback onSaved;
  const UkurPage({super.key, required this.store, required this.onSaved});

  @override
  State<UkurPage> createState() => _UkurPageState();
}

class _UkurPageState extends State<UkurPage> {
  final tag = TextEditingController();
  final tare = TextEditingController();
  final vol = TextEditingController();
  final cb = TextEditingController();
  final dac = TextEditingController();
  final m = List.generate(3, (_) => TextEditingController());
  final c = List.generate(3, (_) => TextEditingController());
  final x = List.generate(3, (_) => TextEditingController());

  @override
  void initState() {
    super.initState();
    tare.text = widget.store.p.getString('bejana_w') ?? '';
    vol.text = widget.store.p.getString('bejana_v') ?? '';
  }

  @override
  void dispose() {
    for (final t in [tag, tare, vol, cb, dac, ...m, ...c, ...x]) {
      t.dispose();
    }
    super.dispose();
  }

  List<double?> get dens {
    final w = parseNum(tare.text) ?? 0;
    final v = parseNum(vol.text);
    return List.generate(3, (i) {
      final mm = parseNum(m[i].text);
      if (mm == null || v == null || v <= 0) return null;
      final net = mm - w;
      return net > 0 ? net / v * 1000 : null;
    });
  }

  List<double?> get cts => c.map((e) => parseNum(e.text)).toList();
  List<double?> get det => x.map((e) => parseNum(e.text)).toList();

  Widget _field(TextEditingController ctl, String label,
      {bool text = false, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: ctl,
      keyboardType: text
          ? TextInputType.text
          : const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (s) {
        onChanged?.call(s);
        setState(() {});
      },
    );
  }

  Widget _kv(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v,
              style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ]),
      );

  Widget _repCard(int i, double? rho, double? err) {
    final over = err != null && err.abs() > kTol;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Pengulangan ${i + 1} · 第 ${i + 1} 次',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _field(m[i], 'Massa total (g) · 总质量')),
              const SizedBox(width: 6),
              Expanded(child: _field(c[i], 'cts (cps)')),
              const SizedBox(width: 6),
              Expanded(child: _field(x[i], 'ρ DCS')),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: Text('ρ actual · 实际ρ: ${fx(rho)} kg/m³')),
              Text(
                err == null
                    ? ''
                    : 'Error ${pct(err, sign: true)}${over ? ' ⚠' : ''}',
                style: TextStyle(
                  color: over ? kRed : null,
                  fontWeight: over ? FontWeight.bold : null,
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final d = dens, cs = cts, dt = det;
    if (d.contains(null) || cs.contains(null) || dt.contains(null)) {
      snack(context,
          'Isi berat dan volume bejana, lalu lengkapi massa, cts, dan ρ DCS untuk ketiga pengulangan.\n填写容器重量和体积，然后填写三次重复的质量、cts 和 ρ DCS。');
      return;
    }
    final now = DateTime.now();
    final j = <String, dynamic>{
      'ts': now.millisecondsSinceEpoch,
      't': fmtDateTime(now),
      'n': tag.text.trim(),
      'w': parseNum(tare.text) ?? 0,
      'm': m.map((e) => parseNum(e.text)).toList(),
      'v': List<double?>.filled(3, parseNum(vol.text)),
      'd': d,
      'mean': avgOf(d),
      'c': cs,
      'cmean': avgOf(cs),
      'dt': dt,
      'dtmean': avgOf(dt),
      'cb': cb.text.trim(),
    };
    final z = parseNum(dac.text);
    if (z != null) j['dac'] = z;
    final r = Rec(j);
    await widget.store.add(r);
    if (!mounted) return;
    if (r.bad) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Perlu kalibrasi · 需要校准'),
          content: const Text(
              'Selisih densitas detektor melebihi 4%. Detektor harus dikalibrasi.\n探测器密度偏差超过 4%，必须校准。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    }
    for (final t in [...m, ...c, ...x, dac]) {
      t.clear();
    }
    setState(() {});
    widget.onSaved();
  }

  void _clear() {
    for (final t in [tag, cb, dac, ...m, ...c, ...x]) {
      t.clear();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final d = dens, cs = cts, dt = det;
    final mean = avgOf(d), cmean = avgOf(cs), dtmean = avgOf(dt);
    final errs = List.generate(3, (i) => errOf(d[i], dt[i]));
    final meanErr = errOf(mean, dtmean);
    final checks = [...errs, meanErr].whereType<double>().toList();
    final bad = checks.any((e) => e.abs() > kTol);
    final complete = checks.length == 4;
    final muted = Theme.of(context).colorScheme.outline;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _field(tag, 'Tag Number', text: true),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: _field(tare, 'Berat bejana (g) · 容器重量',
                onChanged: (s) => widget.store.p.setString('bejana_w', s)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _field(vol, 'Volume bejana (mL) · 容器体积',
                onChanged: (s) => widget.store.p.setString('bejana_v', s)),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Text(
            'Berat dan volume bejana tersimpan dan berlaku untuk ketiga pengulangan.\n容器重量和体积已保存，适用于三次重复。',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ),
        for (var i = 0; i < 3; i++) _repCard(i, d[i], errs[i]),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              _kv('Rata-rata ρ actual · 实际ρ平均值', '${fx(mean)} kg/m³'),
              _kv('Simpangan baku ρ · ρ 标准偏差', fx(sdOf(d))),
              _kv('Rata-rata ρ DCS · DCS ρ 平均值', '${fx(dtmean)} kg/m³'),
              _kv('Selisih rata-rata · 平均偏差', pct(meanErr, sign: true),
                  color: meanErr != null && meanErr.abs() > kTol
                      ? kRed
                      : null),
              _kv('Rata-rata cts · cts 平均值', '${fx(cmean)} cps'),
              _kv('Simpangan baku cts · cts 标准偏差', fx(sdOf(cs))),
            ]),
          ),
        ),
        if (checks.isNotEmpty && (bad || complete))
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (bad ? kRed : kGreen).withAlpha(30),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              bad
                  ? '⚠ Detektor harus dikalibrasi. Selisih dengan densitas actual melebihi 4%.\n探测器必须校准，与实际密度偏差超过 4%。'
                  : '✓ Selisih detektor dalam batas (4%).\n探测器偏差在允许范围内 (4%)。',
              style: TextStyle(
                  color: bad ? kRed : kGreen, fontWeight: FontWeight.bold),
            ),
          ),
        const SizedBox(height: 12),
        _field(cb, 'Check by (pisahkan dengan koma) · 检查人（逗号分隔）', text: true),
        const SizedBox(height: 12),
        _field(dac, 'Density setelah kalibrasi (opsional) · 校准后密度（可选）'),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: FilledButton(
                onPressed: _save, child: const Text('Catat pengukuran · 记录测量')),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _clear, child: const Text('Kosongkan · 清空')),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ===================== Layar Riwayat =====================

class RiwayatPage extends StatelessWidget {
  final Store store;
  const RiwayatPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final recs = store.recs;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            onPressed: recs.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: riwayatCsv(recs)));
                    snack(context, 'CSV disalin · CSV 已复制');
                  },
            icon: const Icon(Icons.copy),
            label: const Text('Salin CSV · 复制 CSV'),
          ),
          OutlinedButton.icon(
            onPressed: recs.isEmpty
                ? null
                : () async {
                    if (await confirm(context,
                        'Hapus semua riwayat di HP ini? Data di Google Sheets tidak ikut terhapus.\n删除本手机上的全部历史记录？Google Sheets 中的数据不会被删除。')) {
                      store.clearAll();
                    }
                  },
            icon: const Icon(Icons.delete_outline),
            label: const Text('Hapus semua · 全部删除'),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('Tekan lama sebuah catatan untuk menghapusnya.\n长按记录即可删除。',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.outline)),
        ),
        if (recs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Belum ada catatan · 暂无记录')),
          ),
        for (var i = 0; i < recs.length; i++)
          RecCard(
            rec: recs[i],
            no: recs.length - i,
            onDelete: () => store.remove(recs[i]),
          ),
      ],
    );
  }
}

class RecCard extends StatelessWidget {
  final Rec rec;
  final int no;
  final VoidCallback onDelete;
  const RecCard(
      {super.key, required this.rec, required this.no, required this.onDelete});

  TableRow _row(String label, List<String> vals,
      {Color? bg, Color? labelBg, List<bool>? red, bool bold = false}) {
    return TableRow(
      decoration: bg == null ? null : BoxDecoration(color: bg),
      children: [
        Container(
          color: labelBg,
          padding: const EdgeInsets.all(6),
          child: Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: labelBg != null ? Colors.black : null)),
        ),
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              vals[i],
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: bold ? FontWeight.bold : null,
                color: (red != null && red[i]) ? kRed : null,
              ),
            ),
          ),
      ],
    );
  }

  Widget _info(BuildContext context, String l, String v, {Color? color}) {
    return Container(
      width: 150,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l,
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).colorScheme.outline)),
          Text(v,
              style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bad = rec.bad;
    final e = rec.errs;
    final avgErr = rec.avgAbsErr;
    final hasDetail = rec.m.any((x) => x != null);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onLongPress: () async {
          if (await confirm(context, 'Hapus catatan #$no? · 删除记录 #$no？')) onDelete();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('#$no',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 10),
                Text(fmtDate(rec.date)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rec.tag.isEmpty ? '-' : rec.tag,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('Dev. rata-rata · 平均偏差 ${pct(avgErr)}',
                          style: TextStyle(
                              fontSize: 12,
                              color: avgErr != null && avgErr > kTol
                                  ? kRed
                                  : Theme.of(context).colorScheme.outline)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: bad ? kRed : kGreen,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(bad ? 'Calibration!!' : 'OK',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ]),
              const SizedBox(height: 10),
              Table(
                border:
                    TableBorder.all(color: Theme.of(context).dividerColor),
                columnWidths: const {0: FlexColumnWidth(1.5)},
                children: [
                  _row('', const ['1', '2', '3'], bold: true),
                  _row('Actual', rec.d.map((v) => fx(v, 1)).toList()),
                  _row('DCS', rec.dt.map((v) => fx(v, 1)).toList()),
                  _row('Deviation %', e.map((v) => pct(v?.abs())).toList(),
                      bg: kOrange,
                      bold: true,
                      red: e.map((v) => v != null && v.abs() > kTol).toList()),
                  _row('CTS', rec.c.map((v) => fx(v, 0)).toList(),
                      labelBg: kYellow),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _info(context, 'Check by', rec.cb.isEmpty ? '----' : rec.cb),
                _info(context, 'Actual Density (kg/m³)', fx(rec.mean, 1)),
                _info(context, 'CTS (rata-rata)', fx(rec.cmean, 1)),
                _info(context, 'Density Aft Calib',
                    rec.dac == null ? 'isi data manual' : fx(rec.dac, 1),
                    color: rec.dac == null && bad ? kRed : null),
              ]),
              if (hasDetail)
                Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Detail massa dan volume · 质量与体积详情',
                        style: TextStyle(fontSize: 13)),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Berat bejana: ${fx(rec.w)} g\n'
                          'Volume bejana: ${fx(rec.v[0])} mL\n'
                          'Massa total: ${rec.m.map((v) => fx(v)).join(' / ')} g',
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===================== Layar Rekap =====================

class RekapPage extends StatefulWidget {
  final Store store;
  const RekapPage({super.key, required this.store});

  @override
  State<RekapPage> createState() => _RekapPageState();
}

class _RekapPageState extends State<RekapPage> {
  String? month;
  final urlCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    urlCtl.text = widget.store.sheetUrl;
  }

  @override
  void dispose() {
    urlCtl.dispose();
    super.dispose();
  }

  double? _avgErr(List<Rec> a) =>
      avgOf(a.expand((r) => r.errs.map((e) => e?.abs())));

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final recs = store.recs;
    final months = recs.map((r) => r.monthKey).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    final sel = (month != null && months.contains(month))
        ? month
        : (months.isEmpty ? null : months.first);
    final list = recs.where((r) => r.monthKey == sel).toList();
    final groups = <String, List<Rec>>{};
    for (final r in list) {
      groups.putIfAbsent(r.tag.isEmpty ? '(tanpa tag · 无位号)' : r.tag, () => []).add(r);
    }
    final keys = groups.keys.toList()..sort();

    String rekapCsv() {
      final head = [
        'Bulan', 'Tag Number', 'Jumlah', 'Rata-rata rho actual',
        'Rata-rata rho DCS', 'Rata-rata cts', 'Rata-rata |error| (%)',
        'Jumlah Kalibrasi'
      ];
      final rows = keys.map((k) {
        final a = groups[k]!;
        return [
          sel, k, a.length,
          fx(avgOf(a.map((r) => r.mean))),
          fx(avgOf(a.map((r) => r.dtmean))),
          fx(avgOf(a.map((r) => r.cmean))),
          fx(_avgErr(a)),
          a.where((r) => r.bad).length,
        ].map(csvCell).join(',');
      });
      return [head.map(csvCell).join(','), ...rows].join('\n');
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Rekap bulanan · 月度汇总',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                DropdownButton<String>(
                  isExpanded: true,
                  value: sel,
                  hint: const Text('Belum ada data · 暂无数据'),
                  items: months
                      .map((k) =>
                          DropdownMenuItem(value: k, child: Text(k)))
                      .toList(),
                  onChanged: (v) => setState(() => month = v),
                ),
                _kv('Jumlah catatan · 记录数', '${list.length}'),
                _kv('Perlu kalibrasi · 需要校准', '${list.where((r) => r.bad).length}'),
                _kv('Rata-rata ρ actual · 实际ρ平均值',
                    '${fx(avgOf(list.map((r) => r.mean)))} kg/m³'),
                _kv('Rata-rata ρ DCS · DCS ρ 平均值',
                    '${fx(avgOf(list.map((r) => r.dtmean)))} kg/m³'),
                _kv('Rata-rata cts · cts 平均值',
                    '${fx(avgOf(list.map((r) => r.cmean)))} cps'),
                _kv('Rata-rata |error| · 平均误差', pct(_avgErr(list))),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 16,
                    columns: const [
                      DataColumn(label: Text('Tag Number 位号')),
                      DataColumn(label: Text('Jumlah 数量'), numeric: true),
                      DataColumn(label: Text('ρ actual 实际'), numeric: true),
                      DataColumn(label: Text('ρ DCS'), numeric: true),
                      DataColumn(label: Text('cts'), numeric: true),
                      DataColumn(label: Text('|Error| 误差'), numeric: true),
                      DataColumn(label: Text('Kalibrasi 校准'), numeric: true),
                    ],
                    rows: keys.map((k) {
                      final a = groups[k]!;
                      return DataRow(cells: [
                        DataCell(Text(k)),
                        DataCell(Text('${a.length}')),
                        DataCell(Text(fx(avgOf(a.map((r) => r.mean))))),
                        DataCell(Text(fx(avgOf(a.map((r) => r.dtmean))))),
                        DataCell(Text(fx(avgOf(a.map((r) => r.cmean))))),
                        DataCell(Text(pct(_avgErr(a)))),
                        DataCell(Text('${a.where((r) => r.bad).length}')),
                      ]);
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: keys.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(
                                ClipboardData(text: rekapCsv()));
                            snack(context, 'CSV rekap disalin · 汇总 CSV 已复制');
                          },
                    icon: const Icon(Icons.copy),
                    label: const Text('Salin CSV rekap · 复制汇总 CSV'),
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
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline),
                ),
                if (store.lastError.isNotEmpty)
                  Text(store.lastError,
                      style: const TextStyle(fontSize: 12, color: kRed)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton(
                    onPressed: store.sheetUrl.isEmpty || recs.isEmpty
                        ? null
                        : () {
                            store.sendAll();
                            snack(context, 'Mengirim semua riwayat… · 正在发送全部历史…');
                          },
                    child: const Text('Kirim semua riwayat · 发送全部历史'),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
