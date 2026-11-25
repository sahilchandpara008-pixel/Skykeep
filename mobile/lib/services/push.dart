import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../screens/channels.dart' show ChannelPage;
import '../screens/post.dart' show PostScreen;
import '../screens/premium.dart' show PremiumScreen;
import 'api.dart';

/// Push notifications (Firebase Cloud Messaging, SkyKeep's own Firebase project), Android only.
/// * Registers this phone's token with SkyKeep's server (register_push_token), again when the token or the
///   signed-in account changes. Who gets a message is decided on the server (everyone / ads / organic / Premium …).
/// * A tapped message opens what it points to: a video, a channel, Premium or an https link (push_opened counts it).
/// * Firebase options come from Config (like Puffle; no google-services.json). Without an app id
///   for this package (the Play build for now), push is off. It never blocks or breaks the app.
class Push {
  static final navigatorKey = GlobalKey<NavigatorState>();
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();
  static Api? _api;
  static bool _ready = false, _tried = false, _listening = false;

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static Future<bool> _init() async {
    if (!_supported || _api == null) return false;
    if (_ready || _tried) return _ready;
    _tried = true;
    try {
      if (Config.firebaseAppId.isEmpty) return false; // e.g. the Play build until its Firebase app exists
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: const FirebaseOptions(
          apiKey: Config.firebaseApiKey,
          appId: Config.firebaseAppId,
          messagingSenderId: Config.firebaseSenderId,
          projectId: Config.firebaseProjectId,
          storageBucket: Config.firebaseStorageBucket,
        ));
      }
      _ready = true;
    } catch (e) {
      debugPrint('push off: $e');
    }
    return _ready;
  }

  /// App start: remembers the API and opens the message that launched the app, if any.
  static Future<void> start(Api api) async {
    _api = api;
    if (!await _init()) return;
    try {
      final msg = await FirebaseMessaging.instance.getInitialMessage();
      if (msg != null) _open(msg.data);
    } catch (_) {}
    await register();
  }

  /// After the first-run consent, at start and after login: sends the token when it (or the account) changed.
  static Future<void> register() async {
    if (!await _init()) return;
    try {
      final m = FirebaseMessaging.instance;
      if (!_listening) {
        _listening = true;
        // The FCM registration token is what the server's push-send uses (HTTP v1 "token" target).
        // ignore: deprecated_member_use
        m.onTokenRefresh.listen((t) => _send(t, force: true));
        FirebaseMessaging.onMessageOpenedApp.listen((msg) => _open(msg.data));
        FirebaseMessaging.onMessage.listen(_foreground);
      }
      // ignore: deprecated_member_use
      final token = await m.getToken();
      if (token != null) await _send(token);
    } catch (_) {/* tried again next start */}
  }

  static Future<void> _send(String token, {bool force = false}) async {
    final api = _api;
    final uid = api?.user?.id;
    if (api == null || uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$token|$uid';
      if (!force && prefs.getString('push_token_sent') == key) return;
      await api.registerPushToken(token);
      await prefs.setString('push_token_sent', key);
    } catch (_) {}
  }

  // While the app is open Android shows nothing by itself: show a bar instead.
  static void _foreground(RemoteMessage msg) {
    final n = msg.notification;
    final title = n?.title ?? '';
    if (title.isEmpty) return;
    messengerKey.currentState?.showSnackBar(SnackBar(
      content: Text(n?.body?.isNotEmpty == true ? '$title\n${n!.body}' : title, maxLines: 3, overflow: TextOverflow.ellipsis),
      duration: const Duration(seconds: 6),
      action: ['post', 'channel', 'premium', 'url'].contains(msg.data['type'])
          ? SnackBarAction(label: 'Open', onPressed: () => _open(msg.data))
          : null,
    ));
  }

  static void _open(Map<String, dynamic> d) {
    final mid = d['mid'] as String?;
    if (mid != null && _api?.user != null) unawaited(_api!.pushOpened(mid).then((_) {}, onError: (Object _) {}));
    final nav = navigatorKey.currentState;
    final id = (d['id'] as String?) ?? '';
    switch (d['type']) {
      case 'post' when id.isNotEmpty:
        nav?.push(MaterialPageRoute(builder: (_) => PostScreen(postId: id)));
      case 'channel' when id.isNotEmpty:
        nav?.push(MaterialPageRoute(builder: (_) => ChannelPage(channelId: id)));
      case 'premium':
        nav?.push(MaterialPageRoute(builder: (_) => const PremiumScreen()));
      case 'url':
        final uri = Uri.tryParse((d['url'] as String?) ?? '');
        if (uri != null && uri.scheme == 'https') {
          unawaited(launchUrl(uri, mode: LaunchMode.externalApplication).then((_) {}, onError: (Object _) {}));
        }
    }
  }
}
