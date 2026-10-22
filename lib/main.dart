import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'density.dart' as density;
import 'documents.dart';
import 'jarak.dart';
import 'laporan.dart';
import 'radiation.dart' as radiation;
import 'statistik.dart';
import 'auth.dart';
import 'sync_hub.dart';
import 'mcu.dart';
import 'pendose.dart';
import 'tld.dart';
import 'trefoil.dart';
import 'sources_util.dart';

// Warna dari logo PT SLRT: biru navy dan merah.
const Color kNavy = Color(0xFF16295E);
const Color kSky = Color(0xFF3A5BA8);
const Color kRed = Color(0xFFC8202E);
const Color kInk = Color(0xFF0F1B3D);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  kAfterLogin = (_) => const ShellPage();
  runApp(const SlrtApp());
}

class SlrtApp extends StatelessWidget {
  const SlrtApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SLRT Apps',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: kNavy, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: kNavy,
          brightness: Brightness.dark,
          useMaterial3: true),
      home: const SplashPage(),
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: mq.textScaler.clamp(minScaleFactor: 0.85, maxScaleFactor: 1.15)),
          child: child ?? const SizedBox(),
        );
      },
    );
  }
}

// ===================== Halaman pembuka =====================

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});
  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController ctl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..forward();

  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 2200), () async {
      await Auth.load();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 450),
        pageBuilder: (_, __, ___) =>
            Auth.name.isEmpty ? LoginPage(next: (_) => const ShellPage()) : const ShellPage(),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
      ));
    });
  }

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(children: [
        Positioned.fill(
          child: CustomPaint(painter: SkylinePainter()),
        ),
        Align(
          alignment: const Alignment(0, -0.15),
          child: FadeTransition(
            opacity: CurvedAnimation(parent: ctl, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: Tween(begin: 0.92, end: 1.0).animate(
                  CurvedAnimation(parent: ctl, curve: Curves.easeOutBack)),
              child: Image.asset('assets/logo.png', width: 270),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Siluet kawasan industri di bagian bawah halaman pembuka.
class SkylinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final base = h * 0.80;
    final far = Paint()..color = const Color(0xFFE6EBF4);
    final near = Paint()..color = const Color(0xFFCDD5E3);
    final rnd = math.Random(7);

    // gedung jauh
    double x = 0;
    while (x < w) {
      final bw = 24 + rnd.nextDouble() * 40;
      final bh = 50 + rnd.nextDouble() * 110;
      canvas.drawRect(Rect.fromLTWH(x, base - bh - 30, bw, bh + 30), far);
      x += bw + 4;
    }
    // crane
    final crane = Paint()
      ..color = const Color(0xFFDAE1EE)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    for (final cx in [w * 0.30, w * 0.62]) {
      canvas.drawLine(Offset(cx, base), Offset(cx, base - 190), crane);
      canvas.drawLine(Offset(cx - 40, base - 180), Offset(cx + 90, base - 180), crane);
      canvas.drawLine(Offset(cx + 80, base - 180), Offset(cx + 80, base - 140), crane);
    }
    // gedung dekat, cerobong, tangki
    x = 0;
    while (x < w) {
      final bw = 20 + rnd.nextDouble() * 46;
      final bh = 30 + rnd.nextDouble() * 80;
      canvas.drawRect(Rect.fromLTWH(x, base - bh, bw, bh), near);
      if (rnd.nextDouble() > 0.6) {
        canvas.drawRect(
            Rect.fromLTWH(x + bw * 0.3, base - bh - 70, bw * 0.28, 70), near);
      }
      if (rnd.nextDouble() > 0.75) {
        canvas.drawCircle(Offset(x + bw / 2, base - bh - 10), bw * 0.35, near);
      }
      x += bw + 6;
    }
    canvas.drawRect(Rect.fromLTWH(0, base, w, h - base), near);

    // lengkung hijau di bawah
    final g = Paint()
      ..shader = const LinearGradient(
              colors: [kNavy, kSky],
              begin: Alignment.bottomLeft,
              end: Alignment.topRight)
          .createShader(Rect.fromLTWH(0, base, w, h - base));
    final r = w * 0.36;
    canvas.drawCircle(Offset(w * 0.42, h + r * 0.35), r, g);
    canvas.drawCircle(Offset(w * 1.02, h + r * 0.42), r * 0.95, g);
    final hole = Paint()..color = const Color(0xFFCDD5E3);
    canvas.drawCircle(Offset(w * 0.42, h + r * 0.55), r * 0.38, hole);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ===================== Kerangka utama =====================

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});
  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: IndexedStack(index: tab, children: const [
        HomeTab(),
        InfoTab(),
      ]),
      bottomNavigationBar: SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [
              BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 6))
            ],
          ),
          child: Row(children: [
            _navItem(0, Icons.home_rounded, 'Beranda 首页'),
            _navItem(-1, Icons.insights_rounded, 'Statistik 统计', onTap: () {
              final i = kMenu.indexWhere((m) => m.title == 'Statistik Kerja');
              if (i >= 0) openMenu(context, kMenu[i]);
            }),
            _navItem(1, Icons.info_outline_rounded, 'Informasi 信息'),
          ]),
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, String label, {VoidCallback? onTap}) {
    final on = tab == i;
    final c = on ? kNavy : Theme.of(context).colorScheme.outline;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap ?? () => setState(() => tab = i),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: c, size: 26),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, color: c, fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
          ]),
        ),
      ),
    );
  }
}

