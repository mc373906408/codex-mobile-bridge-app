import 'package:flutter/material.dart';

class BridgeMark extends StatelessWidget {
  const BridgeMark({super.key, required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _BridgePainter(color));
}

class _BridgePainter extends CustomPainter {
  _BridgePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width / 11
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(size.width * .12, size.height * .75)
      ..lineTo(size.width * .12, size.height * .4)
      ..quadraticBezierTo(
        size.width * .5,
        -size.height * .1,
        size.width * .88,
        size.height * .4,
      )
      ..lineTo(size.width * .88, size.height * .75);
    canvas.drawPath(path, paint);
    canvas.drawLine(
      Offset(size.width * .12, size.height * .55),
      Offset(size.width * .88, size.height * .55),
      paint,
    );
    paint.style = PaintingStyle.fill;
    for (final x in [.12, .88]) {
      canvas.drawCircle(
        Offset(size.width * x, size.height * .82),
        size.width * .09,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BridgePainter oldDelegate) => color != oldDelegate.color;
}
