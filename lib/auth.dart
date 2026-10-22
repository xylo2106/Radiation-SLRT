import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'sync_hub.dart';

/// Login sederhana di HP: tiap pengguna punya nama, jabatan dan PIN.
/// Nama pengguna yang login otomatis terisi sebagai petugas/PPR di
/// Log Book Paparan, Perawatan, Buka/Tutup, Density dan Laporan Kerja
/// (tetap bisa diubah / diisi manual di tiap form).
class Auth {
  static String name = '';
  static String role = '';
  static List<Map<String, String>> users = [];

  static const List<String> kRoles = [
    'PPR · 辐射防护员',
    'PKZR · 放射源安保员',
    'Pekerja Radiasi · 辐射工作人员',
    'Supervisor · 主管',
  ];

  /// FNV-1a 32-bit: PIN tidak disimpan sebagai teks biasa.
  static String hash(String pin) {
    var h = 0x811c9dc5;
    for (final c in utf8.encode('slrt:$pin')) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }

  static Future<SharedPreferences> _p() => SharedPreferences.getInstance();

  static Future<void> load() async {
    final p = await _p();
    try {
      users = (jsonDecode(p.getString('auth_users') ?? '[]') as List)
          .map((e) => Map<String, String>.from(
              (e as Map).map((k, v) => MapEntry(k.toString(), v.toString()))))
          .toList();
    } catch (_) {
      users = [];
    }
    name = p.getString('auth_current') ?? '';
    if (!users.any((u) => u['name'] == name)) name = '';
    // Data lama tanpa admin dengan satu akun saja: akun itu menjadi admin.
    if (users.length == 1 && !users.any((u) => u['admin'] == '1') && name.isNotEmpty) {
      users.firstWhere((u) => u['name'] == name)['admin'] = '1';
      await _saveUsers();
    }
    role = users.firstWhere((u) => u['name'] == name, orElse: () => {})['role'] ?? '';
  }

  static Future<void> _saveUsers() async =>
      (await _p()).setString('auth_users', jsonEncode(users));

  /// Admin = pembuat akun pertama; hanya admin yang boleh mendaftarkan akun lain.
  static bool get isAdmin => users.any((u) => u['name'] == name && u['admin'] == '1');
  static bool isAdminUser(String n) => users.any((u) => u['name'] == n && u['admin'] == '1');
  static int get adminCount => users.where((u) => u['admin'] == '1').length;

  /// Username login: huruf kecil, angka, titik, garis bawah, strip.
  static String slug(String n) =>
      n.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '.').replaceAll(RegExp(r'[^a-z0-9._-]'), '');
  static String usernameOf(Map<String, String> u) {
    final x = (u['username'] ?? '').trim();
    return x.isEmpty ? slug(u['name'] ?? '') : x;
  }

  static Map<String, String>? byUsername(String un) {
    final k = un.trim().toLowerCase();
    if (k.isEmpty) return null;
    for (final u in users) {
      if (usernameOf(u).toLowerCase() == k) return u;
    }
    return null;
  }

  static bool hasPin(String n) => (users.firstWhere((u) => u['name'] == n, orElse: () => {})['pin'] ?? '').isNotEmpty;

  static bool check(String n, String pin) {
    final u = users.firstWhere((u) => u['name'] == n, orElse: () => {});
    final h = u['pin'] ?? '';
    return h.isEmpty || h == hash(pin);
  }

  static Future<void> login(String n) async {
    name = n;
    final u = users.firstWhere((u) => u['name'] == n, orElse: () => {});
    role = u['role'] ?? '';
    final p = await _p();
    await p.setString('auth_current', n);
    if (u.isNotEmpty) await p.setString('auth_last_username', usernameOf(u));
  }

  static Future<void> logout() async {
    name = '';
    role = '';
    await (await _p()).remove('auth_current');
  }

  /// Simpan akun. [oldName] untuk mengubah akun yang sudah ada; PIN kosong saat
  /// mengubah = PIN lama tetap dipakai.
  static Future<void> addUser(String n, String r, String pin,
      {bool admin = false, String? oldName, String username = ''}) async {
    final old = users.firstWhere((u) => u['name'] == (oldName ?? n), orElse: () => {});
    var keepPin = pin.isEmpty && oldName != null ? (old['pin'] ?? '') : (pin.isEmpty ? '' : hash(pin));
    if (!admin) keepPin = ''; // pengguna biasa masuk hanya dengan username
    users.removeWhere((u) => u['name'] == (oldName ?? n) || u['name'] == n);
    users.add({
      'name': n,
      'username': username.isEmpty ? slug(n) : username,
      'role': r,
      'pin': keepPin,
      'admin': admin ? '1' : '',
    });
    if (oldName != null && name == oldName && n != oldName) {
      name = n;
      await (await _p()).setString('auth_current', n);
    }
    users.sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
    await _saveUsers();
  }

  static Future<void> removeUser(String n) async {
    users.removeWhere((u) => u['name'] == n);
    await _saveUsers();
    if (name == n) await logout();
  }

  /// Nama pekerja dari Kartu Dosis TLD, untuk saran saat membuat akun.
  static Future<List<String>> workerNames() async {
    try {
      final l = jsonDecode((await _p()).getString('tld_workers') ?? '[]') as List;
      return l.map((e) => ((e as Map)['name'] ?? '').toString().trim()).where((e) => e.isNotEmpty).toSet().toList()
        ..sort();
    } catch (_) {
      return [];
    }
  }

  static String initials(String n) {
    final p = n.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (p.isEmpty) return '?';
    return (p.length == 1 ? p[0].substring(0, p[0].length < 2 ? p[0].length : 2) : '${p[0][0]}${p[1][0]}')
        .toUpperCase();
  }
}

