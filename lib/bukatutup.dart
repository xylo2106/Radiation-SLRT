import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'radiation.dart';

/// Rekaman Buka/Tutup Sumber Radioaktif (No. Dok 29/RBT-DI-SLRT/I/X/2026).
/// Periode per triwulan, mis. "April - Juni 2026".

const List<String> _qName = ['Januari - Maret', 'April - Juni', 'Juli - September', 'Oktober - Desember'];
const List<String> _qZh = ['1–3 月', '4–6 月', '7–9 月', '10–12 月'];
const List<String> kBtNotes = [
  'Perawatan rutin',
  'Pembersihan kontainer',
  'Penggantian / perbaikan detektor',
  'Shutdown pabrik',
  'Uji kebocoran (wipe test)',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-04-12T08:30" -> "2026-Q2"
String quarterOf(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})').firstMatch(iso);
  if (m == null) return '';
  return '${m.group(1)}-Q${((int.parse(m.group(2)!) - 1) ~/ 3) + 1}';
}

String quarterLabel(String q) {
  final m = RegExp(r'^(\d{4})-Q([1-4])$').firstMatch(q);
  if (m == null) return q;
  return '${_qName[int.parse(m.group(2)!) - 1]} ${m.group(1)}';
}

String quarterZh(String q) {
  final m = RegExp(r'^(\d{4})-Q([1-4])$').firstMatch(q);
  if (m == null) return '';
  return '${m.group(1)} 年 ${_qZh[int.parse(m.group(2)!) - 1]}';
}

/// "2026-04-12T08:30" -> "12/04/2026 08:30"
String btDisp(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?').firstMatch(iso);
  if (m == null) return iso;
  final d = '${m.group(3)}/${m.group(2)}/${m.group(1)}';
  return m.group(4) == null ? d : '$d ${m.group(4)}:${m.group(5)}';
}

String _isoDT(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}T${_two(d.hour)}:${_two(d.minute)}';

class BukaTutupPage extends StatefulWidget {
  const BukaTutupPage({super.key, required this.store});
  final Store store;
  @override
  State<BukaTutupPage> createState() => _BukaTutupPageState();
}

class _BukaTutupPageState extends State<BukaTutupPage> {
  String q = quarterOf(_isoDT(DateTime.now()));

  Store get store => widget.store;

  List<String> get quarters {
    final s = store.bt.map((r) => quarterOf((r['open'] ?? '').toString())).where((e) => e.isNotEmpty).toSet();
    s.add(quarterOf(_isoDT(DateTime.now())));
    return s.toList()..sort((a, b) => b.compareTo(a));
  }

