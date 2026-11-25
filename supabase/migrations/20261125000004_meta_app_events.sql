-- Meta Conversions API at Puffle's level, adapted to SkyKeep's rules (only users who installed from one of our
-- Meta ads are ever reported — private.is_ads_user; Google Play / organic users never).
--
--  App events (action_source 'app', with the Android app_data Meta requires):
--    MobileAppInstall      install recorded from an ads referrer (event_id install_<install id>)
--    CompleteRegistration  guest adds an email (reg_<user>)
--    ViewContent           record_activity('ViewContent') from the app (activity-<uuid>)
--    InitiateCheckout      UPI order created (checkout_<order>)
--    Purchase              ONLY when the order is paid AND verified (owner approve / mark paid / bank SMS /
--                          provider / "Bank verified"). A phone "SUCCESS" alone never becomes a Purchase;
--                          a revoked/rejected order's queued Purchase is suppressed. Value = order amount.
--  Website: Lead (APK download) through record_web_attribution (server) / record_web_measurement (browser),
--    event_id 'web-<uuid>' so the browser Pixel's eventID 'web-<uuid>' is de-duplicated by Meta.
--  App events wait for the phone's app context (set_measurement_preferences); turning advertising off
--  suppresses everything queued for that user. Google Play installs from Meta app ads
--  (utm_source=apps.facebook.com, facebook/instagram links) now count as ads installs.
--  Admin: Dataset/Pixel ID, Meta app ID, test code and switch are editable; the token stays in
--  private.meta_secrets (write-only, shown masked).

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
alter table public.meta_settings
  add column if not exists app_id text check (app_id is null or app_id ~ '^[0-9]{5,20}$'),
  add column if not exists website_url text not null default 'https://skykeep.vercel.app'
    check (website_url ~ '^https://[a-z0-9.-]+$'),
  add column if not exists revision bigint not null default 1;

-- ---------------------------------------------------------------------------
-- Events queue
-- ---------------------------------------------------------------------------
alter table public.meta_events
  add column if not exists action_source text not null default 'app' check (action_source in ('app', 'website')),
  add column if not exists app_data jsonb,
  add column if not exists anon_id text,
  add column if not exists custom_data jsonb not null default '{}',
  add column if not exists fbc text,
  add column if not exists fbp text,
  add column if not exists client_ip text,
  add column if not exists client_ua text,
  add column if not exists source_url text,
  add column if not exists content_name text,
  add column if not exists config_revision bigint not null default 1,
  add column if not exists next_attempt_at timestamptz not null default now(),
  add column if not exists lease_until timestamptz,
  add column if not exists meta_trace_id text;
alter table public.meta_events drop constraint if exists meta_events_event_name_check;
alter table public.meta_events add constraint meta_events_event_name_check
  check (event_name in ('Lead', 'MobileAppInstall', 'CompleteRegistration', 'ViewContent', 'InitiateCheckout', 'Purchase'));
alter table public.meta_events drop constraint if exists meta_events_status_check;
alter table public.meta_events add constraint meta_events_status_check
  check (status in ('queued', 'processing', 'sent', 'test_sent', 'failed', 'skipped', 'suppressed'));
create index if not exists meta_events_due_idx on public.meta_events (next_attempt_at, created_at) where status in ('queued', 'processing');
create index if not exists meta_events_created_idx on public.meta_events (created_at desc);
create index if not exists meta_events_user_idx on public.meta_events (user_id) where user_id is not null;
create index if not exists meta_events_order_idx on public.meta_events (order_id) where order_id is not null;
create index if not exists meta_events_web_ip_idx on public.meta_events (client_ip, created_at) where action_source = 'website';

alter table public.ad_clicks add column if not exists event_id uuid unique;
create index if not exists ad_clicks_created_idx on public.ad_clicks (created_at);

alter table public.installs
  add column if not exists fb_anon_id text,
  add column if not exists ad_id text,
  add column if not exists updated_at timestamptz not null default now();
