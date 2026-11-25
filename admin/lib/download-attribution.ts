/**
 * True when a /get visit comes from a paid Meta ad: a Meta click ID (fbclid), or utm_source=meta (or another Meta
 * network name) with a paid medium. Those visitors get the ads APK; everyone else gets the organic APK.
 */
export function isMetaAdQuery(q: URLSearchParams) {
  const paid = /^(cpc|ppc|paid|paid_social|paidsocial|social_paid|display|video)$/i.test(q.get('utm_medium') ?? '');
  const meta = /^(meta|facebook|instagram|ig|fb|messenger|audience_network)$/i.test(q.get('utm_source') ?? '');
  return !!q.get('fbclid') || (meta && paid);
}
