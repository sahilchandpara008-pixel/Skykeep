import { requireAdmin, supabaseServer } from '@/lib/supabase/server';
import { run, str } from '@/lib/action';
import { Submit } from '@/components/ui';
import { count, dateTime, fromIstInput, hourLabel } from '@/lib/format';
import { APP_NAME } from '@/lib/site';

const BACK = '/control-7x2k/notifications';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const fail = (message: string) => ({ error: { message } });

async function sendPush(f: FormData) {
  'use server';
  await requireAdmin(true);
  const title = str(f, 'title'), type = str(f, 'type') || 'none', target = str(f, 'target'), url = str(f, 'url');
  const when = fromIstInput(str(f, 'when'));
  await run(BACK, when ? 'Scheduled' : 'Queued — it goes out within a minute', async () => {
    if (!title) return fail('Write a title.');
    if ((type === 'post' || type === 'channel') && !UUID.test(target)) return fail('Choose the video to open.');
    if (type === 'url' && !url.startsWith('https://')) return fail('The link must start with https://');
    return (await supabaseServer()).rpc('admin_push_create', {
      p_title: title, p_body: str(f, 'body'), p_image: str(f, 'image'), p_type: type,
      p_target: target, p_url: url, p_audience: str(f, 'audience') || 'all', p_scheduled_at: when,
    });
  });
}

async function cancelPush(f: FormData) {
  'use server';
  await requireAdmin(true);
  await run(BACK, 'Cancelled', async () => (await supabaseServer()).rpc('admin_push_cancel', { p_id: str(f, 'id') }));
}

async function saveSettings(f: FormData) {
  'use server';
  await requireAdmin(true);
  await run(BACK, 'Saved', async () => (await supabaseServer()).rpc('admin_push_settings_save', {
    p_auto: str(f, 'auto') === '1', p_quiet_start: Number(str(f, 'quiet_start')), p_quiet_end: Number(str(f, 'quiet_end')),
    p_daily_cap: Number(str(f, 'daily_cap')),
  }));
}

async function saveAuto(f: FormData) {
  'use server';
  await requireAdmin(true);
  await run(BACK, 'Automatic message saved', async () => (await supabaseServer()).rpc('admin_push_auto_save', {
    p_kind: str(f, 'kind'), p_enabled: str(f, 'enabled') === '1', p_title: str(f, 'title'), p_body: str(f, 'body'),
    p_title2: str(f, 'title2') || null, p_body2: str(f, 'body2') || null,
  }));
}

async function saveDaily(f: FormData) {
  'use server';
  await requireAdmin(true);
  const hours = f.getAll('hours').map(Number).filter((h) => Number.isInteger(h) && h >= 0 && h <= 23);
  const msgs = f.getAll('pos').map((p) => ({ pos: Number(p), title: str(f, `title_${p}`), body: str(f, `body_${p}`), enabled: str(f, `on_${p}`) === '1' }));
  await run(BACK, 'Daily messages saved', async () => (await supabaseServer()).rpc('admin_push_daily_save', { p_hours: hours, p_msgs: msgs }));
}

type Msg = { id: string; title: string; body: string | null; type: string; audience: string; status: string; scheduled_at: string;
  auto: boolean; created_at: string; recipients: number; sent: number; failed: number; opened: number };
type Auto = { kind: string; enabled: boolean; title: string; body: string; title2: string | null; body2: string | null;
  delay1: number | null; delay2: number | null; sent_7d: number; opened_7d: number };
type Daily = { pos: number; source: string; title: string; body: string; enabled: boolean };
type Overview = { settings: { auto_enabled: boolean; quiet_start: number; quiet_end: number; daily_cap: number; daily_hours?: number[] } | null;
  phones: number; users: number; messages: Msg[]; autos?: Auto[]; daily_msgs?: Daily[] };

