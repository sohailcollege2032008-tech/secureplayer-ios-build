import 'package:flutter/material.dart';

import 'security_guard_state.dart';

/// Full-screen block shown when the runtime guard confirms a real
/// violation. Deliberately has no exit/dismiss button — it only clears
/// automatically, the instant the ongoing recheck (periodic tick, or the
/// focus-regained recheck) finds the underlying condition gone. Because
/// there's no button, the copy for each reason has to say exactly what's
/// wrong and exactly what fixes it (or say plainly that nothing does).
class SecurityBlockScreen extends StatelessWidget {
  const SecurityBlockScreen({super.key, required this.reason});

  final SecurityGuardReason reason;

  @override
  Widget build(BuildContext context) {
    final copy = _copyFor(reason);
    return ColoredBox(
      color: const Color(0xFF0D0D0D),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.security_rounded, size: 72, color: Colors.red),
              const SizedBox(height: 20),
              Text(
                copy.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                copy.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white60, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReasonCopy {
  const _ReasonCopy(this.title, this.message);
  final String title;
  final String message;
}

_ReasonCopy _copyFor(SecurityGuardReason reason) {
  switch (reason) {
    case SecurityGuardReason.adbEnabled:
      return const _ReasonCopy(
        'Developer Options Detected',
        'USB debugging is enabled. Turn it off in Developer Options, '
            'then wait a moment — this will clear automatically.',
      );
    case SecurityGuardReason.developerOptionsEnabled:
      return const _ReasonCopy(
        'Developer Options Detected',
        'Developer Options must be turned off to watch this content. '
            'Go to Settings, System, Developer Options, and turn it off.',
      );
    case SecurityGuardReason.flagSecureMissing:
      return const _ReasonCopy(
        'Screen Protection Interrupted',
        'Screen protection was interrupted — disconnect any screen '
            'mirroring or casting and try again.',
      );
    case SecurityGuardReason.fridaDetected:
      return const _ReasonCopy(
        'Instrumentation Tool Detected',
        'An instrumentation tool was detected on this device. Close it '
            'completely (and reboot if it does not fully stop) to continue.',
      );
    case SecurityGuardReason.rooted:
      return const _ReasonCopy(
        'Rooted Device',
        'This device appears to be rooted. SecurePlayer cannot run on '
            'rooted devices.',
      );
    case SecurityGuardReason.xposed:
      return const _ReasonCopy(
        'System Modification Detected',
        'A system-modification framework (Xposed/LSposed) was detected. '
            'Disable the module and reboot to continue.',
      );
    case SecurityGuardReason.magiskHidden:
      return const _ReasonCopy(
        'Rooted Device',
        'This device appears to be rooted (hidden root detected). '
            'SecurePlayer cannot run on rooted devices.',
      );
    case SecurityGuardReason.signatureInvalid:
      return const _ReasonCopy(
        'Unofficial Copy Detected',
        "This copy of the app doesn't match the official release. Please "
            'uninstall it and reinstall the official SecurePlayer app from '
            'your teacher.',
      );
    case SecurityGuardReason.emulatorDetected:
      return const _ReasonCopy(
        'Emulator Detected',
        'SecurePlayer cannot run on an emulator or virtual device. Please '
            'use a physical Android device.',
      );
    case SecurityGuardReason.debuggableBuild:
      return const _ReasonCopy(
        'Unsupported Build',
        'This build of the app is not supported. Please reinstall the '
            'official SecurePlayer app from your teacher.',
      );
    case SecurityGuardReason.virtualMachineDetected:
      return const _ReasonCopy(
        'Virtual Machine Detected',
        'SecurePlayer cannot run inside a virtual machine. Please use a '
            'physical Windows PC.',
      );
    case SecurityGuardReason.debuggerAttached:
      return const _ReasonCopy(
        'Debugger Detected',
        'A debugger is attached to this application. Close it completely '
            'to continue.',
      );
  }
}
