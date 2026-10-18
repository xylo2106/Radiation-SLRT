import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kalkulator jarak aman radiasi gamma (sumber titik, hukum kuadrat terbalik)
/// berdasarkan Nilai Batas Dosis (NBD) Perka BAPETEN No. 4 Tahun 2013:
///  - Pekerja radiasi  : 20 mSv/tahun (Pasal 15)
///  - Anggota masyarakat (non pekerja radiasi): 1 mSv/tahun (Pasal 23)
///  - Daerah pengendalian: potensi > 3/10 NBD pekerja (Pasal 27)
///  - Daerah supervisi  : > NBD masyarakat dan < 3/10 NBD pekerja (Pasal 29)

const Color _navy = Color(0xFF16295E);
const Color _red = Color(0xFFC8202E);
const Color _amber = Color(0xFFB7791F);
const Color _green = Color(0xFF15803D);

class Nuclide {
  final String name;

  /// Konstanta laju dosis perkiraan, µSv/jam per GBq pada 1 m (tanpa perisai).
  final double gamma;

  /// HVL (cm) untuk timbal, baja, beton.
  final Map<String, double> hvl;
  const Nuclide(this.name, this.gamma, this.hvl);
}

const List<Nuclide> kNuclides = [
  Nuclide('Cs-137', 86, {'Timbal': 0.65, 'Baja': 1.6, 'Beton': 4.8}),
  Nuclide('Co-60', 342, {'Timbal': 1.2, 'Baja': 2.1, 'Beton': 6.2}),
  Nuclide('Ir-192', 125, {'Timbal': 0.48, 'Baja': 1.3, 'Beton': 4.3}),
  Nuclide('Am-241', 4, {'Timbal': 0.013, 'Baja': 0.1, 'Beton': 1.0}),
  Nuclide('Lainnya (isi manual)', 0, {}),
];
const Map<String, String> kShieldZh = {'Tanpa': '无', 'Timbal': '铅', 'Baja': '钢', 'Beton': '混凝土'};
const Map<String, double> kActToGBq = {'MBq': 0.001, 'GBq': 1, 'TBq': 1000, 'mCi': 0.037, 'Ci': 37};

double? _num(String v) => double.tryParse(v.trim().replaceAll(',', '.'));
String _f(double x, [int d = 2]) {
  if (x.isInfinite || x.isNaN) return '-';
  if (x >= 100) return x.toStringAsFixed(0);
  if (x >= 10) return x.toStringAsFixed(1);
  return x.toStringAsFixed(d);
}

class JarakPage extends StatefulWidget {
  const JarakPage({super.key});
  @override
  State<JarakPage> createState() => _JarakPageState();
}

class _JarakPageState extends State<JarakPage> {
  int mode = 0; // 0 = dari hasil ukur, 1 = dari aktivitas
  // hasil ukur
  final rate = TextEditingController(text: '');
  final dist = TextEditingController(text: '1');
  String tag = '';
  Map<String, String> lastMeter = {}; // tag -> nilai 1 m terakhir
  Map<String, String> lastWhen = {};
  List<Map<String, dynamic>> srcs = []; // data sumber dengan aktivitas sertifikat
  String srcTag = '';
  String decayInfo = '';
  // aktivitas
  Nuclide nuc = kNuclides.first;
  final gammaCtl = TextEditingController(text: '86');
  final act = TextEditingController(text: '');
  String actUnit = 'mCi';
  String shield = 'Tanpa';
  final thick = TextEditingController(text: '0');
  // parameter
  final nbdW = TextEditingController(text: '20');
  final nbdP = TextEditingController(text: '1');
  final hoursW = TextEditingController(text: '2000');
  final hoursP = TextEditingController(text: '2000');

