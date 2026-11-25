import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../config.dart';
import '../services/api.dart';
import '../services/flixvault.dart';
import '../services/status.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'explore.dart';
import 'home.dart' show HomeShellState;
import 'login_sheet.dart';
import 'profile.dart' show ProfileButton;
import 'premium.dart';

/// Channels tab: Flixvault channels only (Discover / Joined), sort, search and the blocked-channels list.
/// Following, blocking and reporting are SkyKeep's own data (flixvault_follows / flixvault_blocks / flixvault_reports).
class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key, this.joinedOnly = false});

  /// Opened from Profile › My channels: only joined channels, with a back button.
  final bool joinedOnly;
  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  late int _tab = widget.joinedOnly ? 1 : 0; // Discover | Joined
  String _sort = 'trending';
  List<Json> _rows = const [];
  Set<String> _joined = {};
  bool _loading = true, _error = false;
  int _gen = 0;
  String? _accessKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Ads / organic or login changed: the server shows different channels, so load again.
    final key = AppScope.of(context).accessKey;
    final previous = _accessKey;
    _accessKey = key;
    if (previous == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    } else if (previous != key) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _accessKey == key) _load(); });
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final gen = ++_gen;
    final api = AppScope.read(context).api;
    try {
      final r = await Future.wait([api.fvChannels(sort: _sort), api.fvFollowedIds()]);
      if (!mounted || gen != _gen) return;
      setState(() { _rows = r[0] as List<Json>; _joined = r[1] as Set<String>; _error = false; _loading = false; });
    } catch (_) {
      if (mounted && gen == _gen) setState(() { _error = true; _loading = false; });
    }
  }

  Future<void> _showBlocked() async {
    final changed = await openBlockedChannels(context);
    if (changed && mounted) await _load();
  }

  Future<void> _search() async {
    final picked = await showSearch<Json?>(context: context,
        delegate: ChannelSearch(rows: _rows, joined: _joined, onlyJoined: _tab == 1));
    if (picked == null || !mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ChannelPage(channelId: picked['id'] as String, name: picked['name'] as String?)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _tab == 1 ? _rows.where((r) => _joined.contains(r['id'])).toList() : _rows;
    Widget body;
    if (_loading) {
      body = const SkeletonList();
    } else if (_error && _rows.isEmpty) {
      body = ErrorRetry(onRetry: _load);
    } else if (rows.isEmpty) {
      body = EmptyState(icon: Icons.groups_outlined,
          title: _tab == 1 ? 'You have not joined any channels' : 'No channels yet',
          message: _tab == 1 ? 'Channels you join show up here.' : 'Check back soon.',
          action: _tab == 1 && !widget.joinedOnly ? OutlinedButton(onPressed: () => setState(() => _tab = 0), child: const Text('Discover channels')) : null);
    } else {
      body = ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: rows.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => ChannelTile(channel: rows[i], joined: _joined.contains(rows[i]['id']), onChanged: _load),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.joinedOnly ? 'My channels' : 'Channels'),
        actions: [
          IconButton(tooltip: 'Search channels', icon: const Icon(Icons.search), onPressed: _loading ? null : _search),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) async {
              if (v == 'blocked') {
                await _showBlocked();
              } else {
                setState(() { _sort = v; _loading = true; });
                await _load();
              }
            },
            itemBuilder: (_) => [
              for (final e in fvChannelSorts.entries) CheckedPopupMenuItem(value: e.key, checked: _sort == e.key, child: Text(e.value)),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'blocked', child: Text('Blocked channels')),
            ],
          ),
          if (!widget.joinedOnly) const ProfileButton(),
        ],
      ),
      body: Column(children: [
        if (!widget.joinedOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: PillTabs(labels: const ['Discover', 'Joined'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
          ),
        Expanded(child: RefreshIndicator(onRefresh: _load, child: body)),
      ]),
    );
  }
}