const Color _navy = Color(0xFF16295E);
const Color _sky = Color(0xFF3A5BA8);
const Color _red = Color(0xFFC8202E);

/// Halaman login: pilih nama lalu masukkan PIN. Bila belum ada pengguna,
/// langsung tampil form "Buat akun".
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.next});
  final WidgetBuilder next;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool loading = true;
  bool offline = false; // daftar akun belum bisa diperiksa ke server
  String? picked;
  String pin = '';
  String error = '';
  final userCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) => userCtl.text = p.getString('auth_last_username') ?? '');
    _init();
  }

  @override
  void dispose() {
    userCtl.dispose();
    super.dispose();
  }

  /// Ketik username -> langsung masuk. Akun admin diminta PIN.
  Future<void> _login() async {
    final un = userCtl.text.trim();
    if (un.isEmpty) {
      setState(() => error = 'Ketik username Anda · 请输入用户名');
      return;
    }
    var u = Auth.byUsername(un);
    if (u == null) {
      // mungkin baru didaftarkan admin di HP lain: ambil daftar terbaru
      setState(() => loading = true);
      await Hub.sync();
      await Auth.load();
      u = Auth.byUsername(un);
      if (!mounted) return;
      setState(() => loading = false);
    }
    if (u == null) {
      HapticFeedback.heavyImpact();
      setState(() => error = 'Username tidak terdaftar. Hubungi admin.\n用户名未注册，请联系管理员。');
      return;
    }
    error = '';
    _pick(u['name'] ?? '');
  }

  /// HP baru: ambil daftar akun dari server dulu. Akun admin hanya boleh dibuat
  /// bila di server benar-benar belum ada akun sama sekali.
  Future<void> _init() async {
    if (!loading || offline) {
      setState(() {
        loading = true;
        offline = false;
      });
    }
    await Auth.load();
    if (Auth.users.isEmpty) {
      final ok = await Hub.sync();
      await Auth.load();
      offline = !ok && Auth.users.isEmpty && kRadSheetUrl.trim().isNotEmpty;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _done(String n) async {
    await Auth.login(n);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: widget.next));
  }

  void _pick(String n) {
    if (!Auth.hasPin(n)) {
      _done(n);
      return;
    }
    setState(() {
      picked = n;
      pin = '';
      error = '';
    });
  }

  void _key(String k) {
    setState(() {
      error = '';
      if (k == '<') {
        if (pin.isNotEmpty) pin = pin.substring(0, pin.length - 1);
      } else if (k == 'OK') {
        // kirim
      } else if (pin.length < 6) {
        pin += k;
      }
    });
    if (k == 'OK' || pin.length == 6) _submit();
  }

  void _submit() {
    final n = picked;
    if (n == null) return;
    if (Auth.check(n, pin)) {
      _done(n);
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        error = 'PIN salah · PIN 错误';
        pin = '';
      });
    }
  }

  /// Hanya bila HP belum punya akun: buat akun admin pertama lalu langsung masuk.
  Future<void> _firstAdmin() async {
    final ok = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const UserFormPage(firstAdmin: true)));
    if (ok == true && mounted && Auth.users.isNotEmpty) _done(Auth.users.first['name'] ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: EdgeInsets.zero, children: [
              Container(
                padding: EdgeInsets.fromLTRB(24, top + 28, 24, 36),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0F1F4D), _navy, _sky]),
                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                    child: Image.asset('assets/logo.png', height: 26),
                  ),
                  const SizedBox(height: 26),
                  Text(picked == null ? 'Masuk · 登录' : 'Halo, $picked',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                      picked == null
                          ? (Auth.users.isEmpty
                              ? (offline
                                  ? 'Memerlukan internet untuk memeriksa akun · 需要网络检查账户'
                                  : 'Buat akun admin untuk mulai · 创建管理员账户')
                              : 'Ketik username dari admin · 输入管理员提供的用户名')
                          : 'Akun admin · 管理员账户 — masukkan PIN · 请输入 PIN',
                      style: const TextStyle(color: Color(0xFFC9D3EE))),
                ]),
              ),
              const SizedBox(height: 18),
              if (picked == null) ..._userList() else _pinPad(),
            ]),
    );
  }

  List<Widget> _userList() => [
        if (Auth.users.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: TextField(
              controller: userCtl,
              autofocus: userCtl.text.isEmpty,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _login(),
              onChanged: (_) {
                if (error.isNotEmpty) setState(() => error = '');
              },
              decoration: InputDecoration(
                labelText: 'Username · 用户名',
                hintText: 'mis. ferdinan',
                prefixIcon: const Icon(Icons.person_outline),
                filled: true,
                fillColor: Colors.white,
                errorText: error.isEmpty ? null : error,
                errorMaxLines: 3,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: _navy,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              onPressed: _login,
              icon: const Icon(Icons.login),
              label: const Text('Masuk · 登录', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
        if (Auth.users.isEmpty && offline)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              onPressed: _init,
              icon: const Icon(Icons.refresh),
              label: const Text('Coba lagi · 重试'),
            ),
          ),
        if (Auth.users.isEmpty && !offline)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              onPressed: _firstAdmin,
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: const Text('Buat akun admin · 创建管理员账户'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
              Auth.users.isEmpty
                  ? (offline
                      ? 'Daftar akun belum bisa diambil dari server. Nyalakan internet lalu tekan Coba lagi.\n无法从服务器获取账户列表，请联网后重试。'
                      : 'Belum ada akun di semua HP. Akun pertama menjadi admin; hanya admin yang bisa mendaftarkan akun lain.\n所有手机尚无账户。第一个账户为管理员，只有管理员可以注册其他账户。')
                  : 'Belum punya username? Minta admin mendaftarkan Anda.\n没有用户名？请联系管理员注册。',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7390))),
        ),
      ];

  Widget _pinPad() {
    Widget key(String k, {IconData? icon}) => Padding(
          padding: const EdgeInsets.all(7),
          child: Material(
            color: k == 'OK' ? _navy : Colors.white,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _key(k),
              child: SizedBox(
                width: 76,
                height: 62,
                child: Center(
                  child: icon != null
                      ? Icon(icon, color: k == 'OK' ? Colors.white : _navy)
                      : Text(k, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: _navy)),
                ),
              ),
            ),
          ),
        );
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < 6; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 7),
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < pin.length ? _navy : Colors.transparent,
              border: Border.all(color: error.isEmpty ? _navy : _red, width: 2),
            ),
          ),
      ]),
      SizedBox(
          height: 30,
          child: Center(child: Text(error, style: const TextStyle(color: _red, fontWeight: FontWeight.w600)))),
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9']
      ])
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final k in row) key(k)]),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        key('<', icon: Icons.backspace_outlined),
        key('0'),
        key('OK', icon: Icons.arrow_forward),
      ]),
      TextButton(
          onPressed: () => setState(() => picked = null), child: const Text('Ganti pengguna · 切换用户')),
      const SizedBox(height: 24),
    ]);
  }
}

