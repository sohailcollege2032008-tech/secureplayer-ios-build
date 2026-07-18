import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../security_layer/root_detection/root_detection_provider.dart';
import 'router.dart';
import 'theme.dart';

class SecurePlayerApp extends ConsumerWidget {
  const SecurePlayerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rootDetectionState = ref.watch(rootDetectionProvider);

    return rootDetectionState.when(
      loading: () => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFF0D0D0D),
          body: Center(
            child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
          ),
        ),
      ),
      // Fail closed: if root detection itself throws an unexpected exception,
      // block the app rather than silently opening it in an unprotected state.
      error: (_, __) => _buildRootedScreen(),
      data: (isRooted) {
        if (isRooted) return _buildRootedScreen();
        return _buildApp(ref);
      },
    );
  }

  Widget _buildApp(WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'SecurePlayer',
      theme: AppTheme.dark,
      routerConfig: router,
    );
  }

  Widget _buildRootedScreen() {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Color(0xFF0D0D0D),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.security_rounded, size: 72, color: Colors.red),
                SizedBox(height: 20),
                Text(
                  'Device Not Supported',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'SecurePlayer cannot run on rooted or compromised devices.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
