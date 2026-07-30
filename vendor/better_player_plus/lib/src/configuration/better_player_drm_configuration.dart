import 'package:better_player_plus/src/configuration/better_player_drm_type.dart';

///Configuration of DRM used to protect data source
class BetterPlayerDrmConfiguration {
  BetterPlayerDrmConfiguration({
    this.drmType,
    this.token,
    this.licenseUrl,
    this.certificateUrl,
    this.headers,
    this.clearKey,
    this.offlineFairplayConfig,
  });

  ///Type of DRM
  final BetterPlayerDrmType? drmType;

  ///Parameter used only for token encrypted DRMs
  final String? token;

  ///Url of license server
  final String? licenseUrl;

  ///Url of fairplay certificate
  final String? certificateUrl;

  ///ClearKey json object, used only for ClearKey protection. Only support for Android.
  final String? clearKey;

  ///Additional headers send with auth request, used only for WIDEVINE DRM
  final Map<String, String>? headers;

  ///iOS only. When set (a JSON string: {ksmProxyUrl, idToken, lectureId,
  ///videoId, courseId, deviceId}), FairPlay content is played through
  ///AVContentKeySession with persistable offline keys instead of the legacy
  ///AVAssetResourceLoaderDelegate path certificateUrl/licenseUrl normally
  ///trigger — required for "import once, play forever offline" content,
  ///since the resource-loader path only supports online streaming keys.
  final String? offlineFairplayConfig;
}
