import '../tdlib/td_models.dart';

int blockedMessageRunEnd(
  List<ChatMessage> messages,
  int start, {
  required bool Function(int index) startsNewSection,
}) {
  if (start < 0 || start >= messages.length || !messages[start].blockedByUser) {
    return start;
  }
  var end = start + 1;
  while (end < messages.length &&
      messages[end].blockedByUser &&
      !startsNewSection(end)) {
    end++;
  }
  return end;
}
