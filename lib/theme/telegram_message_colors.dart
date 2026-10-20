import 'package:flutter/widgets.dart';

import '../chat/chat_wallpaper.dart';

/// Per-surface message colours derived from an emoji chat theme's
/// [ChatThemeStyle].
@immutable
class TelegramMessageColors {
  const TelegramMessageColors({
    required this.incomingLink,
    required this.outgoingLink,
    required this.incomingQuote,
    required this.outgoingQuote,
    required this.incomingReplyLine,
    required this.outgoingReplyLine,
    required this.incomingReplyName,
    required this.outgoingReplyName,
    required this.incomingReplyText,
    required this.outgoingReplyText,
    required this.incomingReplyMediaText,
    required this.outgoingReplyMediaText,
    required this.incomingForwardedName,
    required this.outgoingForwardedName,
    required this.incomingPreviewLine,
    required this.outgoingPreviewLine,
    required this.incomingSiteName,
    required this.outgoingSiteName,
    required this.incomingTime,
    required this.outgoingTime,
  });

  factory TelegramMessageColors.fromChatThemeStyle(ChatThemeStyle style) {
    final incomingText = style.incomingTextColor;
    final outgoingText = style.outgoingTextColor;
    final incomingAccent = style.nameColor;
    final outgoingAccent = style.outgoingMessageAccentColor == 0
        ? outgoingText
        : style.outgoingAccentColor;
    return TelegramMessageColors(
      incomingLink: incomingAccent,
      outgoingLink: outgoingAccent,
      incomingQuote: incomingAccent,
      outgoingQuote: outgoingAccent,
      incomingReplyLine: incomingAccent,
      outgoingReplyLine: outgoingAccent,
      incomingReplyName: incomingAccent,
      outgoingReplyName: outgoingAccent,
      incomingReplyText: incomingText.withValues(alpha: 0.72),
      outgoingReplyText: outgoingText.withValues(alpha: 0.72),
      incomingReplyMediaText: incomingText.withValues(alpha: 0.72),
      outgoingReplyMediaText: outgoingText.withValues(alpha: 0.72),
      incomingForwardedName: incomingAccent,
      outgoingForwardedName: outgoingAccent,
      incomingPreviewLine: incomingAccent,
      outgoingPreviewLine: outgoingAccent,
      incomingSiteName: incomingAccent,
      outgoingSiteName: outgoingAccent,
      incomingTime: incomingText.withValues(alpha: 0.65),
      outgoingTime: outgoingText.withValues(alpha: 0.65),
    );
  }

  final Color incomingLink;
  final Color outgoingLink;
  final Color incomingQuote;
  final Color outgoingQuote;
  final Color incomingReplyLine;
  final Color outgoingReplyLine;
  final Color incomingReplyName;
  final Color outgoingReplyName;
  final Color incomingReplyText;
  final Color outgoingReplyText;
  final Color incomingReplyMediaText;
  final Color outgoingReplyMediaText;
  final Color incomingForwardedName;
  final Color outgoingForwardedName;
  final Color incomingPreviewLine;
  final Color outgoingPreviewLine;
  final Color incomingSiteName;
  final Color outgoingSiteName;
  final Color incomingTime;
  final Color outgoingTime;
}
