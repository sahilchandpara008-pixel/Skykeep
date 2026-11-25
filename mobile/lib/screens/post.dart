import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../config.dart';
import '../services/api.dart';
import '../services/flixvault.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/pro_player.dart';
import 'channels.dart' show ChannelIcon, ChannelPage, confirmBlock;
import 'explore.dart';
import 'login_sheet.dart';
import 'premium.dart';

const reportReasons = ['Sexual/nude', 'Violence', 'Hate/harassment', 'Copyright', 'Spam/scam', 'Other'];

/// Share text for a video: SkyKeep's website (Flixvault videos have no public page of their own).
String shareText(Json? post) => '${post?['title'] ?? Config.appName} · Watch on ${Config.appName}: ${Config.websiteUrl}';

/// One Flixvault video. Premium users get the full video, free users the preview (the server decides
/// with every play link); organic guests log in first.
class PostScreen extends StatefulWidget {
  const PostScreen({super.key, required this.postId, this.queue = const [], this.autoPlay = false});
  final String postId;

  /// Posts in the order they were listed: powers the player's previous / next buttons.
  final List<String> queue;

  /// Opened with the player's previous / next buttons: keep playing.
  final bool autoPlay;
  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen> {
  Json? _post;
  List<Json> _more = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final api = app.api;
    try {
      _post = await api.fvPost(widget.postId);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loading = false);
    final p = _post;
    if (p == null) return;
    app.measurement.track('ViewContent', {'screen': 'Post'});
    try {
      // "More to watch": newer videos from this channel first, then popular videos from other channels.
      final channelId = p['channel_id'] as String?;
      final same = channelId == null
          ? const <Json>[]
          : ((await api.fvChannelPage(channelId))?.posts ?? const <Json>[]).where((x) => x['id'] != widget.postId).take(6).toList();
      final other = (await api.fvExplore(tab: 'popular'))
          .where((x) => x['channel_id'] != channelId && x['id'] != widget.postId)
          .take(6)
          .toList();
      if (mounted) setState(() => _more = [...same, ...other]);
    } catch (_) {
      /* suggestions never block playback */
    }
  }

  int get _at => widget.queue.indexOf(widget.postId);

  // The next / previous buttons play through the list the post was opened from; when it runs out,
  // "next" continues into the suggested videos so the user can keep watching.
  String? get _nextId {
    if (_at >= 0 && _at < widget.queue.length - 1) return widget.queue[_at + 1];
    return _more.isNotEmpty ? _more.first['id'] as String? : null;
  }

  String? get _prevId => _at > 0 ? widget.queue[_at - 1] : null;

  void _open(String id, List<String> queue) => Navigator.pushReplacement(
    context,
    MaterialPageRoute(
      builder: (_) => PostScreen(postId: id, queue: queue, autoPlay: true),
    ),
  );

  void _next() {
    final id = _nextId;
    if (id == null) return;
    if (_at >= 0 && _at < widget.queue.length - 1) {
      _open(id, widget.queue);
    } else {
      _open(id, [for (final p in _more) p['id'] as String]); // keep playing through the suggestions
    }
  }

  void _previous() {
    final id = _prevId;
    if (id != null) _open(id, widget.queue);
  }

  Future<void> _report() async {
    if (!await requireMember(context, reason: 'Log in to report')) return;
    if (!mounted) return;
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: C.surface,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Why are you reporting this?')),
            for (final r in reportReasons) ListTile(title: Text(r), onTap: () => Navigator.pop(c, r)),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    try {
      await AppScope.read(context).api.fvReport(widget.postId, reason);
      if (mounted) toast(context, 'Thanks — our team will review it.');
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    }
  }

