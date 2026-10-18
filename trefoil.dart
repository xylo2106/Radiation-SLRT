import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Penanda menu yang memakai lambang radiasi (trefoil) alih-alih ikon Material.
const IconData kTrefoil = IconData(0xe9f0, fontFamily: 'MaterialIcons');

/// Lambang radiasi ☢ (trefoil) dengan proporsi standar:
/// lingkaran tengah R, daun dari 1,5R sampai 5R, tiap daun 60°.
class TrefoilIcon extends StatelessWidget {
  const TrefoilIcon({super.key, this.size, this.color});
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = IconTheme.of(context);
    final s = size ?? t.size ?? 24;
    final c = color ?? t.color ?? Colors.black;
    return SizedBox(
      width: s,
      height: s,
      child: CustomPaint(painter: _TrefoilPainter(c)),
    );
  }
}

class _TrefoilPainter extends CustomPainter {
  _TrefoilPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..isAntiAlias = true;
    final c = size.center(Offset.zero);
    final outer = size.shortestSide / 2 * 0.96;
    final r0 = outer / 5;
    final inner = r0 * 1.5;
    canvas.drawCircle(c, r0, p);
    const sweep = math.pi / 3; // 60°
    // daun: kanan-atas, kiri-atas, bawah (sudut layar, searah jarum jam dari sumbu x)
    for (final mid in [-math.pi / 6, -5 * math.pi / 6, math.pi / 2]) {
      final a0 = mid - sweep / 2;
      final path = Path()
        ..moveTo(c.dx + inner * math.cos(a0), c.dy + inner * math.sin(a0))
        ..lineTo(c.dx + outer * math.cos(a0), c.dy + outer * math.sin(a0))
        ..arcTo(Rect.fromCircle(center: c, radius: outer), a0, sweep, false)
        ..lineTo(c.dx + inner * math.cos(a0 + sweep), c.dy + inner * math.sin(a0 + sweep))
        ..arcTo(Rect.fromCircle(center: c, radius: inner), a0 + sweep, -sweep, false)
        ..close();
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_TrefoilPainter old) => old.color != color;
}

/// Ikon menu: lambang radiasi untuk [kTrefoil], selain itu ikon Material biasa.
Widget menuIcon(IconData icon, {double? size, Color? color}) =>
    icon == kTrefoil ? TrefoilIcon(size: size, color: color) : Icon(icon, size: size, color: color);
