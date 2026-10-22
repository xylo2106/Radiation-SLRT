import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'density.dart' show Rec;
import 'laporan.dart' show LapRec, lapAutoFromRadiation, kJobTypes, kLapMonths;
import 'sources_util.dart';
import 'sync.dart';
import 'config.dart';

/// Statistik pekerjaan & produktivitas PPR, dihitung dari data di HP:
/// Laporan Kerja (manual + otomatis), Log Book Paparan, Perawatan,
/// Rekaman Buka/Tutup Sumber dan Density.
class StatistikPage extends StatefulWidget {
  const StatistikPage({super.key});
  @override
  State<StatistikPage> createState() => _StatistikPageState();
}

class _Data {
  List<LapRec> laps = [];
  List<String> tags = []; // semua sumber terdaftar
  Map<String, Set<String>> expTags = {}; // bulan -> tag yang diukur paparannya
  Map<String, Set<String>> notInst = {}; // bulan -> tag belum terpasang
  Map<String, Set<String>> mntTags = {}; // bulan -> tag yang dirawat
  Map<String, int> mntBad = {}; // bulan -> jumlah item "tidak bagus"
  Map<String, int> densOk = {}, densBad = {}; // bulan -> jumlah pengukuran density
  Map<String, int> btCount = {}; // bulan -> jumlah buka/tutup
  int btOpen = 0; // sumber yang masih terbuka
}

String _two2(int v) => v.toString().padLeft(2, '0');
String _mkOf(DateTime d) => '${d.year}-${_two2(d.month)}';