// ===================== Menu =====================

class MenuItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder page;
  final String zh;
  final String zhSub;
  const MenuItem(this.title, this.subtitle, this.icon, this.page, [this.zh = '', this.zhSub = '']);
  String get biTitle => zh.isEmpty ? title : '$title · $zh';
}

final List<MenuItem> kMenu = [
  MenuItem('Density SLRT', 'Cek densitas aktual vs detektor DCS', Icons.science_rounded,
      (_) => const density.HomePage(), '密度检测', '实际密度与 DCS 探测器对比'),
  MenuItem('Radiation Log', 'Log paparan radiasi bulanan per sumber', kTrefoil,
      (_) => const radiation.HomePage(), '辐射记录', '各放射源月度辐射剂量记录'),
  MenuItem('Kartu Dosis Pekerja Radiasi (TLD)', 'Dosis TLD per triwulan tiap pekerja',
      Icons.badge_rounded, (_) => const TldPage(), '辐射工作人员剂量卡', '每位人员季度 TLD 剂量'),
  MenuItem('Kartu Dosis Pendose', 'Bacaan dosimeter baca langsung tiap pekerja',
      Icons.speed_rounded, (_) => const PendosePage(), '直读剂量计剂量卡', '每位人员直读剂量计读数'),
  MenuItem('Kartu Pemantauan Kesehatan Pekerja', 'Hasil MCU tahunan tiap pekerja',
      Icons.health_and_safety_rounded, (_) => const McuPage(), '工作人员健康监测卡', '每位人员年度体检结果'),
  MenuItem('Laporan Kerja PPR', 'Laporan kegiatan pemeriksaan & maintenance bulanan',
      Icons.assignment_rounded, (_) => const LaporanPage(), 'PPR 工作报告', '月度检查与维护工作报告'),
  MenuItem('Statistik Kerja', 'Statistik pekerjaan & produktivitas PPR', Icons.bar_chart_rounded,
      (_) => const StatistikPage(), '工作统计', 'PPR 工作与效率统计'),
  MenuItem('Jarak Aman Radiasi', 'Hitung jarak aman pekerja & non pekerja radiasi', Icons.social_distance_rounded,
      (_) => const JarakPage(), '辐射安全距离', '计算工作人员与公众安全距离'),
  MenuItem('Dokumen & Regulasi', 'SOP, izin BAPETEN, dan peraturan', Icons.description_rounded,
      (_) => const DocumentsPage(), '文件与法规', 'SOP、BAPETEN 许可证及法规'),
];

