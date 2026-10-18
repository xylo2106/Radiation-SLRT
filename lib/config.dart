/// Alamat spreadsheet tujuan yang sudah tertanam di aplikasi (siap pakai).
///
/// - kRadSheetUrl  : web app dari skrip LogBookRadiasi.gs
///   (Radiation Log, Kartu TLD, MCU, Pendose, Laporan Kerja PPR)
/// - kDensSheetUrl : web app dari skrip Code.gs (Density SLRT)
///
/// Bisa juga diisi saat build: --dart-define=RAD_SHEET_URL=... --dart-define=DENS_SHEET_URL=...
const String kRadSheetUrl = String.fromEnvironment('RAD_SHEET_URL',
    defaultValue: 'https://script.google.com/macros/s/AKfycbwFBUHTstu1YjCkTp-9DvgkJ4BXmJaW1L7B67dbPDNZTAUrDNxmKH1prtH8x-s3jBsrEA/exec');
const String kDensSheetUrl = String.fromEnvironment('DENS_SHEET_URL',
    defaultValue: '');
