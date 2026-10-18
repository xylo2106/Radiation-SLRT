/// Terjemahan Mandarin untuk nilai data yang tampil di layar
/// (status, jabatan, kategori, hasil MCU). Nilai aslinya tetap disimpan
/// dalam Bahasa Indonesia agar data & spreadsheet tidak berubah.
const Map<String, String> kZh = {
  'PPR Aktif': 'PPR 在岗',
  'PPR Non Aktif': 'PPR 离岗',
  'Pekerja Radiasi Gauging Aktif': '辐射工作人员（料位计）在岗',
  'Pekerja Radiasi Gauging Non Aktif': '辐射工作人员（料位计）离岗',
  'Pekerja Radiasi XRF Aktif': '辐射工作人员（XRF）在岗',
  'Pekerja Radiasi XRF Non Aktif': '辐射工作人员（XRF）离岗',
  'PPR': '辐射防护员',
  'Pekerja Radiasi Gauging': '辐射工作人员（料位计）',
  'Pekerja Radiasi XRF': '辐射工作人员（XRF）',
  'Regulasi': '法规',
  'Izin BAPETEN': 'BAPETEN 许可证',
  'SOP': '操作规程',
  'Program & Laporan': '计划与报告',
  'Lainnya': '其他',
  'FIT': '合格',
  'Normal': '正常',
  'Sehat': '健康',
};

/// "Indonesia · 中文" bila ada terjemahannya.
String bi(String s) {
  final z = kZh[s];
  return z == null ? s : '$s · $z';
}