/// Buka menu. Selama menu terbuka sinkron antar HP ditahan, lalu
/// dijalankan lagi setelah menu ditutup.
Future<void> openMenu(BuildContext context, MenuItem m) async {
  Hub.moduleOpen = true;
  try {
    await Navigator.of(context).push(MaterialPageRoute(builder: m.page));
  } finally {
    Hub.moduleOpen = false;
  }
  await Hub.sync();
}

// ===================== Home =====================

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});
  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with WidgetsBindingObserver {
  final pager = PageController(viewportFraction: 0.84);
  int page = 0;
  Timer? timer;
  String densSummary = 'Memuat… · 加载中…';
  String radSummary = 'Memuat… · 加载中…';
  String docSummary = 'Memuat… · 加载中…';
  String tldSummary = 'Memuat… · 加载中…';
  String mcuSummary = 'Memuat… · 加载中…';
  String pdSummary = 'Memuat… · 加载中…';
  String lapSummary = 'Memuat… · 加载中…';
  // target & peringatan bulan ini (Beranda)
  int tTotal = 0, tExp = 0, tMnt = 0, tDens = 0, tDensBad = 0, tOpen = 0, tMntBad = 0;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!pager.hasClients) return;
      final next = (page + 1) % kMenu.length;
      pager.animateToPage(next,
          duration: const Duration(milliseconds: 500), curve: Curves.easeInOut);
    });
    _loadSummary();
    WidgetsBinding.instance.addObserver(this);
    Hub.listen(_hubChanged);
    Hub.startTimer();
    Hub.sync();
  }

  /// Setelah data dari HP lain masuk, perbarui ringkasan Beranda.
  void _hubChanged() {
    if (!mounted) return;
    if (!Hub.busy) _loadSummary();
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !Hub.moduleOpen) Hub.sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Hub.unlisten(_hubChanged);
    timer?.cancel();
    pager.dispose();
    super.dispose();
  }

  Future<void> _loadSummary() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    // Density
    try {
      final list = jsonDecode(p.getString('riwayat') ?? '[]') as List;
      if (list.isEmpty) {
        densSummary = 'Belum ada pengukuran · 暂无测量';
      } else {
        final last = Map<String, dynamic>.from(list.first as Map);
        final ts = (last['ts'] as num?)?.toInt() ?? 0;
        final d = DateTime.fromMillisecondsSinceEpoch(ts);
        final tag = (last['n'] ?? '').toString();
        densSummary =
            '${list.length} catatan · terakhir ${tag.isEmpty ? '' : '$tag, '}${d.day}/${d.month}/${d.year}';
      }
    } catch (_) {
      densSummary = 'Belum ada pengukuran · 暂无测量';
    }
    // Radiation
    try {
      final m = jsonDecode(p.getString('sessions') ?? '{}') as Map;
      final now = DateTime.now();
      final key = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final rows = ((m[key] as Map?)?['rows'] as List?)?.length ?? 0;
      int total = 16;
      final s = p.getString('sources');
      if (s != null && p.getString('sources_ver') == radiation.kSourcesVer) total = (jsonDecode(s) as List).length;
      radSummary = '$rows dari $total sumber tercatat bulan ini · 本月已记录 $rows/$total';
    } catch (_) {
      radSummary = 'Belum ada log bulan ini · 本月暂无记录';
    }
    // TLD
    try {
      final ws = jsonDecode(p.getString('tld_workers') ?? '[]') as List;
      final aktif = ws.where((w) => ((w as Map)['status'] ?? '').toString().endsWith('Aktif') &&
          !(w['status'] ?? '').toString().contains('Non')).length;
      tldSummary = ws.isEmpty ? 'Belum ada pekerja · 暂无人员' : '${ws.length} pekerja · $aktif aktif · ${ws.length} 人 / $aktif 在岗';
    } catch (_) {
      tldSummary = 'Belum ada pekerja · 暂无人员';
    }
    // Pendose
    try {
      final m = jsonDecode(p.getString('pendose') ?? '{}') as Map;
      final now = DateTime.now();
      final key = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      var n = 0;
      final who = <String>{};
      m.forEach((k, v) {
        for (final r in (v as List)) {
          if (((r as Map)['date'] ?? '').toString().startsWith(key)) {
            n++;
            who.add(k.toString());
          }
        }
      });
      pdSummary = n == 0 ? 'Belum ada pencatatan bulan ini · 本月暂无记录' : '$n pencatatan bulan ini · ${who.length} pekerja · 本月 $n 条';
    } catch (_) {
      pdSummary = 'Belum ada pencatatan · 暂无记录';
    }
    // MCU
    try {
      final ws = (jsonDecode(p.getString('tld_workers') ?? '[]') as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((w) => !(w['status'] ?? '').toString().endsWith('Non Aktif'))
          .toList();
      final m = jsonDecode(p.getString('mcu') ?? '{}') as Map;
      final now = DateTime.now();
      var due = 0;
      for (final w in ws) {
        final l = ((m[w['id']] as List?) ?? [])
            .map((e) => (e as Map)['date']?.toString() ?? '')
            .where((d) => d.isNotEmpty)
            .toList()
          ..sort();
        final d = l.isEmpty ? null : DateTime.tryParse(l.last);
        if (d == null || now.isAfter(DateTime(d.year + 1, d.month, d.day))) due++;
      }
      mcuSummary = ws.isEmpty
          ? 'Belum ada pekerja aktif · 暂无在岗人员'
          : (due == 0 ? 'Semua pekerja aktif sudah MCU · 在岗人员均已体检' : '$due pekerja aktif perlu MCU · $due 人需体检');
    } catch (_) {
      mcuSummary = 'Belum ada data MCU · 暂无体检数据';
    }
    // Laporan Kerja PPR
    try {
      final l = jsonDecode(p.getString('laporan') ?? '[]') as List;
      final now = DateTime.now();
      final key = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final n = l.where((r) => ((r as Map)['date'] ?? '').toString().startsWith(key)).length;
      lapSummary = n == 0 ? 'Belum ada pekerjaan bulan ini · 本月暂无工作' : '$n pekerjaan tercatat bulan ini · 本月 $n 项工作';
    } catch (_) {
      lapSummary = 'Belum ada pekerjaan · 暂无工作';
    }
    // Dokumen
    try {
      final docs = jsonDecode(p.getString('documents') ?? '[]') as List;
      docSummary = docs.isEmpty ? 'Belum ada dokumen · 暂无文件' : '${docs.length} dokumen tersimpan · 已保存 ${docs.length} 份';
    } catch (_) {
      docSummary = 'Belum ada dokumen · 暂无文件';
    }
    await _loadTargets(p);
    if (mounted) setState(() {});
  }

  Future<void> _loadTargets(SharedPreferences p) async {
    final now = DateTime.now();
    final mk = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    tTotal = tExp = tMnt = tDens = tDensBad = tOpen = tMntBad = 0;
    try {
      tTotal = (jsonDecode(await sourcesJson(p)) as List).length;
    } catch (_) {}
    try {
      final s = (jsonDecode(p.getString('sessions') ?? '{}') as Map)[mk];
      for (final r in ((s as Map?)?['rows'] as List? ?? [])) {
        final m = r as Map;
        final a = (m['surface'] ?? '').toString().trim(), b = (m['meter'] ?? '').toString().trim();
        if (!(a == '-' && b == '-') && (a.isNotEmpty || b.isNotEmpty)) tExp++;
      }
    } catch (_) {}
    try {
      final s = (jsonDecode(p.getString('maint') ?? '{}') as Map)[mk];
      for (final r in ((s as Map?)?['rows'] as List? ?? [])) {
        tMnt++;
        tMntBad += (r as Map).values.where((x) => x == 'X').length;
      }
    } catch (_) {}
    try {
      for (final e in (jsonDecode(p.getString('riwayat') ?? '[]') as List)) {
        final m = Map<String, dynamic>.from(e as Map);
        final ts = (m['ts'] as num?)?.toInt();
        if (ts == null) continue;
        final d = DateTime.fromMillisecondsSinceEpoch(ts);
        if (d.year != now.year || d.month != now.month) continue;
        tDens++;
        try {
          if (density.Rec(m).bad) tDensBad++;
        } catch (_) {}
      }
    } catch (_) {}
    try {
      for (final e in (jsonDecode(p.getString('bukatutup') ?? '[]') as List)) {
        if (((e as Map)['close'] ?? '').toString().isEmpty) tOpen++;
      }
    } catch (_) {}
  }

  Future<void> _open(MenuItem m) async {
    await openMenu(context, m);
    _loadSummary();
  }

  static const List<String> _short = [
    'Density', 'Radiation Log', 'Dosis TLD', 'Pendose', 'Kesehatan', 'Laporan Kerja', 'Statistik', 'Jarak Aman', 'Dokumen'
  ];
  static const List<Color> _tint = [
    Color(0xFF0F766E), Color(0xFFB45309), Color(0xFF6D28D9), Color(0xFF0369A1), Color(0xFFBE123C),
    kNavy, Color(0xFF15803D), Color(0xFFC2410C), Color(0xFF475569)
  ];
  static const _days = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
  static const _months = [
    'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'
  ];

  String _shortOf(int i) => i < _short.length ? _short[i] : kMenu[i].title;
  Color _tintOf(int i) => i < _tint.length ? _tint[i] : kNavy;
  void _openTitle(String t) {
    final i = kMenu.indexWhere((m) => m.title == t);
    if (i >= 0) _open(kMenu[i]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF10131D) : const Color(0xFFF3F5FA);
    final card = dark ? const Color(0xFF1B2032) : Colors.white;
    final top = MediaQuery.of(context).padding.top;
    final now = DateTime.now();
    final summaries = [densSummary, radSummary, tldSummary, pdSummary, mcuSummary, lapSummary, 'Pekerjaan, capaian target & produktivitas · 工作与效率', 'NBD 20 / 1 mSv per tahun · Perka BAPETEN 4/2013', docSummary];

    BoxDecoration box() => BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(20),
          boxShadow: dark ? null : const [BoxShadow(color: Color(0x1416295E), blurRadius: 18, offset: Offset(0, 6))],
        );

    return ColoredBox(
      color: bg,
      child: RefreshIndicator(
        onRefresh: () async {
          await Hub.sync();
          await _loadSummary();
        },
        child: ListView(padding: EdgeInsets.zero, children: [
          // ---------- header ----------
          Container(
            padding: EdgeInsets.fromLTRB(18, top + 12, 18, 80),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0F1F4D), kNavy, kSky]),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: Image.asset('assets/logo.png', height: 22),
                ),
                const Spacer(),
                ProfileButton(onChanged: () => setState(() {})),
              ]),
              const SizedBox(height: 18),
              Text(
                  '${_days[now.weekday - 1]}, ${now.day} ${_months[now.month - 1]} ${now.year} · ${now.year}年${now.month}月${now.day}日',
                  style: TextStyle(color: Colors.white.withAlpha(200), fontSize: 12.5)),
              const SizedBox(height: 2),
              Text(Auth.name.isEmpty ? 'Selamat bekerja' : 'Halo, ${Auth.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => Hub.sync(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(color: Colors.white.withAlpha(36), borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Hub.busy
                        ? const SizedBox(
                            width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Hub.lastError.isEmpty ? const Color(0xFF4ADE80) : const Color(0xFFFF8A8A))),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(Hub.status,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                  ]),
                ),
              ),
            ]),
          ),

          Transform.translate(
            offset: const Offset(0, -62),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ---------- target bulan ini ----------
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: box(),
                  child: Column(children: [
                    Row(children: [
                      Expanded(
                        child: Text('Target ${_months[now.month - 1]} · 本月目标',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                      InkWell(
                        onTap: () => _openTitle('Statistik Kerja'),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Text('Statistik ›',
                              style: TextStyle(color: kSky, fontWeight: FontWeight.w600, fontSize: 12.5)),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                          child: _ring(tTotal == 0 ? 0 : tExp / tTotal, '${tTotal == 0 ? 0 : (tExp * 100 / tTotal).round()}%',
                              'Paparan', '$tExp/$tTotal sumber', scheme)),
                      Expanded(
                          child: _ring(tTotal == 0 ? 0 : tMnt / tTotal, '${tTotal == 0 ? 0 : (tMnt * 100 / tTotal).round()}%',
                              'Perawatan', '$tMnt/$tTotal sumber', scheme)),
                      Expanded(
                          child: _ring(tDens == 0 ? 0 : (tDens - tDensBad) / tDens, '${tDens - tDensBad}/$tDens', 'Density',
                              tDens == 0 ? 'belum ada' : 'sesuai', scheme,
                              color: kSky)),
                    ]),
                  ]),
                ),
                const SizedBox(height: 12),

                // ---------- peringatan ----------
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (tDensBad > 0)
                    _alert(Icons.warning_amber_rounded, '$tDensBad detektor perlu kalibrasi', const Color(0xFFFDE8EA),
                        const Color(0xFFA11826)),
                  tOpen > 0
                      ? _alert(Icons.lock_open_rounded, '$tOpen sumber masih terbuka', const Color(0xFFFFF3D6),
                          const Color(0xFF8A5A00))
                      : _alert(Icons.lock_outline_rounded, 'Semua sumber tertutup', const Color(0xFFDFF6E8),
                          const Color(0xFF13703D)),
                  if (tMntBad > 0)
                    _alert(Icons.build_circle_outlined, '$tMntBad temuan perawatan', const Color(0xFFFFF3D6),
                        const Color(0xFF8A5A00)),
                  if (tTotal > 0 && tExp < tTotal)
                    _alert(Icons.radar_rounded, '${tTotal - tExp} sumber belum diukur', const Color(0xFFE5EBFA),
                        kNavy),
                ]),
                const SizedBox(height: 16),

                // ---------- aksi cepat ----------
                Row(children: [
                  _quick(kTrefoil, 'Catat\nPaparan', const [Color(0xFFF59E0B), Color(0xFFD97706)],
                      () => _openTitle('Radiation Log')),
                  _quick(Icons.science_rounded, 'Ukur\nDensity', const [Color(0xFF14B8A6), Color(0xFF0F766E)],
                      () => _openTitle('Density SLRT')),
                  _quick(Icons.assignment_rounded, 'Laporan\nKerja', const [kSky, kNavy],
                      () => _openTitle('Laporan Kerja PPR')),
                  _quick(Icons.social_distance_rounded, 'Jarak\nAman', const [Color(0xFFEF4444), Color(0xFFB91C1C)],
                      () => _openTitle('Jarak Aman Radiasi')),
                ]),
                const SizedBox(height: 18),

                // ---------- semua modul ----------
                const Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 10),
                  child: Text('Semua modul · 全部模块', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                GridView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: kMenu.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3, mainAxisSpacing: 10, crossAxisSpacing: 10, mainAxisExtent: 112),
                  itemBuilder: (_, i) {
                    final m = kMenu[i];
                    final c = _tintOf(i);
                    return Material(
                      color: card,
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => _open(m),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(color: c.withAlpha(30), borderRadius: BorderRadius.circular(14)),
                              child: Center(child: menuIcon(m.icon, size: 24, color: c)),
                            ),
                            const SizedBox(height: 7),
                            Text(_shortOf(i),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                            if (m.zh.isNotEmpty)
                              Text(m.zh,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 10.5, color: scheme.outline)),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 18),

                // ---------- ringkasan ----------
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 14, 6, 6),
                  decoration: box(),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 2, bottom: 4),
                      child: Text('Ringkasan · 摘要', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    ),
                    for (var i = 0; i < kMenu.length; i++)
                      ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.only(right: 4),
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration:
                              BoxDecoration(color: _tintOf(i).withAlpha(28), borderRadius: BorderRadius.circular(11)),
                          child: Center(child: menuIcon(kMenu[i].icon, size: 20, color: _tintOf(i))),
                        ),
                        title: Text(_shortOf(i), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                        subtitle: Text(i < summaries.length ? summaries[i] : '',
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                        trailing: Icon(Icons.chevron_right, color: scheme.outline),
                        onTap: () => _open(kMenu[i]),
                      ),
                  ]),
                ),
                const SizedBox(height: 60),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _ring(double v, String center, String label, String sub, ColorScheme scheme, {Color? color}) {
    final c = color ?? (v >= 1 ? const Color(0xFF22C55E) : (v >= 0.5 ? const Color(0xFFF59E0B) : const Color(0xFFEF4444)));
    return Column(children: [
      SizedBox(
        width: 72,
        height: 72,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: 68,
            height: 68,
            child: CircularProgressIndicator(
              value: v.clamp(0.0, 1.0).toDouble(),
              strokeWidth: 8,
              color: c,
              backgroundColor: const Color(0xFFE8ECF5),
            ),
          ),
          Text(center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ]),
      ),
      const SizedBox(height: 6),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
      Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: scheme.outline)),
    ]);
  }

  Widget _alert(IconData icon, String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 12)),
        ]),
      );

  Widget _quick(IconData icon, String label, List<Color> g, VoidCallback onTap) => Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: g),
                  boxShadow: [BoxShadow(color: g.last.withAlpha(70), blurRadius: 10, offset: const Offset(0, 4))],
                ),
                child: Center(child: menuIcon(icon, size: 28, color: Colors.white)),
              ),
              const SizedBox(height: 6),
              Text(label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.2)),
            ]),
          ),
        ),
      );
}

