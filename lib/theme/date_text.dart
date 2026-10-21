class DateText {
  static String _two(int n) => n.toString().padLeft(2, '0');

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dateLabel(DateTime date, DateTime now) {
    if (date.year == now.year) return '${_two(date.month)}/${_two(date.day)}';
    return '${date.year}/${_two(date.month)}/${_two(date.day)}';
  }

  static String _timeLabel(DateTime date) =>
      '${_two(date.hour)}:${_two(date.minute)}';

  static String listLabel(int unix) {
    if (unix <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    final now = DateTime.now();
    if (_sameDay(date, now)) return _timeLabel(date);
    return _dateLabel(date, now);
  }

  static String separatorLabel(int unix) {
    if (unix <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    final now = DateTime.now();
    if (_sameDay(date, now)) return _timeLabel(date);
    return '${_dateLabel(date, now)} ${_timeLabel(date)}';
  }

  static String bubbleLabel(int unix) {
    if (unix <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    return _timeLabel(date);
  }

  static String messageDetailLabel(int unix) {
    if (unix <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    return '${_two(date.month)}-${_two(date.day)} '
        '${_two(date.hour)}:${_two(date.minute)}:${_two(date.second)}';
  }

  static String quoteLabel(int unix) {
    if (unix <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    final now = DateTime.now();
    if (_sameDay(date, now)) return _timeLabel(date);
    return '${_dateLabel(date, now)} ${_timeLabel(date)}';
  }
}
