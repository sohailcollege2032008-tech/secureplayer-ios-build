/// Compares two strings for equality in constant time (independent of where
/// the first differing byte occurs), to avoid a timing side-channel on
/// Bearer-token checks in the local shelf server.
bool constantTimeEquals(String a, String b) {
  final aBytes = a.codeUnits;
  final bBytes = b.codeUnits;
  if (aBytes.length != bBytes.length) return false;

  var diff = 0;
  for (var i = 0; i < aBytes.length; i++) {
    diff |= aBytes[i] ^ bBytes[i];
  }
  return diff == 0;
}