class _AdminBadge extends StatelessWidget {
  const _AdminBadge();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFFFFF3D6), borderRadius: BorderRadius.circular(6)),
        child: const Text('Admin', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF8A5A00))),
      );
}

/// Form akun.
/// - [firstAdmin]: akun pertama di HP (otomatis admin, PIN wajib).
/// - [edit] tanpa [selfOnly]: admin mengubah akun siapa pun.
/// - [selfOnly]: pengguna biasa hanya mengganti PIN-nya sendiri.
class UserFormPage extends StatefulWidget {
  const UserFormPage({super.key, this.edit, this.firstAdmin = false, this.selfOnly = false});
  final String? edit;
  final bool firstAdmin;
  final bool selfOnly;
  @override
  State<UserFormPage> createState() => _UserFormPageState();
}

class _UserFormPageState extends State<UserFormPage> {
  final name = TextEditingController();
  final pin = TextEditingController();
  final pin2 = TextEditingController();
  final uname = TextEditingController();
  bool unameTouched = false;
  String role = Auth.kRoles.first;
  bool admin = false;
  List<String> suggest = [];

  bool get _editing => widget.edit != null;

  @override
  void initState() {
    super.initState();
    admin = widget.firstAdmin;
    if (_editing) {
      name.text = widget.edit!;
      final u = Auth.users.firstWhere((u) => u['name'] == widget.edit, orElse: () => {});
      if (Auth.kRoles.contains(u['role'])) role = u['role']!;
      admin = u['admin'] == '1';
      uname.text = Auth.usernameOf(u);
      unameTouched = true;
    }
    if (!widget.selfOnly) {
      Auth.workerNames().then((l) {
        if (mounted) setState(() => suggest = l.where((n) => !Auth.users.any((u) => u['name'] == n)).toList());
      });
    }
  }