create index if not exists installs_user_idx on public.installs (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- The user's choice and the phone's app context
-- ---------------------------------------------------------------------------
create table if not exists public.measurement_preferences (
  user_id           uuid primary key references auth.users (id) on delete cascade,
  analytics         boolean not null default false,
  advertising       boolean not null default false,
  policy_version    text not null default '2026-11-25',
  advertising_since timestamptz,
  updated_at        timestamptz not null default now()
);
alter table public.measurement_preferences enable row level security;
create policy measurement_preferences_read on public.measurement_preferences for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.measurement_preferences from anon, authenticated;
grant select on public.measurement_preferences to authenticated;

create table if not exists private.app_measurement_context (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  install_id text not null,
  app_data   jsonb not null,
  last_ip    text,
  last_ua    text,
  updated_at timestamptz not null default now()
);
alter table private.app_measurement_context enable row level security;

create table if not exists private.app_activity (
  event_id    uuid primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  session_id  uuid not null,
  event_name  text not null,
  properties  jsonb not null default '{}',
  occurred_at timestamptz not null,
  received_at timestamptz not null default now()
);
create index if not exists app_activity_user_time on private.app_activity (user_id, received_at desc);
create index if not exists app_activity_received on private.app_activity (received_at);
alter table private.app_activity enable row level security;

-- ---------------------------------------------------------------------------
-- Request helpers
-- ---------------------------------------------------------------------------
create or replace function private.req_header(p_name text) returns text
language plpgsql stable set search_path = '' as $$
declare h text := current_setting('request.headers', true);
begin
  if h is null or h = '' then return null; end if;
  return nullif(h::json ->> p_name, '');
exception when others then return null;
end $$;

create or replace function private.req_ip() returns text
language sql stable set search_path = '' as $$
  select nullif(trim(split_part(coalesce(private.req_header('x-forwarded-for'), ''), ',', 1)), '')
$$;

create or replace function private.meta_ready() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.meta_settings m, private.meta_secrets s
                  where m.enabled and coalesce(m.pixel_id, '') <> '' and coalesce(s.capi_token, '') <> '')
$$;

