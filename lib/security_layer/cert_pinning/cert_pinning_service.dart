import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Real TLS trust-anchor pinning for Windows Cloud Function calls.
///
/// Android already has OS-level SPKI pinning via
/// android/app/src/main/res/xml/network_security_config.xml. This is the
/// Windows-side equivalent — Windows has no OS-level pinning mechanism
/// reachable from Flutter, and Dart's default `HttpClient` otherwise trusts
/// whatever the OS certificate store trusts (vulnerable to a MITM proxy
/// with a locally-installed "trusted" root, e.g. a rogue WiFi hotspot, a
/// corporate proxy, or antivirus TLS inspection).
///
/// Approach: build the client with a [SecurityContext] that trusts ONLY
/// GTS Root R1 (the exact root Android already pins) instead of the OS's
/// default trust store. A connection whose chain doesn't terminate at
/// this root fails TLS validation outright — this is real chain
/// validation, not a reactive `badCertificateCallback` (which only ever
/// exposes the leaf certificate to Dart — the wrong certificate to check
/// an intermediate/root pin against; comparing SPKI hashes there can
/// never match, silently reverting to no protection while looking
/// implemented). Trusting the root alone, rather than pinning the
/// specific WR2 intermediate too, means this also survives Google
/// rotating the intermediate CA without needing an app update — same
/// fallback behavior Android's dual intermediate+root pin-set gives it.
///
/// Limitation, stated plainly: this can't protect against an attacker who
/// somehow obtains a certificate that genuinely chains to the real GTS
/// Root R1 (i.e. compromises Google's CA infrastructure) — no pinning
/// scheme can. It fully blocks the realistic threat: a MITM that doesn't
/// have Google's actual private key.
class CertPinningService {
  // GTS Root R1 — verified 2026-07-09 against the live TLS chain served by
  // us-central1-stud-future-platform-db.cloudfunctions.net (SPKI SHA-256
  // hxqRlPTu1bMS/0DITB1SSu0vd4u/8l8TjPgfaAp63Gc=, matching the exact pin
  // already deployed in network_security_config.xml on Android — see the
  // unit test alongside this file, which checks this constant against
  // that same hash). Root CAs are long-lived by design; rotation is a
  // rare, planned event, not a per-release concern.
  static const gtsRootR1Pem = '''
-----BEGIN CERTIFICATE-----
MIIFYjCCBEqgAwIBAgIQd70NbNs2+RrqIQ/E8FjTDTANBgkqhkiG9w0BAQsFADBX
MQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEQMA4GA1UE
CxMHUm9vdCBDQTEbMBkGA1UEAxMSR2xvYmFsU2lnbiBSb290IENBMB4XDTIwMDYx
OTAwMDA0MloXDTI4MDEyODAwMDA0MlowRzELMAkGA1UEBhMCVVMxIjAgBgNVBAoT
GUdvb2dsZSBUcnVzdCBTZXJ2aWNlcyBMTEMxFDASBgNVBAMTC0dUUyBSb290IFIx
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAthECix7joXebO9y/lD63
ladAPKH9gvl9MgaCcfb2jH/76Nu8ai6Xl6OMS/kr9rH5zoQdsfnFl97vufKj6bwS
iV6nqlKr+CMny6SxnGPb15l+8Ape62im9MZaRw1NEDPjTrETo8gYbEvs/AmQ351k
KSUjB6G00j0uYODP0gmHu81I8E3CwnqIiru6z1kZ1q+PsAewnjHxgsHA3y6mbWwZ
DrXYfiYaRQM9sHmklCitD38m5agI/pboPGiUU+6DOogrFZYJsuB6jC511pzrp1Zk
j5ZPaK49l8KEj8C8QMALXL32h7M1bKwYUH+E4EzNktMg6TO8UpmvMrUpsyUqtEj5
cuHKZPfmghCN6J3Cioj6OGaK/GP5Afl4/Xtcd/p2h/rs37EOeZVXtL0m79YB0esW
CruOC7XFxYpVq9Os6pFLKcwZpDIlTirxZUTQAs6qzkm06p98g7BAe+dDq6dso499
iYH6TKX/1Y7DzkvgtdizjkXPdsDtQCv9Uw+wp9U7DbGKogPeMa3Md+pvez7W35Ei
Eua++tgy/BBjFFFy3l3WFpO9KWgz7zpm7AeKJt8T11dleCfeXkkUAKIAf5qoIbap
sZWwpbkNFhHax2xIPEDgfg1azVY80ZcFuctL7TlLnMQ/0lUTbiSw1nH69MG6zO0b
9f6BQdgAmD06yK56mDcYBZUCAwEAAaOCATgwggE0MA4GA1UdDwEB/wQEAwIBhjAP
BgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTkrysmcRorSCeFL1JmLO/wiRNxPjAf
BgNVHSMEGDAWgBRge2YaRQ2XyolQL30EzTSo//z9SzBgBggrBgEFBQcBAQRUMFIw
JQYIKwYBBQUHMAGGGWh0dHA6Ly9vY3NwLnBraS5nb29nL2dzcjEwKQYIKwYBBQUH
MAKGHWh0dHA6Ly9wa2kuZ29vZy9nc3IxL2dzcjEuY3J0MDIGA1UdHwQrMCkwJ6Al
oCOGIWh0dHA6Ly9jcmwucGtpLmdvb2cvZ3NyMS9nc3IxLmNybDA7BgNVHSAENDAy
MAgGBmeBDAECATAIBgZngQwBAgIwDQYLKwYBBAHWeQIFAwIwDQYLKwYBBAHWeQIF
AwMwDQYJKoZIhvcNAQELBQADggEBADSkHrEoo9C0dhemMXoh6dFSPsjbdBZBiLg9
NR3t5P+T4Vxfq7vqfM/b5A3Ri1fyJm9bvhdGaJQ3b2t6yMAYN/olUazsaL+yyEn9
WprKASOshIArAoyZl+tJaox118fessmXn1hIVw41oeQa1v1vg4Fv74zPl6/AhSrw
9U5pCZEt4Wi4wStz6dTZ/CLANx8LZh1J7QJVj2fhMtfTJr9w4z30Z209fOU0iOMy
+qduBmpvvYuR7hZL6Dupszfnw0Skfths18dG9ZKb59UhvmaSGZRVbNQpsg3BZlvi
d0lIKO2d1xozclOzgjXPYovJJIultzkMu34qQb9Sz/yilrbCgj8=
-----END CERTIFICATE-----
''';

