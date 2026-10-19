import 'package:flutter/material.dart';
import '../theme/app_layout.dart';

/// Keeps typography, spacing, and control sizes in the preview's proportions.
class AppDesignLayout extends StatelessWidget {
  const AppDesignLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final scale =
            (width / AppLayout.referenceWidth).clamp(.85, 1.3).toDouble();
        final designSize = Size(width / scale, height / scale);
        final designMedia = media.copyWith(
          size: designSize,
          padding: media.padding / scale,
          viewPadding: media.viewPadding / scale,
          viewInsets: media.viewInsets / scale,
          systemGestureInsets: media.systemGestureInsets / scale,
        );

        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: designSize.width,
              height: designSize.height,
              child: MediaQuery(data: designMedia, child: child),
            ),
          ),
        );
      },
    );
  }
}