  Future<void> _edit([Map<String, dynamic>? r]) async {
    final res = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => BtForm(store: store, rec: r == null ? null : {...r})));
    if (res == null) return;
    final touched = <String>{};
    if (r != null) touched.add(quarterOf((r['open'] ?? '').toString()));
    if (res['id'] == '__delete__') {
      store.bt.removeWhere((x) => x['id'] == r?['id']);
    } else {
      final i = store.bt.indexWhere((x) => x['id'] == res['id']);
      if (i >= 0) {
        store.bt[i] = res;
      } else {
        store.bt.add(res);
      }
      touched.add(quarterOf((res['open'] ?? '').toString()));
      q = quarterOf((res['open'] ?? '').toString());
    }
    touched.remove('');
    await store.saveBt(touched);
    if (mounted) snack(context, 'Tersimpan · 已保存');
  }

  Future<void> _closeNow(Map<String, dynamic> r) async {
    if (!await confirm(context, 'Tutup ${r['tag']} sekarang? · 立即关闭？')) return;
    r['close'] = _isoDT(DateTime.now());
    await store.saveBt({quarterOf((r['open'] ?? '').toString())});
    if (mounted) snack(context, '${r['tag']} ditutup · 已关闭');
  }

  String _tsv(List<Map<String, dynamic>> l) {
    final b = StringBuffer('No.\tTag Number\tTanggal Buka\tTanggal Tutup\tPersonel (Nama)\tKeterangan\n');
    for (var i = 0; i < l.length; i++) {
      final r = l[i];
      b.writeln([
        i + 1,
        r['tag'] ?? '',
        btDisp((r['open'] ?? '').toString()),
        btDisp((r['close'] ?? '').toString()),
        r['person'] ?? '',
        r['note'] ?? ''
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
        final border = BorderSide(color: Theme.of(context).dividerColor);
        final head = scheme.surfaceContainerHighest;
        final open = store.bt.where((r) => (r['close'] ?? '').toString().isEmpty).toList();
        final list = store.bt.where((r) => quarterOf((r['open'] ?? '').toString()) == q).toList();

        Widget cell(String t, double w, {bool bold = false, Color? bg, Color? fg, bool left = false}) => Container(
              width: w,
              constraints: const BoxConstraints(minHeight: 36),
              alignment: left ? Alignment.centerLeft : Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              decoration: BoxDecoration(color: bg, border: Border(right: border, bottom: border)),
              child: Text(t,
                  textAlign: left ? TextAlign.left : TextAlign.center,
                  style: TextStyle(fontWeight: bold ? FontWeight.bold : null, color: fg)),
            );
        const w = [40.0, 130.0, 130.0, 130.0, 150.0, 200.0];

        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            heroTag: 'bt_fab',
            onPressed: () => _edit(),
            icon: const Icon(Icons.lock_open),
            label: const Text('Buka sumber · 开启放射源'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              const Text('REKAMAN BUKA/TUTUP SUMBER RADIOAKTIF\n放射源开/关记录',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: kBlue)),
              const SizedBox(height: 10),
              if (open.isNotEmpty) ...[
                for (final r in open)
                  Card(
                    color: const Color(0xFFFDECEC),
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.lock_open, color: kRed),
                      title: Text('${r['tag']} · masih terbuka 仍开启',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: kRed)),
                      subtitle: Text('Dibuka · 开启: ${btDisp((r['open'] ?? '').toString())}'
                          '${(r['person'] ?? '').toString().isEmpty ? '' : ' · ${r['person']}'}'),
                      trailing: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: kRed),
                        onPressed: () => _closeNow(r),
                        child: const Text('Tutup 关闭'),
                      ),
                    ),
                  ),
                const SizedBox(height: 4),
              ],
              SizedBox(
                height: 38,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final k in quarters)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(
                            '${quarterLabel(k)} (${store.bt.where((r) => quarterOf((r['open'] ?? '').toString()) == k).length})'),
                        selected: k == q,
                        onSelected: (_) => setState(() => q = k),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 4),
              Text('Periode · 期间: ${quarterLabel(q)} · ${quarterZh(q)}',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
              const SizedBox(height: 8),
              if (list.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                      border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(14)),
                  child: Column(children: [
                    Icon(Icons.lock_outline, size: 44, color: scheme.outline),
                    const SizedBox(height: 8),
                    const Text('Belum ada rekaman di periode ini · 本期暂无记录',
                        textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text('Tekan "Buka sumber" saat shutter/sumber dibuka, lalu "Tutup" setelah selesai.\n'
                        '开启快门/放射源时点击“开启放射源”，完成后点击“关闭”。',
                        textAlign: TextAlign.center, style: TextStyle(color: scheme.outline, fontSize: 12)),
                  ]),
                )
              else ...[
                Text('Ketuk baris untuk mengubah atau menghapus · 点击行可修改或删除',
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Container(
                    decoration: BoxDecoration(border: Border(left: border, top: border)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      IntrinsicHeight(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          cell('No.\n序号', w[0], bold: true, bg: head),
                          cell('Tag Number\n位号', w[1], bold: true, bg: head),
                          cell('Tanggal Buka\n开启日期', w[2], bold: true, bg: head),
                          cell('Tanggal Tutup\n关闭日期', w[3], bold: true, bg: head),
                          cell('Personel (Nama)\n人员（姓名）', w[4], bold: true, bg: head),
                          cell('Keterangan\n备注', w[5], bold: true, bg: head),
                        ]),
                      ),
                      for (var i = 0; i < list.length; i++)
                        InkWell(
                          onTap: () => _edit(list[i]),
                          child: IntrinsicHeight(
                            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              cell('${i + 1}', w[0]),
                              cell('${list[i]['tag'] ?? ''}', w[1]),
                              cell(btDisp('${list[i]['open'] ?? ''}'), w[2]),
                              (list[i]['close'] ?? '').toString().isEmpty
                                  ? cell('Masih terbuka\n仍开启', w[3], fg: kRed, bold: true)
                                  : cell(btDisp('${list[i]['close']}'), w[3]),
                              cell('${list[i]['person'] ?? ''}', w[4]),
                              cell('${list[i]['note'] ?? ''}', w[5], left: true),
                            ]),
                          ),
                        ),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy),
                    label: const Text('Salin untuk Excel · 复制到 Excel'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _tsv(list)));
                      snack(context, 'Disalin · 已复制');
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Kirim ulang ke Sheets · 重新发送'),
                    onPressed: store.sheetUrl.isEmpty ? null : () => store.enqueue('b:$q'),
                  ),
                ]),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ===================== Form buka/tutup =====================

class BtForm extends StatefulWidget {
  const BtForm({super.key, required this.store, this.rec});
  final Store store;
  final Map<String, dynamic>? rec;
  @override
  State<BtForm> createState() => _BtFormState();
}

class _BtFormState extends State<BtForm> {
  late Map<String, dynamic> r;
  late final TextEditingController person, note;
  String loc = '';
  bool closed = false;

