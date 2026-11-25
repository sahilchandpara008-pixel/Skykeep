const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });
const inrWhole = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 });
const dt = new Intl.DateTimeFormat('en-IN', { timeZone: 'Asia/Kolkata', dateStyle: 'medium', timeStyle: 'short' });
const d = new Intl.DateTimeFormat('en-IN', { timeZone: 'Asia/Kolkata', dateStyle: 'medium' });

/** ₹ with Indian grouping (₹1,23,456). */
export const rupees = (v: number | null | undefined, whole = true) => (whole ? inrWhole : inr).format(Number(v ?? 0));
export const paise = (p: number | null | undefined) => inr.format(Number(p ?? 0) / 100);
export const count = (v: number | null | undefined) => new Intl.NumberFormat('en-IN').format(Number(v ?? 0));

/**
 * The admin's single date/time formatter: every date and time in the admin is shown in India time (Asia/Kolkata),
 * whatever the server's or browser's time zone is. Use these, never toLocaleString / raw dates.
 */
export const IST_ZONE = 'Asia/Kolkata';
export const dateTime = (s: string | null | undefined) => (s ? `${dt.format(new Date(s))} IST` : '—');
export const date = (s: string | null | undefined) => (s ? d.format(new Date(s)) : '—');
/** Hour of day (0–23) as "09:00" — for IST hour pickers (quiet hours, daily times). */
export const hourLabel = (h: number) => `${String(h).padStart(2, '0')}:00`;
/** ISO timestamp → value for <input type="datetime-local"> in IST. */
export const toIstInput = (s: string | null | undefined) =>
  (s ? new Date(new Date(s).getTime() + 330 * 60000).toISOString().slice(0, 16) : '');
/** <input type="datetime-local"> value typed in IST → ISO timestamp (null when empty). */
export const fromIstInput = (v: string | null | undefined) => (v ? new Date(`${v}:00+05:30`).toISOString() : null);

export function bytes(n: number | null | undefined) {
  let v = Number(n ?? 0);
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(i ? 1 : 0)} ${u[i]}`;
}

export function durationLabel(days: number) {
  if (days % 365 === 0) return `= ${days / 365} year${days === 365 ? '' : 's'}`;
  if (days % 30 === 0) return `= ${days / 30} month${days === 30 ? '' : 's'}`;
  if (days % 7 === 0) return `= ${days / 7} week${days === 7 ? '' : 's'}`;
  return `= ${days} day${days === 1 ? '' : 's'}`;
}

/** "6 hours", "2 days", "1 month" — hours win when a plan has them. */
export function planLength(p: { duration_days: number; duration_hours?: number | null }) {
  const h = p.duration_hours;
  if (h) return h % 24 === 0 ? durationLabel(h / 24).slice(2) : `${h} hour${h === 1 ? '' : 's'}`;
  return durationLabel(p.duration_days).slice(2);
}
