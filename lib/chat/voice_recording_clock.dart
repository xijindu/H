class VoiceRecordingClock {
  Duration elapsed = Duration.zero;
  bool hasRecorderProgress = false;

  void update(Duration duration) {
    if (duration <= Duration.zero) return;
    hasRecorderProgress = true;
    elapsed = duration;
  }

  void tick(Duration interval, {required bool paused}) {
    if (!paused && !hasRecorderProgress) elapsed += interval;
  }

  double get seconds => elapsed.inMilliseconds / 1000;
}
