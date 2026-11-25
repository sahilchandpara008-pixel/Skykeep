// SkyKeep's door to Flixvault's videos (ported from Puffle; same actions and JSON).
//
// The app calls it with its session (guest or member). It:
//   1. checks the SkyKeep user (JWT) and reads my_status from SkyKeep's own database:
//      audience = fv_audience() (same split as Flixvault/Puffle: install source ads, or full access => 'ads');  premium = is_premium (SkyKeep's has_full_access:
//      paid mode → active plan, free mode → full access);
//   2. browsing reads SkyKeep's copy (flixvault_* tables, policies apply SkyKeep's rules);
//   3. play: the item must be visible to this user in the copy, then Flixvault's partner-feed "play" signs a
//      short-lived link: Premium users get the full video, everyone else the preview.
//
// Secrets: FLIXVAULT_PARTNER_KEY (never in the app), FLIXVAULT_FEED_URL (or private.flixvault_settings).
//
// App request: POST JSON { action, ... }
//   explore   { tab?: all|latest|popular|most_watched, offset?, search? }  -> { posts }
//   channels  { sort?: trending|latest|top, search? }                      -> { channels }
//   channel   { channel_id, before? }                                     -> { channel, folders, posts }
//   post      { post_id }                                                 -> { post }
//   following { }                                                         -> { posts }
//   play      { item_id, kind: "video" | "preview" }                      -> Flixvault's answer ({ url, ... } or { error })
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { cors, flixvaultFeedUrl } from '../_shared/util.ts';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'content-type': 'application/json', 'cache-control': 'no-store' } });

type Status = { is_guest?: boolean; source?: string; has_ads_access?: boolean; is_premium?: boolean; can_play_premium?: boolean };
// deno-lint-ignore no-explicit-any
type Row = any;

async function viewerId(uid: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode('skykeep:' + uid)));
  return Array.from(d.slice(0, 16), (b) => b.toString(16).padStart(2, '0')).join('');
}

async function feed(body: Record<string, unknown>): Promise<{ status: number; data: Row }> {
  const key = Deno.env.get('FLIXVAULT_PARTNER_KEY') ?? '';
  const url = await flixvaultFeedUrl();
  if (!key || !url) return { status: 503, data: { error: 'not_configured' } };
  try {
    const res = await fetch(url, {
      method: 'POST', signal: AbortSignal.timeout(15000),
      headers: { 'content-type': 'application/json', 'x-partner-key': key },
      body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({ error: 'bad_response' }));
    return { status: res.status, data };
  } catch {
    return { status: 502, data: { error: 'unavailable' } };
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const auth = req.headers.get('Authorization') ?? '';
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: who, error: whoError } = await sb.auth.getUser(auth.replace(/^Bearer /, ''));
  if (whoError || !who.user) return json({ error: 'not signed in' }, 401);

  const { data: st, error: stError } = await sb.rpc('my_status');
  if (stError || !st) return json({ error: 'status unavailable' }, 503);
  const status = st as Status;
  const { data: aud } = await sb.rpc('fv_audience');
  const audience = aud === 'ads' ? 'ads' : 'organic';
  const premium = status.can_play_premium === true || status.is_premium === true;

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: 'invalid request body' }, 400); }
  const action = String(body.action ?? '');

  const blocked = async (): Promise<Set<string>> => {
    const { data } = await sb.from('flixvault_blocks').select('channel_id');
    return new Set((data ?? []).map((r: { channel_id: string }) => r.channel_id));
  };
  const dropBlocked = (posts: Row[], b: Set<string>) => posts.filter((p) => !b.has(p?.channel_id));
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await sb.rpc(fn, args);
    if (error) throw new Error(error.message);
    return data;
  };
  const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, 100) : null);
  const num = (v: unknown) => (Number.isFinite(Number(v)) ? Math.max(0, Math.trunc(Number(v))) : 0);
  const id = (v: unknown) => (typeof v === 'string' && UUID.test(v) ? v : null);

  try {
    switch (action) {
      case 'explore': {
        const tab = ['all', 'latest', 'popular', 'most_watched'].includes(String(body.tab)) ? String(body.tab) : 'all';
        const [posts, b] = await Promise.all([
          rpc('fv_explore', { p_tab: tab, p_offset: num(body.offset), p_limit: 30, p_search: str(body.search) }),
          blocked(),
        ]);
        return json({ posts: dropBlocked(posts ?? [], b) });
      }
      case 'channels': {
        const sort = ['trending', 'latest', 'top'].includes(String(body.sort)) ? String(body.sort) : 'trending';
        const [channels, b] = await Promise.all([rpc('fv_channels', { p_sort: sort, p_search: str(body.search) }), blocked()]);
        return json({ channels: (channels ?? []).filter((c: Row) => !b.has(c?.id)) });
      }
      case 'channel': {
        const cid = id(body.channel_id);
        if (!cid) return json({ error: 'channel_id required' }, 400);
        const before = typeof body.before === 'string' && !isNaN(Date.parse(body.before)) ? body.before : null;
        const data = await rpc('fv_channel', { p_channel_id: cid, p_before: before });
        return data ? json(data) : json({ error: 'not found' }, 404);
      }
      case 'post': {
        const pid = id(body.post_id);
        if (!pid) return json({ error: 'post_id required' }, 400);
        const post = await rpc('fv_post', { p_post_id: pid });
        return post ? json({ post }) : json({ error: 'not found' }, 404);
      }
      case 'following':
        return json({ posts: (await rpc('fv_following', {})) ?? [] });
      case 'play': {
        const iid = id(body.item_id);
        if (!iid) return json({ error: 'item_id required' }, 400);
        // SkyKeep's own rule first: the item must be visible to this user in the copy (policies decide)
        const { data: item } = await sb.from('flixvault_items').select('id,is_premium').eq('id', iid).maybeSingle();
        if (!item) return json({ error: 'not_allowed' }, 403);
        const kind = body.kind === 'preview' ? 'preview' : 'video';
        // the server decides Premium: a premium item in full needs SkyKeep Premium (Flixvault checks again)
        if (kind === 'video' && item.is_premium && !premium) return json({ error: 'premium_required' }, 403);
        const r = await feed({ action: 'play', audience, item_id: iid, kind, premium, viewer: await viewerId(who.user.id) });
        return json(r.data, r.status);
      }
      default:
        return json({ error: 'unknown action' }, 400);
    }
  } catch {
    return json({ error: 'unavailable' }, 503);
  }
});
