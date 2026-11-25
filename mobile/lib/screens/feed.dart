import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../services/api.dart';
import '../services/flixvault.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'channels.dart' show ChannelIcon, ChannelPage;
import 'explore.dart' show MediaThumb, openSearch;
import 'login_sheet.dart';
import 'profile.dart' show ProfileButton;
import 'post.dart';

/// Feed tab: Following (Flixvault channels the user follows) / For You (newest Flixvault videos the server lets them see).
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});
  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  int _tab = 1; // For You first: works for guests too
  final _posts = <Json>[];
  bool _loading = true, _more = true, _error = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _load();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  String? _accessKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Login, ads / organic or Premium changed: the server shows different videos, so load again.
    final key = AppScope.of(context).accessKey;
    final previous = _accessKey;
    _accessKey = key;
    if (previous != null && previous != key) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _accessKey == key) _reload(); });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() { _posts.clear(); _more = true; _error = false; _loading = true; });
    await _load(force: true);
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted || (!force && (_loading || !_more))) return;
    setState(() => _loading = true);
    try {
      final api = AppScope.read(context).api;
      final following = _tab == 0;
      final xs = following ? await api.fvFollowing() : await api.fvExplore(tab: 'latest', offset: _posts.length);
      if (!mounted) return;
      final seen = {for (final p in _posts) p['id']};
      setState(() { _posts.addAll(xs.where((p) => !seen.contains(p['id']))); _more = !following && xs.length >= fvPageSize; });
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final guest = AppScope.of(context).api.isGuest;
    Widget body;
    if (_error && _posts.isEmpty) {
      body = ErrorRetry(onRetry: _reload);
    } else if (_loading && _posts.isEmpty) {
      body = const SkeletonList(count: 3);
    } else if (_posts.isEmpty) {
      body = _tab == 0
          ? EmptyState(icon: Icons.dynamic_feed_outlined, title: guest ? 'Log in to follow channels' : 'Your feed is empty',
              message: 'Join channels in the Channels tab and their new videos show up here.',
              action: guest ? FilledButton(onPressed: () => requireMember(context, reason: 'Log in to follow channels').then((_) => _reload()),
                  child: const Text('Log in')) : null)
          : const EmptyState(icon: Icons.movie_outlined, title: 'No videos here yet', message: 'Check back later.');
    } else {
      body = ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: _posts.length + (_more ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (_, i) => i == _posts.length ? const Skeleton(height: 240) : FeedCard(post: _posts[i], queue: [for (final x in _posts) x['id'] as String]),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Feed'), actions: [
        IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: () => openSearch(context)),
        const ProfileButton(),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: PillTabs(labels: const ['Following', 'For You'], index: _tab, onChanged: (i) { if (i != _tab) { _tab = i; _reload(); } }),
        ),
        Expanded(child: RefreshIndicator(onRefresh: _reload, child: body)),
      ]),
    );
  }
}

/// Social-style post card: channel row, big media, actions.
class FeedCard extends StatelessWidget {
  const FeedCard({super.key, required this.post, this.queue = const []});
  final Json post;
  final List<String> queue;
  @override
  Widget build(BuildContext context) {
    final items = (post['post_items'] as List?) ?? const [];
    final thumb = items.isEmpty ? null : (items.first as Map)['thumbnail_key'] as String?;
    final premium = items.any((e) => (e as Map)['is_premium'] == true);
    final seconds = items.isEmpty ? null : (items.first as Map)['duration_s'] as int?;
    final channel = post['channels'] as Map?;
    final id = post['id'] as String;
    void open() => Navigator.push(context, MaterialPageRoute(builder: (_) => PostScreen(postId: id, queue: queue)));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: channel?['id'] == null ? null
              : () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChannelPage(channelId: channel!['id'] as String))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 10),
            child: Row(children: [
              ClipOval(child: ChannelIcon(keyName: channel?['icon_url'] as String?, size: 38)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(channel?['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ])),
              IconButton(tooltip: 'Open post', icon: const Icon(Icons.more_vert), onPressed: open),
            ]),
          ),
        ),
        InkWell(onTap: open, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ClipRRect(borderRadius: BorderRadius.circular(14),
              child: AspectRatio(aspectRatio: 16 / 9, child: MediaThumb(keyName: thumb, premium: premium, seconds: seconds))),
        )),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
          child: Row(children: [
            Expanded(child: Text(post['title'] as String? ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
            IconButton(tooltip: 'Share', icon: const Icon(Icons.share_outlined),
                onPressed: () => SharePlus.instance.share(ShareParams(text: shareText(post)))),
          ]),
        ),
      ]),
    );
  }
}