const AUTO: Record<string, { name: string; when: (a: Auto) => string; second?: string }> = {
  welcome: { name: 'Welcome', when: (a) => `${a.delay1 ?? 3} hours after a new phone signs up` },
  daily: { name: 'Daily messages', when: (a) => `At the times below, to free users in their first ${a.delay2 ?? 14} days` },
  come_back: { name: 'Come back', when: (a) => `After ${a.delay1 ?? 5} and ${a.delay2 ?? 14} days without opening the app`, second: 'Second message (after {d} days)' },
  payment_reminder: { name: 'Payment reminder', when: (a) => `${a.delay1 ?? 1} hour and ${a.delay2 ?? 24} hours after an unfinished payment`, second: 'Second reminder' },
  payment_failed: { name: 'Payment failed', when: () => 'Right away' },
  payment_approved: { name: 'Plan active', when: () => 'Right away, after a real payment is approved' },
  plan_ending: { name: 'Plan ends tomorrow', when: () => '1 day before the plan ends' },
  plan_ended: { name: 'Plan ended', when: (a) => `When the plan ends, and again after ${a.delay2 ?? 3} days`, second: 'Second message' },
};
const SOURCE: Record<string, string> = { trending: 'Most watched video', newest: 'Newest video', premium: 'A premium video', channel: 'A channel', plan: 'Plan offer' };
const AUD: Record<string, string> = { all: 'Everyone', ads: 'Ads users', organic: 'Organic users', premium: 'Paid users', free: 'Free users' };
const STATUS: Record<string, string> = { sent: 'bg-emerald-100 text-emerald-700', cancelled: 'bg-slate-100 text-slate-500', queued: 'bg-amber-100 text-amber-800', sending: 'bg-amber-100 text-amber-800' };
const HOURS = Array.from({ length: 24 }, (_, h) => h);
const OnOff = ({ name, on, id }: { name: string; on: boolean; id?: string }) => (
  <select id={id} name={name} className="input" defaultValue={on ? '1' : '0'}><option value="1">On</option><option value="0">Off</option></select>
);

