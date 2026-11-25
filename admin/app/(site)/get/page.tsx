import Link from 'next/link';
import { supabasePublic } from '@/lib/supabase/server';
import { isMetaAdQuery } from '@/lib/download-attribution';
import { APP_NAME, ADS_APK_URL, APK_URL, SHORT_CODE } from '@/lib/site';
import { GetClient } from './client';

export const metadata = { title: `Get ${APP_NAME} for Android` };
export const dynamic = 'force-dynamic';

/** Landing page for ads and links: ad traffic gets the ads APK, everyone else the organic APK. */
export default async function Get({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(await searchParams)) if (typeof v === 'string') q.set(k, v);
  const ads = isMetaAdQuery(q);
  const { data: m } = await supabasePublic().from('meta_settings').select('pixel_id, enabled').single();
  return (
    <main className="mx-auto max-w-xl px-4 py-10 text-center">
      <span className="gradient mx-auto grid h-20 w-20 place-items-center rounded-2xl text-2xl font-bold text-white">{SHORT_CODE}</span>
      <h1 className="mt-6 text-3xl font-bold">Get {APP_NAME}</h1>
      <p className="mt-2 text-slate-300">15 GB free private cloud storage, up to 2 TB with Premium, and creator channels reviewed by people. Android 7.0 or newer.</p>
      <GetClient ads={ads} adsApk={ADS_APK_URL} organicApk={APK_URL} pixelId={m?.enabled ? m.pixel_id : null} />
      <ol className="mx-auto mt-8 max-w-sm list-decimal space-y-1 text-left text-sm text-slate-300">
        <li>Tap Download and open the file when it finishes.</li>
        <li>If Android asks, allow installing from this browser.</li>
        <li>Open {APP_NAME} — no sign-up needed to start.</li>
      </ol>
      <p className="mt-8 text-sm text-slate-400">
        <Link href="/privacy" className="underline">Privacy policy</Link> · <Link href="/terms" className="underline">Terms</Link> · <Link href="/" className="underline">About {APP_NAME}</Link>
      </p>
    </main>
  );
}
