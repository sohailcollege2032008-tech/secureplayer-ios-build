sealed class AppException implements Exception {
  const AppException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class NotEnrolledException extends AppException {
  const NotEnrolledException(super.message);
}

class DeviceMismatchException extends AppException {
  const DeviceMismatchException(super.message);
}

class RootedDeviceException extends AppException {
  const RootedDeviceException(super.message);
}

class KeyFetchException extends AppException {
  const KeyFetchException(super.message);
}

class ImportException extends AppException {
  const ImportException(super.message);
}

class DecryptionException extends AppException {
  const DecryptionException(super.message);
}

class ProfileNotFoundException extends AppException {
  const ProfileNotFoundException(super.message);
}

class KeyNotFoundException extends AppException {
  const KeyNotFoundException(super.message);
}

class AdbDetectedException extends AppException {
  const AdbDetectedException(super.message);
}

class VideoStartupTimeoutException extends AppException {
  const VideoStartupTimeoutException(super.message);
}

/// Thrown by FirestoreRest when a request still gets 401/403 after already
/// retrying once with a force-refreshed ID token — i.e. the local session
/// itself is broken (not just a momentarily-stale cached token), and the
/// only known fix is a real sign-out/sign-in. Distinct from a generic
/// permission error so the UI can show a guided recovery action instead of
/// the raw REST error text.
class AuthSessionExpiredException extends AppException {
  const AuthSessionExpiredException(super.message);
}