/// Search the loaded channels by name (only joined ones from the Joined tab).
class ChannelSearch extends SearchDelegate<Json?> {
  ChannelSearch({required List<Json> rows, required Set<String> joined, this.onlyJoined = false})
      : _rows = onlyJoined ? rows.where((r) => joined.contains(r['id'])).toList() : rows,
        super(searchFieldLabel: onlyJoined ? 'Search joined channels' : 'Search channels');
  final bool onlyJoined;
  final List<Json> _rows;

  @override
  List<Widget> buildActions(BuildContext context) =>
      [if (query.isNotEmpty) IconButton(tooltip: 'Clear', icon: const Icon(Icons.clear), onPressed: () => query = '')];
  @override
  Widget buildLeading(BuildContext context) => BackButton(onPressed: () => close(context, null));
  @override
  Widget buildResults(BuildContext context) => _results(context);
  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    final term = query.trim().toLowerCase();
    final matches = _rows.where((r) => (r['name'] as String? ?? '').toLowerCase().contains(term)).toList();
    if (matches.isEmpty) {
      return EmptyState(icon: Icons.search_off, title: onlyJoined && _rows.isEmpty ? 'Join a channel to find it here' : 'No matching channels');
    }
    return ListView.builder(itemCount: matches.length, itemBuilder: (_, i) {
      final r = matches[i];
      return ListTile(
        leading: ClipOval(child: ChannelIcon(keyName: r['icon_url'] as String?, size: 40)),
        title: Text(r['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => close(context, r),
      );
    });
  }
}

/// Blocked channels with Unblock buttons. Returns true when something changed.
Future<bool> openBlockedChannels(BuildContext context) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: C.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => const BlockedChannelsSheet(),
  );
  return changed == true;
}

class BlockedChannelsSheet extends StatefulWidget {
  const BlockedChannelsSheet({super.key});
  @override
  State<BlockedChannelsSheet> createState() => _BlockedChannelsSheetState();
}

class _BlockedChannelsSheetState extends State<BlockedChannelsSheet> {
  Future<List<Json>>? _rows;
  bool _changed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rows ??= AppScope.read(context).api.fvBlockedChannels();
  }

  Future<void> _unblock(String id) async {
    final api = AppScope.read(context).api;
    try {
      await api.fvUnblock(id);
      _changed = true;
      if (mounted) setState(() => _rows = api.fvBlockedChannels());
    } catch (_) {
      if (mounted) toast(context, 'Could not unblock. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) { if (!didPop) Navigator.pop(context, _changed); },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(4)))),
            const SizedBox(height: 12),
            const Text('Blocked channels', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            FutureBuilder<List<Json>>(
              future: _rows,
              builder: (_, s) {
                if (s.connectionState != ConnectionState.done) {
                  return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
                }
                final rows = s.data ?? const [];
                if (rows.isEmpty) {
                  return const Padding(padding: EdgeInsets.all(24),
                      child: Text('You have not blocked any channels.', textAlign: TextAlign.center, style: TextStyle(color: C.muted)));
                }
                return ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .6),
                  child: ListView(shrinkWrap: true, children: [
                    for (final r in rows)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: ClipOval(child: ChannelIcon(keyName: r['icon_url'] as String?, size: 40)),
                        title: Text(r['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: OutlinedButton(onPressed: () => _unblock(r['id'] as String), child: const Text('Unblock')),
                      ),
                  ]),
                );
              },
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => Navigator.pop(context, _changed), child: const Text('Done')),
          ]),
        ),
      );
}

class ChannelIcon extends StatelessWidget {
  const ChannelIcon({super.key, required this.keyName, this.size = 48});
  /// A Flixvault image URL (https) or a key in the `channel-icons` bucket.
  final String? keyName;
  final double size;
  @override
  Widget build(BuildContext context) {
    final direct = fvImage(keyName);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 4),
      child: SizedBox(width: size, height: size, child: Container(
        color: C.surface2,
        child: keyName == null ? const Icon(Icons.tag, color: C.muted)
            : direct != null ? Image.network(direct, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.tag, color: C.muted))
            : FutureBuilder<String?>(
                future: AppScope.read(context).api.signedUrl('channel-icons', keyName),
                builder: (_, s) => s.data == null ? const SizedBox() : Image.network(s.data!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
              ),
      )),
    );
  }
}

