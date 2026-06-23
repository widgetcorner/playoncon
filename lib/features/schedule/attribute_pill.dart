import 'package:flutter/material.dart';

import '../../models/event_attribute.dart';
import '../../theme/poc_theme.dart';

/// Compact pill rendering one event attribute (leading emoji + short label).
class AttributePill extends StatelessWidget {
  final EventAttribute attribute;
  final bool dense;

  const AttributePill({
    super.key,
    required this.attribute,
    this.dense = true,
  });

  factory AttributePill.fromCode(String code, {bool dense = true}) {
    return AttributePill(
      attribute: EventAttribute.resolve(code),
      dense: dense,
    );
  }

  @override
  Widget build(BuildContext context) {
    final padH = dense ? 8.0 : 10.0;
    final padV = dense ? 2.0 : 4.0;
    final fontSize = dense ? 11.0 : 12.0;
    final text = dense ? attribute.code : attribute.label;
    final display =
        attribute.emoji.isEmpty ? text : '${attribute.emoji} $text';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: PocColors.creamSoft,
        border: Border.all(color: PocColors.saddle, width: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        display,
        style: TextStyle(
          fontSize: fontSize,
          color: PocColors.inkSoft,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Wrap of pills that sizes itself; renders nothing if [codes] is empty.
class AttributePillRow extends StatelessWidget {
  final List<String> codes;
  final bool dense;
  final EdgeInsetsGeometry padding;

  const AttributePillRow({
    super.key,
    required this.codes,
    this.dense = true,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    if (codes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final c in codes) AttributePill.fromCode(c, dense: dense),
        ],
      ),
    );
  }
}
