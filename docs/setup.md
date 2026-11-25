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
3. **Cron (automatic jobs)**: the migrations create every job (`expire-orders`, `meta-send` every 5 min,
   `flixvault-sync` every 10 min, `push-tick` every minute, `measurement-retention` daily). They call our edge
   functions through `pg_net` with a random key that the database generated itself (`private.meta_cron`, header
   `x-cron-key`; never in code). Turn the calls on **once** in the SQL editor:
   ```sql
   update private.meta_cron set url = 'https://vzeehoissxdutmxdezjf.supabase.co/functions/v1/meta-send' where id = 1;
   ```
   (or `select admin_set_cron_url('…/functions/v1/meta-send')` from the admin panel's owner session).
   `admin_cron_status()` shows whether it is set. Delete any old dashboard HTTP job for meta-send.
4. **Edge Functions › Secrets** (only when you need them):
   | Secret | Needed for |
   |---|---|
   | `UPI_WEBHOOK_SECRET` | only if a bank/provider will call `upi-webhook` |
   | `FLIXVAULT_PARTNER_KEY` | Flixvault videos: the key Flixvault's owner creates for the `skykeep` partner |
   | `FLIXVAULT_FEED_URL` | Flixvault's `partner-feed` function address (or put it in `private.flixvault_settings.feed_url` with SQL) |
   | `FCM_SERVICE_ACCOUNT` | push notifications: Firebase console › Project settings › Service accounts › Generate new private key (paste the whole JSON) |
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

## Flixvault videos, push notifications, Meta
- **Flixvault**: after the two secrets above are set, `flixvault-sync` fills `flixvault_*` every 10 minutes
  (Admin › Flixvault shows `admin_flixvault_sync()`). Browsing reads SkyKeep's copy; only *play* asks Flixvault
  (`flixvault-feed`), with SkyKeep's own rules: audience `ads` when `has_ads_access`, else `organic`; Premium
  (`my_status.can_play_premium`) gets full videos, everyone else previews. Nothing in SkyKeep can change Flixvault.
  Run `python3 tool/check_backend_identity.py`: no other project's address or key may enter the repository.
- **Push**: set `FCM_SERVICE_ACCOUNT`; the app calls `register_push_token` on every start. Admin › Notifications
  switches automations on/off and edits texts; all hours are India time (quiet 03:00–09:00 IST).
- **Meta**: Admin › Meta: Dataset (Pixel) ID, Meta app ID, test code, token (write-only, shown masked).
  App events need the app context the phone sends with `set_measurement_preferences`; Purchase is sent only for
  verified payments.