/// Follow / unfollow a Flixvault channel (members only). Returns the new state, or null when nothing changed.
Future<bool?> toggleFollow(BuildContext context, String channelId, bool following) async {
  if (!await requireMember(context, reason: 'Log in to join channels')) return null;
  if (!context.mounted) return null;
  final app = AppScope.read(context);
  try {
    await app.api.fvSetFollowing(channelId, !following);
    if (!following) app.measurement.track('ChannelJoined');
    return !following;
  } catch (_) {
    if (context.mounted) toast(context, 'Could not update. Please try again.');
    return null;
  }
}

class ChannelTile extends StatefulWidget {
  const ChannelTile({super.key, required this.channel, this.onChanged, this.joined});
  final Json channel;
  final VoidCallback? onChanged;
  /// null = no Join button
  final bool? joined;
  @override
  State<ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<ChannelTile> {
  late bool? _joined = widget.joined;
  bool _busy = false;

  @override
  void didUpdateWidget(ChannelTile old) {
    super.didUpdateWidget(old);
    if (old.joined != widget.joined) _joined = widget.joined;
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    final now = await toggleFollow(context, widget.channel['id'] as String, _joined ?? false);
    if (!mounted) return;
    setState(() { _busy = false; if (now != null) _joined = now; });
    if (now != null) widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final category = channel['category'] as String?;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => ChannelPage(channelId: channel['id'] as String, name: channel['name'] as String?)));
          widget.onChanged?.call();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            ClipOval(child: ChannelIcon(keyName: channel['icon_url'] as String?, size: 48)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(channel['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 2),
              Text('${compactCount(channel['members_count'] as num? ?? 0)} members${category == null || category.isEmpty ? '' : ' · $category'}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: C.muted)),
            ])),
            if (_joined != null) ...[
              const SizedBox(width: 8),
              _joined!
                  ? OutlinedButton(onPressed: _busy ? null : _toggle,
                      style: OutlinedButton.styleFrom(minimumSize: const Size(80, 40)), child: const Text('Joined'))
                  : FilledButton(onPressed: _busy ? null : _toggle,
                      style: FilledButton.styleFrom(minimumSize: const Size(80, 40), backgroundColor: C.primarySoft, foregroundColor: C.primary),
                      child: const Text('Join')),
            ],
          ]),
        ),
      ),
    );
  }
}

