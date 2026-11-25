'use client';
// Browser-side Meta Pixel helpers shared by the /d and /get download pages.

type Fbq = ((...a: unknown[]) => void) & { callMethod?: (...a: unknown[]) => void; queue: unknown[]; loaded: boolean; version: string; push: unknown };

declare global { interface Window { fbq?: Fbq; _fbq?: Fbq } }

export const PIXEL_SCRIPT = 'https://connect.facebook.net/en_US/fbevents.js';

/** Sets up the fbq queue (the script itself is loaded with next/script) and initialises the pixel once. */
export function initPixel(id: string) {
  if (window.fbq) return;
  const f = function (...a: unknown[]) { if (f.callMethod) f.callMethod(...a); else f.queue.push(a); } as Fbq;
  f.queue = []; f.loaded = true; f.version = '2.0'; f.push = f;
  window.fbq = window._fbq = f;
  window.fbq('init', id);
}

export const cookie = (n: string) => document.cookie.split('; ').find((c) => c.startsWith(`${n}=`))?.split('=')[1] ?? null;

const UTM = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'];

/**
 * Download-button Lead, sent once from the browser Pixel and once from our server (Conversions API) with the same
 * event ID ("web-<uuid>"), so Meta counts it once.
 */
export function trackLead() {
  const id = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : null;
  if (!id) { window.fbq?.('track', 'Lead', { content_name: 'apk_download' }); return; }
  window.fbq?.('track', 'Lead', { content_name: 'apk_download' }, { eventID: `web-${id}` });
  const q = new URLSearchParams(location.search);
  let click = q.get('fbclid') ?? '';
  try { if (click) sessionStorage.setItem('skykeep_fbclid', click); else click = sessionStorage.getItem('skykeep_fbclid') ?? ''; } catch { /* private mode */ }
  const fbc = cookie('_fbc') ?? (click ? `fb.1.${Date.now()}.${click}` : '');
  const utm = new URLSearchParams();
  for (const k of UTM) { const v = q.get(k); if (v) utm.set(k, v.slice(0, 200)); }
  let referrer = utm.toString();
  try { if (referrer) sessionStorage.setItem('skykeep_utm', referrer); else referrer = sessionStorage.getItem('skykeep_utm') ?? ''; } catch { /* private mode */ }
  fetch('/api/meta-event', {
    method: 'POST', keepalive: true, headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ event: 'Lead', event_id: id, consent: true, fbc, fbp: cookie('_fbp') ?? '', path: location.pathname, referrer }),
  }).catch(() => {});
}
