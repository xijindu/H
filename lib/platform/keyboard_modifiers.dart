import 'package:flutter/services.dart';

bool keyboardModifiersPressed({bool allowShift = false}) {
  final keyboard = HardwareKeyboard.instance;
  return keyboard.isControlPressed ||
      keyboard.isMetaPressed ||
      keyboard.isAltPressed ||
      (!allowShift && keyboard.isShiftPressed);
}