  @override
  void initState() {
    super.initState();
    final last = widget.store.bt.isEmpty ? null : widget.store.bt.last;
    r = widget.rec ??
        {
          'id': DateTime.now().microsecondsSinceEpoch.toString(),
          'tag': '',
          'open': _isoDT(DateTime.now()),
          'close': '',
          'person': (last?['person'] ?? '').toString(),
          'note': '',
        };
    closed = (r['close'] ?? '').toString().isNotEmpty;
    final t = (r['tag'] ?? '').toString();
    loc = t.isEmpty ? '' : locOf(t);
    person = TextEditingController(text: (r['person'] ?? '').toString());
    note = TextEditingController(text: (r['note'] ?? '').toString());
  }

  @override
  void dispose() {
    person.dispose();
    note.dispose();
    super.dispose();
  }

  Future<String?> _pick(String iso) async {
    final cur = DateTime.tryParse(iso) ?? DateTime.now();
    final d = await showDatePicker(
        context: context, initialDate: cur, firstDate: DateTime(2015), lastDate: DateTime(2100));
    if (d == null || !mounted) return null;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(cur));
    final dt = DateTime(d.year, d.month, d.day, t?.hour ?? cur.hour, t?.minute ?? cur.minute);
    return _isoDT(dt);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    final locs = s.sources.map((x) => locOf(x.tag)).toSet().toList()..sort();
    final tags = s.sources.where((x) => loc.isEmpty || locOf(x.tag) == loc).map((x) => x.tag).toList();
    final tag = (r['tag'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.rec == null ? 'Buka sumber · 开启放射源' : 'Ubah rekaman · 修改记录'),
        actions: [
          if (widget.rec != null)
            IconButton(
              tooltip: 'Hapus 删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirm(context, 'Hapus rekaman ini? · 删除此记录？') && context.mounted) {
                  Navigator.pop(context, {'id': '__delete__'});
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Row(children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                value: loc.isEmpty ? null : loc,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Lokasi · 位置', isDense: true, border: OutlineInputBorder()),
                items: [for (final l in locs) DropdownMenuItem(value: l, child: Text(l))],
                onChanged: (v) => setState(() {
                  loc = v ?? '';
                  if (!tag.startsWith('$loc-')) r['tag'] = '';
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                value: tags.contains(tag) ? tag : null,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Tag Number · 位号', isDense: true, border: OutlineInputBorder()),
                items: [for (final t in tags) DropdownMenuItem(value: t, child: Text(t))],
                onChanged: (v) => setState(() {
                  r['tag'] = v ?? '';
                  if (v != null) loc = locOf(v);
                }),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_open, color: kRed),
            title: const Text('Tanggal Buka · 开启日期'),
            subtitle: Text(btDisp((r['open'] ?? '').toString())),
            trailing: const Icon(Icons.edit_calendar_outlined),
            onTap: () async {
              final v = await _pick((r['open'] ?? '').toString());
              if (v != null) setState(() => r['open'] = v);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: closed,
            title: const Text('Sudah ditutup · 已关闭'),
            subtitle: Text(closed ? 'Tanggal Tutup · 关闭日期: ${btDisp((r['close'] ?? '').toString())}' : 'Sumber masih terbuka · 放射源仍开启'),
            onChanged: (v) => setState(() {
              closed = v;
              r['close'] = v ? ((r['close'] ?? '').toString().isEmpty ? _isoDT(DateTime.now()) : r['close']) : '';
            }),
          ),
          if (closed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock, color: kGreen),
              title: const Text('Ubah tanggal tutup · 修改关闭日期'),
              subtitle: Text(btDisp((r['close'] ?? '').toString())),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: () async {
                final v = await _pick((r['close'] ?? '').toString());
                if (v != null) setState(() => r['close'] = v);
              },
            ),
          const SizedBox(height: 8),
          TextField(
            controller: person,
            decoration: const InputDecoration(
                labelText: 'Personel (Nama) · 人员（姓名）',
                helperText: 'Pisahkan dengan koma bila lebih dari satu · 多人用逗号分隔',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Keterangan · 备注', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final n in kBtNotes)
              ActionChip(label: Text(n, style: const TextStyle(fontSize: 12)), onPressed: () => setState(() => note.text = n)),
          ]),
          const SizedBox(height: 20),
          FilledButton.icon(
            icon: const Icon(Icons.save_outlined),
            label: const Text('Simpan 保存'),
            onPressed: () {
              if ((r['tag'] ?? '').toString().isEmpty) {
                snack(context, 'Pilih Tag Number · 请选择位号');
                return;
              }
              final c = (r['close'] ?? '').toString();
              if (c.isNotEmpty && c.compareTo((r['open'] ?? '').toString()) < 0) {
                snack(context, 'Tanggal tutup lebih awal dari tanggal buka · 关闭日期早于开启日期');
                return;
              }
              r['person'] = person.text.trim();
              r['note'] = note.text.trim();
              Navigator.pop(context, r);
            },
          ),
        ],
      ),
    );
  }
}
