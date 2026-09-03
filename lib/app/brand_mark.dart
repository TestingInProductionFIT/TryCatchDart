import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Brand mark: pink '{}' tile + wordmark with the "Testing in Production"
/// tagline as a monospace micro-label.
///
/// Drawn with type only — no image assets — so it stays crisp at any DPI.
class BrandMark extends StatelessWidget {
  final bool compact;

  const BrandMark({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: AppColors.pink,
            borderRadius: BorderRadius.circular(7),
            boxShadow: const [
              BoxShadow(color: Color(0x40FF00A1), blurRadius: 8, offset: Offset(0, 2)),
            ],
          ),
          alignment: Alignment.center,
          child: const Text(
            '{}',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 13,
              fontFamily: AppText.monoFamily,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '{TryCatch}',
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
                letterSpacing: -0.2,
              ),
            ),
            if (!compact)
              Text(
                'TESTING IN PRODUCTION',
                style: AppText.microLabel.copyWith(
                  fontSize: 8,
                  letterSpacing: 1.2,
                  color: AppColors.faint,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
