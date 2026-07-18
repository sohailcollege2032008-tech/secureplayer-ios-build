import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'secure_storage_service.dart';

final secureStorageProvider = Provider<SecureStorageService>(
  (ref) => SecureStorageService(),
);
