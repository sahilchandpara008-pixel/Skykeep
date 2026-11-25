import { NextResponse, type NextRequest } from 'next/server';
import { supabaseSecret } from '@/lib/supabase/server';

export const runtime = 'nodejs';

const EVENTS = ['PageView', 'Lead', 'PlanViewed'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Server half of a website Meta event (Conversions API). The browser Pixel sends the same event with
 * eventID "web-<event_id>"; record_web_attribution stores it under that ID so Meta de-duplicates the pair.
 */
export async function POST(req: NextRequest) {
  if (req.headers.get('origin') !== req.nextUrl.origin) return NextResponse.json({ ok: false }, { status: 403 });
  const text = await req.text();
  if (text.length > 6000) return NextResponse.json({ ok: false }, { status: 413 });
  let b: Record<string, unknown>;
  try { b = JSON.parse(text); } catch { return NextResponse.json({ ok: false }, { status: 400 }); }
  if (b.consent !== true || !EVENTS.includes(String(b.event)) || !UUID.test(String(b.event_id ?? ''))) return NextResponse.json({ ok: false }, { status: 400 });
  // Vercel sets this header at its edge; never take an IP from the request body.
  const ip = (req.headers.get('x-vercel-forwarded-for') ?? req.headers.get('x-forwarded-for') ?? '').split(',')[0].trim();
  if (!ip) return NextResponse.json({ ok: false }, { status: 503 });
  const path = typeof b.path === 'string' && b.path.startsWith('/') && !b.path.startsWith('//') ? b.path.split(/[?#]/)[0] : '/';
  try {
    const { data, error } = await supabaseSecret().rpc('record_web_attribution', {
      p_event: b.event, p_event_id: b.event_id, p_consent: true, p_ip: ip, p_ua: req.headers.get('user-agent') ?? '',
      p_url: req.nextUrl.origin + path, p_fbc: String(b.fbc ?? '').slice(0, 600), p_fbp: String(b.fbp ?? '').slice(0, 200),
      p_referrer: String(b.referrer ?? '').slice(0, 2048),
    });
    if (error) throw error;
    return NextResponse.json({ ok: data === true });
  } catch (e) {
    console.error('web meta event not stored', e);
    return NextResponse.json({ ok: false }, { status: 500 });
  }
}
