// Builds one Meta Conversions API event from a queued public.meta_events row (ported from Puffle).
// No private content ever goes to Meta: user ids / emails are SHA-256 hashed and custom data is allow-listed.
export type QueuedEvent = {
  event_name: string; event_id: string; created_at: string; action_source: string;
  app_data: Record<string, unknown> | null; anon_id: string | null; user_id: string | null;
  fbc?: string | null; fbp?: string | null; client_ip?: string | null; client_ua?: string | null;
  source_url?: string | null; value_inr?: number | string | null; content_name?: string | null;
  custom_data?: Record<string, unknown> | null;
};
// Install details for Meta matching (public.installs).
export type InstallIds = { fb_anon_id?: string | null; ad_id?: string | null; raw_referrer?: string | null; referrer_status?: string | null; source?: string | null };

export const APP_PACKAGE = 'com.skykeep.app';

export async function hash(value: string) {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(bytes)].map((x) => x.toString(16).padStart(2, '0')).join('');
}

export async function buildEvent(e: QueuedEvent, email?: string | null, now = Date.now(), inst?: InstallIds | null) {
  const time = Math.floor(new Date(e.created_at).getTime() / 1000);
  if (!Number.isFinite(time) || time > Math.floor(now / 1000) + 60 || time < Math.floor(now / 1000) - 7 * 86400) {
    throw new Error('Event is outside the delivery window');
  }
  if (!/^[A-Za-z][A-Za-z0-9_]{0,49}$/.test(e.event_name) || !e.event_id) throw new Error('Invalid event identity');
  if (e.action_source !== 'app' && e.action_source !== 'website') throw new Error('Invalid action source');
  const user: Record<string, unknown> = {};
  if (e.client_ip) user.client_ip_address = e.client_ip;
  if (e.client_ua) user.client_user_agent = e.client_ua;
  if (e.fbc) user.fbc = e.fbc;
  if (e.fbp) user.fbp = e.fbp;
  if (e.user_id) user.external_id = [await hash(e.user_id)];
  if (email?.trim()) user.em = [await hash(email.trim().toLowerCase())];
  if (e.action_source === 'app') {
    // the Meta SDK's install id when the app sent it, else SkyKeep's own install id
    const anon = inst?.fb_anon_id || e.anon_id;
    if (anon) user.anon_id = anon;
    // advertising id (not hashed, as Meta asks); only stored while the user allows ad personalisation
    if (inst?.ad_id && /^[0-9a-f-]{36}$/.test(inst.ad_id)) user.madid = inst.ad_id;
  }
  const event: Record<string, unknown> = { event_name: e.event_name, event_id: e.event_id, event_time: time, action_source: e.action_source, user_data: user };
  if (e.action_source === 'app') {
    const data = e.app_data; const ext = data?.extinfo;
    if (!data || !Array.isArray(ext) || ext.length !== 16 || ext[0] !== 'a2' || ext[1] !== APP_PACKAGE || !ext[4] || ext.some((x) => typeof x !== 'string')) {
      throw new Error('Valid Android app_data is required');
    }
    const app: Record<string, unknown> = { advertiser_tracking_enabled: 1, application_tracking_enabled: 1, extinfo: ext };
    // installed from Google Play through a Meta ad: pass Meta's own referrer on
    if (inst?.source === 'ads' && inst.referrer_status === 'play_ok' && inst.raw_referrer) {
      app.install_referrer = inst.raw_referrer.slice(0, 2048);
      app.installer_package = 'com.android.vending';
    }
    event.app_data = app;
  } else if (e.source_url) event.event_source_url = e.source_url;

  const custom: Record<string, unknown> = {};
  const p = e.custom_data ?? {};
  if (['Cloud', 'Home', 'Explore', 'Channel', 'Profile', 'Premium', 'Post', 'Safety'].includes(String(p.screen))) custom.screen = p.screen;
  if (['video', 'image', 'file'].includes(String(p.media_type))) custom.media_type = p.media_type;
  for (const field of ['preview', 'premium']) if (typeof p[field] === 'boolean') custom[field] = p[field];
  if (e.event_name === 'Lead') custom.content_name = 'apk_download';
  if (e.value_inr !== null && e.value_inr !== undefined) {
    const value = Number(e.value_inr);
    if (!Number.isFinite(value) || value < 0) throw new Error('Invalid event value');
    custom.currency = 'INR'; custom.value = value;
    if (e.content_name) custom.content_name = e.content_name.slice(0, 120);
    if (typeof p.order_id === 'string' && /^[0-9a-f-]{36}$/.test(p.order_id)) custom.order_id = p.order_id;
  }
  if (e.event_name === 'Purchase' && (!(Number(custom.value) > 0) || custom.currency !== 'INR')) {
    throw new Error('Purchase requires verified value and currency');
  }
  if (Object.keys(custom).length) event.custom_data = custom;
  return event;
}
