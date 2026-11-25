'use client';
import { useEffect, useState } from 'react';
import Script from 'next/script';
import { PIXEL_SCRIPT, cookie, initPixel, trackLead } from '@/lib/meta-pixel';

const KEY = 'skykeep_download_variant';

export function GetClient({ ads, adsApk, organicApk, pixelId }: { ads: boolean; adsApk: string; organicApk: string; pixelId: string | null }) {
  // An ad visitor who moves around the site keeps getting the ads APK for this browser session.
  const [fromAd, setFromAd] = useState(ads);
  useEffect(() => {
    try {
      if (ads) sessionStorage.setItem(KEY, 'ads');
      else if (sessionStorage.getItem(KEY) === 'ads') setFromAd(true);
    } catch { /* private mode */ }
  }, [ads]);

  useEffect(() => {
    if (pixelId) { initPixel(pixelId); window.fbq?.('track', 'PageView'); window.fbq?.('track', 'ViewContent'); }
    const fbclid = new URLSearchParams(location.search).get('fbclid');
    if (!fbclid) return;
    // give the pixel a moment to set _fbp, then store the ad click for install matching
    const t = setTimeout(() => {
      fetch('/api/click', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fbclid, fbp: cookie('_fbp'), fbc: cookie('_fbc'), path: location.pathname }) }).catch(() => {});
    }, 1500);
    return () => clearTimeout(t);
  }, [pixelId]);

  return (
    <>
      {pixelId && <Script src={PIXEL_SCRIPT} strategy="afterInteractive" />}
      <a href={fromAd ? adsApk : organicApk} onClick={() => { if (pixelId) trackLead(); }} download
        className="gradient mt-6 inline-block rounded-xl px-8 py-3 font-semibold text-white">Download APK</a>
    </>
  );
}
