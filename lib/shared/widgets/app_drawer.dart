import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/quiz/quiz_history_service.dart';
import '../../security_layer/fairplay/fairplay_service.dart';
import '../../security_layer/secure_storage/secure_storage_service.dart';

/// DEBUG-ONLY: shows the FairPlay diagnostics log in a scrollable sheet.
Future<void> _showFairplayLog(BuildContext context) async {
  final log = await FairplayService.readDiagnostics();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1A2E),
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('FairPlay diagnostics',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white38),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  log.isEmpty ? '(log is empty)' : log,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}


class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = FirebaseAuth.instance.currentUser;

    return Drawer(
      backgroundColor: const Color(0xFF0D0D0D),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF6C63FF).withValues(alpha: 0.2),
                    ),
                    child: const Icon(
                      Icons.person_rounded,
                      color: Color(0xFF6C63FF),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.displayName ?? 'Student',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (user?.email != null)
                          Text(
                            user!.email!,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 8),
            _DrawerTile(
              icon: Icons.school_rounded,
              label: 'My Courses',
              onTap: () {
                Navigator.of(context).pop();
                context.go('/courses');
              },
            ),
            _DrawerTile(
              icon: Icons.quiz_rounded,
              label: 'My Quizzes',
              onTap: () {
                Navigator.of(context).pop();
                context.push('/my-quizzes');
              },
            ),
            _DrawerTile(
              icon: Icons.edit_note_rounded,
              label: 'Personal Quizzes',
              onTap: () {
                Navigator.of(context).pop();
                context.push('/personal-quizzes');
              },
            ),
            // DEBUG-ONLY (import/isImported diagnosis on devices we cannot
            // pull logs from): shows the FairPlay diagnostics log in a sheet.
            // Reads an empty file on non-iOS platforms — harmless.
            _DrawerTile(
              icon: Icons.bug_report_rounded,
              label: 'FairPlay Log (DEBUG)',
              onTap: () {
                Navigator.of(context).pop();
                _showFairplayLog(context);
              },
            ),
            const Spacer(),
            const Divider(color: Colors.white12, height: 1),
            _DrawerTile(
              icon: Icons.logout_rounded,
              label: 'Sign Out',
              color: Colors.white38,
              onTap: () {
                Navigator.of(context).pop();
                FirebaseAuth.instance.signOut();
              },
            ),
            _DrawerTile(
              icon: Icons.delete_forever_rounded,
              label: 'Delete Account',
              color: Colors.redAccent.withValues(alpha: 0.7),
              onTap: () {
                Navigator.of(context).pop();
                _confirmAndDeleteAccount(context, ref);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: Icon(icon, color: color ?? Colors.white70, size: 22),
      title: Text(
        label,
        style: TextStyle(
          color: color ?? Colors.white70,
          fontSize: 15,
        ),
      ),
      onTap: onTap,
      dense: true,
    );
  }
}

Future<void> _confirmAndDeleteAccount(BuildContext context, WidgetRef ref) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text(
        'Delete Account',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: const Text(
        'This permanently deletes your account, enrollments, and all '
        'locally downloaded course data. This cannot be undone.',
        style: TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  if (!context.mounted) return;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
      child: CircularProgressIndicator(color: Color(0xFF6C63FF)),
    ),
  );

  try {
    await FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('deleteMyAccount')
        .call();
    await ref.read(quizHistoryServiceProvider).clearAll();
    await SecureStorageService().deleteAll();
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // close loading dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete account: $e')),
      );
    }
    return;
  }

  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop(); // close loading dialog
  }
  // Router redirects to /login automatically once this completes, same as
  // the plain Sign Out tile above.
  await FirebaseAuth.instance.signOut();
}
