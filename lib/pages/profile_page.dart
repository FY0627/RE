import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ProfilePage extends StatelessWidget {
  final bool isDark;
  final ValueChanged<bool> onThemeToggle;

  const ProfilePage({
    super.key,
    required this.isDark,
    required this.onThemeToggle,
  });

  @override
  Widget build(BuildContext context) {
    final inkColor = isDark ? AppTheme.darkInk : AppTheme.lightInk;
    final mutedColor = isDark ? AppTheme.darkMuted : AppTheme.lightMuted;
    final surfaceColor = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 110),
      children: [
        Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: surfaceColor, shape: BoxShape.circle),
              child: Center(
                child: Text(
                  '记',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: inkColor),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('本地账本', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: inkColor)),
                Text('无需登录 · 离线存储', style: TextStyle(fontSize: 11, color: mutedColor)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 32),

        Text('个性化与设置', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: inkColor)),
        const SizedBox(height: 12),

        // 昼夜模式切换
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: surfaceColor, borderRadius: BorderRadius.circular(16)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined, size: 20, color: inkColor),
                  const SizedBox(width: 12),
                  Text('深色外观', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: inkColor)),
                ],
              ),
              Switch.adaptive(
                value: isDark,
                onChanged: onThemeToggle,
                activeTrackColor: inkColor,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        _buildSettingItem('账本管理', '默认单账本', Icons.book_outlined, inkColor, mutedColor, surfaceColor),
        _buildSettingItem('货币符号', '¥ 人民币 (CNY)', Icons.currency_yen_outlined, inkColor, mutedColor, surfaceColor),
        _buildSettingItem('汇率与金价缓存', '已配置官方央行基准', Icons.cloud_outlined, inkColor, mutedColor, surfaceColor),
        _buildSettingItem('关于日常记账', 'v1.0.0 (Flutter 重构版)', Icons.info_outline, inkColor, mutedColor, surfaceColor),
      ],
    );
  }

  Widget _buildSettingItem(
    String title,
    String subtitle,
    IconData icon,
    Color inkColor,
    Color mutedColor,
    Color surfaceColor,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: surfaceColor, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(icon, size: 20, color: inkColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: inkColor)),
                Text(subtitle, style: TextStyle(fontSize: 11, color: mutedColor)),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: mutedColor),
        ],
      ),
    );
  }
}
