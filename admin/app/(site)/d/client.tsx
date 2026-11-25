'use client';
import { useEffect } from 'react';
import Script from 'next/script';
import { PIXEL_SCRIPT, cookie, initPixel, trackLead } from '@/lib/meta-pixel';

export function DownloadClient({ apkUrl, pixelId }: { apkUrl: string; pixelId: string | null }) {
  useEffect(() => {
    if (pixelId) { initPixel(pixelId); window.fbq?.('track', 'PageView'); window.fbq?.('track', 'ViewContent'); }
    const fbclid = new URLSearchParams(location.search).get('fbclid');
    // give the pixel a moment to set _fbp, then store the click for Meta matching
    const t = setTimeout(() => {
      fetch('/api/click', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fbclid, fbp: cookie('_fbp'), fbc: cookie('_fbc'), path: location.pathname }) }).catch(() => {});
    }, 1500);
    return () => clearTimeout(t);
  }, [pixelId]);

  return (
    <>
      {pixelId && <Script src={PIXEL_SCRIPT} strategy="afterInteractive" />}
      <a href={apkUrl} onClick={() => { if (pixelId) trackLead(); }} download
        className="gradient mt-6 inline-block rounded-xl px-8 py-3 font-semibold text-white">Download APK</a>
    </>
  );
}
