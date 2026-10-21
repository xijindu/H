import 'package:flutter/material.dart';
import 'package:handy/l10n/app_localizations.dart';

import '../components/app_icons.dart';
import '../components/app_interactive_surface.dart';
import '../components/ui_components.dart';
import '../theme/app_theme.dart';

const List<Color> kAccentColors = [
  Color(0xFFCC5049),
  Color(0xFFD67722),
  Color(0xFF955CDB),
  Color(0xFF40A920),
  Color(0xFF309EBA),
  Color(0xFF368AD1),
  Color(0xFFC7508B),
];

class AccentColorPickerView extends StatefulWidget {
  const AccentColorPickerView({
    super.key,
    required this.title,
    required this.selectedId,
    this.allowNone = false,
    this.footnote,
  });

  final String title;
  final int selectedId;
  final bool allowNone;
  final String? footnote;

  @override
  State<AccentColorPickerView> createState() => _AccentColorPickerViewState();
}

class _AccentColorPickerViewState extends State<AccentColorPickerView> {
  late int _sel = widget.selectedId;

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: widget.title,
      onBack: () => Navigator.of(context).pop(),
      trailing: AppInteractiveSurface(
        semanticLabel: AppStrings.t(AppStringKeys.accentColorPickerSave),
        onTap: () => Navigator.of(context).pop(_sel),
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            AppStrings.t(AppStringKeys.accentColorPickerSave),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.brand,
            ),
          ),
        ),
      ),
      child: SettingsListView(
        children: [
          SettingsPanel(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Wrap(
              spacing: AppSpacing.xxl,
              runSpacing: AppSpacing.xxl,
              children: [
                if (widget.allowNone) _swatch(-1, null),
                for (var i = 0; i < kAccentColors.length; i++)
                  _swatch(i, kAccentColors[i]),
              ],
            ),
          ),
          if (widget.footnote case final footnote?)
            SettingsNote(text: footnote),
        ],
      ),
    );
  }

  Widget _swatch(int id, Color? color) {
    final c = context.colors;
    final selected = _sel == id;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _sel = id),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? (color ?? c.textSecondary) : Colors.transparent,
            width: 2,
          ),
        ),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color ?? c.groupedBackground,
            shape: BoxShape.circle,
            border: color == null
                ? Border.all(color: c.textTertiary, width: 1.5)
                : null,
          ),
          child: selected
              ? AppIcon(
                  HeroAppIcons.check,
                  size: 20,
                  color: color == null
                      ? c.textSecondary
                      : readableForeground(color),
                )
              : (color == null
                    ? AppIcon(HeroAppIcons.ban, size: 18, color: c.textTertiary)
                    : null),
        ),
      ),
    );
  }
}
