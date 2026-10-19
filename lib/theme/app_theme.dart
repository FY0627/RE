import 'package:flutter/material.dart';

class AppTheme {
  // 日间使用参考图中的柔和灰白，夜间纯黑。
  static const Color lightBg = Color(0xFFF2F1F6);
  static const Color darkBg = Color(0xFF000000);

  static const Color lightInk = Color(0xFF171719);
  static const Color darkInk = Color(0xFFF5F5F7);

  static const Color lightMuted = Color(0xFF85858A);
  static const Color darkMuted = Color(0xFF818187);

  static const Color lightSurface = Color(0xFFF5F5F7);
  static const Color darkSurface = Color(0xFF1C1C1E);

  static const Color lightLine = Color(0xFFECECEE);
  static const Color darkLine = Color(0xFF272729);

  // 日夜均用 15% 白色玻璃底色，保留背景模糊。
  static const Color lightGlass = Color.fromRGBO(255, 255, 255, .15);
  static const Color darkGlass = Color.fromRGBO(255, 255, 255, .15);

  // 胶囊选中指示块高亮颜色
  static const Color lightIndicator = Color(0x14000000); // 8% 中性灰，日间选中层略深
  static const Color darkIndicator = Color(0x29FFFFFF); // 16% 亮灰，夜间选中层略亮

  static ThemeData light() {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: lightBg,
      colorScheme: const ColorScheme.light(
        surface: lightSurface,
        onSurface: lightInk,
        primary: lightInk,
      ),
      fontFamily: 'SF Pro Display',
    );
  }

  static ThemeData dark() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,
      colorScheme: const ColorScheme.dark(
        surface: darkSurface,
        onSurface: darkInk,
        primary: darkInk,
      ),
      fontFamily: 'SF Pro Display',
    );
  }
}
