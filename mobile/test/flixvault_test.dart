import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skykeep/screens/channels.dart';
import 'package:skykeep/screens/feed.dart';
import 'package:skykeep/screens/post.dart';
import 'package:skykeep/screens/welcome.dart';
import 'package:skykeep/services/flixvault.dart';
import 'package:skykeep/services/measurement.dart';
import 'package:skykeep/theme.dart' show PillTabs;
import 'package:skykeep/widgets/pro_player.dart';

import 'fakes.dart';

Map<String, dynamic> _serverPost(String id, {String channel = 'ch1', bool premium = false, bool preview = true}) => {
      'id': id, 'channel_id': channel, 'folder_id': null, 'title': 'Video $id', 'caption': 'About $id',
      'published_at': '2026-11-20T10:00:00Z', 'view_count': 10,
      'channel': {'id': channel, 'name': 'Flix $channel', 'icon_url': 'https://img.example/$channel.jpg'},
      'items': [
        {'id': 'i-$id', 'kind': 'video', 'is_premium': premium, 'thumb_url': 'https://img.example/$id.jpg', 'duration_s': 95,
          'position': 0, 'playable': true, 'has_preview': preview},
      ],
    };

Future<void> _play(WidgetTester t) async {
  await t.tap(find.byKey(const Key('play-video')));
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('server JSON becomes the rows the screens use', () {
    final row = fvPostRow(_serverPost('p1', premium: true));
    expect(row['description'], 'About p1');
    expect((row['channels'] as Map)['name'], 'Flix ch1');
    final item = (row['post_items'] as List).single as Map;
    expect(item['thumbnail_key'], 'https://img.example/p1.jpg');
    expect(item['is_premium'], true);
    expect(item['has_preview'], true);
    expect(item['mime'], 'video/mp4');

    final page = fvChannelPageOf({
      'channel': {'id': 'ch1', 'name': 'Flix', 'members_count': 1200, 'rating': 4.5},
      'posts': [_serverPost('p1')],
      'folders': [{'id': 'f2', 'name': 'Season 2', 'position': 2}, {'id': 'f1', 'name': 'Season 1', 'position': 1}],
    });
    expect(page.channel['members_count'], 1200);
    expect(page.posts.single['id'], 'p1');
    expect([for (final f in page.folders) f['name']], ['Season 1', 'Season 2']);
    expect(fvImage('https://x/y.jpg'), 'https://x/y.jpg');
    expect(fvImage('user/key.jpg'), isNull);
  });

  test('playback access: organic guests log in, Premium plays full, free gets the preview', () {
    PlaybackAccess a({bool guest = false, String source = 'organic', bool can = false, bool premium = true, bool preview = true}) =>
        playbackAccess(guest: guest, source: source, canPlayPremium: can, premium: premium, hasPreview: preview);
    expect(a(guest: true), PlaybackAccess.login);
    expect(a(guest: true, source: 'ads', premium: false), PlaybackAccess.full);
    expect(a(can: true), PlaybackAccess.full);
    expect(a(premium: false), PlaybackAccess.full);
    expect(a(), PlaybackAccess.preview);
    expect(a(preview: false), PlaybackAccess.subscribe);
  });

  testWidgets('free user: premium video plays the preview from flixvault-feed', (t) async {
    final api = FakeApi(status: statusJson())..postValue = fvPostRow(_serverPost('p1', premium: true));
    await pumpApp(t, api, const PostScreen(postId: 'p1'));
    expect(api.played, isEmpty); // nothing is asked for until the user taps play
    await _play(t);
    expect(find.byType(ProPlayer), findsOneWidget);
    expect(api.played, [['i-p1', 'preview']]);
    expect(find.textContaining('Preview'), findsOneWidget);
    expect(find.text('About p1'), findsOneWidget);
  });

  testWidgets('Premium user: full video', (t) async {
    final api = FakeApi(status: statusJson(premium: true, hasPlan: true))..postValue = fvPostRow(_serverPost('p1', premium: true));
    await pumpApp(t, api, const PostScreen(postId: 'p1'));
    await _play(t);
    expect(api.played, [['i-p1', 'video']]);
    expect(find.textContaining('Preview'), findsNothing);
  });

  testWidgets('server says premium_required: falls back to the preview', (t) async {
    final api = FakeApi(status: statusJson(premium: true, hasPlan: true))
      ..postValue = fvPostRow(_serverPost('p1', premium: true))
      ..playError = 'premium_required';
    await pumpApp(t, api, const PostScreen(postId: 'p1'));
    await _play(t);
    expect(api.played, [['i-p1', 'video'], ['i-p1', 'preview']]);
    expect(find.textContaining('Preview'), findsOneWidget);
  });

  testWidgets('organic guest must log in before anything plays', (t) async {
    final api = FakeApi(guest: true, status: statusJson(guest: true, source: 'organic'))..postValue = fvPostRow(_serverPost('p1'));
    await pumpApp(t, api, const PostScreen(postId: 'p1'));
    expect(find.text('Log in to watch'), findsOneWidget);
    expect(api.played, isEmpty);
  });

  testWidgets('report and block a channel from a video', (t) async {
    final api = FakeApi(status: statusJson())..postValue = fvPostRow(_serverPost('p1'));
    await pumpApp(t, api, const PostScreen(postId: 'p1'));
    await t.tap(find.byTooltip('More'));
    await t.pumpAndSettle();
    await t.tap(find.text('Report'));
    await t.pumpAndSettle();
    await t.tap(find.text('Spam/scam'));
    await t.pumpAndSettle();
    expect(api.reports, [['p1', 'Spam/scam']]);
    await t.tap(find.byTooltip('More'));
    await t.pumpAndSettle();
    await t.tap(find.text('Block channel'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Block'));
    await t.pumpAndSettle();
    expect(api.blocked, {'ch1'});
  });

  testWidgets('channels: join, Joined tab, blocked list with unblock', (t) async {
    final api = FakeApi(channelsList: const [
      {'id': 'c1', 'name': 'Flix Movies', 'members_count': 1200, 'category': 'Movies'},
      {'id': 'c2', 'name': 'Flix Shorts', 'members_count': 30, 'category': null},
    ])..blocked.add('c9');
    await pumpApp(t, api, const ChannelsScreen());
    await t.tap(find.widgetWithText(FilledButton, 'Join').first);
    await t.pumpAndSettle();
    expect(api.followed, {'c1'});
    await t.tap(find.descendant(of: find.byType(PillTabs), matching: find.text('Joined')));
    await t.pumpAndSettle();
    expect(find.text('Flix Movies'), findsOneWidget);
    expect(find.text('Flix Shorts'), findsNothing);
    await t.tap(find.byTooltip('More'));
    await t.pumpAndSettle();
    expect(find.text('Top rated'), findsOneWidget);
    await t.tap(find.text('Blocked channels'));
    await t.pumpAndSettle();
    expect(find.text('Blocked c9'), findsOneWidget);
    await t.tap(find.text('Unblock'));
    await t.pumpAndSettle();
    expect(api.blocked, isEmpty);
  });

  testWidgets('channel page: folders filter the videos', (t) async {
    final p1 = fvPostRow({..._serverPost('p1'), 'folder_id': 'f1'});
    final p2 = fvPostRow(_serverPost('p2'));
    final api = FakeApi()
      ..channelPageValue = (channel: fvChannelRow({'id': 'ch1', 'name': 'Flix', 'members_count': 5}), posts: [p1, p2],
          folders: [{'id': 'f1', 'name': 'Season 1'}]);
    await pumpApp(t, api, const ChannelPage(channelId: 'ch1'));
    expect(find.text('Video p1'), findsOneWidget);
    expect(find.text('Video p2'), findsOneWidget);
    await t.tap(find.text('Season 1'));
    await t.pumpAndSettle();
    expect(find.text('Video p2'), findsNothing);
    expect(find.text('Video p1'), findsOneWidget);
  });

  testWidgets('feed: Following shows followed Flixvault channels only', (t) async {
    final api = FakeApi(posts: [fvPostRow(_serverPost('p1'))]);
    await pumpApp(t, api, const FeedScreen());
    await t.tap(find.text('Following'));
    await t.pumpAndSettle();
    expect(find.text('Flix ch1'), findsOneWidget);
  });

  testWidgets('first-run consent: both buttons accept the terms; only one allows measurement', (t) async {
    bool? choice;
    await pumpApp(t, FakeApi(), ConsentScreen(onAgree: (v) => choice = v));
    await t.ensureVisible(find.text('Continue without optional sharing'));
    await t.tap(find.text('Continue without optional sharing'));
    expect(choice, false);
    await t.tap(find.text('Agree and continue'));
    expect(choice, true);
  });

  test('measurement choice is stored on the device; inert controller sends nothing', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final m = Measurement(api: FakeApi(), prefs: prefs, enabled: false);
    expect(m.hasChoice, false);
    await m.save(analytics: true, advertising: false);
    expect(m.hasChoice, true);
    expect(m.analytics, true);
    expect(m.advertising, false);
    await m.track('AppOpen');
    expect(prefs.getString('measurement_queue_v1'), isNull);
  });
}
