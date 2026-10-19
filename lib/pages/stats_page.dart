import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class StatsPage extends StatelessWidget {
  final bool isDark;
  const StatsPage({super.key, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final inkColor = isDark ? AppTheme.darkInk : AppTheme.lightInk;
    final mutedColor = isDark ? AppTheme.darkMuted : AppTheme.lightMuted;
    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final lineColor = isDark ? AppTheme.darkLine : AppTheme.lightLine;

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 110),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('支出统计', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: inkColor)),
                Text('2026年10月 · 支出构成', style: TextStyle(fontSize: 11, color: mutedColor)),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: surfaceColor, borderRadius: BorderRadius.circular(16)),
              child: Text('按月', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: inkColor)),
            ),
          ],
        ),
        const SizedBox(height: 28),

        Text('总支出', style: TextStyle(fontSize: 12, color: mutedColor)),
        const SizedBox(height: 4),
        Text('¥ 1,286.50', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: inkColor)),
        const SizedBox(height: 24),

        // 分类比例展示条
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 10,
            child: Row(
              children: [
                Expanded(flex: 4865, child: Container(color: inkColor)),
                Expanded(flex: 4500, child: Container(color: inkColor.withValues(alpha: 0.6))),
                Expanded(flex: 1800, child: Container(color: inkColor.withValues(alpha: 0.35))),
                Expanded(flex: 1700, child: Container(color: lineColor)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),

        Text('支出排行', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: inkColor)),
        const SizedBox(height: 12),
        _buildCategoryRank('餐饮美食', '37.8%', '¥ 486.50', Icons.fastfood_outlined, inkColor, mutedColor),
        _buildCategoryRank('日常购物', '35.0%', '¥ 450.00', Icons.shopping_bag_outlined, inkColor, mutedColor),
        _buildCategoryRank('交通出行', '14.0%', '¥ 180.00', Icons.directions_subway_outlined, inkColor, mutedColor),
        _buildCategoryRank('其他支出', '13.2%', '¥ 170.00', Icons.more_horiz, inkColor, mutedColor),
      ],
    );
  }

  Widget _buildCategoryRank(
    String name,
    String percentage,
    String amount,
    IconData icon,
    Color inkColor,
    Color mutedColor,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: inkColor),
          const SizedBox(width: 14),
          Expanded(
            child: Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: inkColor)),
          ),
          Text(percentage, style: TextStyle(fontSize: 12, color: mutedColor)),
          const SizedBox(width: 16),
          Text(amount, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: inkColor)),
        ],
      ),
    );
  }
}