  @override
  void dispose() {
    name.dispose();
    pin.dispose();
    pin2.dispose();
    uname.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final n = name.text.trim();
    final un = Auth.slug(uname.text);
    uname.text = un;
    final hadPin = _editing && Auth.hasPin(widget.edit!);
    String? err;
    if (n.isEmpty) {
      err = 'Isi nama lengkap · 请填写全名';
    } else if (!RegExp(r'^[a-z0-9._-]{3,30}$').hasMatch(un)) {
      err = 'Username 3–30 huruf kecil/angka tanpa spasi · 用户名须为 3–30 个小写字母/数字';
    } else if (Auth.users.any((u) => u['name'] != widget.edit && Auth.usernameOf(u) == un)) {
      err = 'Username sudah dipakai · 用户名已被使用';
    } else if (pin.text.isNotEmpty && !RegExp(r'^\d{4,6}$').hasMatch(pin.text)) {
      err = 'PIN harus 4–6 angka · PIN 须为 4–6 位数字';
    } else if (pin.text != pin2.text) {
      err = 'Ulangi PIN tidak sama · 两次 PIN 不一致';
    } else if (admin && pin.text.isEmpty && !hadPin) {
      err = 'Akun admin wajib memakai PIN · 管理员账户必须设置 PIN';
    } else if (n != widget.edit && Auth.users.any((u) => u['name'] == n)) {
      err = 'Nama sudah terdaftar · 名字已存在';
    } else if (_editing && Auth.isAdminUser(widget.edit!) && !admin && Auth.adminCount <= 1) {
      err = 'Harus ada minimal 1 admin · 至少需要一名管理员';
    }
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    await Auth.addUser(n, role, admin ? pin.text : '', admin: admin, oldName: widget.edit, username: un);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.firstAdmin
        ? 'Buat akun admin · 创建管理员账户'
        : widget.selfOnly
            ? 'Ganti PIN · 修改 PIN'
            : (_editing ? 'Ubah akun · 修改账户' : 'Daftarkan akun · 注册账户');
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: name,
          enabled: !widget.selfOnly,
          textCapitalization: TextCapitalization.words,
          onChanged: (v) {
            if (!unameTouched) uname.text = Auth.slug(v.split(' ').first);
          },
          decoration: const InputDecoration(
              labelText: 'Nama lengkap · 全名',
              hintText: 'mis. Ferdinan H S',
              prefixIcon: Icon(Icons.person_outline),
              border: OutlineInputBorder()),
        ),
        if (suggest.isNotEmpty && !_editing) ...[
          const SizedBox(height: 8),
          const Text('Dari daftar pekerja TLD · 来自 TLD 人员名单', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final s in suggest)
              ActionChip(
                  label: Text(s),
                  onPressed: () => setState(() {
                        name.text = s;
                        if (!unameTouched) uname.text = Auth.slug(s.split(' ').first);
                      })),
          ]),
        ],
        const SizedBox(height: 14),
        TextField(
          controller: uname,
          enabled: !widget.selfOnly,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => unameTouched = true,
          decoration: const InputDecoration(
              labelText: 'Username untuk login · 登录用户名',
              hintText: 'mis. ferdinan',
              helperText: 'Huruf kecil/angka tanpa spasi. Berikan ke orangnya untuk login.',
              prefixIcon: Icon(Icons.alternate_email),
              border: OutlineInputBorder()),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          value: role,
          isExpanded: true,
          decoration: const InputDecoration(
              labelText: 'Jabatan · 职务', prefixIcon: Icon(Icons.badge_outlined), border: OutlineInputBorder()),
          items: [for (final r in Auth.kRoles) DropdownMenuItem(value: r, child: Text(r))],
          onChanged: widget.selfOnly ? null : (v) => setState(() => role = v ?? role),
        ),
        if (!widget.firstAdmin && !widget.selfOnly && Auth.isAdmin) ...[
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: admin,
            onChanged: (v) => setState(() {
              admin = v;
              if (!v) {
                pin.clear();
                pin2.clear();
              }
            }),
            title: const Text('Admin · 管理员'),
            subtitle: const Text('Boleh mendaftarkan & menghapus akun lain · 可注册和删除其他账户'),
          ),
        ],
        if (admin) ...[
        const SizedBox(height: 14),
        TextField(
          controller: pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
              labelText: _editing
                  ? 'PIN baru (kosongkan = tidak diubah) · 新 PIN（留空不变）'
                  : (admin ? 'PIN 4–6 angka (wajib) · PIN（必填）' : 'PIN 4–6 angka (boleh kosong) · PIN（可留空）'),
              prefixIcon: const Icon(Icons.lock_outline),
              border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: pin2,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
              labelText: 'Ulangi PIN · 再次输入 PIN', prefixIcon: Icon(Icons.lock_outline), border: OutlineInputBorder()),
        ),
        ],
        const SizedBox(height: 8),
        Text(
          widget.firstAdmin
              ? 'Akun ini menjadi admin: hanya admin yang bisa mendaftarkan, mengubah dan menghapus akun orang lain.\n'
                  '此账户为管理员：只有管理员可以注册、修改和删除其他账户。'
              : 'Pengguna masuk cukup dengan mengetik username (tanpa PIN); akun admin memakai PIN. '
                  'Nama otomatis tercatat sebagai petugas di setiap form dan tetap bisa diubah manual.\n'
                  '普通用户只需输入用户名登录（无需 PIN），管理员账户需要 PIN。',
          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7390)),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          onPressed: _save,
          icon: const Icon(Icons.check),
          label: const Text('Simpan · 保存'),
        ),
      ]),
    );
  }
}