  Future<void> _block() async {
    final ch = _post?['channels'] as Map?;
    final id = _post?['channel_id'] as String?;
    if (ch == null || id == null || !await requireMember(context, reason: 'Log in to block channels')) return;
    if (!mounted) return;
    final ok = await confirmBlock(context, ch['name'] as String? ?? '');
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).api.fvBlock(id);
      if (mounted) {
        toast(context, 'Channel blocked. You can unblock it from Channels.');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _post;
    final items = [...((p?['post_items'] as List?) ?? const [])];
    final ch = p?['channels'] as Map?;
    final channelId = p?['channel_id'] as String?;
    return Scaffold(
      appBar: AppBar(
        title: Text(p?['title'] as String? ?? ''),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share),
            onPressed: p == null ? null : () => SharePlus.instance.share(ShareParams(text: shareText(p))),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            enabled: p != null,
            onSelected: (v) => v == 'report' ? _report() : _block(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'report', child: Text('Report')),
              PopupMenuItem(value: 'block', child: Text('Block channel')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const SkeletonList(count: 3)
          : p == null
          ? const EmptyState(icon: Icons.lock_outline, title: 'This video is not available')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: MediaItem(
                      autoPlay: widget.autoPlay,
                      key: ValueKey(it['id']),
                      item: Json.from(it as Map),
                      title: p['title'] as String?,
                      onNext: _nextId != null ? _next : null,
                      onPrevious: _prevId != null ? _previous : null,
                    ),
                  ),
                if (items.isEmpty) const EmptyState(icon: Icons.hourglass_empty, title: 'No video yet'),
                Text(p['title'] as String? ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                if ((p['description'] as String?)?.trim().isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(p['description'] as String, style: const TextStyle(color: C.muted)),
                  ),
                if (ch != null && channelId != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: ClipOval(child: ChannelIcon(keyName: ch['icon_url'] as String?, size: 38)),
                      title: Text(ch['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChannelPage(channelId: channelId, name: ch['name'] as String?),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (_more.isNotEmpty) _MoreToWatch(posts: _more),
              ],
            ),
    );
  }
}

/// "More to watch": more videos from this channel, then popular videos from other channels.
class _MoreToWatch extends StatelessWidget {
  const _MoreToWatch({required this.posts});
  final List<Json> posts;
  @override
  Widget build(BuildContext context) {
    final queue = [for (final p in posts) p['id'] as String];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('More to watch', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 12),
          SizedBox(
            height: 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: posts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final p = posts[i];
                final its = (p['post_items'] as List?) ?? const [];
                final thumb = its.isEmpty ? null : (its.first as Map)['thumbnail_key'] as String?;
                final premium = its.any((e) => (e as Map)['is_premium'] == true);
                final channel = (p['channels'] as Map?)?['name'] as String?;
                return SizedBox(
                  width: 130,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PostScreen(postId: p['id'] as String, queue: queue),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: AspectRatio(
                              aspectRatio: .72,
                              child: MediaThumb(keyName: thumb, premium: premium),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          p['title'] as String? ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, height: 1.15),
                        ),
                        if (channel != null && channel.isNotEmpty)
                          Text(
                            channel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: C.muted, fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One media item of a Flixvault post. Images show directly; videos play through the flixvault-feed link
/// (full for Premium, the preview otherwise).
class MediaItem extends StatefulWidget {
  const MediaItem({super.key, required this.item, this.title, this.onNext, this.onPrevious, this.autoPlay = false});
  final Json item;
  final String? title;
  final VoidCallback? onNext, onPrevious;
  final bool autoPlay;
  @override
  State<MediaItem> createState() => _MediaItemState();
}

class _MediaItemState extends State<MediaItem> {
  bool? _preview; // null until decided from the user's status
  bool _locked = false, _started = false;
  late bool _play = widget.autoPlay;

  bool get _hasPreview => widget.item['has_preview'] == true;
  bool get _premium => widget.item['is_premium'] == true;

  void _openPlans() => Navigator.push(context, MaterialPageRoute(builder: (_) => const PremiumScreen()));

  Future<String?> _resolve(String itemId, {required bool refresh}) async {
    final app = AppScope.read(context);
    try {
      final url = await app.api.fvPlay(itemId, kind: _preview == true ? 'preview' : 'video');
      if (!_started) {
        _started = true;
        app.measurement.track('VideoStart', {'premium': _premium, 'preview': _preview == true});
      }
      return url;
    } on FlixvaultError catch (e) {
      // The server knows best: Premium ended or not active yet → fall back to the preview.
      if (_preview != true && e.code == 'premium_required' && _hasPreview) {
        if (mounted) setState(() => _preview = true);
        return app.api.fvPlay(itemId, kind: 'preview');
      }
      if (e.code == 'premium_required' && mounted) setState(() => _locked = true);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.status;
    final plans = s.plansVisible && Config.sellsPlans;
    final thumb = widget.item['thumbnail_key'] as String?;
    if ((widget.item['mime'] as String? ?? '').startsWith('image/') || widget.item['kind'] == 'image') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: MediaThumb(keyName: thumb),
        ),
      );
    }
    final access = playbackAccess(
      guest: app.api.isGuest,
      source: s.source,
      canPlayPremium: s.canPlayPremium,
      premium: _premium,
      hasPreview: _hasPreview,
    );
    if (access == PlaybackAccess.login) {
      return _Gate(
        thumb: thumb,
        icon: Icons.login,
        title: 'Log in to watch',
        action: FilledButton(
          onPressed: () => requireMember(context, reason: 'Log in to watch videos'),
          child: const Text('Log in'),
        ),
      );
    }
    if (access == PlaybackAccess.subscribe || _locked) {
      return _Gate(
        thumb: thumb,
        icon: Icons.lock,
        iconColor: C.gold,
        title: 'For Premium members',
        action: plans ? TextButton(onPressed: _openPlans, child: const Text('Get Premium')) : null,
      );
    }
    _preview ??= access == PlaybackAccess.preview;
    final seconds = widget.item['duration_s'] as int?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_play)
          // Tap to play: the short-lived link is only asked for when the user wants to watch.
          Semantics(
            button: true,
            label: 'Play video',
            child: InkWell(
              key: const Key('play-video'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _play = true),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MediaThumb(keyName: thumb, premium: _premium, seconds: seconds),
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: C.navy.withValues(alpha: .6), shape: BoxShape.circle),
                          child: const Icon(Icons.play_arrow_rounded, size: 44, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        else
          ProPlayer(
            autoPlay: true,
            itemId: widget.item['id'] as String,
            storageKey: widget.item['id'] as String,
            title: widget.title,
            trailerOnly: _preview!,
            hls: true,
            resolveUrl: _resolve,
            onNext: widget.onNext,
            onPrevious: widget.onPrevious,
            onUpgrade: plans ? _openPlans : null,
          ),
        if (_preview!)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              plans ? 'Preview · Get Premium to watch the full video' : 'Preview · Full video for Premium members',
              style: const TextStyle(color: C.goldText, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate({required this.thumb, required this.icon, required this.title, this.action, this.iconColor = Colors.white});
  final String? thumb;
  final IconData icon;
  final Color iconColor;
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaThumb(keyName: thumb),
          ColoredBox(
            color: C.navy.withValues(alpha: .72),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: iconColor, size: 34),
                const SizedBox(height: 8),
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                if (action != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: C.gold)),
                      ),
                      child: action!,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
