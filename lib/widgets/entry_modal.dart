import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class EntryModal extends StatefulWidget {
  final bool isDark;
  const EntryModal({super.key, required this.isDark});

  @override
  State<EntryModal> createState() => _EntryModalState();
}

class _EntryModalState extends State<EntryModal> {
  String _amount = '0.00';
  String _category = '餐饮';

  final List<Map<String, dynamic>> _categories = [
    {'name': '餐饮', 'icon': Icons.fastfood_outlined},
    {'name': '日用', 'icon': Icons.shopping_bag_outlined},
    {'name': '交通', 'icon': Icons.directions_subway_outlined},
    {'name': '娱乐', 'icon': Icons.movie_outlined},
    {'name': '服饰', 'icon': Icons.checkroom_outlined},
    {'name': '其他', 'icon': Icons.more_horiz_outlined},
  ];

  @override
  Widget build(BuildContext context) {
    final inkColor = widget.isDark ? AppTheme.darkInk : AppTheme.lightInk;
    final surfaceColor = widget.isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final bgColor = widget.isDark ? const Color(0xFF161618) : const Color(0xFFFFFFFF);

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 24,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部抓手与关闭
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '记一笔支出',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: inkColor),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: inkColor,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 金额展示
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Text('¥', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: inkColor)),
                  const SizedBox(width: 8),
                  Text(
                    _amount,
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: inkColor),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 分类选择网格
            Text('选择分类', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _categories.map((cat) {
                final isSelected = _category == cat['name'];
                return GestureDetector(
                  onTap: () => setState(() => _category = cat['name'] as String),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? inkColor : surfaceColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          cat['icon'] as IconData,
                          size: 16,
                          color: isSelected ? (widget.isDark ? Colors.black : Colors.white) : inkColor,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          cat['name'] as String,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: isSelected ? (widget.isDark ? Colors.black : Colors.white) : inkColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),

            // 确认保存按钮
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: inkColor,
                  foregroundColor: widget.isDark ? Colors.black : Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  elevation: 0,
                ),
                onPressed: () {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已记录 [$_category] 支出'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                child: const Text('完成记录', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
