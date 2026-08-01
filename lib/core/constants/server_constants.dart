class ServerConstants {
  static const String localhost = '127.0.0.1';

  // ── Deterministic per-lecture port (browser-memory feature) ──────────────
  // Browser storage (localStorage/cookies) is keyed by origin, and the
  // origin includes the port. A random port per session silently orphaned
  // all stored state on every open; a stable per-lecture port keeps the
  // WebView origin byte-identical across opens and app restarts, so the
  // native WebView storage (disk-persisted on Android/iOS/Windows) behaves
  // like a real browser. Range chosen below the OS ephemeral ranges
  // (Windows 49152+, Linux/Android 32768+) to make collisions with
  // unrelated sockets unlikely.
  static const int _portBase = 11000;
  static const int _portRange = 12000; // 11000..22999

  static int portFor(String lectureId) {
    // FNV-1a 32-bit — cheap, deterministic, well-distributed.
    var hash = 0x811c9dc5;
    for (final unit in lectureId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return _portBase + (hash % _portRange);
  }
}
