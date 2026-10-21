import 'package:flutter/widgets.dart';

void scheduleChatPostFrame(VoidCallback callback) {
  final binding = WidgetsBinding.instance;
  binding.addPostFrameCallback((_) => callback());
  binding.ensureVisualUpdate();
}
