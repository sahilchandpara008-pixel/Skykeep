import { buildEvent, type QueuedEvent } from './payload.ts';
const ext = ['a2', 'com.skykeep.app', '10', '1.0.5', '14', '', 'en_IN', '', '', '1080', '2400', '3', '8', '', '', ''];
const base = (): QueuedEvent => ({
  event_name: 'Purchase', event_id: 'order_test', created_at: new Date().toISOString(), action_source: 'app',
  user_id: 'user-1', anon_id: 'install-1', app_data: { advertiser_tracking_enabled: 1, application_tracking_enabled: 1, extinfo: ext },
  value_inr: 259, content_name: 'Gold', custom_data: { password: 'never', filename: 'private.mp4', search: 'private', order_id: '00000000-0000-0000-0000-000000000001' },
});
function ok(v: unknown) { if (!v) throw Error('Assertion failed'); }
async function rejects(e: QueuedEvent) {
  try { await buildEvent(e); throw Error('did not reject'); } catch (x) { if (String(x).includes('did not reject')) throw x; }
}
Deno.test('hashes identifiers and strips private properties', async () => {
  const r = await buildEvent(base(), '  TEST@EXAMPLE.COM ');
  const u = r.user_data as Record<string, string[]>;
  ok(u.em[0].length === 64 && u.external_id[0].length === 64);
  ok(!JSON.stringify(r).includes('private') && !JSON.stringify(r).includes('password'));
  const c = r.custom_data as Record<string, unknown>;
  ok(c.value === 259 && c.currency === 'INR' && c.order_id === '00000000-0000-0000-0000-000000000001');
});
Deno.test('app context is mandatory', () => rejects({ ...base(), app_data: null }));
Deno.test('other app packages are rejected', () => rejects({ ...base(), app_data: { extinfo: ['a2', 'com.other', ...ext.slice(2)] } }));
Deno.test('expired events are rejected', () => rejects({ ...base(), created_at: new Date(Date.now() - 8 * 86400000).toISOString() }));
Deno.test('non-positive Purchase rejected', () => rejects({ ...base(), value_inr: 0 }));
Deno.test('Meta app-ad installs pass the Play referrer', async () => {
  const r = await buildEvent({ ...base(), event_name: 'MobileAppInstall', value_inr: null }, null, Date.now(),
    { source: 'ads', referrer_status: 'play_ok', raw_referrer: 'utm_source=apps.facebook.com' });
  ok((r.app_data as Record<string, unknown>).install_referrer === 'utm_source=apps.facebook.com');
});
Deno.test('website Lead keeps the browser event id', async () => {
  const r = await buildEvent({ ...base(), event_name: 'Lead', action_source: 'website', event_id: 'web-123', value_inr: null, source_url: 'https://skykeep.vercel.app/d' });
  ok(r.event_id === 'web-123' && !r.app_data);
  ok((r.custom_data as Record<string, string>).content_name === 'apk_download');
});