/// Khusus admin: daftar akun, daftarkan akun baru, ubah, hapus.
class ManageUsersPage extends StatefulWidget {
  const ManageUsersPage({super.key});
  @override
  State<ManageUsersPage> createState() => _ManageUsersPageState();
}

class _ManageUsersPageState extends State<ManageUsersPage> {
  Future<void> _form({String? edit}) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => UserFormPage(edit: edit)));
    if (mounted) setState(() {});
  }

  Future<void> _remove(String n) async {
    if (n == Auth.name) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Akun yang sedang login tidak bisa dihapus · 不能删除当前登录账户')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus akun? · 删除账户？'),
        content: Text('Akun "$n" dihapus dari HP ini. Data pengukuran tidak ikut terhapus.\n仅删除账户，测量数据保留。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal · 取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus · 删除')),
        ],
      ),
    );
    if (ok == true) {
      await Auth.removeUser(n);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Auth.isAdmin) {
      return Scaffold(
          appBar: AppBar(title: const Text('Kelola pengguna · 用户管理')),
          body: const Center(child: Text('Khusus admin · 仅限管理员')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Kelola pengguna · 用户管理')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _form(),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Daftarkan · 注册'),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
        for (final u in Auth.users)
          Card(
            child: ListTile(
              leading: CircleAvatar(
                  backgroundColor: _navy,
                  child: Text(Auth.initials(u['name'] ?? ''), style: const TextStyle(color: Colors.white))),
              title: Row(children: [
                Flexible(child: Text(u['name'] ?? '', overflow: TextOverflow.ellipsis)),
                if (u['admin'] == '1') const _AdminBadge(),
              ]),
              subtitle: Text('@${Auth.usernameOf(u)} · ${u['role'] ?? ''}'),
              trailing: PopupMenuButton<String>(
                onSelected: (v) => v == 'e' ? _form(edit: u['name']) : _remove(u['name'] ?? ''),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'e', child: Text('Ubah / reset PIN · 修改/重置 PIN')),
                  PopupMenuItem(value: 'd', child: Text('Hapus · 删除')),
                ],
              ),
              onTap: () => _form(edit: u['name']),
            ),
          ),
        const SizedBox(height: 8),
        const Text(
          'Hanya admin yang bisa mendaftarkan akun dan menentukan username. Pengguna masuk cukup dengan '
          'mengetik username-nya.\n只有管理员可以注册账户并设定用户名，用户输入用户名即可登录。',
          style: TextStyle(fontSize: 12, color: Color(0xFF6B7390)),
        ),
      ]),
    );
  }
}

