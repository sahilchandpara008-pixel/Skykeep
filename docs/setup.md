# SkyKeep — setup (step by step)

Never paste keys into chat or commit them. Everything secret goes into the settings pages below.

## 1. Supabase project
Your project ref is `vzeehoissxdutmxdezjf` (Tokyo). Change these in the Supabase dashboard:

1. **Authentication › Sign In / Providers**: turn on **Allow anonymous sign-ins**. Email provider on, **Confirm email** on.
2. **Authentication › URL Configuration**
   - Site URL: `https://skykeep.vercel.app`
   - Redirect URLs (add all):
     - `com.skykeep.app://login-callback`
     - `com.skykeep.play://login-callback`
     - `https://skykeep.vercel.app/**`
3. **Integrations › Cron**: the `cancel-stale-orders` job is created by the migrations. Add two HTTP jobs (Integrations › Cron › New job › HTTP request):
   - `meta-send` every 5 min, POST `https://vzeehoissxdutmxdezjf.supabase.co/functions/v1/meta-send`, header `Authorization: Bearer <service role key>`
4. **Edge Functions › Secrets** (only when you need them):
   | Secret | Needed for |
   |---|---|
   | `UPI_WEBHOOK_SECRET` | only if a bank/provider will call `upi-webhook` |
   | `PLAY_PACKAGE` = `com.skykeep.play` | same |

## 2. GitHub secrets (Settings › Secrets and variables › Actions)
| Secret | Where to get it |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | supabase.com › Account › Access tokens |
| `SUPABASE_DB_PASSWORD` | Project Settings › Database (reset it if you don't know it) |
| `SUPABASE_PROJECT_REF` | `vzeehoissxdutmxdezjf` |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 skykeep-release.jks` (see mobile README) |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | from when you created the keystore |
| `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` | Project Settings › API (public values, baked into the app) |

On every push to `main`, the `supabase-deploy` job runs `db push` and deploys all edge functions.

## 3. Vercel
1. vercel.com › Add New › Project › import `rekhachandpara1975/Skykeep`.
2. **Root Directory: `admin`** (framework auto-detects Next.js).
3. Environment variables (Production + Preview):
   | Name | Value |
   |---|---|
   | `NEXT_PUBLIC_SUPABASE_URL` | `https://vzeehoissxdutmxdezjf.supabase.co` |
   | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Project Settings › API › publishable key |
   | `SUPABASE_SECRET_KEY` | Project Settings › API › secret key (server only, **no** `NEXT_PUBLIC_`) |
   | `NEXT_PUBLIC_SITE_URL` | `https://skykeep.vercel.app` |
   | `ANDROID_SIGNING_SHA256` | SHA-256 of the release key, from the mobile CI log (`keytool -list`) |
4. Name the project `skykeep` so the URL is `skykeep.vercel.app` (or set your domain and update `NEXT_PUBLIC_SITE_URL` + Auth URLs).

## 4. First owner
1. In Supabase › Authentication › Users › **Add user** (email + password, auto-confirm), use your own email.
2. In SQL editor:
   ```sql
   insert into public.admins (user_id, role, email)
   select id, 'owner', email from auth.users where email = 'YOUR_EMAIL';
   ```
3. Log in at `https://skykeep.vercel.app/control-7x2k/login`. Invite other admins from the **Admins** page.

## 5. Turn on payments
Admin › Payments › enter your UPI ID and payee name (exactly as your bank shows it) › Save. Then Admin › Plans › add plans. Until a UPI ID is set, payments stay off everywhere.

## Release signing key (done 12 Nov 2026)
- Keystore `skykeep-release.jks`, alias `skykeep`, certificate `CN=SkyKeep, O=SkyKeep, C=IN`. Kept by the owner; it is never committed.
- GitHub secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
- SHA-256 fingerprint (public; used by `/.well-known/assetlinks.json` via Vercel env `ANDROID_SIGNING_SHA256`):
  `2E:40:74:C2:F0:97:81:C2:7E:7D:A9:32:6D:9C:92:33:80:D0:17:D3:10:88:77:4D:D1:7C:61:A2:3E:56:ED:35`

## App: Flixvault videos, push, Meta (v1.0.2)

- **Videos/channels** in Explore, Feed, Channels and posts come only from Flixvault: RPCs `fv_explore`, `fv_channels`,
  `fv_channel`, `fv_post`, `fv_following` (ads/organic decided by the server, `fv_audience`), play links from the
  `flixvault-feed` edge function (`action: play`, `kind: video | preview`). Follows / blocks / reports:
  `flixvault_follows`, `flixvault_blocks`, `flixvault_reports`; blocked list names from `flixvault_channels`.
- **Push**: Firebase project `skykeep-a345c`; public client values live in `mobile/lib/config.dart` (no
  google-services.json). The Play package `com.skykeep.play` has no Firebase app yet: set its app id in
  `Config.firebasePlayAppId` or the repository variable `FIREBASE_PLAY_APP_ID`; until then the Play build skips push.
  Tokens: `register_push_token`, taps: `push_opened`.
- **Meta**: repository variables `META_APP_ID` and `META_CLIENT_TOKEN` (public build values). The Meta SDK and the
  advertising ID start only after the user allows ad measurement (first-run consent or Profile › Settings ›
  Measurement preferences): `set_measurement_preferences`, `record_activity`, `record_ad_ids`. The manifest now
  declares `AD_ID` — update the Play Console data-safety / advertising-ID declaration.
- **Installs**: Play installs send the Play install referrer to `record_install` (status `play_ok`); the server should
  count `utm_source=apps.facebook.com` / `utm_source=meta` / facebook / instagram referrers as ads.
