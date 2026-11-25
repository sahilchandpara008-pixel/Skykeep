// Copies Flixvault's channels, folders and posts into SkyKeep's own flixvault_* tables (ported from Puffle).
// Run every 10 minutes by pg_cron (header x-cron-key); the owner may also run it from the admin panel.
//
// Read-only towards Flixvault: it only READS the partner feed (x-partner-key). It never stores Flixvault video
// ids and never writes to Flixvault. If Flixvault can't be reached or sharing is off, the copy stays as it is.
// Secrets: FLIXVAULT_PARTNER_KEY; feed address FLIXVAULT_FEED_URL (or private.flixvault_settings.feed_url).
import { admin, cronOrOwner, flixvaultFeedUrl, json, serve } from '../_shared/util.ts';

// deno-lint-ignore no-explicit-any
type Row = any;

async function feed(body: Record<string, unknown>): Promise<Row> {
  const key = Deno.env.get('FLIXVAULT_PARTNER_KEY') ?? '';
  if (!key) throw new Error('FLIXVAULT_PARTNER_KEY not set');
  const url = await flixvaultFeedUrl();
  if (!url) throw new Error('Flixvault feed address not set');
  const r = await fetch(url, {
    method: 'POST', signal: AbortSignal.timeout(20000),
    headers: { 'content-type': 'application/json', 'x-partner-key': key },
    body: JSON.stringify(body),
  });
  if (r.status !== 200) throw new Error(`feed ${body.action} ${body.audience}: HTTP ${r.status}`);
  return await r.json();
}

async function allPosts(audience: string): Promise<Row[]> {
  const out: Row[] = [];
  for (let offset = 0; offset < 5000; offset += 100) {
    const page = (await feed({ action: 'explore', audience, tab: 'latest', limit: 100, offset })).posts ?? [];
    out.push(...page);
    if (page.length < 100) break;
  }
  return out;
}

// in both lists => 'all'; only in one => that audience
function withAudience(ads: Row[], organic: Row[]) {
  const a = new Map(ads.map((x) => [x.id, x]));
  const o = new Map(organic.map((x) => [x.id, x]));
  const out: Row[] = [];
  for (const [id, x] of a) out.push({ ...x, audience: o.has(id) ? 'all' : 'ads' });
  for (const [id, x] of o) if (!a.has(id)) out.push({ ...x, audience: 'organic' });
  return out;
}

serve(async (req) => {
  if (!(await cronOrOwner(req))) return json({ error: 'unauthorized' }, 401);
  const db = admin();
  try {
    const [chAds, chOrg, poAds, poOrg] = await Promise.all([
      feed({ action: 'channels', audience: 'ads' }).then((r) => r.channels ?? []),
      feed({ action: 'channels', audience: 'organic' }).then((r) => r.channels ?? []),
      allPosts('ads'),
      allPosts('organic'),
    ]);
    const channels = withAudience(chAds, chOrg);
    const posts = withAudience(poAds, poOrg);
    // folders: one small read per channel (as an audience that can see it)
    const folders: Row[] = [];
    for (const c of channels) {
      const r = await feed({ action: 'channel', audience: c.audience === 'organic' ? 'organic' : 'ads', channel_id: c.id });
      for (const f of r.folders ?? []) folders.push({ ...f, channel_id: c.id });
    }
    const { data, error } = await db.rpc('flixvault_apply', { p: { channels, posts, folders } });
    if (error) throw new Error(error.message);
    return json(data);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await db.rpc('flixvault_sync_failed', { p_error: msg });
    return json({ error: msg }, 502);
  }
});
