import Link from 'next/link';
import { requireAdmin, supabaseServer } from '@/lib/supabase/server';
import { run, str } from '@/lib/action';
import { Submit } from '@/components/ui';
import { count, dateTime } from '@/lib/format';
import { APP_NAME } from '@/lib/site';

const BASE = '/control-7x2k/flixvault';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TABS = [['channels', 'Channels'], ['posts', 'Posts'], ['reports', 'Reports']] as const;

type Sync = { last_run: string | null; last_ok: string | null; channels: number | null; posts: number | null; error: string | null;
  hidden_channels: number; hidden_posts: number; follows: number; reports_7d: number };
type Named = { name?: string } | { name?: string }[] | null | undefined;
const nameOf = (c: Named) => (Array.isArray(c) ? c[0]?.name : c?.name) ?? '—';

/** Hide or show a copied Flixvault channel/post in this app only. Flixvault itself is never changed. */
async function setHidden(f: FormData) {
  'use server';
  await requireAdmin();
  const type = str(f, 'type'), id = str(f, 'id'), hidden = str(f, 'hidden') === '1';
  const back = str(f, 'back').startsWith(BASE) ? str(f, 'back') : BASE;
  await run(back, hidden ? `Hidden in the ${APP_NAME} app` : `Visible in the ${APP_NAME} app again`, async () => {
    if (!UUID.test(id) || !['channel', 'post'].includes(type)) return { error: { message: 'Choose a valid channel or post.' } };
    const sb = await supabaseServer();
    const { data, error } = await sb.from(type === 'channel' ? 'flixvault_channels' : 'flixvault_posts').update({ hidden }).eq('id', id).select('id');
    return { error: error ?? (!data?.length ? { message: 'Not found.' } : null) };
  });
}

function HideForm({ type, id, hidden, back }: { type: 'channel' | 'post'; id: string; hidden: boolean; back: string }) {
  return (
    <form action={setHidden}>
      <input type="hidden" name="type" value={type} /><input type="hidden" name="id" value={id} />
      <input type="hidden" name="hidden" value={hidden ? '0' : '1'} /><input type="hidden" name="back" value={back} />
      <Submit className={hidden ? 'btn-success' : 'btn-danger'} confirm={hidden ? undefined : `Hide this ${type} in the ${APP_NAME} app? Flixvault is not changed.`}>{hidden ? 'Show' : 'Hide'}</Submit>
    </form>
  );
}

const audienceBadge = (a: string) => <span className={`badge ${a === 'ads' ? 'bg-violet-100 text-violet-700' : a === 'organic' ? 'bg-sky-100 text-sky-700' : 'bg-slate-100 text-slate-700'}`}>{a}</span>;
const hiddenBadge = <span className="badge mt-1 bg-red-100 text-red-700">Hidden in {APP_NAME}</span>;

