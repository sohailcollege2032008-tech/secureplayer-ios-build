import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/review_settings.dart';
import '../../core/services/review_settings_service.dart';

class ReviewSettingsNotifier extends StateNotifier<ReviewSettings> {
  ReviewSettingsNotifier() : super(const ReviewSettings()) {
    _load();
  }

  Future<void> _load() async {
    state = await ReviewSettingsService.instance.load();
  }

  Future<void> _update(ReviewSettings next) async {
    state = next;
    await ReviewSettingsService.instance.save(next);
  }

  Future<void> setWrongIntervalMin(double value) =>
      _update(state.copyWith(wrongIntervalMin: value));

  Future<void> setHardFloorMin(double value) =>
      _update(state.copyWith(hardFloorMin: value));

  Future<void> setHardMultiplier(double value) =>
      _update(state.copyWith(hardMultiplier: value));

  Future<void> setMediumFirstMin(double value) =>
      _update(state.copyWith(mediumFirstMin: value));

  Future<void> setMediumMultiplier(double value) =>
      _update(state.copyWith(mediumMultiplier: value));

  Future<void> setEasyFirstMin(double value) =>
      _update(state.copyWith(easyFirstMin: value));

  Future<void> setEasyMultiplier(double value) =>
      _update(state.copyWith(easyMultiplier: value));

  Future<void> setRetentionPercent(double value) => _update(state.copyWith(
        retentionPercent: value.clamp(
          ReviewSettings.minRetentionPercent,
          ReviewSettings.maxRetentionPercent,
        ),
      ));

  Future<void> setCooldownSeconds(int value) =>
      _update(state.copyWith(cooldownSeconds: value));
}

final reviewSettingsProvider =
    StateNotifierProvider<ReviewSettingsNotifier, ReviewSettings>(
  (ref) => ReviewSettingsNotifier(),
);