Future<_Data> _loadData(SharedPreferences p) async {
    final d = _Data();
    Map<String, dynamic> read(String k) {
      try {
        return Map<String, dynamic>.from(jsonDecode(p.getString(k) ?? '{}') as Map);
      } catch (_) {
        return {};
      }
    }

    // Laporan kerja: entri tersimpan + entri otomatis yang belum tersimpan
    try {
      d.laps = (jsonDecode(p.getString('laporan') ?? '[]') as List)
          .map((e) => LapRec.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {}
    try {
      final ids = d.laps.map((r) => r.id).toSet();
      d.laps.addAll(lapAutoFromRadiation(p).where((r) => !ids.contains(r.id)));
    } catch (_) {}

    try {
      d.tags = (jsonDecode(await sourcesJson(p)) as List)
          .map((e) => ((e as Map)['tag'] ?? '').toString())
          .where((t) => t.isNotEmpty)
          .toList();
    } catch (_) {}

    read('sessions').forEach((month, v) {
      try {
        for (final r in ((v as Map)['rows'] as List? ?? [])) {
          final m = Map<String, dynamic>.from(r as Map);
          final tag = (m['tag'] ?? '').toString();
          if (tag.isEmpty) continue;
          final s = (m['surface'] ?? '').toString().trim(), mt = (m['meter'] ?? '').toString().trim();
          if (s == '-' && mt == '-') {
            d.notInst.putIfAbsent(month, () => {}).add(tag);
          } else if (s.isNotEmpty || mt.isNotEmpty) {
            d.expTags.putIfAbsent(month, () => {}).add(tag);
          }
        }
      } catch (_) {}
    });
    read('maint').forEach((month, v) {
      try {
        for (final r in ((v as Map)['rows'] as List? ?? [])) {
          final m = Map<String, dynamic>.from(r as Map);
          final tag = (m['tag'] ?? '').toString();
          if (tag.isEmpty) continue;
          d.mntTags.putIfAbsent(month, () => {}).add(tag);
          final bad = m.values.where((x) => x == 'X').length;
          if (bad > 0) d.mntBad[month] = (d.mntBad[month] ?? 0) + bad;
        }
      } catch (_) {}
    });
    try {
      for (final e in (jsonDecode(p.getString('riwayat') ?? '[]') as List)) {
        final m = Map<String, dynamic>.from(e as Map);
        final ts = (m['ts'] as num?)?.toInt();
        if (ts == null) continue;
        final k = _mkOf(DateTime.fromMillisecondsSinceEpoch(ts));
        bool bad = false;
        try {
          bad = Rec(m).bad;
        } catch (_) {}
        if (bad) {
          d.densBad[k] = (d.densBad[k] ?? 0) + 1;
        } else {
          d.densOk[k] = (d.densOk[k] ?? 0) + 1;
        }
      }
    } catch (_) {}
    try {
      for (final e in (jsonDecode(p.getString('bukatutup') ?? '[]') as List)) {
        final m = Map<String, dynamic>.from(e as Map);
        final open = (m['open'] ?? '').toString();
        if (open.length < 7) continue;
        final k = open.substring(0, 7);
        d.btCount[k] = (d.btCount[k] ?? 0) + 1;
        if ((m['close'] ?? '').toString().isEmpty) d.btOpen++;
      }
    } catch (_) {}

    return d;
}


/// Isi kiriman untuk file "SLRT - Statistik": satu tab per tahun.
Map<String, dynamic> _statBody(_Data d, int year) {
  final total = d.tags.length;
  final ms = [for (var i = 1; i <= 12; i++) '$year-${_two2(i)}'];
  final months = <Map<String, dynamic>>[];
  final workers = <String, List<int>>{}; // nama -> jumlah pekerjaan per bulan
  final wDays = <String, Set<String>>{};
  final locs = <String, List<int>>{};
  for (var i = 0; i < 12; i++) {
    final k = ms[i];
    final laps = d.laps.where((r) => r.date.startsWith(k)).toList();
    final days = laps.map((r) => r.date).toSet();
    final job = [for (final j in kJobTypes) laps.where((r) => r.job == j).length];
    for (final r in laps) {
      for (final w in r.workers.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet()) {
        workers.putIfAbsent(w, () => List.filled(12, 0))[i]++;
        wDays.putIfAbsent(w, () => {}).add(r.date);
      }
      final l = r.loc.trim().isEmpty ? '-' : r.loc.trim();
      locs.putIfAbsent(l, () => List.filled(12, 0))[i]++;
    }
    months.add({
      'month': kLapMonths[i],
      'jobs': laps.length,
      'days': days.length,
      'byJob': job,
      'exp': d.expTags[k]?.length ?? 0,
      'mnt': d.mntTags[k]?.length ?? 0,
      'notInst': d.notInst[k]?.length ?? 0,
      'densOk': d.densOk[k] ?? 0,
      'densBad': d.densBad[k] ?? 0,
      'bt': d.btCount[k] ?? 0,
      'mntBad': d.mntBad[k] ?? 0,
    });
  }
  return {
    'type': 'statistik',
    'year': year,
    'totalSources': total,
    'jobTypes': kJobTypes,
    'btOpen': d.btOpen,
    'months': months,
    'workers': [
      for (final e in workers.entries) {'name': e.key, 'jobs': e.value, 'days': wDays[e.key]?.length ?? 0}
    ],
    'locs': [for (final e in locs.entries) {'loc': e.key, 'jobs': e.value}],
  };
}

final AutoSync _statSync = AutoSync('statistik_synced');

/// Kirim statistik (tahun-tahun yang ada datanya) ke spreadsheet; hanya tahun yang berubah.
Future<void> statSync() async {
  try {
    final url = kRadSheetUrl.trim();
    if (url.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final d = await _loadData(p);
    final years = <int>{DateTime.now().year};
    for (final r in d.laps) {
      final y = int.tryParse(r.date.length >= 4 ? r.date.substring(0, 4) : '');
      if (y != null) years.add(y);
    }
    await _statSync.run(p, url, () => {for (final y in years) '$y': _statBody(d, y)}, () {});
  } catch (_) {}
}

class _StatistikPageState extends State<StatistikPage> {
  _Data? data;
  bool yearMode = false;
  DateTime cur = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
  String _mk(DateTime d) => '${d.year}-${_two(d.month)}';

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final d = await _loadData(p);
    if (mounted) setState(() => data = d);
    statSync(); // perbarui file "SLRT - Statistik" di spreadsheet
  }

  bool _inPeriod(String isoDate) {
    if (isoDate.length < 7) return false;
    return yearMode ? isoDate.startsWith('${cur.year}-') : isoDate.startsWith(_mk(cur));
  }

  List<String> get _months => yearMode
      ? [for (var i = 1; i <= 12; i++) '${cur.year}-${_two(i)}']
      : [_mk(cur)];

  int _sum(Map<String, int> m) => _months.fold<int>(0, (a, k) => a + (m[k] ?? 0));

  void _shift(int step) => setState(() {
        cur = yearMode ? DateTime(cur.year + step, cur.month) : DateTime(cur.year, cur.month + step);
      });

  @override
  Widget build(BuildContext context) {
    final d = data;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Statistik Kerja · 工作统计'),
        actions: [
          IconButton(
              tooltip: 'Muat ulang · 刷新',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(() => data = null);
                _load();
              }),
        ],
      ),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              _periodBar(scheme),
              const SizedBox(height: 12),
              ..._content(d, scheme),
            ]),
    );
  }

  Widget _periodBar(ColorScheme scheme) {
    final label = yearMode ? 'Tahun ${cur.year} · ${cur.year}年' : '${kLapMonths[cur.month - 1]} ${cur.year} · ${cur.year}年${cur.month}月';
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        ChoiceChip(
            label: const Text('Bulanan · 月度'),
            selected: !yearMode,
            onSelected: (_) => setState(() => yearMode = false)),
        const SizedBox(width: 8),
        ChoiceChip(
            label: const Text('Tahunan · 年度'),
            selected: yearMode,
            onSelected: (_) => setState(() => yearMode = true)),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shift(-1)),
        Expanded(
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: scheme.primary))),
        IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _shift(1)),
      ]),
    ]);
  }

  List<Widget> _content(_Data d, ColorScheme scheme) {
    final laps = d.laps.where((r) => _inPeriod(r.date)).toList();
    final days = laps.map((r) => r.date).toSet();
    final perDay = days.isEmpty ? 0.0 : laps.length / days.length;

    // per jenis pekerjaan
    final byJob = <String, int>{for (final j in kJobTypes) j: 0};
    for (final r in laps) {
      byJob[r.job] = (byJob[r.job] ?? 0) + 1;
    }
    // per pekerja: jumlah pekerjaan & hari kerja
    final byWorker = <String, int>{};
    final workerDays = <String, Set<String>>{};
    for (final r in laps) {
      for (final w in r.workers.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet()) {
        byWorker[w] = (byWorker[w] ?? 0) + 1;
        workerDays.putIfAbsent(w, () => {}).add(r.date);
      }
    }
    // per lokasi
    final byLoc = <String, int>{};
    for (final r in laps) {
      final l = r.loc.trim().isEmpty ? '-' : r.loc.trim();
      byLoc[l] = (byLoc[l] ?? 0) + 1;
    }

    // cakupan sumber
    final total = d.tags.length;
    double cover(Map<String, Set<String>> m) {
      if (total == 0) return 0;
      final ms = _months.where((k) => m.containsKey(k) || !yearMode).toList();
      if (ms.isEmpty) return 0;
      // tahunan: rata-rata cakupan bulan yang ada datanya
      final vals = ms.map((k) => (m[k]?.length ?? 0) / total).toList();
      return vals.reduce((a, b) => a + b) / vals.length;
    }

    final expC = cover(d.expTags), mntC = cover(d.mntTags);
    final dOk = _sum(d.densOk), dBad = _sum(d.densBad);
    final btN = _sum(d.btCount), mBad = _sum(d.mntBad);
    final ni = yearMode ? 0 : (d.notInst[_mk(cur)]?.length ?? 0);

    return [
      // ---------- ringkasan ----------
      _section('Ringkasan · 概要', Icons.insights, [
        Wrap(spacing: 8, runSpacing: 8, children: [
          _stat('Pekerjaan\n工作数', '${laps.length}', scheme),
          _stat('Hari kerja\n工作天数', '${days.length}', scheme),
          _stat('Rata-rata / hari\n日均工作', perDay.toStringAsFixed(1), scheme),
          _stat('Pekerja aktif\n在岗人员', '${byWorker.length}', scheme),
        ]),
      ]),

      // ---------- capaian target ----------
      _section(yearMode ? 'Capaian target (rata-rata bulanan) · 目标完成率（月均）' : 'Capaian target bulan ini · 本月目标完成率',
          Icons.flag, [
        if (total == 0)
          const Text('Data sumber belum ada · 暂无放射源数据')
        else ...[
          _progress('Pengukuran paparan · 辐射测量', expC,
              yearMode ? null : '${d.expTags[_mk(cur)]?.length ?? 0}/$total sumber', scheme),
          _progress('Perawatan sumber · 放射源维护', mntC,
              yearMode ? null : '${d.mntTags[_mk(cur)]?.length ?? 0}/$total sumber', scheme),
          if (ni > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('$ni sumber belum terpasang/operasional · 放射源未安装/未运行',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ),
        ],
      ]),

      // ---------- kegiatan lain ----------
      _section('Kegiatan · 活动', Icons.fact_check, [
        _kv('Pengukuran density · 密度检测', '${dOk + dBad} kali'),
        _kv('   • Sesuai · 合格', '$dOk'),
        _kv('   • Perlu kalibrasi · 需要校准', '$dBad', warn: dBad > 0),
        _kv('Buka/tutup sumber · 放射源开关', '$btN kali'),
        _kv('Sumber masih terbuka · 仍开启', '${d.btOpen}', warn: d.btOpen > 0),
        _kv('Temuan perawatan "tidak bagus" · 维护异常', '$mBad', warn: mBad > 0),
      ]),

      // ---------- jenis pekerjaan ----------
      _section('Jenis pekerjaan · 任务类型', Icons.category, [
        if (laps.isEmpty)
          const Text('Belum ada pekerjaan · 暂无工作')
        else
          ..._bars({for (final e in byJob.entries) _shortJob(e.key): e.value}, scheme),
      ]),

      // ---------- produktivitas pekerja ----------
      _section('Produktivitas pekerja · 人员工作效率', Icons.groups, [
        if (byWorker.isEmpty)
          const Text('Belum ada nama pekerja di laporan · 报告中暂无人员')
        else
          ..._bars(byWorker, scheme,
              suffix: (k) => '${workerDays[k]?.length ?? 0} hari · '
                  '${((byWorker[k] ?? 0) / ((workerDays[k]?.length ?? 1))).toStringAsFixed(1)}/hari'),
      ]),

      // ---------- lokasi ----------
      _section('Pekerjaan per lokasi · 各位置工作', Icons.place, [
        if (byLoc.isEmpty) const Text('Belum ada pekerjaan · 暂无工作') else ..._bars(byLoc, scheme, sortByKey: true),
      ]),

      // ---------- tren ----------
      _section('Tren 12 bulan terakhir · 近12个月趋势', Icons.show_chart, [
        _trend(d, scheme),
      ]),
      const SizedBox(height: 24),
    ];
  }

  String _shortJob(String j) {
    if (j == kJobTypes[2]) return 'Maintenance & Pemeriksaan';
    if (j == kJobTypes[1]) return 'Maintenance 检修维护';
    if (j == kJobTypes[0]) return 'Pemeriksaan 检查';
    return j;
  }

  Widget _section(String title, IconData icon, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
            ]),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );

  Widget _stat(String label, String value, ColorScheme scheme) => Container(
        width: 150,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: scheme.primaryContainer.withOpacity(0.5), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: scheme.primary)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      );

  Widget _progress(String label, double v, String? detail, ColorScheme scheme) {
    final pct = (v * 100).clamp(0, 100).round();
    final color = pct >= 100 ? Colors.green : (pct >= 50 ? Colors.orange : Colors.red);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text('$pct%${detail == null ? '' : '  ($detail)'}',
              style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
              value: v.clamp(0.0, 1.0).toDouble(),
              minHeight: 10,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest),
        ),
      ]),
    );
  }

  Widget _kv(String k, String v, {bool warn = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: const TextStyle(fontSize: 13))),
          Text(v,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13, color: warn ? Colors.red.shade700 : null)),
        ]),
      );

  List<Widget> _bars(Map<String, int> m, ColorScheme scheme,
      {String Function(String)? suffix, bool sortByKey = false}) {
    final e = m.entries.toList()
      ..sort((a, b) => sortByKey ? a.key.compareTo(b.key) : b.value.compareTo(a.value));
    final max = e.fold<int>(1, (a, x) => x.value > a ? x.value : a);
    return [
      for (final x in e)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(x.key, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
              Text('${x.value}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ]),
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                  value: x.value / max, minHeight: 8, backgroundColor: scheme.surfaceContainerHighest),
            ),
            if (suffix != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(suffix(x.key), style: TextStyle(fontSize: 11, color: scheme.outline)),
              ),
          ]),
        ),
    ];
  }

  /// Grafik batang sederhana: jumlah pekerjaan per bulan (12 bulan terakhir s/d periode terpilih).
  Widget _trend(_Data d, ColorScheme scheme) {
    final end = yearMode ? DateTime(cur.year, 12) : cur;
    final months = [for (var i = 11; i >= 0; i--) DateTime(end.year, end.month - i)];
    final counts = [
      for (final m in months) d.laps.where((r) => r.date.startsWith(_mk(m))).length,
    ];
    final max = counts.fold<int>(1, (a, x) => x > a ? x : a);
    return SizedBox(
      height: 150,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < months.length; i++)
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              Text(counts[i] == 0 ? '' : '${counts[i]}', style: const TextStyle(fontSize: 10)),
              const SizedBox(height: 2),
              Container(
                height: 100 * counts[i] / max,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                    color: _mk(months[i]) == _mk(cur) && !yearMode ? scheme.primary : scheme.primary.withOpacity(0.45),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
              ),
              const SizedBox(height: 4),
              Text(kLapMonths[months[i].month - 1].substring(0, 3), style: const TextStyle(fontSize: 10)),
            ]),
          ),
      ]),
    );
  }
}
