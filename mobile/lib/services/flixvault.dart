/// Flixvault content in SkyKeep.
///
/// SkyKeep shows only Flixvault's videos and channels. Browsing reads SkyKeep's own copy of Flixvault
/// (RPCs fv_explore / fv_channels / fv_channel / fv_post / fv_following); the server's table policies apply
/// the ads / organic rule (fv_audience), so ads users see ads content and organic users organic content.
/// Playing asks the `flixvault-feed` edge function, which checks Premium and returns a short-lived link:
/// the full video for Premium, a preview otherwise.
///
/// The adapters below turn the server's JSON into the row shape the screens use
/// (`channels`, `post_items`, `thumbnail_key` = a ready public image URL).
library;

typedef FvJson = Map<String, dynamic>;

/// Explore tabs (server values → labels).
const fvExploreTabs = {'all': 'All', 'latest': 'Latest', 'popular': 'Popular', 'most_watched': 'Most watched'};

/// Channel sort orders (server values → labels).
const fvChannelSorts = {'trending': 'Most members', 'latest': 'Latest', 'top': 'Top rated'};

/// Page size of fv_explore (the server caps it at 100).
const fvPageSize = 30;

/// Page size of fv_channel posts (fixed on the server).
const fvChannelPageSize = 50;

List<FvJson> fvPostRows(Object? list) => [for (final p in (list as List? ?? const [])) fvPostRow(FvJson.from(p as Map))];

FvJson fvPostRow(FvJson p) {
  final ch = FvJson.from((p['channel'] as Map?) ?? const {});
  final items = [
    for (final i in (p['items'] as List? ?? const []))
      () {
        final m = FvJson.from(i as Map);
        final image = m['kind'] == 'image';
        return <String, dynamic>{
          'id': m['id'],
          'kind': m['kind'],
          'is_premium': m['is_premium'] == true,
          'duration_s': (m['duration_s'] as num?)?.toInt(),
          'position': (m['position'] as num?)?.toInt() ?? 0,
          'thumbnail_key': m['thumb_url'],
          'mime': image ? 'image/jpeg' : 'video/mp4',
          'playable': m['playable'] == true,
          'has_preview': m['has_preview'] == true,
        };
      }(),
  ]..sort((a, b) => (a['position'] as int).compareTo(b['position'] as int));
  return {
    'id': p['id'],
    'title': p['title'] ?? '',
    'description': p['caption'],
    'created_at': p['published_at'],
    'published_at': p['published_at'],
    'channel_id': p['channel_id'],
    'folder_id': p['folder_id'],
    'view_count': p['view_count'],
    'channels': {'id': p['channel_id'] ?? ch['id'], 'name': ch['name'] ?? '', 'icon_url': ch['icon_url']},
    'post_items': items,
  };
}

FvJson fvChannelRow(FvJson c) => {
      'id': c['id'],
      'name': c['name'] ?? '',
      'description': c['description'],
      'category': c['category'],
      'icon_url': c['icon_url'],
      'members_count': (c['members_count'] as num?)?.toInt() ?? 0,
      'rating': (c['rating'] as num?)?.toDouble() ?? 0,
      'created_at': c['created_at'],
    };

/// One channel page: the channel, its newest posts (50 per page) and its folders.
typedef FvChannelPage = ({FvJson channel, List<FvJson> posts, List<FvJson> folders});

FvChannelPage fvChannelPageOf(FvJson data) => (
      channel: fvChannelRow(FvJson.from(data['channel'] as Map)),
      posts: fvPostRows(data['posts']),
      folders: [
        for (final f in (data['folders'] as List? ?? const [])) FvJson.from(f as Map)
      ]..sort((a, b) => ((a['position'] as num?) ?? 0).compareTo((b['position'] as num?) ?? 0)),
    );

/// An image URL Flixvault gave us (public https link), or null.
String? fvImage(Object? v) => v is String && v.startsWith('https://') ? v : null;

class FlixvaultError implements Exception {
  FlixvaultError(this.code);

  /// premium_required | not_allowed | login_required | not_configured | unavailable ...
  final String code;
  @override
  String toString() => 'FlixvaultError($code)';
}

enum PlaybackAccess { login, full, preview, subscribe }

/// Which play button flow to show. The server checks again; this never grants anything.
PlaybackAccess playbackAccess({required bool guest, required String source, required bool canPlayPremium,
    required bool premium, required bool hasPreview}) {
  if (guest && source != 'ads') return PlaybackAccess.login; // organic guests log in before anything plays
  if (!premium || canPlayPremium) return PlaybackAccess.full;
  return hasPreview ? PlaybackAccess.preview : PlaybackAccess.subscribe;
}