export default async function Flixvault({ searchParams }: { searchParams: Promise<{ tab?: string; q?: string }> }) {
  await requireAdmin();
  const sp = await searchParams;
  const tab = TABS.some(([k]) => k === sp.tab) ? sp.tab! : 'channels';
  const term = (sp.q ?? '').replace(/[%_,()]/g, ' ').trim();
  const back = `${BASE}?tab=${tab}${term ? `&q=${encodeURIComponent(term)}` : ''}`;
  const sb = await supabaseServer();

  const { data: syncData, error: syncError } = await sb.rpc('admin_flixvault_sync');
  const sync = (syncData ?? null) as Sync | null;
  let problem = syncError?.message ?? null;
  let body: React.ReactNode;

  if (tab === 'channels') {
    let q = sb.from('flixvault_channels').select('id,name,category,audience,members_count,icon_url,hidden').order('members_count', { ascending: false }).limit(300);
    if (term) q = q.ilike('name', `%${term}%`);
    const [{ data: rows, error }, { data: stats }] = await Promise.all([q, sb.rpc('admin_flixvault_channel_stats')]);
    problem ??= error?.message ?? null;
    const byId = new Map(((stats ?? []) as { channel_id: string; follows: number; blocks: number; reports: number }[]).map((s) => [s.channel_id, s]));
    body = (
      <table className="table min-w-[760px]">
        <thead><tr><th>Channel</th><th>Category</th><th>Audience</th><th className="text-right">Flixvault followers</th><th className="text-right">{APP_NAME} follows</th><th className="text-right">Blocked by</th><th className="text-right">Reports</th><th /></tr></thead>
        <tbody>
          {(rows ?? []).map((c) => {
            const s = byId.get(c.id);
            return (
              <tr key={c.id}>
                <td>
                  <div className="flex items-center gap-2 font-medium">
                    {c.icon_url
                      // eslint-disable-next-line @next/next/no-img-element
                      ? <img src={c.icon_url} alt="" className="h-8 w-8 shrink-0 rounded-lg object-cover" />
                      : <span className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-accent/10 text-sm font-bold text-accent">{String(c.name).charAt(0).toUpperCase()}</span>}
                    {c.name}
                  </div>
                  {c.hidden && hiddenBadge}
                </td>
                <td>{c.category ?? '—'}</td><td>{audienceBadge(c.audience)}</td>
                <td className="text-right">{count(c.members_count)}</td><td className="text-right">{count(s?.follows)}</td>
                <td className="text-right">{count(s?.blocks)}</td>
                <td className="text-right">{s?.reports ? <span className="badge bg-amber-100 text-amber-800">{s.reports}</span> : 0}</td>
                <td><HideForm type="channel" id={c.id} hidden={c.hidden} back={back} /></td>
              </tr>
            );
          })}
          {!rows?.length && <tr><td colSpan={8} className="text-muted">No Flixvault channels copied yet.</td></tr>}
        </tbody>
      </table>
    );
  } else if (tab === 'posts') {
    let q = sb.from('flixvault_posts').select('id,title,audience,published_at,view_count,hidden,flixvault_channels(name),flixvault_items(thumb_url,is_premium,position)')
      .order('published_at', { ascending: false }).limit(300);
    if (term) q = q.ilike('title', `%${term}%`);
    const { data: rows, error } = await q;
    problem ??= error?.message ?? null;
    body = (
      <table className="table min-w-[760px]">
        <thead><tr><th /><th>Title</th><th>Channel</th><th>Audience</th><th>Premium</th><th className="text-right">Flixvault views</th><th>Published</th><th /></tr></thead>
        <tbody>
          {(rows ?? []).map((p) => {
            const items = (p.flixvault_items ?? []) as { thumb_url: string | null; is_premium: boolean; position: number }[];
            const thumb = [...items].sort((a, b) => a.position - b.position).find((i) => i.thumb_url)?.thumb_url;
            return (
              <tr key={p.id}>
                <td className="w-20">
                  <div className="grid h-12 w-20 place-items-center overflow-hidden rounded-md bg-slate-100 text-[10px] text-muted">
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    {thumb ? <img src={thumb} alt="" className="h-full w-full object-cover" /> : 'No image'}
                  </div>
                </td>
                <td><span className="font-medium">{p.title}</span>{p.hidden && <div>{hiddenBadge}</div>}</td>
                <td>{nameOf(p.flixvault_channels as Named)}</td><td>{audienceBadge(p.audience)}</td>
                <td>{items.some((i) => i.is_premium) ? <span className="badge bg-amber-100 text-amber-800">Premium</span> : <span className="text-muted">Free</span>}</td>
                <td className="text-right">{count(p.view_count)}</td>
                <td className="whitespace-nowrap text-xs text-muted">{dateTime(p.published_at)}</td>
                <td><HideForm type="post" id={p.id} hidden={p.hidden} back={back} /></td>
              </tr>
            );
          })}
          {!rows?.length && <tr><td colSpan={8} className="text-muted">No Flixvault posts match.</td></tr>}
        </tbody>
      </table>
    );
  } else {
    const { data: rows, error } = await sb.from('flixvault_reports').select('id,post_id,reason,created_at').order('created_at', { ascending: false }).limit(300);
    problem ??= error?.message ?? null;
    const ids = [...new Set((rows ?? []).map((r) => r.post_id))];
    const { data: posts } = ids.length
      ? await sb.from('flixvault_posts').select('id,title,hidden,flixvault_channels(name)').in('id', ids)
      : { data: [] as { id: string; title: string; hidden: boolean; flixvault_channels: unknown }[] };
    const byId = new Map((posts ?? []).map((p) => [p.id, p]));
    body = (
      <table className="table min-w-[680px]">
        <thead><tr><th>Post</th><th>Channel</th><th>Reason</th><th>Reported</th><th /></tr></thead>
        <tbody>
          {(rows ?? []).map((r) => {
            const p = byId.get(r.post_id);
            return (
              <tr key={r.id}>
                <td>{p ? <span className="font-medium">{p.title}</span> : <span className="text-muted">No longer on Flixvault</span>}{p?.hidden && <div>{hiddenBadge}</div>}</td>
                <td>{nameOf(p?.flixvault_channels as Named)}</td>
                <td><span className="badge bg-amber-100 text-amber-800">{r.reason}</span></td>
                <td className="whitespace-nowrap text-xs text-muted">{dateTime(r.created_at)}</td>
                <td>{p && <HideForm type="post" id={p.id} hidden={p.hidden} back={back} />}</td>
              </tr>
            );
          })}
          {!rows?.length && <tr><td colSpan={5} className="text-muted">No reports from {APP_NAME} users.</td></tr>}
        </tbody>
      </table>
    );
  }

  const tiles = [
    ['Channels copied', count(sync?.channels)], ['Posts copied', count(sync?.posts)],
    ['Last copy', sync?.last_ok ? dateTime(sync.last_ok) : 'Not yet'], ['Reports (7 days)', count(sync?.reports_7d)],
  ];

  return (
    <>
      <h1 className="h1">Flixvault content</h1>
      <p className="-mt-2 mb-4 text-sm text-muted">Channels and videos copied from Flixvault every 10 minutes, with the same ads/organic rules. Hiding here only hides it in {APP_NAME}.</p>
      {problem && <p className="mb-4 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-800">Could not load Flixvault data: {problem}</p>}
      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {tiles.map(([label, v]) => (
          <div key={label} className="card"><p className="text-xs text-muted">{label}</p><p className={`mt-1 font-semibold ${label === 'Last copy' ? 'text-sm' : 'text-xl'}`}>{v}</p></div>
        ))}
      </div>
      {sync?.error && <p className="mb-4 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-800">Last copy attempt had a problem: {sync.error}. {APP_NAME} keeps showing the previous copy.</p>}
      {sync && <p className="mb-3 text-xs text-muted">Hidden: {count(sync.hidden_channels)} channels · {count(sync.hidden_posts)} posts · {count(sync.follows)} follows in {APP_NAME} · last attempt {dateTime(sync.last_run)}</p>}
      <div className="mb-3 flex flex-wrap gap-2">
        {TABS.map(([k, l]) => (
          <Link key={k} href={`${BASE}?tab=${k}`} className={k === tab ? 'btn-primary' : 'btn-ghost'}>
            {l}{k === 'reports' && !!sync?.reports_7d && <span className="rounded-full bg-red-600 px-1.5 text-xs font-semibold text-white">{sync.reports_7d}</span>}
          </Link>
        ))}
        {tab !== 'reports' && (
          <form className="ml-auto flex gap-2">
            <input type="hidden" name="tab" value={tab} />
            <input name="q" defaultValue={term} className="input w-48" aria-label="Search" placeholder={tab === 'channels' ? 'Search channel' : 'Search title'} />
            <button className="btn-ghost">Search</button>
          </form>
        )}
      </div>
      <div className="card overflow-x-auto">{body}</div>
    </>
  );
}
