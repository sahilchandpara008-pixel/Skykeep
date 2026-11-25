import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'flixvault.dart';

typedef Json = Map<String, dynamic>;

/// Thin wrapper over Supabase so screens stay testable (tests subclass this).
class Api {
  Api([this._db]);
  final SupabaseClient? _db;
  SupabaseClient get db => _db ?? Supabase.instance.client;

  // ---------- auth ----------
  User? get user => db.auth.currentUser;
  bool get isGuest => user == null || user!.isAnonymous;
  Stream<AuthState> get authChanges => db.auth.onAuthStateChange;

  /// First open: anonymous sign-in, then record_install once with the APK referrer.
  Future<void> ensureSession(SharedPreferences prefs) async {
    if (db.auth.currentSession == null) await db.auth.signInAnonymously();
    if (prefs.getBool('install_recorded') == true) return;
    final rnd = Random.secure();
    String token(int n) => List.generate(n, (_) => rnd.nextInt(16).toRadixString(16)).join();
    final id = prefs.getString('install_id') ?? token(32);
    final secret = prefs.getString('install_secret') ?? token(48);
    await prefs.setString('install_id', id);
    await prefs.setString('install_secret', secret);
    // Google Play installs: the Play install referrer (a Meta ad install carries utm_source=apps.facebook.com /
    // utm_source=meta; the server classifies it as ads). Sideloaded APKs: the referrer baked into the ads APK.
    final cached = prefs.getString('install_referrer');
    final play = cached != null ? Json.from(jsonDecode(cached) as Map) : await readPlayReferrer();
    await prefs.setString('install_referrer', jsonEncode(play));
    final fromPlay = play['status'] == 'play_ok';
    await db.rpc('record_install', params: {
      'p_install_id': id,
      'p_referrer_status': fromPlay ? 'play_ok' : Config.apkReferrer.isEmpty ? (play['status'] ?? 'none') : 'apk_define',
      'p_raw_referrer': fromPlay ? (play['referrer'] ?? '') : Config.apkReferrer,
      'p_install_secret': secret,
    });
    await prefs.setBool('install_recorded', true);
  }

  static const _referrer = MethodChannel('app/install-referrer');

  /// {status: play_ok | non_play | not_available, referrer, click_ts, install_ts}; never throws.
  Future<Json> readPlayReferrer() async {
    try {
      final r = await _referrer.invokeMapMethod<String, dynamic>('get').timeout(const Duration(seconds: 6));
      return Json.from(r ?? const {'status': 'not_available', 'referrer': ''});
    } catch (_) {
      return {'status': 'not_available', 'referrer': ''};
    }
  }

  /// No session (first open was offline, or guest sign-in failed): try again as a guest.
  Future<void> ensureGuest() async {
    if (db.auth.currentSession == null) await db.auth.signInAnonymously();
  }

  /// Guest → account: keeps the same user id (all guest data stays).
  Future<void> signUp(String email, String password) async {
    if (user != null && user!.isAnonymous) {
      await db.auth.updateUser(UserAttributes(email: email, password: password), emailRedirectTo: Config.authCallback);
    } else {
      await db.auth.signUp(email: email, password: password, emailRedirectTo: Config.authCallback);
    }
  }

  Future<void> signIn(String email, String password) => db.auth.signInWithPassword(email: email, password: password);
  Future<void> resetPassword(String email) => db.auth.resetPasswordForEmail(email, redirectTo: Config.authCallback);
  Future<void> setPassword(String password) => db.auth.updateUser(UserAttributes(password: password));

  Future<void> signOut() async {
    await db.auth.signOut();
    await db.auth.signInAnonymously();
  }

  Future<void> deleteAccount() async {
    await db.functions.invoke('delete-account');
    await db.auth.signOut();
    await db.auth.signInAnonymously();
  }

  Future<bool> hasConsent() async =>
      (await db.from('consents').select('policy_version').eq('user_id', user!.id).limit(1)).isNotEmpty;
  Future<void> giveConsent() =>
      db.from('consents').upsert({'user_id': user!.id, 'policy_version': Config.policyVersion});