class BannerCard extends StatelessWidget {
  final MenuItem item;
  final String summary;
  final int index;
  final VoidCallback onTap;
  const BannerCard(
      {super.key,
      required this.item,
      required this.summary,
      required this.index,
      required this.onTap});

  static const _grads = [
    [Color(0xFF16295E), Color(0xFF2B4A94)],
    [Color(0xFF0F1F4A), Color(0xFF3A5BA8)],
    [Color(0xFF16295E), Color(0xFF8E1E2A)],
  ];

  @override
  Widget build(BuildContext context) {
    final g = _grads[index % _grads.length];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: g, begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
            child: Stack(children: [
              Positioned(
                right: -18,
                bottom: -18,
                child: menuIcon(item.icon, size: 150, color: Colors.white.withAlpha(30)),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: kRed,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(item.biTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                    const Spacer(),
                    Text(item.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                            height: 1.2)),
                    if (item.zhSub.isNotEmpty)
                      Text(item.zhSub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.3)),
                    const SizedBox(height: 6),
                    Text(summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withAlpha(210), fontSize: 12.5)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ===================== Informasi =====================

class InfoTab extends StatelessWidget {
  const InfoTab({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return ListView(
      padding: EdgeInsets.fromLTRB(
          20, MediaQuery.of(context).padding.top + 24, 20, 120),
      children: [
        Center(child: Image.asset('assets/logo.png', height: 56)),
        const SizedBox(height: 18),
        const Center(
          child: Text('PT Sulawesi Recycling Technology',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
        Center(child: Text('SLRT Apps · versi 1.0', style: TextStyle(color: muted))),
        const SizedBox(height: 24),
        for (final m in kMenu)
          Card(
            child: ListTile(
              leading: menuIcon(m.icon, size: 24, color: kNavy),
              title: Text(m.biTitle),
              subtitle: Text(m.zhSub.isEmpty ? m.subtitle : '${m.subtitle}\n${m.zhSub}'),
              onTap: () => openMenu(context, m),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          'Data setiap menu tersimpan di HP ini dan tersinkron otomatis ke Google Sheets. Sambungkan Density SLRT dan '
          'Radiation Log ke Google Sheets dari menu masing-masing sebagai cadangan.\n各菜单数据保存在本手机，并自动同步到 Google Sheets 作为备份。',
          style: TextStyle(color: muted),
        ),
      ],
    );
  }
}