/// Tombol profil di Beranda: menampilkan nama yang login + menu.
class ProfileButton extends StatelessWidget {
  const ProfileButton({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: () => _sheet(context),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        decoration: BoxDecoration(color: Colors.white.withAlpha(170), borderRadius: BorderRadius.circular(22)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
              radius: 15,
              backgroundColor: _navy,
              child: Text(Auth.initials(Auth.name),
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 110),
            child: Text(Auth.name.isEmpty ? 'Masuk' : Auth.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _navy, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ]),
      ),
    );
  }

  void _sheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: CircleAvatar(
                backgroundColor: _navy,
                child: Text(Auth.initials(Auth.name), style: const TextStyle(color: Colors.white))),
            title: Row(children: [
              Flexible(child: Text(Auth.name, style: const TextStyle(fontWeight: FontWeight.bold))),
              if (Auth.isAdmin) const _AdminBadge(),
            ]),
            subtitle: Text(Auth.role),
          ),
          const Divider(),
          if (Auth.isAdmin)
            ListTile(
              leading: const Icon(Icons.manage_accounts_outlined),
              title: const Text('Kelola pengguna · 用户管理'),
              subtitle: const Text('Daftarkan, ubah, hapus akun · 注册、修改、删除账户'),
              onTap: () async {
                Navigator.pop(ctx);
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ManageUsersPage()));
                onChanged();
              },
            ),
          if (Auth.isAdmin)
          ListTile(
            leading: const Icon(Icons.password_outlined),
            title: const Text('Ubah akun saya / PIN · 修改我的账户'),
            onTap: () async {
              Navigator.pop(ctx);
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => UserFormPage(edit: Auth.name, selfOnly: !Auth.isAdmin)));
              onChanged();
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: _red),
            title: const Text('Keluar / ganti pengguna · 退出/切换用户'),
            onTap: () async {
              Navigator.pop(ctx);
              await Auth.logout();
              if (!context.mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => LoginPage(next: kAfterLogin!)), (_) => false);
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Diisi oleh main.dart: halaman yang dibuka setelah login.
WidgetBuilder? kAfterLogin;

/// Nama petugas default untuk form: nama yang login, bila tidak ada pakai [fallback].
String whoDefault([String fallback = '']) => Auth.name.isNotEmpty ? Auth.name : fallback;