/// One Flixvault channel: details, join / leave, block, folders and its videos (50 at a time).
class ChannelPage extends StatefulWidget {
  const ChannelPage({super.key, required this.channelId, this.name});
  final String channelId;
  final String? name;
  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends State<ChannelPage> {
  Json? _ch;
  final _posts = <Json>[];
  List<Json> _folders = const [];
  String? _folder;
  bool _member = false, _loading = true, _busy = false, _more = false, _fetching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final api = AppScope.read(context).api;
    try {
      final r = await Future.wait<Object?>([api.fvChannelPage(widget.channelId), api.fvFollowedIds()]);
      final page = r[0] as FvChannelPage?;
      _ch = page?.channel;
      _folders = page?.folders ?? const [];
      _posts..clear()..addAll(page?.posts ?? const []);
      _more = (page?.posts.length ?? 0) >= fvChannelPageSize;
      _member = (r[1] as Set<String>).contains(widget.channelId);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMore() async {
    if (_fetching || !_more || _posts.isEmpty) return;
    _fetching = true;
    try {
      final page = await AppScope.read(context).api.fvChannelPage(widget.channelId, before: _posts.last['published_at'] as String?);
      final xs = page?.posts ?? const <Json>[];
      if (mounted) setState(() { _posts.addAll(xs); _more = xs.length >= fvChannelPageSize; });
    } catch (_) {
      if (mounted) setState(() => _more = false);
    }
    _fetching = false;
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    final now = await toggleFollow(context, widget.channelId, _member);
    if (mounted) setState(() { _busy = false; if (now != null) _member = now; });
  }

  Future<void> _block() async {
    final ch = _ch;
    if (ch == null || !await requireMember(context, reason: 'Log in to block channels')) return;
    if (!mounted) return;
    final ok = await confirmBlock(context, ch['name'] as String? ?? '');
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).api.fvBlock(widget.channelId);
      if (mounted) { toast(context, 'Channel blocked. You can unblock it from Channels.'); Navigator.pop(context); }
    } catch (_) {
      if (mounted) toast(context, 'Could not block this channel. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final ch = _ch;
    final posts = _folder == null ? _posts : _posts.where((p) => p['folder_id'] == _folder).toList();
    final queue = [for (final x in posts) x['id'] as String];
    return Scaffold(
      appBar: AppBar(title: Text(ch?['name'] as String? ?? widget.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis), actions: [
        if (app.status.plansVisible && Config.sellsPlans)
          IconButton(tooltip: 'Premium', icon: const Icon(Icons.workspace_premium, color: C.gold),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PremiumScreen()))),
        if (ch != null)
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (_) => _block(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'block', child: Text('Block channel'))],
          ),
      ]),
      body: _loading
          ? const SkeletonList(count: 4)
          : ch == null
              ? const EmptyState(icon: Icons.lock_outline, title: 'Channel not available', message: 'It may have been removed.')
              : RefreshIndicator(
                  onRefresh: _load,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _loadMore();
                      return false;
                    },
                    child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
                      Row(children: [
                        ChannelIcon(keyName: ch['icon_url'] as String?, size: 64),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(ch['name'] as String? ?? '', style: Theme.of(context).textTheme.titleLarge),
                          Text('${compactCount(ch['members_count'] as num? ?? 0)} members', style: const TextStyle(color: C.muted)),
                        ])),
                      ]),
                      if ((ch['description'] as String?)?.isNotEmpty == true)
                        Padding(padding: const EdgeInsets.only(top: 12), child: Text(ch['description'] as String)),
                      const SizedBox(height: 12),
                      _member
                          ? OutlinedButton(onPressed: _busy ? null : _toggle, child: const Text('Leave channel'))
                          : GradientButton(label: 'Join channel', onPressed: _busy ? null : _toggle),
                      if (_folders.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal, children: [
                          for (final f in [null, ..._folders])
                            Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
                              label: Text(f == null ? 'All' : f['name'] as String? ?? ''),
                              selected: _folder == f?['id'],
                              showCheckmark: false,
                              onSelected: (_) => setState(() => _folder = f?['id'] as String?),
                            )),
                        ])),
                      ],
                      const SizedBox(height: 16),
                      if (posts.isEmpty) const Text('No videos yet.', style: TextStyle(color: C.muted)),
                      for (final p in posts) Padding(padding: const EdgeInsets.only(bottom: 12), child: PostCard(post: {...p, 'channels': null}, queue: queue)),
                      if (_more) const Skeleton(height: 120),
                    ]),
                  ),
                ),
    );
  }
}

Future<bool?> confirmBlock(BuildContext context, String name) => showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text('Block $name?'), content: const Text('You will no longer see videos from this channel. You can unblock it from Channels.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Block'))]));

/// SkyKeep's own creator channels are no longer shown to users (only Flixvault channels are);
/// the creator form below is kept but no longer linked from the app.
Future<void> openChannelForm(BuildContext context, {Json? channel}) async {
  if (!await requireMember(context, reason: 'Log in to create a channel')) return;
  if (!context.mounted || !await requireConsent(context)) return;
  if (!context.mounted) return;
  if (!AppScope.read(context).status.isPremium) {
    toast(context, 'Creating channels and uploading content is for Premium members');
    if (Config.sellsPlans) { Navigator.of(context).popUntil((r) => r.isFirst); HomeShellState.current?.go(HomeShellState.premiumTab); }
    return;
  }
  await Navigator.push(context, MaterialPageRoute(builder: (_) => ChannelForm(channel: channel)));
}

String? _mime(String? ext) => switch ((ext ?? '').toLowerCase()) {
      'mp4' => 'video/mp4', 'mov' => 'video/quicktime', 'mkv' => 'video/x-matroska', 'webm' => 'video/webm',
      'jpg' || 'jpeg' => 'image/jpeg', 'png' => 'image/png', 'gif' => 'image/gif', 'webp' => 'image/webp',
      'pdf' => 'application/pdf', _ => null,
    };