  // ---------- status ----------
  Future<Json> myStatus() async => Json.from(await db.rpc('my_status') as Map);
  Future<Json> planOffers() async => Json.from(await db.rpc('plan_offers') as Map);
  Future<List<Json>> activePlans() async =>
      List<Json>.from(await db.from('plans').select('id,name,price_inr,duration_days,duration_hours,perks,badge').eq('active', true).order('position'));
  Future<String> requestFullAccess() async => (await db.rpc('request_full_access')).toString();

  /// Realtime: app_mode / plan_catalog changes → callback.
  RealtimeChannel subscribeMode(void Function() onChange) => db
      .channel('mode')
      .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'app_mode', callback: (_) => onChange())
      .onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'plan_catalog', callback: (_) => onChange())
      .subscribe();
  Future<void> unsubscribe(RealtimeChannel c) => db.removeChannel(c);

  // ---------- payments ----------
  Future<Json> createOrder(String planId) async => Json.from(await db.rpc('create_order', params: {'p_plan_id': planId}) as Map);
  Future<String> reportResult(String orderId, String raw) async {
    final r = Json.from(await db.rpc('report_result', params: {'p_order_id': orderId, 'p_raw': raw}) as Map);
    return r['status'] as String;
  }

  Future<Json?> orderStatus(String orderId) async {
    final r = await db.rpc('order_status', params: {'p_order_id': orderId});
    return r == null ? null : Json.from(r as Map);
  }

  /// Buyer's proof: 12-digit UTR (+ optional screenshot). Server answers {status: review|error|paid…, error?}.
  Future<Json> submitPaymentProof(String reference, String utr, {String? screenshotKey}) async => Json.from(await db.rpc(
      'submit_payment_proof', params: {'p_reference': reference, 'p_utr': utr, 'p_screenshot_key': screenshotKey}) as Map);

  /// Private bucket, path `user-id/reference/file`; only the buyer and the owner can read it.
  Future<String> uploadPaymentProof(String reference, String fileName, List<int> bytes, String mime) async {
    final key = '${user!.id}/$reference/${DateTime.now().millisecondsSinceEpoch}-${fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';
    await db.storage.from('payment-proofs').uploadBinary(key, Uint8ListX.from(bytes), fileOptions: FileOptions(contentType: mime));
    return key;
  }

  Future<Json> claimFreePlan(String planId) async =>
      Json.from(await db.rpc('claim_free_plan', params: {'p_plan_id': planId}) as Map);
  Future<List<Json>> paymentHistory() async => List<Json>.from(await db
      .from('payment_orders')
      .select('id,reference,amount_paise,status,created_at,utr,paid_at,plans(name)')
      .order('created_at', ascending: false)
      .limit(100));
  Future<Json?> latestPendingOrder() async {
    final r = await db.from('payment_orders').select('id,reference,status').inFilter('status', ['pending', 'submitted', 'review'])
        .order('created_at', ascending: false).limit(1);
    return r.isEmpty ? null : Json.from(r.first);
  }

  // ---------- content ----------
  /// Explore › Recent files (members with cloud storage).
  Future<List<Json>> recentFiles({int limit = 3}) async {
    if (user == null || isGuest) return const [];
    return List<Json>.from(await db.from('cloud_files').select('id,name,mime,size_bytes,created_at')
        .order('created_at', ascending: false).limit(limit));
  }

  Future<Json> saveChannel(Json row, {String? id}) async => id == null
      ? Json.from(await db.from('channels').insert(row).select().single())
      : Json.from(await db.from('channels').update(row).eq('id', id).select().single());

  Future<String> uploadIcon(String path, List<int> bytes) async {
    final key = '${user!.id}/${DateTime.now().millisecondsSinceEpoch}-${path.split('/').last}';
    await db.storage.from('channel-icons').uploadBinary(key, Uint8ListX.from(bytes));
    return key;
  }

  final _signed = <String, (String, DateTime)>{};

  /// Signed URL cache with refresh 5 min before expiry.
  Future<String?> signedUrl(String bucket, String? key, {int seconds = 3600, bool download = false}) async {
    if (key == null) return null;
    final ck = '$bucket/$key/$download';
    final hit = _signed[ck];
    if (hit != null && hit.$2.isAfter(DateTime.now().add(const Duration(minutes: 5)))) return hit.$1;
    try {
      final url = await db.storage.from(bucket).createSignedUrl(key, seconds, transform: null);
      final u = download ? '$url&download=' : url;
      _signed[ck] = (u, DateTime.now().add(Duration(seconds: seconds)));
      return u;
    } catch (_) {
      return null;
    }
  }

  void forgetSigned(String bucket, String key) => _signed.removeWhere((k, _) => k.startsWith('$bucket/$key/'));


  /// Creator upload: media → `media/<channel>/...`, optional thumbnail + trailer, then the post and its item.
  /// Images are their own thumbnail unless one is given; for videos the caller passes the thumbnail
  /// (picked by the creator or auto-cut from the video).
  Future<void> uploadPost({required String channelId, required String title, String? description,
      required String fileName, required List<int> bytes, String? mime,
      List<int>? thumbBytes, String? thumbMime, List<int>? trailerBytes, String? trailerName, String? trailerMime,
      bool premium = false, int? durationS}) async {
    String ext(String n) => n.contains('.') ? n.split('.').last : 'bin';
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final key = '$channelId/$stamp.${ext(fileName)}';
    final store = db.storage.from('media');
    await store.uploadBinary(key, Uint8ListX.from(bytes), fileOptions: FileOptions(contentType: mime));
    String? thumbKey = (mime ?? '').startsWith('image/') ? key : null;
    if (thumbBytes != null) {
      thumbKey = '$channelId/$stamp-thumb.${(thumbMime ?? 'image/jpeg').endsWith('png') ? 'png' : 'jpg'}';
      await store.uploadBinary(thumbKey, Uint8ListX.from(thumbBytes), fileOptions: FileOptions(contentType: thumbMime ?? 'image/jpeg'));
    }
    String? trailerKey;
    if (trailerBytes != null) {
      trailerKey = '$channelId/$stamp-trailer.${ext(trailerName ?? 'trailer.mp4')}';
      await store.uploadBinary(trailerKey, Uint8ListX.from(trailerBytes), fileOptions: FileOptions(contentType: trailerMime ?? 'video/mp4'));
    }
    final post = await db.from('posts').insert({'channel_id': channelId, 'title': title, 'description': description, 'status': 'published'}).select('id').single();
    await db.from('post_items').insert({'post_id': post['id'], 'media_key': key, 'thumbnail_key': thumbKey, 'trailer_key': trailerKey,
      'is_premium': premium, 'duration_s': durationS, 'mime': mime, 'size_bytes': bytes.length});
  }

  // ---------- Flixvault (the only videos and channels users see; see services/flixvault.dart) ----------
  Future<Object?> _fvRpc(String fn, [Map<String, dynamic>? params]) async => await db.rpc(fn, params: params);

  /// Channels this user blocked (hidden everywhere).
  Future<Set<String>> fvBlockedIds() async {
    if (user == null) return {};
    return {for (final r in await db.from('flixvault_blocks').select('channel_id')) r['channel_id'] as String};
  }

  /// tab: all | latest | popular | most_watched
  Future<List<Json>> fvExplore({String tab = 'all', int offset = 0, String? search}) async {
    final s = search?.trim() ?? '';
    final r = await Future.wait([
      _fvRpc('fv_explore', {'p_tab': fvExploreTabs.containsKey(tab) ? tab : 'all', 'p_offset': offset, 'p_limit': fvPageSize,
        'p_search': s.isEmpty ? null : s}),
      fvBlockedIds(),
    ]);
    final blocked = r[1] as Set<String>;
    return fvPostRows(r[0]).where((p) => !blocked.contains(p['channel_id'])).toList();
  }

  /// Newest posts from the Flixvault channels this user follows (blocked channels already left out).
  Future<List<Json>> fvFollowing() async {
    if (user == null) return const [];
    return fvPostRows(await _fvRpc('fv_following'));
  }

  /// sort: trending | latest | top
  Future<List<Json>> fvChannels({String sort = 'trending', String? search}) async {
    final s = search?.trim() ?? '';
    final r = await Future.wait([
      _fvRpc('fv_channels', {'p_sort': fvChannelSorts.containsKey(sort) ? sort : 'trending', 'p_search': s.isEmpty ? null : s}),
      fvBlockedIds(),
    ]);
    final blocked = r[1] as Set<String>;
    return [
      for (final c in (r[0] as List? ?? const []))
        if (!blocked.contains((c as Map)['id'])) fvChannelRow(Json.from(c)),
    ];
  }

  /// The channel, 50 posts before [before] and its folders; null when this user may not see it.
  Future<FvChannelPage?> fvChannelPage(String id, {String? before}) async {
    final r = await _fvRpc('fv_channel', {'p_channel_id': id, 'p_before': before});
    return r is Map && r['channel'] is Map ? fvChannelPageOf(Json.from(r)) : null;
  }

  Future<Json?> fvPost(String id) async {
    final r = await _fvRpc('fv_post', {'p_post_id': id});
    return r is Map ? fvPostRow(Json.from(r)) : null;
  }

  /// Short-lived HLS link from the flixvault-feed edge function. kind: video | preview.
  /// Throws [FlixvaultError] (premium_required, not_allowed, login_required, ...).
  Future<String> fvPlay(String itemId, {required String kind}) async {
    final Object? data;
    try {
      data = (await db.functions.invoke('flixvault-feed', body: {'action': 'play', 'item_id': itemId, 'kind': kind})).data;
    } on FunctionException catch (e) {
      final d = e.details;
      throw FlixvaultError(d is Map && d['error'] != null ? d['error'].toString() : 'unavailable');
    }
    if (data is! Map || data['error'] != null || data['url'] is! String) {
      throw FlixvaultError(data is Map && data['error'] != null ? data['error'].toString() : 'unavailable');
    }
    return data['url'] as String;
  }

  Future<Set<String>> fvFollowedIds() async {
    if (user == null) return {};
    return {for (final r in await db.from('flixvault_follows').select('channel_id')) r['channel_id'] as String};
  }

  Future<void> fvSetFollowing(String channelId, bool follow) async {
    if (follow) {
      await db.from('flixvault_follows').upsert({'channel_id': channelId});
    } else {
      await db.from('flixvault_follows').delete().eq('channel_id', channelId);
    }
  }

  Future<void> fvBlock(String channelId) async {
    await db.from('flixvault_blocks').upsert({'channel_id': channelId});
    await db.from('flixvault_follows').delete().eq('channel_id', channelId);
  }

  Future<void> fvUnblock(String channelId) => db.from('flixvault_blocks').delete().eq('channel_id', channelId);

  /// Blocked channels with names, so they can be unblocked.
  Future<List<Json>> fvBlockedChannels() async {
    final ids = (await fvBlockedIds()).toList();
    if (ids.isEmpty) return const [];
    final rows = await db.from('flixvault_channels').select('id,name,icon_url').inFilter('id', ids).order('name');
    final named = {for (final r in rows) r['id'] as String: Json.from(r)};
    return [for (final id in ids) named[id] ?? {'id': id, 'name': 'Channel no longer available', 'icon_url': null}];
  }

  Future<void> fvReport(String postId, String reason) =>
      db.from('flixvault_reports').insert({'post_id': postId, 'reason': reason});

  // ---------- push / measurement (best effort; never block the app) ----------
  Future<void> registerPushToken(String token) => db.rpc('register_push_token', params: {'p_token': token});
  Future<void> pushOpened(String messageId) => db.rpc('push_opened', params: {'p_mid': messageId});
  Future<void> setMeasurementPreferences(bool analytics, bool advertising, Json context) => db.rpc('set_measurement_preferences',
      params: {'p_analytics': analytics, 'p_advertising': advertising, 'p_context': context});
  Future<void> recordActivity(Json params) => db.rpc('record_activity', params: params);

  /// Meta SDK anonymous id + advertising id (only after the user allowed ad measurement; the server checks again).
  Future<void> recordAdIds(String installId, {String? fbAnonId, String? adId}) =>
      db.rpc('record_ad_ids', params: {'p_install_id': installId, 'p_fb_anon_id': fbAnonId, 'p_ad_id': adId});

  // ---------- cloud ----------
  Future<List<Json>> cloudFolders(String? parentId) async {
    var q = db.from('cloud_folders').select();
    q = parentId == null ? q.isFilter('parent_id', null) : q.eq('parent_id', parentId);
    return List<Json>.from(await q.order('name'));
  }

  Future<List<Json>> allFolders() async => List<Json>.from(await db.from('cloud_folders').select('id,name').order('name'));

  Future<List<Json>> cloudFiles(String? folderId) async {
    var q = db.from('cloud_files').select();
    q = folderId == null ? q.isFilter('folder_id', null) : q.eq('folder_id', folderId);
    return List<Json>.from(await q.order('created_at', ascending: false));
  }

  Future<void> createFolder(String name, String? parentId) =>
      db.from('cloud_folders').insert({'name': name, 'parent_id': parentId, 'user_id': user!.id});
  Future<void> deleteFolder(String id) => db.from('cloud_folders').delete().eq('id', id);
  Future<void> renameFile(String id, String name) => db.from('cloud_files').update({'name': name}).eq('id', id);
  Future<void> moveFile(String id, String? folderId) => db.from('cloud_files').update({'folder_id': folderId}).eq('id', id);
  Future<void> deleteFile(String id) => db.functions.invoke('cloud-files', body: {'action': 'delete', 'id': id});
  Future<String?> fileUrl(String id, {bool download = false}) async =>
      (await db.functions.invoke('cloud-files', body: {'action': 'download', 'id': id, 'save': download})).data?['url'] as String?;

  /// Upload with progress. Retries the transfer up to 3 times on network errors.
  /// shortcut: re-sends the whole file on retry (no TUS chunk resume); switch to resumable uploads for >500 MB files.
  Future<void> uploadCloud({required String name, required int size, String? mime, String? folderId,
      required Stream<List<int>> Function() open, required void Function(double) onProgress}) async {
    final res = await db.functions.invoke('cloud-files', body: {'action': 'upload', 'name': name, 'size': size, 'mime': mime, 'folder_id': folderId});
    final data = Json.from(res.data as Map);
    if (data['error'] != null) throw Exception(data['error']);
    final url = Uri.parse(data['upload_url'] as String);
    for (var attempt = 1;; attempt++) {
      try {
        final req = http.StreamedRequest('PUT', url)
          ..headers['Content-Type'] = mime ?? 'application/octet-stream'
          ..contentLength = size;
        var sent = 0;
        final done = req.send();
        await for (final chunk in open()) {
          req.sink.add(chunk);
          sent += chunk.length;
          onProgress(size == 0 ? 1 : sent / size);
        }
        unawaited(req.sink.close());
        final r = await done;
        if (r.statusCode >= 300) throw http.ClientException('upload failed ${r.statusCode}: ${await r.stream.bytesToString()}');
        return;
      } on http.ClientException {
        if (attempt >= 3) {
          await deleteFile(Json.from(data['file'] as Map)['id'] as String);
          rethrow;
        }
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
  }

  // ---------- play ----------
  Future<String> playChallenge() async => (await db.rpc('play_integrity_challenge')).toString();
  Future<bool> playVerify(String token, String nonce) async =>
      jsonDecode(jsonEncode((await db.functions.invoke('play-verify', body: {'token': token, 'nonce': nonce})).data))['verified'] == true;
}

extension Uint8ListX on List<int> {
  static Uint8List from(List<int> b) => b is Uint8List ? b : Uint8List.fromList(b);
}