-- Meta app-install ads: Google Play referrer utm_source=apps.facebook.com / facebook / instagram links count as ads
create or replace function private.is_meta_referrer(p_raw text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare r text := lower(coalesce(p_raw, '')); s text;
begin
  r := replace(replace(replace(replace(r, '%3d', '='), '%26', '&'), '%2e', '.'), '%2f', '/');
  s := (regexp_match(r, '(?:^|[&?])utm_source=([^&]*)'))[1];
  return coalesce(s, '') in ('meta', 'facebook', 'instagram', 'ig', 'fb', 'messenger', 'threads', 'audience_network',
                            'apps.facebook.com', 'apps.instagram.com', 'm.facebook.com', 'l.facebook.com', 'l.instagram.com')
      or r like '%facebook.com%' or r like '%instagram.com%';
end $$;

-- ---------------------------------------------------------------------------
-- One place that queues app events (all the rules)
-- ---------------------------------------------------------------------------
create or replace function private.meta_enqueue(p_event text, p_user uuid, p_event_id text, p_order uuid default null,
  p_value numeric default null, p_custom jsonb default '{}', p_time timestamptz default now(), p_ads boolean default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare ctx private.app_measurement_context; v_name text; v_inst text;
begin
  if p_user is null then return false; end if;
  if not coalesce(p_ads, private.is_ads_user(p_user)) then return false; end if;           -- ads users only
  if exists (select 1 from public.measurement_preferences m where m.user_id = p_user and not m.advertising) then
    return false;                                                                           -- the user said no
  end if;
  select * into ctx from private.app_measurement_context where user_id = p_user;
  v_inst := coalesce(ctx.install_id,
                     (select i.install_id from public.installs i where i.user_id = p_user order by i.created_at desc limit 1));
  if p_order is not null then
    select pl.name into v_name from public.payment_orders o left join public.plans pl on pl.id = o.plan_id where o.id = p_order;
  end if;
  insert into public.meta_events (event_name, event_id, user_id, order_id, value_inr, created_at, action_source,
    app_data, anon_id, custom_data, client_ip, client_ua, content_name, config_revision)
  values (p_event, p_event_id, p_user, p_order, p_value, coalesce(p_time, now()), 'app',
    ctx.app_data, v_inst,
    coalesce(p_custom, '{}') || case when p_order is null then '{}'::jsonb else jsonb_build_object('order_id', p_order::text) end,
    ctx.last_ip, ctx.last_ua, v_name, (select revision from public.meta_settings limit 1))
  on conflict (event_id) do nothing;
  return found;
end $$;

create or replace function private.enqueue_registration() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.is_guest and not new.is_guest then
    perform private.meta_enqueue('CompleteRegistration', new.id, 'reg_' || new.id);
  end if;
  return null;
end $$;

create or replace function private.enqueue_checkout() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.meta_enqueue('InitiateCheckout', new.user_id, 'checkout_' || new.id, new.id, new.amount_paise / 100.0);
  return null;
end $$;

-- install from an ads referrer (the old "Lead at install" becomes MobileAppInstall)
create or replace function private.enqueue_lead() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.source = 'ads' and new.user_id is not null then
    perform private.meta_enqueue('MobileAppInstall', new.user_id, 'install_' || new.install_id, p_ads => true);
  end if;
  return null;
end $$;

-- Purchase: only a paid AND verified order (never the phone's word alone)
drop trigger if exists orders_purchase on public.payment_orders;
create or replace function private.enqueue_purchase() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'paid' and new.bank_verified and not (old.status = 'paid' and old.bank_verified) then
    perform private.meta_enqueue('Purchase', new.user_id, 'order_' || new.id, new.id, new.amount_paise / 100.0);
  end if;
  if new.status in ('revoked', 'rejected', 'failed', 'cancelled') and old.status is distinct from new.status then
    update public.meta_events set status = 'suppressed', last_error = 'order is no longer a verified paid purchase'
     where order_id = new.id and event_name = 'Purchase' and status in ('queued', 'processing', 'failed');
  end if;
  return null;
end $$;
create trigger orders_purchase after update of status, bank_verified on public.payment_orders
  for each row execute function private.enqueue_purchase();

-- nothing unverified may still be waiting from before this change
update public.meta_events e set status = 'suppressed', last_error = 'not a verified paid order'
 where e.event_name = 'Purchase' and e.status in ('queued', 'failed')
   and not exists (select 1 from public.payment_orders o where o.id = e.order_id and o.status = 'paid' and o.bank_verified);

-- Mark paid = the owner found the payment in the bank: it is verified (Purchase may be reported)
create or replace function public.admin_mark_paid(p_order_id uuid, p_utr text) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.payment_orders;
begin
  perform private.require_owner();
  select * into o from public.payment_orders where id = p_order_id for update;
  if not found then raise exception 'order not found'; end if;
  if o.status in ('paid','revoked') then raise exception 'order already %', o.status; end if;
  if p_utr !~ '^[0-9]{12}$' then raise exception 'UTR must be 12 digits'; end if;
  insert into private.used_payment_utrs (txn_id, order_id) values (p_utr, o.id);
  update public.payment_orders set utr = p_utr, updated_at = now() where id = o.id;
  perform private.activate_subscription(o.id, 'admin');
  update public.payment_orders set bank_verified = true, bank_verified_at = coalesce(bank_verified_at, now()),
         utr_source = coalesce(utr_source, 'admin')
   where id = o.id and status = 'paid';
end $$;

-- dataset changed => old queued events are never replayed to the new dataset
create or replace function private.meta_revision() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.pixel_id is distinct from old.pixel_id then
    new.revision := old.revision + 1;
    update public.meta_events set status = 'suppressed', last_error = 'dataset changed, not replayed to the new dataset'
     where status in ('queued', 'processing');
  else
    new.revision := old.revision;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists meta_settings_revision on public.meta_settings;
create trigger meta_settings_revision before update on public.meta_settings
  for each row execute function private.meta_revision();

-- ---------------------------------------------------------------------------
-- App side
-- ---------------------------------------------------------------------------
-- Install source: ads referrers now include Meta app-install ads from Google Play.
create or replace function public.record_install(
  p_install_id text, p_referrer_status text, p_raw_referrer text, p_install_secret text
) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_src text;
  v_hash text := encode(sha256(convert_to(coalesce(p_install_secret,''), 'UTF8')), 'hex');
  v_existing public.installs;
  v_utm text := lower(coalesce(private.referrer_param(p_raw_referrer, 'utm_source'), ''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if length(coalesce(p_install_secret,'')) < 16 then raise exception 'bad install secret'; end if;
  select * into v_existing from public.installs where install_id = p_install_id;
  if found then
    if v_existing.secret_hash <> v_hash then raise exception 'install secret mismatch'; end if;
    v_src := v_existing.source;
    if v_existing.user_id is null then
      update public.installs set user_id = v_uid, updated_at = now() where install_id = p_install_id;
    end if;
  else
    v_src := case when private.is_meta_referrer(p_raw_referrer) then 'ads' else 'organic' end;
    insert into public.installs (install_id, user_id, referrer_status, raw_referrer, secret_hash, source, utm_source, utm_campaign)
    values (p_install_id, v_uid, p_referrer_status, left(p_raw_referrer, 2000), v_hash, v_src,
            nullif(v_utm,''), private.referrer_param(p_raw_referrer, 'utm_campaign'));
  end if;
  insert into private.user_sources (user_id, source) values (v_uid, v_src) on conflict (user_id) do nothing;
  return public.source_of(v_uid);
end $$;

-- Puffle's name for the same call (the timestamps are not needed by SkyKeep)
create or replace function public.record_install_attribution(p_install_id text, p_referrer_status text, p_raw_referrer text,
  p_install_secret text, p_click_ts bigint default null, p_install_ts bigint default null)
returns text language sql security definer set search_path = '' as $$
  select public.record_install(p_install_id, p_referrer_status, p_raw_referrer, p_install_secret)
$$;

-- The user's choice (+ the phone's app context Meta needs for app events).
-- p_context: {"install_id": "<this install>", "extinfo": [16 strings, "a2", "com.skykeep.app", ...]}
create or replace function public.set_measurement_preferences(p_analytics boolean, p_advertising boolean, p_context jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); ext jsonb; inst text; i int; ctx jsonb;
begin
  if uid is null then raise exception 'session required' using errcode = '42501'; end if;
  insert into public.measurement_preferences (user_id, analytics, advertising, advertising_since)
  values (uid, coalesce(p_analytics, false), coalesce(p_advertising, false), case when p_advertising then now() end)
  on conflict (user_id) do update set analytics = excluded.analytics, advertising = excluded.advertising,
    policy_version = '2026-11-25', updated_at = now(),
    advertising_since = case when not excluded.advertising then null
                             when measurement_preferences.advertising then measurement_preferences.advertising_since
                             else now() end;
  if coalesce(p_advertising, false) then
    ext := p_context -> 'extinfo'; inst := p_context ->> 'install_id';
    if coalesce(jsonb_typeof(ext), '') = 'array' then
      if jsonb_array_length(ext) <> 16 or ext->>0 <> 'a2' or ext->>1 <> 'com.skykeep.app' or coalesce(ext->>4, '') = ''
         or not exists (select 1 from public.installs x where x.install_id = inst and x.user_id = uid) then
        raise exception 'valid Android app context required';
      end if;
      for i in 0..15 loop
        if coalesce(jsonb_typeof(ext->i), '') <> 'string' or length(ext->>i) > 120 then raise exception 'invalid app context'; end if;
      end loop;
      ctx := jsonb_build_object('advertiser_tracking_enabled', 1, 'application_tracking_enabled', 1, 'extinfo', ext);
      insert into private.app_measurement_context (user_id, install_id, app_data, last_ip, last_ua)
      values (uid, inst, ctx, private.req_ip(), left(private.req_header('user-agent'), 400))
      on conflict (user_id) do update set install_id = excluded.install_id, app_data = excluded.app_data,
        last_ip = coalesce(excluded.last_ip, app_measurement_context.last_ip),
        last_ua = coalesce(excluded.last_ua, app_measurement_context.last_ua), updated_at = now();
      -- events queued before the phone sent its context can go now
      update public.meta_events set app_data = ctx, anon_id = coalesce(anon_id, inst),
             client_ip = coalesce(client_ip, private.req_ip()), client_ua = coalesce(client_ua, left(private.req_header('user-agent'), 400))
       where user_id = uid and action_source = 'app' and status = 'queued' and app_data is null;
    end if;
  else
    update public.meta_events set status = 'suppressed', last_error = 'advertising sharing turned off by the user',
           app_data = null, anon_id = null, client_ip = null, client_ua = null, fbc = null, fbp = null
     where user_id = uid and status in ('queued', 'processing', 'failed');
    delete from private.app_measurement_context where user_id = uid;
    update public.installs set ad_id = null, fb_anon_id = null, updated_at = now() where user_id = uid;
    if not coalesce(p_analytics, false) then delete from private.app_activity where user_id = uid; end if;
  end if;
  return jsonb_build_object('analytics', coalesce(p_analytics, false), 'advertising', coalesce(p_advertising, false),
                            'policy_version', '2026-11-25');
end $$;

-- App activity (Puffle signature). Only ViewContent is sent to Meta; nothing private (no titles, ids, search text).
create or replace function public.record_activity(p_event_id uuid, p_name text, p_session_id uuid,
  p_properties jsonb default '{}', p_occurred_at timestamptz default now())
returns boolean language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); props jsonb; at_ timestamptz;
begin
  if uid is null then raise exception 'session required' using errcode = '42501'; end if;
  if p_event_id is null or p_session_id is null then raise exception 'event id and session id required'; end if;
  if p_name not in ('AppOpen','ScreenView','Login','ViewContent','VideoStart','VideoProgress','PreviewComplete','SearchUsed',
                    'ChannelCreated','ChannelJoined','VideoUploaded','CloudUploaded','CloudDeleted','PlanViewed','SubscriptionPrompt') then
    raise exception 'event is not permitted';
  end if;
  if not exists (select 1 from public.measurement_preferences m where m.user_id = uid and (m.analytics or m.advertising))
     and not private.is_ads_user(uid) then
    return false;
  end if;
  if (select count(*) from private.app_activity where user_id = uid and received_at > now() - interval '1 day') >= 5000 then
    return false;
  end if;
  at_ := greatest(now() - interval '1 day', least(coalesce(p_occurred_at, now()), now()));
  props := jsonb_strip_nulls(jsonb_build_object(
    'screen', case when p_properties->>'screen' in ('Cloud','Home','Explore','Channel','Profile','Premium','Post','Safety') then p_properties->>'screen' end,
    'media_type', case when p_properties->>'media_type' in ('video','image','file') then p_properties->>'media_type' end,
    'progress', case when p_properties->>'progress' in ('25','50','75','100') then (p_properties->>'progress')::int end,
    'preview', case when jsonb_typeof(p_properties->'preview') = 'boolean' then p_properties->'preview' end,
    'premium', case when jsonb_typeof(p_properties->'premium') = 'boolean' then p_properties->'premium' end));
  insert into private.app_activity (event_id, user_id, session_id, event_name, properties, occurred_at)
  values (p_event_id, uid, p_session_id, p_name, props, at_) on conflict (event_id) do nothing;
  if not found then return false; end if;
  update private.app_measurement_context set last_ip = coalesce(private.req_ip(), last_ip),
         last_ua = coalesce(left(private.req_header('user-agent'), 400), last_ua)
   where user_id = uid and updated_at < now() - interval '1 hour';
  if p_name = 'ViewContent' then
    perform private.meta_enqueue('ViewContent', uid, 'activity-' || p_event_id::text, null, null, props, at_);
  end if;
  return true;
end $$;

-- Meta SDK anonymous id + advertising id (only after the user allowed advertising; ad id cleared when off)
create or replace function public.record_ad_ids(p_install_id text, p_fb_anon_id text default null, p_ad_id text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_anon text := nullif(left(trim(coalesce(p_fb_anon_id, '')), 100), '');
  v_ad   text := lower(nullif(trim(coalesce(p_ad_id, '')), ''));
begin
  if auth.uid() is null then return; end if;
  if not exists (select 1 from public.measurement_preferences m where m.user_id = auth.uid() and m.advertising) then return; end if;
  if v_ad is not null and (v_ad !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                           or v_ad = '00000000-0000-0000-0000-000000000000') then
    v_ad := null;
  end if;
  if v_anon is not null and v_anon !~ '^[A-Za-z0-9_.:-]+$' then v_anon := null; end if;
  update public.installs set fb_anon_id = coalesce(v_anon, fb_anon_id), ad_id = v_ad, updated_at = now()
   where install_id = p_install_id and user_id = auth.uid();
end $$;

-- ---------------------------------------------------------------------------
-- Website (download page): Lead with browser/server de-duplication
-- ---------------------------------------------------------------------------
create or replace function private.web_event(p_event text, p_event_id uuid, p_ip text, p_ua text, p_url text,
  p_fbc text, p_fbp text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_site text; inserted boolean;
begin
  if p_event not in ('PageView', 'Lead', 'PlanViewed') then raise exception 'event is not permitted'; end if;
  if p_event_id is null or nullif(p_ip, '') is null or not private.meta_ready() then return false; end if;
  select website_url into v_site from public.meta_settings limit 1;
  -- only our own site (admin setting + the two SkyKeep addresses)
  select s into v_site from unnest(array[v_site, 'https://skykeep.vercel.app', 'https://skykeep-web.vercel.app']) s
   where coalesce(p_url, '') = s or left(coalesce(p_url, ''), length(s) + 1) = s || '/' limit 1;
  if v_site is null then return false; end if;
  if (select count(*) from public.meta_events where client_ip = p_ip and action_source = 'website'
        and created_at > now() - interval '1 hour') >= 120 then return false; end if;
  insert into public.meta_events (event_name, event_id, action_source, fbc, fbp, client_ip, client_ua, source_url,
    custom_data, content_name, config_revision)
  values (p_event, 'web-' || p_event_id::text, 'website', nullif(left(p_fbc, 600), ''), nullif(left(p_fbp, 200), ''),
    left(p_ip, 100), left(p_ua, 400), left(split_part(split_part(p_url, '?', 1), '#', 1), 500),
    case when p_event = 'Lead' then '{"content_name":"apk_download"}'::jsonb else '{}'::jsonb end,
    case when p_event = 'Lead' then 'apk_download' end, (select revision from public.meta_settings limit 1))
  on conflict (event_id) do nothing;
  inserted := found;
  if inserted and p_event = 'Lead' then
    insert into public.ad_clicks (event_id, fbc, fbp, ip, user_agent, path)
    values (p_event_id, nullif(left(p_fbc, 600), ''), nullif(left(p_fbp, 200), ''), left(p_ip, 100), left(p_ua, 400),
            left(split_part(substr(p_url, length(v_site) + 1), '?', 1), 100))
    on conflict (event_id) do nothing;
  end if;
  return inserted;
end $$;

-- trusted server route (service role) passes the visitor's IP / user agent
create or replace function public.record_web_attribution(p_event text, p_event_id uuid, p_consent boolean, p_ip text, p_ua text,
  p_url text, p_fbc text default '', p_fbp text default '', p_referrer text default '')
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not coalesce(p_consent, false) then return false; end if;
  return private.web_event(p_event, p_event_id, p_ip, p_ua, p_url, p_fbc, p_fbp);
end $$;

-- browser variant (the IP / user agent come from the request itself)
create or replace function public.record_web_measurement(p_event text, p_event_id uuid, p_consent boolean,
  p_fbclid text default '', p_fbc text default '', p_fbp text default '', p_url text default '')
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_fbc text;
begin
  if not coalesce(p_consent, false) then return false; end if;
  v_fbc := coalesce(nullif(left(p_fbc, 600), ''),
                    case when coalesce(p_fbclid, '') <> '' then 'fb.1.' || (extract(epoch from now()) * 1000)::bigint || '.' || left(p_fbclid, 500) end);
  return private.web_event(p_event, p_event_id, private.req_ip(), left(private.req_header('user-agent'), 400), p_url, v_fbc, p_fbp);
end $$;

-- the website reads the ids from here, so the admin setting changes them everywhere
create or replace function public.meta_public() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce((select jsonb_build_object('pixel_id', pixel_id, 'app_id', app_id)
                     from public.meta_settings where enabled and coalesce(pixel_id, '') <> '' limit 1), '{}'::jsonb)
$$;

-- ---------------------------------------------------------------------------
-- Sending (meta-send edge function, service role)
-- ---------------------------------------------------------------------------
create or replace function public.meta_sender_config() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('pixel_id', m.pixel_id, 'app_id', m.app_id, 'test_code', m.test_code, 'enabled', m.enabled,
                            'revision', m.revision, 'website_url', m.website_url, 'token', s.capi_token)
  from public.meta_settings m, private.meta_secrets s
$$;

-- atomic lease: cron and an owner-triggered flush never send the same event twice
create or replace function public.meta_claim_batch(p_limit int default 50) returns setof public.meta_events
language plpgsql security definer set search_path = '' as $$
begin
  update public.meta_events e set status = 'suppressed',
         last_error = case when e.created_at < now() - interval '7 days' then 'older than 7 days (Meta window)'
                           else 'advertising off, dataset changed or no app context' end
   where e.status in ('queued', 'processing')
     and (e.created_at < now() - interval '7 days'
          or e.config_revision <> (select revision from public.meta_settings limit 1)
          or (e.user_id is not null and exists (select 1 from public.measurement_preferences p
                                                 where p.user_id = e.user_id and not p.advertising)));
  return query with picked as (
    select e.id from public.meta_events e
     where ((e.status = 'queued' and e.next_attempt_at <= now()) or (e.status = 'processing' and e.lease_until < now()))
       and (e.action_source = 'website' or e.app_data is not null)
       and e.attempts < 8
     order by e.created_at for update skip locked limit least(greatest(coalesce(p_limit, 50), 1), 100))
  update public.meta_events e set status = 'processing', lease_until = now() + interval '5 minutes', attempts = e.attempts + 1
    from picked p where e.id = p.id returning e.*;
end $$;

-- result of one event: p_status sent | test_sent | retry | failed | suppressed
create or replace function public.meta_finish(p_id bigint, p_status text, p_error text default null, p_trace text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_status not in ('sent', 'test_sent', 'retry', 'failed', 'suppressed') then raise exception 'bad status'; end if;
  update public.meta_events e
     set status = case when p_status = 'retry' and e.attempts < 8 then 'queued' when p_status = 'retry' then 'failed' else p_status end,
         sent_at = case when p_status in ('sent', 'test_sent') then now() else e.sent_at end,
         last_error = left(p_error, 500), meta_trace_id = coalesce(p_trace, e.meta_trace_id), lease_until = null,
         next_attempt_at = now() + make_interval(secs => least(3600, 30 * power(2, least(e.attempts, 7))::int))
   where e.id = p_id and e.status = 'processing';
  update public.meta_settings
     set last_success_at = case when p_status in ('sent', 'test_sent') then now() else last_success_at end,
         last_error = case when p_status in ('sent', 'test_sent') then null when p_status in ('failed', 'retry') then left(p_error, 500) else last_error end
   where id;
end $$;

-- wake meta-send when something sendable is waiting (trigger + every 5 minutes)
create or replace function private.meta_kick() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.meta_ready() then return; end if;
  if not exists (select 1 from public.meta_events where status = 'queued' and next_attempt_at <= now()
                   and (action_source = 'website' or app_data is not null)) then return; end if;
  perform private.call_function('meta-send');
exception when others then null;   -- tracking must never break a payment or a sign-up
end $$;
create or replace function private.meta_kick_trg() returns trigger
language plpgsql security definer set search_path = '' as $$ begin perform private.meta_kick(); return null; end $$;
drop trigger if exists meta_events_kick on public.meta_events;
create trigger meta_events_kick after insert on public.meta_events for each statement execute function private.meta_kick_trg();

do $$ begin perform cron.unschedule('meta-send'); exception when others then null; end $$;
select cron.schedule('meta-send', '*/5 * * * *', $cron$ select private.meta_kick() $cron$);
create or replace function private.measurement_retention() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not pg_try_advisory_xact_lock(hashtext('measurement_retention')) then return; end if;
  delete from private.app_activity where received_at < now() - interval '90 days';
  delete from public.meta_events where created_at < now() - interval '90 days';
  delete from public.ad_clicks where created_at < now() - interval '30 days';
end $$;
do $$ begin perform cron.unschedule('measurement-retention'); exception when others then null; end $$;
-- 03:47 IST (quiet hours)
select cron.schedule('measurement-retention', '17 22 * * *', $cron$ select private.measurement_retention() $cron$);

-- ---------------------------------------------------------------------------
-- Admin (owner)
-- ---------------------------------------------------------------------------
-- p_token: null/'' keeps the saved token; it is never returned (meta_token_masked shows ••••1234)
create or replace function public.admin_meta_save(p_enabled boolean, p_pixel_id text, p_app_id text,
  p_test_code text default null, p_token text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  update public.meta_settings set enabled = coalesce(p_enabled, false), pixel_id = nullif(trim(p_pixel_id), ''),
         app_id = nullif(trim(p_app_id), ''), test_code = nullif(trim(p_test_code), '')
   where id;
  if nullif(trim(coalesce(p_token, '')), '') is not null then
    update private.meta_secrets set capi_token = trim(p_token) where id;
  end if;
end $$;

create or replace function public.admin_meta_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_owner();
  return jsonb_build_object(
    'settings', (select jsonb_build_object('enabled', m.enabled, 'pixel_id', m.pixel_id, 'app_id', m.app_id,
                   'test_code', m.test_code, 'website_url', m.website_url, 'last_success_at', m.last_success_at,
                   'last_error', m.last_error, 'token', public.meta_token_masked()) from public.meta_settings m limit 1),
    'funnel', coalesce((select jsonb_agg(row_to_json(f)) from (
        select n.event_name,
               count(e.id) filter (where e.created_at > now() - interval '1 day') as d1,
               count(e.id) filter (where e.created_at > now() - interval '7 days') as d7,
               count(e.id) as d30,
               count(e.id) filter (where e.status = 'sent') as sent,
               count(e.id) filter (where e.status = 'test_sent') as test_sent,
               count(e.id) filter (where e.status = 'failed') as failed,
               count(e.id) filter (where e.status = 'queued') as queued,
               count(e.id) filter (where e.status = 'queued' and e.action_source = 'app' and e.app_data is null) as waiting_app_context,
               count(e.id) filter (where e.fbc is not null) as with_click,
               coalesce(sum(e.value_inr) filter (where n.event_name = 'Purchase' and e.status = 'sent' and e.created_at > now() - interval '7 days'), 0) as value_d7,
               coalesce(sum(e.value_inr) filter (where n.event_name = 'Purchase' and e.status = 'sent'), 0) as value_d30
          from unnest(array['Lead','MobileAppInstall','CompleteRegistration','ViewContent','InitiateCheckout','Purchase'])
               with ordinality as n(event_name, ord)
          left join public.meta_events e on e.event_name = n.event_name and e.created_at > now() - interval '30 days'
         group by n.event_name, n.ord order by n.ord) f), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(row_to_json(r)) from (
        select id, event_name, status, value_inr, content_name, attempts, last_error, created_at, sent_at, action_source,
               meta_trace_id, (fbc is not null) as has_click, (app_data is not null) as has_app_context
          from public.meta_events order by created_at desc limit 60) r), '[]'::jsonb),
    'clicks_7d', (select count(*) from public.ad_clicks where created_at > now() - interval '7 days'),
    'ads_installs_7d', (select count(*) from public.installs where source = 'ads' and created_at > now() - interval '7 days'),
    'auto_send', (select url <> '' from private.meta_cron where id = 1));
end $$;

create or replace function public.admin_meta_retry() returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform private.require_owner();
  update public.meta_events e set status = 'queued', attempts = 0, next_attempt_at = now(), lease_until = null
   where e.status = 'failed' and e.created_at > now() - interval '6 days'
     and e.config_revision = (select revision from public.meta_settings limit 1)
     and (e.user_id is null or not exists (select 1 from public.measurement_preferences p where p.user_id = e.user_id and not p.advertising));
  get diagnostics n = row_count;
  perform private.meta_kick();
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.record_install(text,text,text,text), public.record_install_attribution(text,text,text,text,bigint,bigint),
  public.set_measurement_preferences(boolean,boolean,jsonb), public.record_activity(uuid,text,uuid,jsonb,timestamptz),
  public.record_ad_ids(text,text,text), public.admin_meta_save(boolean,text,text,text,text), public.admin_meta_overview(),
  public.admin_meta_retry(), public.admin_mark_paid(uuid,text) from public, anon;
grant execute on function public.record_install(text,text,text,text), public.record_install_attribution(text,text,text,text,bigint,bigint),
  public.set_measurement_preferences(boolean,boolean,jsonb), public.record_activity(uuid,text,uuid,jsonb,timestamptz),
  public.record_ad_ids(text,text,text), public.admin_meta_save(boolean,text,text,text,text), public.admin_meta_overview(),
  public.admin_meta_retry(), public.admin_mark_paid(uuid,text) to authenticated;
revoke execute on function public.record_web_measurement(text,uuid,boolean,text,text,text,text) from public;
grant execute on function public.record_web_measurement(text,uuid,boolean,text,text,text,text) to anon, authenticated;
revoke execute on function public.meta_public() from public;
grant execute on function public.meta_public() to anon, authenticated;
revoke execute on function public.record_web_attribution(text,uuid,boolean,text,text,text,text,text,text),
  public.meta_sender_config(), public.meta_claim_batch(int), public.meta_finish(bigint,text,text,text) from public, anon, authenticated;
grant execute on function public.record_web_attribution(text,uuid,boolean,text,text,text,text,text,text),
  public.meta_sender_config(), public.meta_claim_batch(int), public.meta_finish(bigint,text,text,text) to service_role;
