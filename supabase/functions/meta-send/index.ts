// Sends queued Meta Conversions API events (MobileAppInstall, CompleteRegistration, ViewContent, InitiateCheckout,
// verified Purchase, website Lead) with hashed user data. Ported from Puffle's meta-send.
//
// Who may call it: pg_cron / the database (header x-cron-key, checked with meta_cron_ok), the service role
// (old dashboard cron), or the signed-in owner (admin panel).
// Body: {}                 send what is queued (default)
//       {action:"verify"}  check dataset + token (no event sent)
//       {test:true}        send one test Lead (with the admin's test event code)
// The access token lives in private.meta_secrets; it is never logged or returned.
import { admin, cronOrOwner, json, serve } from '../_shared/util.ts';
import { buildEvent, hash, type QueuedEvent } from './payload.ts';

const GRAPH = 'https://graph.facebook.com/v21.0';

type Cfg = { pixel_id: string | null; app_id: string | null; test_code: string | null; enabled: boolean; revision: number; website_url: string; token: string | null };

serve(async (req) => {
  if (!(await cronOrOwner(req))) return json({ error: 'forbidden' }, 403);
  const sb = admin();
  const body = await req.json().catch(() => ({}));
  const action = body?.test === true ? 'test' : String(body?.action ?? 'flush');
  const { data: cfgData, error: cfgErr } = await sb.rpc('meta_sender_config');
  if (cfgErr) throw cfgErr;
  const cfg = cfgData as Cfg;
  if (!cfg?.pixel_id || !cfg?.token) return json({ skipped: 'dataset or token not configured' });
  const token = cfg.token;
  const redact = (s: string) => s.replaceAll(token, '[redacted]').slice(0, 500);

  const graph = async (path: string, payload?: unknown) => {
    const r = await fetch(`${GRAPH}/${encodeURIComponent(cfg.pixel_id!)}${path}`, {
      method: payload ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      ...(payload ? { body: JSON.stringify(payload) } : {}),
      signal: AbortSignal.timeout(20000),
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(redact(String(data?.error?.message ?? `Meta HTTP ${r.status}`)));
    return data;
  };

  if (action === 'verify') {
    try {
      const d = await graph('?fields=name');
      return json({ ok: true, name: d.name ?? cfg.pixel_id, message: 'Connected. App events also need this dataset linked to your Meta app in Events Manager.' });
    } catch (e) {
      return json({ ok: false, message: redact(String(e)) });
    }
  }

  if (action === 'test') {
    try {
      const res = await graph('/events', {
        data: [{
          event_name: 'Lead', event_time: Math.floor(Date.now() / 1000), event_id: `test_${crypto.randomUUID()}`,
          action_source: 'website', event_source_url: cfg.website_url, user_data: { external_id: [await hash('skykeep-admin-test')] },
          custom_data: { content_name: 'apk_download' },
        }],
        ...(cfg.test_code ? { test_event_code: cfg.test_code } : {}),
      });
      await sb.from('meta_settings').update({ last_success_at: new Date().toISOString(), last_error: null }).eq('id', true);
      return json({ ok: true, res: { events_received: res.events_received, fbtrace_id: res.fbtrace_id } });
    } catch (e) {
      await sb.from('meta_settings').update({ last_error: redact(String(e)) }).eq('id', true);
      return json({ ok: false, error: redact(String(e)) }, 502);
    }
  }

  if (!cfg.enabled) return json({ skipped: 'disabled' });
  const { data: rows, error } = await sb.rpc('meta_claim_batch', { p_limit: 50 });
  if (error) throw error;
  const emails = new Map<string, string | null>();
  let sent = 0, failed = 0, suppressed = 0;
  // deno-lint-ignore no-explicit-any
  for (const e of (rows ?? []) as any[]) {
    let status = 'sent', err: string | null = null, trace: string | null = null;
    try {
      if (e.config_revision !== cfg.revision) throw new Error('SUPPRESS: dataset changed');
      // recheck right before sending: a revoked / unverified order never becomes a Purchase
      if (e.event_name === 'Purchase') {
        const { data: o } = await sb.from('payment_orders').select('status,bank_verified,amount_paise,user_id').eq('id', e.order_id).maybeSingle();
        if (o?.status !== 'paid' || !o.bank_verified || o.user_id !== e.user_id || Number(e.value_inr) !== Number(o.amount_paise) / 100) {
          throw new Error('SUPPRESS: not a verified paid order');
        }
      }
      if (e.user_id && !emails.has(e.user_id)) {
        const { data } = await sb.auth.admin.getUserById(e.user_id);
        emails.set(e.user_id, data.user?.email ?? null);
      }
      let inst = null;
      if (e.action_source === 'app' && e.anon_id) {
        const { data } = await sb.from('installs').select('fb_anon_id,ad_id,raw_referrer,referrer_status,source').eq('install_id', e.anon_id).maybeSingle();
        inst = data;
      }
      const event = await buildEvent(e as QueuedEvent, e.user_id ? emails.get(e.user_id) : null, Date.now(), inst);
      const res = await graph('/events', { data: [event], ...(cfg.test_code ? { test_event_code: cfg.test_code } : {}) });
      if (Number(res.events_received) !== 1) throw new Error('Meta did not acknowledge the event');
      status = cfg.test_code ? 'test_sent' : 'sent';
      trace = res.fbtrace_id ?? null;
      sent++;
    } catch (x) {
      err = redact(x instanceof Error ? x.message : String(x));
      if (err.startsWith('SUPPRESS:')) { status = 'suppressed'; suppressed++; }
      else { status = /outside the delivery window|Invalid event|app_data|requires verified/.test(err) ? 'failed' : 'retry'; failed++; }
    }
    await sb.rpc('meta_finish', { p_id: e.id, p_status: status, p_error: err, p_trace: trace });
  }
  return json({ sent, failed, suppressed });
});
