import 'package:flutter/material.dart';

/// M3 滑动操作按钮，统一用于 Slidable 操作。
class M3SlideAction extends StatelessWidget {
  const M3SlideAction({
    super.key,
    required this.onTap,
    required this.color,
    required this.iconColor,
    required this.icon,
    required this.label,
  });

  final VoidCallback onTap;
  final Color color;
  final Color iconColor;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Material(
          color: color,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(fontSize: 11, color: iconColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
