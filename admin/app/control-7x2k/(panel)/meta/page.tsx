import { requireAdmin, supabaseServer } from '@/lib/supabase/server';
import { run, str, bool } from '@/lib/action';
import { Submit } from '@/components/ui';
import { count, dateTime } from '@/lib/format';
import { ADS_APK_URL, APK_URL, SITE_URL } from '@/lib/site';

const BACK = '/control-7x2k/meta';

async function save(f: FormData) {
  'use server';
  await requireAdmin(true);
  await run(BACK, 'Meta settings saved', async () => {
    const sb = await supabaseServer();
    const token = str(f, 'capi_token');
    if (token) { const r = await sb.rpc('set_meta_token', { p_token: token }); if (r.error) return r; }
    const patch: Record<string, unknown> = { pixel_id: str(f, 'pixel_id') || null, test_code: str(f, 'test_code') || null, enabled: bool(f, 'enabled') };
    // The Meta App ID field is shown only once the backend has the meta_settings.app_id column.
    if (f.has('app_id')) {
      const appId = str(f, 'app_id');
      if (appId && !/^\d{5,20}$/.test(appId)) return { error: { message: 'The Meta App ID is a number — copy it from developers.facebook.com › your app.' } };
      patch.app_id = appId || null;
    }
    return sb.from('meta_settings').update(patch).eq('id', true);
  });
}
async function test() {
  'use server';
  await requireAdmin(true);
  await run(BACK, 'Test event sent — check Events Manager › Test events', async () => {
    const { error } = await (await supabaseServer()).functions.invoke('meta-send', { body: { test: true } });
    return { error: error ? { message: error.message } : null };
  });
}
async function flush() {
  'use server';
  await requireAdmin(true);
  await run(BACK, 'Waiting events sent', async () => {
    const { error } = await (await supabaseServer()).functions.invoke('meta-send', { body: {} });
    return { error: error ? { message: error.message } : null };
  });
}

type Ev = { event_name: string; status: string; created_at: string; sent_at: string | null; last_error: string | null };
const LABEL: Record<string, string> = {
  PageView: 'Opened the website', Lead: 'Tapped Download on the website, or first app open', MobileAppInstall: 'First open of the app',
  CompleteRegistration: 'Created an account', InitiateCheckout: 'Started a payment', Purchase: 'Bank-verified paid plan (INR)',
};
const STATUSES = ['queued', 'sent', 'failed', 'skipped'] as const;

