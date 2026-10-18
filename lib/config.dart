/// Alamat spreadsheet tujuan yang sudah tertanam di aplikasi (siap pakai).
///
/// - kRadSheetUrl  : web app dari skrip LogBookRadiasi.gs
///   (Radiation Log, Kartu TLD, MCU, Pendose, Laporan Kerja PPR)
/// - kDensSheetUrl : Density SLRT (default sama dengan kRadSheetUrl)
///
/// Bisa juga diisi saat build: --dart-define=RAD_SHEET_URL=... --dart-define=DENS_SHEET_URL=...
const String kRadSheetUrl = String.fromEnvironment('RAD_SHEET_URL',
    defaultValue: 'https://script.google.com/macros/s/AKfycbwFBUHTstu1YjCkTp-9DvgkJ4BXmJaW1L7B67dbPDNZTAUrDNxmKH1prtH8x-s3jBsrEA/exec');
/// Density memakai web app yang sama (LogBookRadiasi.gs sudah memuat skrip Density).
/// Isi alamat lain di sini hanya bila ingin memakai spreadsheet Density yang terpisah.
const String kDensSheetUrl = String.fromEnvironment('DENS_SHEET_URL',
    defaultValue: kRadSheetUrl);
