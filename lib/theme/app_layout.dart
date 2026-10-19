import 'dart:math' as math;

/// Logical dimensions of the original 340px phone preview's inner screen.
abstract final class AppLayout {
  static const referenceWidth = 327.0;
  static const cardInset = 16.0;
  static const referenceCardWidth = referenceWidth - cardInset * 2;
  static const stackedCardAspectRatio = referenceCardWidth / 186;
  static const detailCardAspectRatio = referenceCardWidth / 196;

  static double cardWidth(double viewportWidth) =>
      math.max(1.0, viewportWidth - cardInset * 2);

  static double stackedCardHeight(double viewportWidth) =>
      cardWidth(viewportWidth) / stackedCardAspectRatio;

  static double detailCardHeight(double viewportWidth) =>
      cardWidth(viewportWidth) / detailCardAspectRatio;

  static double cardPeekOffset(double viewportWidth) =>
      52 * cardWidth(viewportWidth) / referenceCardWidth;
}
