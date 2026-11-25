import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../version.dart';
import 'api.dart';

/// Native side (Android, MainActivity "app/meta"): the Meta SDK and the advertising ID.
/// Nothing native starts before the user allowed ad measurement.
class MetaBridge {
  const MetaBridge();
  static const _ch = MethodChannel('app/meta');

  /// Starts the Meta SDK (with the public app id + client token) and returns
  /// {anon_id, ad_id}. ad_id is null when the user turned ad personalisation off.
  Future<Map<String, dynamic>> enable({required String appId, required String clientToken}) async =>
      await _ch.invokeMapMethod<String, dynamic>('enable', {'app_id': appId, 'client_token': clientToken}) ?? const {};

  /// Stops advertiser-id collection in the Meta SDK.
  Future<void> disable() => _ch.invokeMethod<void>('disable');

  /// {os, model, cores} for Meta's app-event device info.
  Future<Map<String, dynamic>> context() async => await _ch.invokeMapMethod<String, dynamic>('context') ?? const {};
}

/// Optional measurement, only with the user's choice (first-run consent, Profile › Settings › Measurement preferences):
/// * app analytics: app activity events (record_activity);
/// * advertising measurement with Meta: the same events are sent to Meta by the server, plus the Meta SDK's
///   anonymous id and the advertising ID (record_ad_ids) so Meta can match them to the ad click.
/// Everything is best effort and never blocks the app, playback or payments.
class Measurement extends ChangeNotifier {
  Measurement({required this.api, required this.prefs, this.meta = const MetaBridge(), this.enabled = true});

  final Api api;
  final SharedPreferences prefs;
  final MetaBridge meta;

  /// False in tests: nothing is queued or sent.
  final bool enabled;

  static const choiceKey = 'measurement_choice_v1';
  static const _queueKey = 'measurement_queue_v1';
  static const events = {
    'AppOpen', 'ScreenView', 'Login', 'ViewContent', 'VideoStart', 'VideoProgress', 'PreviewComplete', 'SearchUsed',
    'ChannelJoined', 'CloudUploaded', 'CloudDeleted', 'PlanViewed', 'SubscriptionPrompt',
  };

  bool analytics = false, advertising = false;
  bool get hasChoice => prefs.containsKey(choiceKey);
  String? _syncedFor;
  bool _flushing = false;
  String _session = _uuid();
  DateTime _lastActive = DateTime.now();

  void _readChoice() {
    try {
      final v = jsonDecode(prefs.getString(choiceKey) ?? '{}') as Map;
      analytics = v['analytics'] == true;
      advertising = v['advertising'] == true;
    } catch (_) {
      analytics = advertising = false;
    }
  }

  /// App start and after every status refresh: (re)sends the choice when the signed-in user changed.
  Future<void> sync(String? userId) async {
    if (!enabled || userId == null || !hasChoice || _syncedFor == userId) return;
    _syncedFor = userId;
    _readChoice();
    try {
      await _push();
      await track('AppOpen');
    } catch (_) {
      _syncedFor = null; // try again on the next refresh
    }
  }

  /// Saves the user's choice on this device, then on the server.
  Future<void> save({required bool analytics, required bool advertising}) async {
    await prefs.setString(choiceKey, jsonEncode({'analytics': analytics, 'advertising': advertising}));
    this.analytics = analytics;
    this.advertising = advertising;
    if (!analytics && !advertising) await prefs.remove(_queueKey);
    notifyListeners();
    if (!enabled) return;
    try {
      await _push();
      _syncedFor = api.user?.id;
    } catch (e) {
      _syncedFor = null; // kept on the device; sent again on the next refresh
      debugPrint('measurement preferences not saved yet: $e');
    }
    if (analytics || advertising) unawaited(track('AppOpen'));
  }

  Future<void> _push() async {
    await api.setMeasurementPreferences(analytics, advertising, await _context());
    await _adIds();
  }