String? mimeFor(String? ext) => _mime(ext);

Future<String?> _ask(BuildContext context, String title, String initial) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(context: context, builder: (d) => AlertDialog(
    title: Text(title), content: TextField(controller: c, autofocus: true),
    actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(d, c.text.trim().isEmpty ? null : c.text.trim()), child: const Text('OK'))]));
}
Future<String?> askText(BuildContext context, String title, String initial) => _ask(context, title, initial);

const channelCategories = ['Entertainment', 'Music', 'Learning', 'Technology', 'Education', 'Lifestyle', 'Fitness'];

class ChannelForm extends StatefulWidget {
  const ChannelForm({super.key, this.channel});
  final Json? channel;
  @override
  State<ChannelForm> createState() => _ChannelFormState();
}

class _ChannelFormState extends State<ChannelForm> {
  late final _name = TextEditingController(text: widget.channel?['name'] as String?);
  late final _desc = TextEditingController(text: widget.channel?['description'] as String?);
  late final _cat = TextEditingController(text: widget.channel?['category'] as String?);
  late final _tags = TextEditingController(text: ((widget.channel?['tags'] as List?) ?? const []).join(', '));
  late String? _icon = widget.channel?['icon_url'] as String?;
  bool _busy = false;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    // listen to the controller (not only onChanged) so paste, autofill and keyboard suggestions count too
    _name.addListener(() { if (_nameError != null && _name.text.trim().length >= 2) setState(() => _nameError = null); });
  }

  @override
  void dispose() {
    for (final c in [_name, _desc, _cat, _tags]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().length < 2) {
      setState(() => _nameError = 'Enter a channel name (at least 2 characters)');
      return;
    }
    _save();
  }

  Future<void> _pickIcon() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      _icon = await AppScope.read(context).api.uploadIcon(file.name, await file.readAsBytes());
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await AppScope.read(context).api.saveChannel({
        'name': _name.text.trim(), 'description': _desc.text.trim(), 'category': _cat.text.trim().isEmpty ? null : _cat.text.trim(),
        'tags': _tags.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(), 'icon_url': _icon,
        if (widget.channel == null) 'created_by': AppScope.read(context).api.user!.id,
      }, id: widget.channel?['id'] as String?);
      if (!mounted) return;
      toast(context, widget.channel == null ? 'Channel created — it goes live after a quick review.' : 'Changes saved — they go live after a quick review.');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.channel == null ? 'Create channel' : 'Edit channel')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          ChannelIcon(keyName: _icon, size: 72),
          const SizedBox(width: 12),
          OutlinedButton.icon(onPressed: _busy ? null : _pickIcon, icon: const Icon(Icons.image), label: const Text('Choose icon')),
        ]),
        const SizedBox(height: 16),
        TextField(controller: _name, maxLength: 80, textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: 'Channel name', errorText: _nameError)),
        TextField(controller: _desc, maxLines: 4, maxLength: 2000, decoration: const InputDecoration(labelText: 'Description (optional)')),
        const SizedBox(height: 8),
        TextField(controller: _cat, decoration: const InputDecoration(labelText: 'Category (optional)')),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 0, children: [
          for (final c in channelCategories)
            ActionChip(label: Text(c), onPressed: () => setState(() => _cat.text = c)),
        ]),
        const Padding(padding: EdgeInsets.only(top: 4), child: Text('The category decides where your posts appear under Latest posts on Explore.', style: TextStyle(color: C.muted, fontSize: 12))),
        const SizedBox(height: 12),
        TextField(controller: _tags, decoration: const InputDecoration(labelText: 'Tags (optional, comma separated)')),
        const SizedBox(height: 8),
        const Text('New channels and changes are checked by our team before they go live.', style: TextStyle(color: C.muted)),
        const SizedBox(height: 16),
        GradientButton(
          label: _busy ? 'Saving…' : (widget.channel == null ? 'Create channel' : 'Save changes'),
          onPressed: _busy ? null : _submit,
        ),
      ]),
    );
  }
}
