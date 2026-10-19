import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class HomePage extends StatelessWidget {
  final bool isDark;
  const HomePage({super.key, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final inkColor = isDark ? AppTheme.darkInk : AppTheme.lightInk;
    final mutedColor = isDark ? const Color(0xFFA0A0A5) : AppTheme.lightMuted;
    final surfaceColor = isDark ? const Color(0xFF1C1C1E) : AppTheme.lightSurface;
    final lineColor = isDark ? const Color(0xFF2C2C2E) : AppTheme.lightLine;

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 110),
      children: [
        // 顶部标题
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '日常记账',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                    color: inkColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '示例账本 · 2026年10月',
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
              ],
            ),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: surfaceColor,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.calendar_today_outlined, size: 16, color: inkColor),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // 本月支出主视觉
        Text('本月支出', style: TextStyle(fontSize: 12, color: mutedColor)),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('¥ ', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w400, color: inkColor)),
            Text(
              '1,286',
              style: TextStyle(
                fontSize: 42,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.5,
                color: inkColor,
              ),
            ),
            Text('.50', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: inkColor)),
          ],
        ),
        const SizedBox(height: 18),

        // 收入与结余
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本月收入', style: TextStyle(fontSize: 11, color: mutedColor)),
                  const SizedBox(height: 3),
                  Text('¥ 8,000.00', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: inkColor)),
                ],
              ),
            ),
            Container(width: 1, height: 32, color: lineColor),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本月结余', style: TextStyle(fontSize: 11, color: mutedColor)),
                  const SizedBox(height: 3),
                  Text('¥ 6,713.50', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: inkColor)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // 预算进度卡片
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('月度预算', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: inkColor)),
                  Text('已用 42.9%', style: TextStyle(fontSize: 11, color: mutedColor)),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: 0.429,
                  minHeight: 5,
                  backgroundColor: lineColor,
                  valueColor: AlwaysStoppedAnimation<Color>(inkColor),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('剩余 ¥1,713.50', style: TextStyle(fontSize: 11, color: mutedColor)),
                  Text('总计 ¥3,000.00', style: TextStyle(fontSize: 11, color: mutedColor)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),

        // 最近交易 (多条内容以穿透 Dock 毛玻璃)
        Text(
          '最近交易',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: inkColor),
        ),
        const SizedBox(height: 10),
        _buildTransactionItem('咖啡', '今天 09:30 · 餐饮', '-28.00', Icons.coffee, inkColor, mutedColor, surfaceColor),
        _buildTransactionItem('午餐便当', '今天 12:15 · 餐饮', '-36.00', Icons.restaurant, inkColor, mutedColor, surfaceColor),
        _buildTransactionItem('地铁交通', '昨天 18:40 · 交通', '-6.00', Icons.subway, inkColor, mutedColor, surfaceColor),
        _buildTransactionItem('生活超市', '10月5日 · 日用品', '-135.50', Icons.shopping_bag_outlined, inkColor, mutedColor, surfaceColor),
        _buildTransactionItem('晚餐聚餐', '10月4日 · 餐饮', '-168.00', Icons.dinner_dining, inkColor, mutedColor, surfaceColor),
        _buildTransactionItem('共享单车', '10月3日 · 交通', '-1.50', Icons.pedal_bike, inkColor, mutedColor, surfaceColor),
      ],
    );
  }

  Widget _buildTransactionItem(
    String title,
    String subtitle,
    String amount,
    IconData icon,
    Color inkColor,
    Color mutedColor,
    Color surfaceColor,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: surfaceColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: inkColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: inkColor)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 11, color: mutedColor)),
              ],
            ),
          ),
          Text(
            amount,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: inkColor,
            ),
          ),
        ],
      ),
    );
  }
}