/** Asks the push sender whether the Firebase key is set (it reports only yes/no). */
async function firebaseStatus(): Promise<{ key: boolean; login?: string } | null> {
  try {
    const r = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/push-send?check=1`, { cache: 'no-store', signal: AbortSignal.timeout(4000) });
    return r.ok ? await r.json() : null;
  } catch { return null; }
}

export default async function Notifications() {
  await requireAdmin(true);
  const sb = await supabaseServer();
  const [{ data, error }, fb, { data: posts }] = await Promise.all([
    sb.rpc('admin_push_overview'),
    firebaseStatus(),
    sb.from('flixvault_posts').select('id,title').order('published_at', { ascending: false }).limit(100),
  ]);
  const o = (data ?? null) as Overview | null;
  const s = o?.settings;
  const autos = o?.autos ?? [];
  const fbOk = !!fb?.key && fb.login === 'ok';
  const tiles = [
    ['Phones that can receive', count(o?.phones)], ['Users', count(o?.users)],
    ['Automatic messages on', `${autos.filter((a) => a.enabled).length} of ${autos.length}`],
    ['Firebase key', fb?.key ? (fbOk ? 'Working' : 'Check key') : 'Not set'],
  ];

  return (
    <>
      <h1 className="h1">Notifications</h1>
      <p className="-mt-2 mb-4 text-sm text-muted">Send messages to {APP_NAME} phones, or let {APP_NAME} announce new videos automatically. All times are India time (IST).</p>
      {error && <p className="mb-4 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-800">Could not load notifications: {error.message}</p>}
      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {tiles.map(([label, v]) => (
          <div key={label} className="card"><p className="text-xs text-muted">{label}</p>
            <p className={`mt-1 text-xl font-semibold ${label === 'Firebase key' && !fbOk ? 'text-amber-700' : ''}`}>{v}</p></div>
        ))}
      </div>
      {!fb?.key && (
        <p className="mb-4 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-800">Add the Firebase service-account key in Supabase › Edge Functions › Secrets as <code>FCM_SERVICE_ACCOUNT</code>. Until then messages are kept but not delivered.</p>
      )}

      <div className="mb-6 grid gap-4 lg:grid-cols-2">
        <form action={sendPush} className="card space-y-3">
          <h2 className="h2 mb-0">Send a message</h2>
          <div><label className="label" htmlFor="p-title">Title</label><input id="p-title" name="title" className="input" maxLength={80} required placeholder="New videos are waiting" /></div>
          <div><label className="label" htmlFor="p-body">Message (optional)</label><textarea id="p-body" name="body" className="input" maxLength={240} rows={2} /></div>
          <div><label className="label" htmlFor="p-image">Picture link (optional, https:// image shown in the notification)</label><input id="p-image" name="image" className="input" placeholder="https://…" /></div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div><label className="label" htmlFor="p-aud">Send to</label>
              <select id="p-aud" name="audience" className="input" defaultValue="all">{Object.entries(AUD).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></div>
            <div><label className="label" htmlFor="p-type">When tapped, open</label>
              <select id="p-type" name="type" className="input" defaultValue="none">
                <option value="none">The app</option><option value="post">A video</option><option value="premium">Plans page</option><option value="url">A web link</option>
              </select></div>
          </div>
          <div><label className="label" htmlFor="p-target">Video (if “A video”)</label>
            <select id="p-target" name="target" className="input" defaultValue=""><option value="">—</option>{(posts ?? []).map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}</select></div>
          <div><label className="label" htmlFor="p-url">Web link (if “A web link”)</label><input id="p-url" name="url" className="input" placeholder="https://…" /></div>
          <div><label className="label" htmlFor="p-when">Schedule (India time, optional — leave empty to send now)</label><input id="p-when" type="datetime-local" name="when" className="input" /></div>
          <Submit confirm="Send this notification?">Send</Submit>
        </form>

        <form action={saveSettings} className="card space-y-3">
          <h2 className="h2 mb-0">New-video announcements</h2>
          <p className="text-sm text-muted">Announce each new Flixvault video to everyone allowed to see it. Quiet hours apply to all automatic messages.</p>
          <div><label className="label" htmlFor="s-auto">New-video announcements</label><OnOff id="s-auto" name="auto" on={!!s?.auto_enabled} /></div>
          <div className="grid gap-3 sm:grid-cols-3">
            <div><label className="label" htmlFor="s-qs">Quiet from (IST)</label>
              <select id="s-qs" name="quiet_start" className="input" defaultValue={String(s?.quiet_start ?? 23)}>{HOURS.map((h) => <option key={h} value={h}>{hourLabel(h)}</option>)}</select></div>
            <div><label className="label" htmlFor="s-qe">Quiet until (IST)</label>
              <select id="s-qe" name="quiet_end" className="input" defaultValue={String(s?.quiet_end ?? 9)}>{HOURS.map((h) => <option key={h} value={h}>{hourLabel(h)}</option>)}</select></div>
            <div><label className="label" htmlFor="s-cap">Max per day</label>
              <select id="s-cap" name="daily_cap" className="input" defaultValue={String(s?.daily_cap ?? 2)}>{[0, 1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{n}</option>)}</select></div>
          </div>
          <p className="text-xs text-muted">No messages are sent in quiet hours. Turning this on never announces videos that already exist.</p>
          <Submit>Save</Submit>
        </form>
      </div>

      <h2 className="h2 mb-1">Automatic messages</h2>
      <p className="mb-3 text-xs text-muted">Each person only gets videos they are allowed to see (ads/organic). Nothing is sent in quiet hours, at most one of these every 2 hours per person,
        never to admins. Words in {'{'}braces{'}'} are filled in automatically.</p>
      <div className="mb-6 grid gap-4 lg:grid-cols-2">
        {autos.filter((a) => a.kind !== 'daily').map((a) => {
          const meta = AUTO[a.kind] ?? { name: a.kind, when: () => '' };
          return (
            <form key={a.kind} action={saveAuto} className="card space-y-3">
              <input type="hidden" name="kind" value={a.kind} />
              <div className="flex items-center justify-between gap-2">
                <h3 className="font-semibold">{meta.name}</h3>
                <span className={`badge ${a.enabled ? 'bg-emerald-100 text-emerald-700' : 'bg-slate-100 text-slate-600'}`}>{a.enabled ? 'On' : 'Off'}</span>
              </div>
              <p className="text-xs text-muted">{meta.when(a)} · sent {count(a.sent_7d)} in 7 days · tapped {count(a.opened_7d)}</p>
              <div><label className="label" htmlFor={`en-${a.kind}`}>Status</label><OnOff id={`en-${a.kind}`} name="enabled" on={a.enabled} /></div>
              <div><label className="label" htmlFor={`t-${a.kind}`}>Title</label><input id={`t-${a.kind}`} name="title" className="input" maxLength={80} defaultValue={a.title} required /></div>
              <div><label className="label" htmlFor={`b-${a.kind}`}>Message</label><textarea id={`b-${a.kind}`} name="body" className="input" maxLength={240} rows={2} defaultValue={a.body} /></div>
              {a.title2 !== null && (
                <>
                  <div><label className="label" htmlFor={`t2-${a.kind}`}>{(meta.second ?? 'Second message').replace('{d}', String(a.delay2 ?? ''))}</label>
                    <input id={`t2-${a.kind}`} name="title2" className="input" maxLength={80} defaultValue={a.title2 ?? ''} /></div>
                  <div><label className="label" htmlFor={`b2-${a.kind}`}>Second message text</label>
                    <textarea id={`b2-${a.kind}`} name="body2" className="input" maxLength={240} rows={2} defaultValue={a.body2 ?? ''} /></div>
                </>
              )}
              <Submit>Save</Submit>
            </form>
          );
        })}
        {!autos.length && <p className="text-sm text-muted">No automatic messages yet.</p>}
      </div>

      {autos.filter((a) => a.kind === 'daily').map((a) => (
        <section key="daily" className="card mb-6 space-y-4">
          <div>
            <h2 className="h2 mb-0">Daily messages</h2>
            <p className="text-xs text-muted">{AUTO.daily.when(a)}. One per time, rotating through the list · sent {count(a.sent_7d)} in 7 days · tapped {count(a.opened_7d)}</p>
          </div>
          <form action={saveAuto} className="flex flex-wrap items-end gap-3">
            <input type="hidden" name="kind" value="daily" /><input type="hidden" name="title" value={a.title} /><input type="hidden" name="body" value={a.body} />
            <div><label className="label" htmlFor="en-daily">Status</label><OnOff id="en-daily" name="enabled" on={a.enabled} /></div>
            <Submit className="btn-ghost">Save status</Submit>
          </form>
          <form action={saveDaily} className="space-y-3">
            <div>
              <p className="label">Times (India time)</p>
              <div className="flex flex-wrap gap-2">
                {HOURS.map((h) => (
                  <label key={h} className="flex items-center gap-1 text-xs">
                    <input type="checkbox" name="hours" value={h} defaultChecked={(s?.daily_hours ?? []).includes(h)} />{hourLabel(h)}
                  </label>
                ))}
              </div>
            </div>
            {(o?.daily_msgs ?? []).map((d) => (
              <div key={d.pos} className="grid gap-2 rounded-lg border border-line p-3 sm:grid-cols-[130px_1fr_1fr]">
                <input type="hidden" name="pos" value={d.pos} />
                <div className="text-xs text-muted">#{d.pos} · {SOURCE[d.source] ?? d.source}
                  <select name={`on_${d.pos}`} aria-label={`Message ${d.pos} on or off`} className="input mt-1" defaultValue={d.enabled ? '1' : '0'}><option value="1">On</option><option value="0">Off</option></select>
                </div>
                <input name={`title_${d.pos}`} aria-label={`Message ${d.pos} title`} className="input" maxLength={80} defaultValue={d.title} required />
                <input name={`body_${d.pos}`} aria-label={`Message ${d.pos} text`} className="input" maxLength={240} defaultValue={d.body} />
              </div>
            ))}
            <Submit>Save daily messages</Submit>
          </form>
        </section>
      ))}

      <div className="card overflow-x-auto">
        <h2 className="h2">Recent messages</h2>
        <table className="table min-w-[760px]">
          <thead><tr><th>Message</th><th>To</th><th>Status</th><th className="text-right">Phones</th><th className="text-right">Delivered</th><th className="text-right">Tapped</th><th>When</th><th /></tr></thead>
          <tbody>
            {(o?.messages ?? []).map((m) => (
              <tr key={m.id}>
                <td><div className="font-medium">{m.title}</div>{m.body && <div className="text-xs text-muted">{m.body}</div>}
                  {m.auto && <span className="badge mt-1 bg-accent/10 text-accent">Automatic</span>}</td>
                <td>{AUD[m.audience] ?? m.audience}</td>
                <td><span className={`badge ${STATUS[m.status] ?? 'bg-slate-100 text-slate-700'}`}>{m.status}</span></td>
                <td className="text-right">{count(m.recipients)}</td>
                <td className="text-right">{count(m.sent)}{m.failed ? <span className="text-xs text-red-700"> · {m.failed} failed</span> : null}</td>
                <td className="text-right">{count(m.opened)}</td>
                <td className="whitespace-nowrap text-xs text-muted">{dateTime(m.status === 'queued' ? m.scheduled_at : m.created_at)}</td>
                <td>{m.status === 'queued' && (
                  <form action={cancelPush}><input type="hidden" name="id" value={m.id} /><Submit className="btn-danger" confirm="Cancel this notification?">Cancel</Submit></form>
                )}</td>
              </tr>
            ))}
            {!o?.messages?.length && <tr><td colSpan={8} className="text-muted">No notifications yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}