export default async function Meta() {
  await requireAdmin(true);
  const sb = await supabaseServer();
  const since = new Date(Date.now() - 30 * 86400000).toISOString();
  const [{ data: m }, { data: masked }, { data: q }] = await Promise.all([
    sb.from('meta_settings').select('*').single(),
    sb.rpc('meta_token_masked'),
    sb.from('meta_events').select('event_name,status,created_at,sent_at,last_error').gte('created_at', since).order('created_at', { ascending: false }).limit(5000),
  ]);
  const events = (q ?? []) as Ev[];
  const by = (s: string) => events.filter((e) => e.status === s).length;
  const names = [...new Set(events.map((e) => e.event_name))].sort();
  const lastSent = events.find((e) => e.sent_at)?.sent_at;
  const problems = events.filter((e) => e.last_error).slice(0, 10);
  const healthy = m?.enabled && m?.last_success_at && !m?.last_error;
  const hasAppId = !!m && 'app_id' in m;
  const adLink = `${SITE_URL}/get?utm_source=meta&utm_medium=paid_social&utm_campaign=skykeep_meta`;
  const steps: [boolean, string][] = [
    [!!m?.pixel_id, 'Dataset / Pixel ID saved'],
    [!!masked, 'Conversions API token saved'],
    ...(hasAppId ? [[!!m?.app_id, 'Meta App ID saved'] as [boolean, string]] : []),
    [!!m?.enabled, 'Sending events is on'],
    [!!m?.last_success_at, 'At least one event delivered'],
  ];

  return (
    <>
      <h1 className="h1">Meta Pixel</h1>
      <p className="-mt-2 mb-4 text-sm text-muted">One place for the website Pixel and the server-side app events (Conversions API). Changing the IDs or token here needs no app update.</p>
      <section className="card mb-4 space-y-2">
        <h2 className="h2 mb-0">Your Meta ad link</h2>
        <p className="break-all text-sm"><a className="text-accent underline" href={adLink} target="_blank" rel="noreferrer">{adLink}</a></p>
        <p className="text-sm text-muted">Use this landing-page link in your ads. Visitors from a paid Meta link (or with a Meta click ID) get the Ads APK; everyone else gets the normal APK.
          Change only <code>skykeep_meta</code> for separate campaign reporting.</p>
      </section>

      <div className="grid gap-4 lg:grid-cols-3">
        <section className="card">
          <h2 className="h2">Setup checklist</h2>
          <ul className="space-y-1.5 text-sm">
            {steps.map(([ok, label]) => (
              <li key={label} className="flex items-center gap-2"><span className={ok ? 'text-emerald-600' : 'text-slate-300'} aria-hidden>{ok ? '✔' : '○'}</span><span className={ok ? '' : 'text-muted'}>{label}</span></li>
            ))}
          </ul>
        </section>
        <form action={save} className="card space-y-3 lg:col-span-2">
          <div className="flex items-center justify-between"><h2 className="h2 mb-0">Pixel & Conversions API</h2>
            <span className={`badge ${healthy ? 'bg-emerald-100 text-emerald-700' : m?.last_error ? 'bg-red-100 text-red-700' : 'bg-slate-100 text-slate-700'}`}>{healthy ? 'Healthy' : m?.last_error ? 'Error' : 'Not sending yet'}</span></div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div><label className="label" htmlFor="pixel">Dataset / Pixel ID</label><input id="pixel" name="pixel_id" className="input" inputMode="numeric" pattern="[0-9]{5,20}" defaultValue={m?.pixel_id ?? ''} /></div>
            {hasAppId && <div><label className="label" htmlFor="app">Meta App ID</label><input id="app" name="app_id" className="input" inputMode="numeric" pattern="[0-9]{5,20}" defaultValue={m?.app_id ?? ''} /></div>}
            <div className="sm:col-span-2"><label className="label" htmlFor="tok">Conversions API token {masked && <span className="text-muted">(saved: {masked})</span>}</label>
              <input id="tok" name="capi_token" type="password" autoComplete="off" className="input" placeholder={masked ? 'Leave empty to keep the saved token' : 'Paste the token from Events Manager'} /></div>
            <div><label className="label" htmlFor="tc">Test event code (remove it when you finish testing)</label><input id="tc" name="test_code" className="input" defaultValue={m?.test_code ?? ''} placeholder="TEST12345" /></div>
          </div>
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="enabled" defaultChecked={m?.enabled} /> Send events</label>
          <p className="text-xs text-muted">Last success: {dateTime(m?.last_success_at)}{m?.last_error && <> · Last error: <span className="text-red-700">{m.last_error}</span></>}</p>
          <Submit>Save</Submit>
        </form>
      </div>

      <div className="my-4 grid grid-cols-2 gap-3 lg:grid-cols-5">
        {[['Waiting to send', count(by('queued'))], ['Sent (30 days)', count(by('sent'))], ['Failed (30 days)', count(by('failed'))],
          ['Skipped (30 days)', count(by('skipped'))], ['Last sent', lastSent ? dateTime(lastSent) : 'Never']].map(([label, v]) => (
          <div key={label} className="card"><p className="text-xs text-muted">{label}</p><p className={`mt-1 font-semibold ${label === 'Last sent' ? 'text-sm' : 'text-xl'}`}>{v}</p></div>
        ))}
      </div>
      <div className="mb-4 flex flex-wrap gap-2">
        <form action={test}><Submit className="btn-ghost">Send test event</Submit></form>
        <form action={flush}><Submit className="btn-ghost">Send waiting events now</Submit></form>
      </div>

      <div className="card mb-4 overflow-x-auto">
        <h2 className="h2">Event status (last 30 days)</h2>
        <table className="table min-w-[640px]">
          <thead><tr><th>Event</th><th>What it means</th>{STATUSES.map((s) => <th key={s} className="text-right">{s}</th>)}</tr></thead>
          <tbody>
            {names.map((n) => (
              <tr key={n}>
                <td className="font-medium">{n}</td><td className="text-muted">{LABEL[n] ?? n}</td>
                {STATUSES.map((s) => {
                  const c = events.filter((e) => e.event_name === n && e.status === s).length;
                  return <td key={s} className={`text-right ${s === 'failed' && c ? 'text-red-700' : ''}`}>{count(c)}</td>;
                })}
              </tr>
            ))}
            {!names.length && <tr><td colSpan={6} className="text-muted">No events yet. They appear once sending is on and someone uses the app or the website.</td></tr>}
          </tbody>
        </table>
      </div>

      {problems.length > 0 && (
        <div className="card mb-4 overflow-x-auto">
          <h2 className="h2">Latest problems</h2>
          <table className="table min-w-[560px]">
            <thead><tr><th>Time</th><th>Event</th><th>Status</th><th>Problem</th></tr></thead>
            <tbody>{problems.map((e, i) => (
              <tr key={i}><td className="whitespace-nowrap text-xs text-muted">{dateTime(e.created_at)}</td><td>{e.event_name}</td><td>{e.status}</td><td className="text-xs text-red-700">{e.last_error}</td></tr>
            ))}</tbody>
          </table>
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-2">
        <section className="card space-y-2">
          <h2 className="h2 mb-0">Before starting ads</h2>
          <p className="text-sm text-muted">Link this dataset to your Meta app in Events Manager once. Enter a test event code, send a test, check Events Manager, then remove the code for live campaigns.
            A website Download tap is measured once (browser Pixel and server share one event ID, so Meta counts it once). Purchases are sent only after the payment is verified.</p>
          <p className="text-sm text-muted">Never paste access tokens into chat or public pages.</p>
        </section>
        <section className="card space-y-2">
          <h2 className="h2 mb-0">APK files</h2>
          <p className="text-sm text-muted">Every build on main publishes the newest APKs automatically. /get gives ad visitors the Ads APK and others the normal APK; /d always gives the Ads APK.</p>
          <p className="break-all text-xs">Ads APK: <a className="text-accent underline" href={ADS_APK_URL}>{ADS_APK_URL}</a></p>
          <p className="break-all text-xs">Normal APK: <a className="text-accent underline" href={APK_URL}>{APK_URL}</a></p>
        </section>
      </div>
    </>
  );
}
