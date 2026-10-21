import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import 'app_icons.dart';
import 'ui_components.dart';

class SettingsSelectionOption<T> {
  const SettingsSelectionOption({
    required this.id,
    required this.value,
    required this.label,
    this.icon,
    this.subtitle,
    this.enabled = true,
  });

  final String id;
  final T value;
  final String label;
  final AppIconData? icon;
  final String? subtitle;
  final bool enabled;
}

class SettingsSelectionRow<T> extends StatelessWidget {
  const SettingsSelectionRow({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.isSelected,
    required this.onSelected,
    this.leading,
    this.subtitle,
    this.menuTitle,
    this.menuKey,
    this.dismissOnSelect = true,
    this.enabled = true,
    this.showChevron = true,
    this.height = AppMetric.settingsRowHeight,
    this.leadingInset = AppMetric.settingsLeadingInset,
  });

  final String title;
  final String value;
  final Widget? leading;
  final String? subtitle;
  final List<SettingsSelectionOption<T>> options;
  final bool Function(T value) isSelected;
  final FutureOr<void> Function(T value) onSelected;
  final String? menuTitle;
  final Key? menuKey;
  final bool dismissOnSelect;
  final bool enabled;
  final bool showChevron;
  final double height;
  final double leadingInset;

  @override
  Widget build(BuildContext context) {
    final canOpen = enabled && options.any((option) => option.enabled);
    return Builder(
      builder: (anchorContext) => SettingsRow(
        title: title,
        value: value,
        leading: leading,
        subtitle: subtitle,
        enabled: enabled,
        showChevron: showChevron,
        height: height,
        leadingInset: leadingInset,
        onTap: canOpen
            ? () => unawaited(_showSelectionMenu(anchorContext))
            : null,
      ),
    );
  }

  Future<void> _showSelectionMenu(BuildContext anchorContext) async {
    await _showTouchSheet(anchorContext);
  }

  Future<void> _showTouchSheet(BuildContext anchorContext) =>
      showAppModalSheet<void>(
        context: anchorContext,
        backgroundColor: Colors.transparent,
        isScrollControlled: options.length > 8,
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) {
            final titleOffset = menuTitle == null ? 0 : 1;
            return SafeArea(
              top: false,
              child: SettingsPanel(
                key: menuKey,
                margin: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.lg,
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: options.length + titleOffset,
                    separatorBuilder: (_, _) => const SettingsDivider(),
                    itemBuilder: (context, index) {
                      if (menuTitle != null && index == 0) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.xxl,
                            AppSpacing.lg,
                            AppSpacing.xxl,
                            AppSpacing.md,
                          ),
                          child: Text(
                            menuTitle!.l10n(context),
                            style: AppTextStyle.callout(
                              context.colors.textSecondary,
                            ).copyWith(fontWeight: AppTextWeight.semibold),
                          ),
                        );
                      }
                      final option = options[index - titleOffset];
                      final selected = isSelected(option.value);
                      return SettingsRow(
                        key: ValueKey(option.id),
                        title: option.label,
                        subtitle: option.subtitle,
                        leading: option.icon == null
                            ? null
                            : SettingsLeadingIcon(icon: option.icon!),
                        enabled: option.enabled,
                        showChevron: false,
                        trailing: selected
                            ? AppIcon(
                                HeroAppIcons.check,
                                size: AppIconSize.lg,
                                color: AppTheme.brand,
                              )
                            : null,
                        onTap: option.enabled
                            ? () async {
                                await Future<void>.sync(
                                  () => onSelected(option.value),
                                );
                                if (!context.mounted) return;
                                if (dismissOnSelect) {
                                  Navigator.of(context).pop();
                                } else {
                                  setSheetState(() {});
                                }
                              }
                            : null,
                      );
                    },
                  ),
                ),
              ),
            );
          },
        ),
      );
}