  static SecurityContext? _pinnedContext;

  static SecurityContext _pinnedSecurityContext() {
    return _pinnedContext ??= SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(gtsRootR1Pem));
  }

  /// Pure decision logic, split out from [createPinnedClient] so it's
  /// testable without needing to introspect a real [SecurityContext] (which
  /// Dart's API doesn't expose anyway) or run on an actual Windows host.
  ///
  /// Debug builds are excluded — same reasoning as Android's own
  /// `<debug-overrides>` block in network_security_config.xml: a developer
  /// testing against a local HTTPS debugging proxy (Charles, mitmproxy,
  /// Fiddler) or behind a corporate TLS-inspecting network needs normal
  /// trust-store validation to still work. Release strictness is
  /// unaffected — [debugModeOverride]/[isWindowsOverride] exist only so
  /// tests can exercise every branch without needing an actual release
  /// build on an actual Windows host.
  @visibleForTesting
  static bool shouldPin({bool? debugModeOverride, bool? isWindowsOverride}) {
    final isWindows = isWindowsOverride ?? Platform.isWindows;
    final debugMode = debugModeOverride ?? kDebugMode;
    return isWindows && !debugMode;
  }

  /// Returns an [HttpClient] pinned to GTS Root R1 on Windows release
  /// builds. Everywhere else (other platforms, or debug builds anywhere)
  /// this is a plain client — Android's protection is OS-level
  /// (network_security_config.xml) and needs no Dart-side client, and debug
  /// builds intentionally skip pinning (see [shouldPin]).
  static HttpClient createPinnedClient({bool? debugModeOverride}) {
    if (!shouldPin(debugModeOverride: debugModeOverride)) return HttpClient();
    return HttpClient(context: _pinnedSecurityContext());
  }
}