  @override
  void initState() {
    super.initState();
    _loadLog();
    for (final c in [rate, dist, gammaCtl, act, thick, nbdW, nbdP, hoursW, hoursP]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [rate, dist, gammaCtl, act, thick, nbdW, nbdP, hoursW, hoursP]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Ambil nilai "1 meter Distance" terakhir per tag dari Log Book Paparan.
  Future<void> _loadLog() async {
    final p = await SharedPreferences.getInstance();
    try {
      srcs = (jsonDecode(p.getString('sources') ?? '[]') as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => _num((m['actReal'] ?? '').toString()) != null)
          .toList();
    } catch (_) {}
    try {
      final ses = Map<String, dynamic>.from(jsonDecode(p.getString('sessions') ?? '{}') as Map);
      final keys = ses.keys.toList()..sort();
      for (final k in keys) {
        final s = Map<String, dynamic>.from(ses[k] as Map);
        for (final r in (s['rows'] as List? ?? [])) {
          final m = Map<String, dynamic>.from(r as Map);
          final v = (m['meter'] ?? '').toString();
          if (_num(v) == null) continue;
          final t = (m['tag'] ?? '').toString();
          lastMeter[t] = v;
          lastWhen[t] = (m['date'] ?? s['date'] ?? k).toString();
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  static const Map<String, double> _halfLifeYears = {
    'Cs-137': 30.08,
    'Co-60': 5.27,
    'Ir-192': 0.2027,
    'Am-241': 432.2,
  };

  /// Isi aktivitas dari sertifikat sumber, dihitung peluruhannya sampai hari ini.
  void _useSource(String t) {
    final m = srcs.firstWhere((x) => x['tag'] == t, orElse: () => {});
    if (m.isEmpty) return;
    final a0 = _num((m['actReal'] ?? '').toString()) ?? 0;
    final iso = (m['name'] ?? 'Cs-137').toString();
    nuc = kNuclides.firstWhere((n) => n.name == iso, orElse: () => kNuclides.first);
    if (nuc.gamma > 0) gammaCtl.text = '${nuc.gamma}';
    final d0 = DateTime.tryParse((m['actDate'] ?? '').toString());
    var a = a0;
    final th = _halfLifeYears[nuc.name];
    if (d0 != null && th != null) {
      final years = DateTime.now().difference(d0).inDays / 365.25;
      a = a0 * math.pow(0.5, years / th);
      decayInfo = '${_f(a0, 2)} mCi (${m['actDate']}) → ${_f(a, 2)} mCi hari ini · 衰变至今日';
    } else {
      decayInfo = '';
    }
    srcTag = t;
    actUnit = 'mCi';
    act.text = a.toStringAsFixed(3);
  }

  /// Laju dosis pada 1 m (µSv/jam) dari input.
  double? get rate1m {
    if (mode == 0) {
      final r = _num(rate.text);
      final d = _num(dist.text);
      if (r == null || d == null || d <= 0 || r <= 0) return null;
      return r * d * d;
    }
    final g = _num(gammaCtl.text);
    final a = _num(act.text);
    if (g == null || a == null || g <= 0 || a <= 0) return null;
    var r = g * a * (kActToGBq[actUnit] ?? 1);
    final h = nuc.hvl[shield];
    final x = _num(thick.text) ?? 0;
    if (shield != 'Tanpa' && h != null && h > 0 && x > 0) r *= math.pow(0.5, x / h);
    return r;
  }

  /// Batas laju dosis (µSv/jam) = NBD (mSv/th) × 1000 / jam paparan per tahun.
  double _limit(TextEditingController nbd, TextEditingController hours, [double frac = 1]) {
    final n = _num(nbd.text) ?? 0;
    final h = _num(hours.text) ?? 0;
    if (n <= 0 || h <= 0) return double.nan;
    return n * frac * 1000 / h;
  }

  double _distFor(double r1, double limit) => math.sqrt(r1 / limit);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r1 = rate1m;
    final limW = _limit(nbdW, hoursW);
    final limCtrl = _limit(nbdW, hoursW, 0.3);
    final limP = _limit(nbdP, hoursP);
    final tags = lastMeter.keys.toList()..sort();

    Widget field(String label, TextEditingController c, {String? suffix, String? helper}) => TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: label,
              suffixText: suffix,
              helperText: helper,
              isDense: true,
              border: const OutlineInputBorder()),
        );

    Widget result(String title, String zh, double limit, Color color, String basis) {
      final d = r1 == null || limit.isNaN ? null : _distFor(r1, limit);
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        clipBehavior: Clip.antiAlias,
        child: Row(children: [
          Container(width: 8, height: 96, color: color),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$title · $zh', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text('Batas laju dosis · 剂量率限值: ${limit.isNaN ? '-' : _f(limit)} µSv/jam',
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
                Text(basis, style: TextStyle(fontSize: 11, color: scheme.outline)),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(d == null ? '-' : '≥ ${_f(d)} m',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
              Text('jarak aman · 安全距离', style: TextStyle(fontSize: 11, color: scheme.outline)),
            ]),
          ),
        ]),
      );
    }

    final rows = <double>[0.5, 1, 2, 3, 5, 10, 20, 50];
    Color zoneColor(double v) => v > limW
        ? _red
        : v > limCtrl
            ? _amber
            : v > limP
                ? const Color(0xFF2563EB)
                : _green;
    String zoneName(double v) => v > limW
        ? 'Melebihi batas pekerja · 超过工作人员限值'
        : v > limCtrl
            ? 'Daerah pengendalian · 控制区'
            : v > limP
                ? 'Daerah supervisi · 监督区'
                : 'Aman untuk masyarakat · 公众安全';

    String copyText() {
      if (r1 == null) return '';
      final b = StringBuffer('Perhitungan Jarak Aman Radiasi (Perka BAPETEN No. 4/2013)\n');
      if (mode == 0) {
        b.writeln('Sumber: ${tag.isEmpty ? '-' : tag} | Laju dosis terukur ${rate.text} µSv/jam pada ${dist.text} m');
      } else {
        b.writeln('Sumber: ${nuc.name} ${act.text} $actUnit | Γ ${gammaCtl.text} µSv/jam/GBq@1m'
            '${shield == 'Tanpa' ? '' : ' | Perisai $shield ${thick.text} cm'}');
      }
      b.writeln('Laju dosis pada 1 m: ${_f(r1)} µSv/jam');
      b.writeln('Pekerja radiasi (NBD ${nbdW.text} mSv/th, ${hoursW.text} jam/th): batas ${_f(limW)} µSv/jam → jarak aman ≥ ${_f(_distFor(r1, limW))} m');
      b.writeln('Batas daerah pengendalian (3/10 NBD): ${_f(limCtrl)} µSv/jam → ≥ ${_f(_distFor(r1, limCtrl))} m');
      b.writeln('Non pekerja radiasi / masyarakat (NBD ${nbdP.text} mSv/th, ${hoursP.text} jam/th): batas ${_f(limP)} µSv/jam → jarak aman ≥ ${_f(_distFor(r1, limP))} m');
      return b.toString();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Jarak Aman Radiasi · 辐射安全距离')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('Dari hasil ukur 实测'), icon: Icon(Icons.speed)),
              ButtonSegment(value: 1, label: Text('Dari aktivitas 活度'), icon: Icon(Icons.science_outlined)),
            ],
            selected: {mode},
            onSelectionChanged: (v) => setState(() => mode = v.first),
          ),
          const SizedBox(height: 12),
          if (mode == 0) ...[
            if (tags.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                value: tag.isEmpty ? null : tag,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Ambil dari Log Book Paparan (1 meter) · 从辐射记录获取',
                    isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  for (final t in tags)
                    DropdownMenuItem(value: t, child: Text('$t  ·  ${lastMeter[t]} µSv/jam')),
                ],
                onChanged: (v) => setState(() {
                  tag = v ?? '';
                  rate.text = (lastMeter[tag] ?? '').replaceAll(',', '.');
                  dist.text = '1';
                }),
              ),
              if (tag.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Data log ${lastWhen[tag]} · 记录日期',
                      style: TextStyle(fontSize: 11, color: scheme.outline)),
                ),
              const SizedBox(height: 12),
            ],
            Row(children: [
              Expanded(flex: 3, child: field('Laju dosis terukur · 实测剂量率', rate, suffix: 'µSv/jam')),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: field('Pada jarak · 测量距离', dist, suffix: 'm')),
            ]),
          ] else ...[
            if (srcs.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                value: srcTag.isEmpty ? null : srcTag,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Ambil dari data sumber (sertifikat) · 从放射源数据获取',
                    isDense: true,
                    border: OutlineInputBorder()),
                items: [
                  for (final m in srcs)
                    DropdownMenuItem(
                        value: m['tag'].toString(),
                        child: Text('${m['tag']} · ${m['actReal']} mCi')),
                ],
                onChanged: (v) => setState(() => _useSource(v ?? '')),
              ),
              if (decayInfo.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(decayInfo, style: TextStyle(fontSize: 11, color: scheme.outline)),
                ),
              const SizedBox(height: 12),
            ],
            DropdownButtonFormField<Nuclide>(
              value: nuc,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Radionuklida · 放射性核素', isDense: true, border: OutlineInputBorder()),
              items: [for (final n in kNuclides) DropdownMenuItem(value: n, child: Text(n.name))],
              onChanged: (v) => setState(() {
                nuc = v ?? nuc;
                if (nuc.gamma > 0) gammaCtl.text = '${nuc.gamma}';
                if (!nuc.hvl.containsKey(shield)) shield = 'Tanpa';
              }),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(flex: 3, child: field('Aktivitas · 活度', act)),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  value: actUnit,
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                  items: [for (final u in kActToGBq.keys) DropdownMenuItem(value: u, child: Text(u))],
                  onChanged: (v) => setState(() => actUnit = v ?? actUnit),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            field('Konstanta laju dosis Γ · 剂量率常数', gammaCtl,
                suffix: 'µSv/jam per GBq @1 m', helper: 'Nilai perkiraan; ganti bila punya data pabrikan'),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  value: shield,
                  decoration: const InputDecoration(
                      labelText: 'Perisai · 屏蔽', isDense: true, border: OutlineInputBorder()),
                  items: [
                    for (final s in ['Tanpa', ...nuc.hvl.keys])
                      DropdownMenuItem(
                          value: s,
                          child: Text('$s ${kShieldZh[s] ?? ''}'
                              '${nuc.hvl[s] == null ? '' : ' (HVL ${nuc.hvl[s]} cm)'}')),
                  ],
                  onChanged: (v) => setState(() => shield = v ?? 'Tanpa'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: field('Tebal · 厚度', thick, suffix: 'cm')),
            ]),
          ],
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Parameter batas dosis · 剂量限值参数', style: TextStyle(fontSize: 14)),
            subtitle: Text('NBD ${nbdW.text} / ${nbdP.text} mSv per tahun · ${hoursW.text} / ${hoursP.text} jam',
                style: TextStyle(fontSize: 12, color: scheme.outline)),
            children: [
              Row(children: [
                Expanded(child: field('NBD pekerja · 工作人员', nbdW, suffix: 'mSv/th')),
                const SizedBox(width: 8),
                Expanded(child: field('Jam paparan/th · 年照射小时', hoursW, suffix: 'jam')),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: field('NBD masyarakat · 公众', nbdP, suffix: 'mSv/th')),
                const SizedBox(width: 8),
                Expanded(child: field('Jam keberadaan/th · 年停留小时', hoursP, suffix: 'jam')),
              ]),
              const SizedBox(height: 6),
              Text(
                  'Default 2000 jam/tahun (40 jam × 50 minggu). Isi pembatas dosis perusahaan bila lebih ketat dari NBD.\n'
                  '默认每年 2000 小时（每周 40 小时 × 50 周）。如公司剂量约束更严格，请填写。',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
              const SizedBox(height: 8),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: _navy.withAlpha(16), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.radar, color: _navy),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  r1 == null
                      ? 'Isi laju dosis atau aktivitas sumber · 请输入剂量率或活度'
                      : 'Laju dosis pada 1 m · 1 米处剂量率: ${_f(r1)} µSv/jam',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          result('Pekerja Radiasi', '辐射工作人员', limW, _red,
              'NBD ${nbdW.text} mSv/th ÷ ${hoursW.text} jam · Perka BAPETEN 4/2013 Ps. 15'),
          result('Batas Daerah Pengendalian', '控制区边界', limCtrl, _amber,
              '3/10 NBD pekerja · Perka BAPETEN 4/2013 Ps. 27'),
          result('Non Pekerja Radiasi (Masyarakat)', '非辐射工作人员（公众）', limP, _green,
              'NBD ${nbdP.text} mSv/th ÷ ${hoursP.text} jam · Perka BAPETEN 4/2013 Ps. 23 & 29'),
          if (r1 != null) ...[
            const SizedBox(height: 8),
            const Text('Laju dosis menurut jarak · 不同距离剂量率',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(10)),
              child: Column(children: [
                for (final d in rows)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: scheme.outlineVariant, width: .5))),
                    child: Row(children: [
                      SizedBox(width: 56, child: Text('${_f(d, 1)} m', style: const TextStyle(fontWeight: FontWeight.w600))),
                      SizedBox(width: 110, child: Text('${_f(r1 / (d * d))} µSv/jam')),
                      Container(width: 10, height: 10, decoration: BoxDecoration(color: zoneColor(r1 / (d * d)), shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Expanded(child: Text(zoneName(r1 / (d * d)), style: const TextStyle(fontSize: 12))),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Salin hasil · 复制结果'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: copyText()));
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Hasil disalin · 结果已复制')));
                },
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Rumus: Ḋ(d) = Ḋ₁ / d² (sumber titik, hukum kuadrat terbalik); d aman = √(Ḋ₁ / batas laju dosis). '
            'Hasil adalah perkiraan dan tidak menggantikan pengukuran survei meter di lapangan. Tetapkan batas daerah '
            'dengan pengukuran langsung dan pasang tanda radiasi.\n'
            '公式：Ḋ(d) = Ḋ₁ / d²（点源，平方反比定律）。结果为估算值，不能替代现场巡测仪测量。',
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}
