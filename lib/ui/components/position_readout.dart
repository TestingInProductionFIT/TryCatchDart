import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'copy_button.dart';
import 'qr_code_dialog.dart';

/// One stat for a detail line, with an optional explainer tooltip (e.g.
/// what "Drift" measures). Passed in display order: altitude, drift.
typedef PositionDetail = ({String text, String? tooltip});

/// Position readout shared by the GPS position and dead-reckoning tiles:
/// large centred hero coordinates, the remaining stats combined into one
/// line below, and an optional second footer line — with copy + QR actions
/// overlaid top-right so the text block centres in the tile's true middle.
///
/// The card header already names the tile, so no labels repeat it here.
/// Narrow tiles scale the whole block down instead of clipping.
class PositionReadout extends StatelessWidget {
  final String coords;

  /// When non-null, an icon copy button copies this (Google Maps format).
  final String? copyText;

  /// When non-null, a QR button opens these coordinates as a scannable
  /// code dialog. Pass together with [copyText].
  final double? qrLatitude;

  final double? qrLongitude;

  /// QR dialog title, e.g. the tile name.
  final String qrTitle;

  /// Stats for the single detail line under the coordinates.
  final List<PositionDetail> details;

  /// Optional second line under [details] (GPS fix status, or the
  /// dead-reckoning leg from the last known position).
  final PositionDetail? footer;

  const PositionReadout({
    super.key,
    required this.coords,
    this.copyText,
    this.qrLatitude,
    this.qrLongitude,
    this.qrTitle = '',
    this.details = const [],
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final showActions = copyText != null || qrLatitude != null;
    // One centred line; per-stat explainers merge into its hover tooltip.
    final line = details.map((d) => d.text).join(' · ');
    final lineTip = details
        .where((d) => d.tooltip != null)
        .map((d) => d.tooltip!)
        .join('. ');

    final stack = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Display-only live readout — excluded from semantics to spare the
        // Windows accessibility bridge.
        ExcludeSemantics(
          child: Text(
            coords,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppText.mono.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: AppColors.foreground,
            ),
          ),
        ),
        if (line.isNotEmpty) ...[
          const SizedBox(height: 4),
          // Display-only live readout (10 Hz) — no semantics traffic.
          ExcludeSemantics(
            child: _detailLine(line, lineTip),
          ),
        ],
        if (footer != null) ...[
          const SizedBox(height: 2),
          ExcludeSemantics(
            child: footer!.tooltip == null
                ? Text(
                    footer!.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: _lineStyle,
                  )
                : Tooltip(
                    message: footer!.tooltip!,
                    child: Text(
                      footer!.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: _lineStyle,
                    ),
                  ),
          ),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Tiles always hand down a bounded box; the fallback keeps the
        // widget usable anywhere else.
        if (!constraints.maxHeight.isFinite) {
          return Center(child: stack);
        }
        final centred = Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: stack,
            ),
          ),
        );
        // The actions overlay the corner instead of taking layout space,
        // so the text block centres in the tile's true middle.
        if (!showActions) return centred;
        return Stack(
          children: [
            centred,
            Positioned(
              top: 0,
              right: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (copyText != null)
                    CopyButton(text: copyText!, iconOnly: true),
                  if (copyText != null && qrLatitude != null)
                    const SizedBox(width: 2),
                  if (qrLatitude != null && qrLongitude != null)
                    QrCodeButton(
                      latitude: qrLatitude!,
                      longitude: qrLongitude!,
                      title: qrTitle,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// One muted detail line, with an optional hover explainer.
  Widget _detailLine(String text, String tip) => tip.isEmpty
      ? Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: _lineStyle,
        )
      : Tooltip(
          message: tip,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: _lineStyle,
          ),
        );

  TextStyle get _lineStyle => AppText.mono.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: AppColors.mutedForeground,
      );
}