  /// Meta SDK + advertising ID: only after the user allowed ad measurement, and only when the build has a Meta app id.
  Future<void> _adIds() async {
    if (!advertising || Config.metaAppId.isEmpty || Config.metaClientToken.isEmpty) {
      try { await meta.disable(); } catch (_) {}
      return;
    }
    final installId = prefs.getString('install_id');
    if (installId == null) return;
    try {
      final ids = await meta.enable(appId: Config.metaAppId, clientToken: Config.metaClientToken);
      await api.recordAdIds(installId, fbAnonId: ids['anon_id'] as String?, adId: ids['ad_id'] as String?);
    } catch (e) {
      debugPrint('meta ids: $e');
    }
  }

  /// Device context Meta needs for app events (only with ad measurement allowed).
  Future<Json> _context() async {
    if (!advertising) return {};
    final id = prefs.getString('install_id');
    if (id == null) return {};
    var native = <String, dynamic>{};
    try {
      native = await meta.context();
    } catch (_) {}
    final nativeOs = (native['os'] as String?)?.trim() ?? '';
    final os = nativeOs.isNotEmpty ? nativeOs : (kIsWeb ? '' : Platform.operatingSystemVersion.trim());
    final view = PlatformDispatcher.instance.views.first;
    final extinfo = [
      'a2', Config.androidAppId, appVersion.split('+').last, appVersion.split('+').first, os, '${native['model'] ?? ''}',
      PlatformDispatcher.instance.locale.toLanguageTag(), DateTime.now().timeZoneName, '',
      view.physicalSize.width.round().toString(), view.physicalSize.height.round().toString(), view.devicePixelRatio.toString(),
      '${native['cores'] ?? ''}', '', '', '',
    ].map((v) => v.length > 120 ? v.substring(0, 120) : v).toList();
    return {'install_id': id, 'extinfo': extinfo};
  }

  /// App came back: a new session after 30 minutes away.
  void resumed() {
    if (DateTime.now().difference(_lastActive) > const Duration(minutes: 30)) _session = _uuid();
    _lastActive = DateTime.now();
    unawaited(track('AppOpen'));
  }

  Future<void> track(String name, [Map<String, dynamic> properties = const {}]) async {
    if (!enabled || !hasChoice || (!analytics && !advertising) || !events.contains(name)) return;
    final rows = _read()..add({
      'uid': api.user?.id, 'p_event_id': _uuid(), 'p_name': name, 'p_session_id': _session, 'p_properties': properties,
      'p_occurred_at': DateTime.now().toUtc().toIso8601String(),
    });
    if (rows.length > 200) rows.removeRange(0, rows.length - 200);
    await prefs.setString(_queueKey, jsonEncode(rows));
    unawaited(flush());
  }

  List<Json> _read() {
    try {
      final day = DateTime.now().subtract(const Duration(days: 1));
      return [
        for (final x in jsonDecode(prefs.getString(_queueKey) ?? '[]') as List)
          if (DateTime.tryParse((x as Map)['p_occurred_at'] as String? ?? '')?.isAfter(day) ?? false) Json.from(x),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> flush() async {
    if (!enabled || _flushing || (!analytics && !advertising)) return;
    _flushing = true;
    try {
      for (var i = 0; i < 200; i++) {
        final rows = _read();
        if (rows.isEmpty) break;
        final row = rows.first;
        if (row['uid'] == api.user?.id) await api.recordActivity(Map.of(row)..remove('uid'));
        await prefs.setString(_queueKey, jsonEncode(_read()..removeWhere((x) => x['p_event_id'] == row['p_event_id'])));
      }
    } catch (_) {/* offline: retried on the next event */} finally {
      _flushing = false;
    }
  }
}

String _uuid() {
  final r = List<int>.generate(16, (_) => _rnd.nextInt(256));
  r[6] = (r[6] & 0x0f) | 0x40;
  r[8] = (r[8] & 0x3f) | 0x80;
  final h = r.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

final _rnd = Random.secure();
