/// Public web pages the app links out to.
///
/// Apple Guideline 5.1.1(i) requires the privacy policy to be reachable from
/// inside the app, not only from the App Store Connect metadata field. An app
/// with account registration and no in-app link is a common rejection.
///
/// Deliberately NOT the Mashrou3 Dactoor site. This build ships under the
/// generic "Secure Player" identity, so putting a brand's page in front of a
/// reviewer would contradict the app it is attached to. See
/// core/constants/brand_config.dart for why this build carries no brand.
///
/// Static pages, source in `D:\Projects\Antigravity\secure-player-site`.
library app_links;

const String kPrivacyPolicyUrl = 'https://secure-player-app.vercel.app/privacy';
const String kSupportUrl = 'https://secure-player-app.vercel.app/support';
