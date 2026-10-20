import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../components/app_icons.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class NativeBottomTabItem {
  const NativeBottomTabItem({
    required this.id,
    required this.label,
    required this.icon,
  });
  final int id;
  final String label;
  final AppIconData icon;

  Map<String, Object> toMap() => {
    'id': id,
    'label': label,
    'codePoint': icon.data.codePoint,
    'fontFamily': icon.data.fontFamily!,
  };
}

/// UIKit owns the glass, tab layout, selection interaction, and VoiceOver.
/// Only app-owned Heroicons and localized titles cross the platform channel.
class NativeBottomTabBar extends StatefulWidget {
  const NativeBottomTabBar({
    super.key,
    required this.items,
    required this.selection,
    required this.unread,
    this.unreadLabel,
    required this.onSelect,
    required this.onClearUnread,
  });

  final List<NativeBottomTabItem> items;
  final int selection;
  final int unread;
  final String? unreadLabel;
  final ValueChanged<int> onSelect;
  final VoidCallback onClearUnread;

  @override
  State<NativeBottomTabBar> createState() => _NativeBottomTabBarState();
}

class _NativeBottomTabBarState extends State<NativeBottomTabBar> {
  MethodChannel? _channel;
  double? _height;

  Map<String, Object> _configuration() => {
    'items': widget.items.map((item) => item.toMap()).toList(),
    'selection': widget.items[widget.selection].id,
    'unread': widget.unread,
    'unreadLabel': widget.unreadLabel ?? '${widget.unread}',
    'clearUnreadLabel': AppStringKeys.channelDirectMessagesMarkRead.l10n(
      context,
    ),
    'tint': context.colors.linkBlue.toARGB32(),
    'dark': context.colors.background.computeLuminance() < 0.5,
    'rtl': Directionality.of(context) == TextDirection.rtl,
    'safeBottom': MediaQuery.paddingOf(context).bottom,
  };

  @override
  void didUpdateWidget(NativeBottomTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  void _update() {
    final channel = _channel;
    if (channel != null) {
      unawaited(channel.invokeMethod<void>('update', _configuration()));
    }
  }

  void _created(int id) {
    _channel = MethodChannel('handy/native_bottom_bar/$id')
      ..setMethodCallHandler((call) async {
        if (!mounted) return;
        switch (call.method) {
          case 'select':
            final index = widget.items.indexWhere(
              (item) => item.id == call.arguments,
            );
            if (index >= 0) widget.onSelect(index);
          case 'clearUnread':
            widget.onClearUnread();
          case 'height':
            final height = (call.arguments as num).toDouble();
            if (height.isFinite && height > 0 && height != _height) {
              setState(() => _height = height);
            }
        }
      });
    _update();
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('native-bottom-tab-bar'),
    height: _height ?? 64 + MediaQuery.paddingOf(context).bottom,
    child: UiKitView(
      viewType: 'handy/native_bottom_bar',
      creationParamsCodec: const StandardMessageCodec(),
      creationParams: _configuration(),
      onPlatformViewCreated: _created,
    ),
  );
}
