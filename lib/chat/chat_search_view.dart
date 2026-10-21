import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'chat_message_search_bar.dart';
import 'chat_message_search_controller.dart';

class ChatSearchView extends StatefulWidget {
  const ChatSearchView({
    super.key,
    required this.chatId,
    required this.title,
    this.initialQuery,
  });
  final int chatId;
  final String title;
  final String? initialQuery;

  @override
  State<ChatSearchView> createState() => _ChatSearchViewState();
}

class _ChatSearchViewState extends State<ChatSearchView> {
  late final ChatMessageSearchController _search;

  @override
  void initState() {
    super.initState();
    _search = ChatMessageSearchController(
      chatId: widget.chatId,
      autoActivateFirstResult: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search.open(initialQuery: widget.initialQuery);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          ChatSearchHeaderBar(controller: _search, height: 50, onClose: _close),
          Expanded(
            child: ChatSearchResultsPane(
              controller: _search,
              peerTitle: widget.title,
              showHeader: false,
              backgroundColor: c.background,
              onSelect: (message) => Navigator.of(context).pop(message.id),
            ),
          ),
        ],
      ),
    );
  }
}
