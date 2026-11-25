'use client';
import { useState } from 'react';
import { createClient } from '@supabase/supabase-js';
import { supabaseBrowser } from '@/lib/supabase/client';

const field = 'w-full rounded-lg bg-night px-3 py-2 text-white outline-none ring-1 ring-white/10 focus:ring-accent';

export function DeletionForm() {
  const [state, setState] = useState<'idle' | 'busy' | 'done' | string>('idle');
  async function submit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    setState('busy');
    const { error } = await supabaseBrowser().functions.invoke('deletion-request', {
      body: { email: f.get('email'), scope: f.get('scope'), details: f.get('details') },
    });
    setState(error ? `Could not send: ${error.message}` : 'done');
  }
  if (state === 'done') return <p role="status" className="rounded-xl bg-emerald-500/10 p-4 text-emerald-300">Request received. We will email you to confirm.</p>;
  return (
    <form onSubmit={submit} className="space-y-3 rounded-2xl border border-white/10 bg-night-2 p-4">
      <div><label htmlFor="d-email" className="mb-1 block text-sm">Account email</label>
        <input id="d-email" name="email" type="email" required className={field} /></div>
      <fieldset className="space-y-1 text-sm"><legend className="mb-1">What should we delete?</legend>
        <label className="flex gap-2"><input type="radio" name="scope" value="all" defaultChecked /> Delete my account and all data</label>
        <label className="flex gap-2"><input type="radio" name="scope" value="some" /> Delete only some data</label></fieldset>
      <div><label htmlFor="d-details" className="mb-1 block text-sm">Details (optional)</label>
        <textarea id="d-details" name="details" rows={3} maxLength={3000} className={field} /></div>
      {state !== 'idle' && state !== 'busy' && <p role="alert" className="error-alert text-sm text-red-400">{state}</p>}
      <button disabled={state === 'busy'} className="gradient rounded-xl px-5 py-2 font-semibold text-white">{state === 'busy' ? 'Sending…' : 'Send request'}</button>
    </form>
  );
}

/** Log in with email + password and delete the account right here (same as Settings › Delete Account in the app). */
export function SignedInDelete() {
  // A separate, non-persistent session: logging in here never touches an admin session in the same browser.
  const [sb] = useState(() => createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    { auth: { persistSession: false, autoRefreshToken: false } }));
  const [who, setWho] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  async function login(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    setBusy(true); setMsg(null);
    const { data, error } = await sb.auth.signInWithPassword({ email: String(f.get('email')), password: String(f.get('password')) });
    setBusy(false);
    if (error || !data.user) setMsg({ ok: false, text: 'Wrong email or password.' });
    else setWho(data.user.email ?? String(f.get('email')));
  }
  async function remove() {
    if (!window.confirm('Delete your account permanently? Your profile, files, channels and posts will be removed. This cannot be undone.')) return;
    setBusy(true); setMsg(null);
    const { error } = await sb.functions.invoke('delete-account');
    setBusy(false);
    if (error) { setMsg({ ok: false, text: 'Could not delete the account. Please try again or send the request form below.' }); return; }
    await sb.auth.signOut().catch(() => {});
    setWho(null);
    setMsg({ ok: true, text: 'Your account has been deleted.' });
  }
  return (
    <div className="space-y-3 rounded-2xl border border-white/10 bg-night-2 p-4">
      {msg && <p role="status" className={`rounded-lg p-3 text-sm ${msg.ok ? 'bg-emerald-500/10 text-emerald-300' : 'bg-red-500/10 text-red-300'}`}>{msg.text}</p>}
      {who ? (
        <>
          <p className="text-sm">Signed in as <b>{who}</b>.</p>
          <button onClick={remove} disabled={busy} className="rounded-xl bg-red-600 px-5 py-2 font-semibold text-white hover:bg-red-700">{busy ? 'Deleting…' : 'Delete my account'}</button>
        </>
      ) : (
        <form onSubmit={login} className="space-y-3">
          <div><label htmlFor="l-email" className="mb-1 block text-sm">Email</label><input id="l-email" name="email" type="email" required autoComplete="email" className={field} /></div>
          <div><label htmlFor="l-pass" className="mb-1 block text-sm">Password</label><input id="l-pass" name="password" type="password" required autoComplete="current-password" className={field} /></div>
          <button disabled={busy} className="gradient rounded-xl px-5 py-2 font-semibold text-white">{busy ? 'Logging in…' : 'Log in'}</button>
        </form>
      )}
    </div>
  );
}
