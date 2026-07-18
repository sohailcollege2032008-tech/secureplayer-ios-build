import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/services/cloud_function_http_client.dart';
import 'device_binding_service.dart';

final authStateChangesProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

final currentUserProvider = Provider<User>((ref) {
  final user = ref.watch(authStateChangesProvider).valueOrNull;
  if (user == null) throw StateError('No authenticated user');
  return user;
});

final deviceBindingServiceProvider = Provider<DeviceBindingService>(
  (ref) => DeviceBindingService(),
);

/// Runs once per session after login. Throws DeviceMismatchException if the
/// account is already bound to a different device.
final deviceBindingProvider = FutureProvider<void>((ref) async {
  final user = ref.watch(currentUserProvider);
  final service = ref.read(deviceBindingServiceProvider);
  await service.bindOrVerify(user.uid);
});

/// Student profile (name + phone) fetched from Cloud Function for watermark,
/// cached in secure storage for offline-first usage.
final studentProfileProvider = FutureProvider<StudentProfile>((ref) async {
  final user = ref.watch(currentUserProvider);
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final cachedName = await storage.read(key: 'student_name_${user.uid}');
  final cachedPhone = await storage.read(key: 'student_phone_${user.uid}');
  final cachedEmail = await storage.read(key: 'student_email_${user.uid}');

  if (cachedName != null && cachedName.isNotEmpty) {
    return StudentProfile(
      name: cachedName,
      phone: cachedPhone ?? '',
      email: cachedEmail ?? '',
    );
  }

  try {
    // cloud_functions has no Windows platform implementation at all — the
    // SDK call below throws MissingPluginException there, silently caught
    // by the broad catch below and falling back to cached/default data.
    // Route Windows through the same pinned raw-HTTP path used for imports.
    final data = Platform.isWindows
        ? await callCloudFunctionViaHttp('getStudentProfile', {})
        : (await FirebaseFunctions.instanceFor(region: 'us-central1')
                .httpsCallable('getStudentProfile')
                .call())
            .data as Map<String, dynamic>;
    final name = data['name'] as String? ?? user.displayName ?? 'Student';
    final phone = data['phone'] as String? ?? '';
    final email = data['email'] as String? ?? user.email ?? '';

    // Cache the retrieved values for offline use
    await storage.write(key: 'student_name_${user.uid}', value: name);
    await storage.write(key: 'student_phone_${user.uid}', value: phone);
    await storage.write(key: 'student_email_${user.uid}', value: email);

    return StudentProfile(
      name: name,
      phone: phone,
      email: email,
    );
  } catch (_) {
    return StudentProfile(
      name: user.displayName ?? user.email ?? 'Student',
      phone: '',
      email: user.email ?? '',
    );
  }
});

class StudentProfile {
  const StudentProfile(
      {required this.name, required this.phone, this.email = ''});
  final String name;
  final String phone;
  final String email;
}
