-- Push notifications: tokens, owner messages by audience, fan-out / claim / finish, automations, IST rules, admin.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select no_plan();

create schema tests;
create function tests.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function tests.as_service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
end $$;
grant usage on schema tests to authenticated;
create table tests.m (k text primary key, id uuid);
grant all on tests.m to authenticated;

insert into auth.users (id, email, is_anonymous, created_at) values
  ('00000000-0000-0000-0000-0000000015a0', 'owner15@x.test', false, now() - interval '30 days'),
  ('00000000-0000-0000-0000-0000000015a1', 'ads15@x.test', false, now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000015a2', 'org15@x.test', false, now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000015a3', 'prem15@x.test', false, now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000015a4', 'content15@x.test', false, now() - interval '1 day');
insert into admins (user_id, role) values ('00000000-0000-0000-0000-0000000015a0', 'owner'), ('00000000-0000-0000-0000-0000000015a4', 'content');
insert into private.user_sources values ('00000000-0000-0000-0000-0000000015a1', 'ads'),
  ('00000000-0000-0000-0000-0000000015a2', 'organic'), ('00000000-0000-0000-0000-0000000015a3', 'organic')
  on conflict (user_id) do nothing;
update profiles set is_guest = false where id::text like '00000000-0000-0000-0000-0000000015a%';
update plans set active = false where true;
insert into plans (id, code, name, price_inr, duration_days, duration_hours) values
  ('00000000-0000-0000-0000-0000000015f1', 'p15_trial', 'Trial', 69, 1, 6),
  ('00000000-0000-0000-0000-0000000015f2', 'p15_year', 'Year Plan', 899, 365, null);
update app_mode set free_mode = false, plans_visible_for = 'everyone' where true;
update payment_settings set upi_id = 'shop@okaxis', payee_name = 'Shop', activation_mode = 'manual' where true;
-- premium user: active paid plan
insert into subscriptions (user_id, plan_id, kind, ends_at, created_at)
values ('00000000-0000-0000-0000-0000000015a3', '00000000-0000-0000-0000-0000000015f2', 'grant', now() + interval '20 days', now() - interval '10 days');

-- ===== tokens =====
select tests.as_user('00000000-0000-0000-0000-0000000015a1');
select lives_ok($$ select register_push_token('short') $$, 'short token ignored');
select register_push_token('tok-ads-aaaaaaaaaaaaaaaaaaaa');
select throws_ok($$ select count(*) from push_tokens $$, '42501', null, 'tokens are not readable by apps');
select throws_ok($$ select admin_push_create('Hi', null, null, 'none', null, null, 'all') $$, 'Owner only');
reset role;
select tests.as_user('00000000-0000-0000-0000-0000000015a2'); select register_push_token('tok-org-bbbbbbbbbbbbbbbbbbbb'); reset role;
select tests.as_user('00000000-0000-0000-0000-0000000015a3'); select register_push_token('tok-prem-cccccccccccccccccccc'); reset role;
select tests.as_user('00000000-0000-0000-0000-0000000015a0'); select register_push_token('tok-owner-dddddddddddddddddddd'); reset role;
select is((select count(*)::int from push_tokens), 4, 'four phones registered');
set local role anon;
select throws_ok($$ select register_push_token('tok-anon-eeeeeeeeeeeeeeeeeeee') $$, '42501', null, 'anon cannot register');
reset role;

-- ===== owner messages by audience =====
select tests.as_user('00000000-0000-0000-0000-0000000015a4');
select throws_ok($$ select admin_push_create('Hi', null, null, 'none', null, null, 'all') $$, 'Owner only');
reset role;
select tests.as_user('00000000-0000-0000-0000-0000000015a0');
insert into tests.m values
  ('all', admin_push_create('Hello all', 'body', null, 'none', null, null, 'all')),
  ('ads', admin_push_create('Hello ads', null, null, 'none', null, null, 'ads')),
  ('org', admin_push_create('Hello organic', null, null, 'none', null, null, 'organic')),
  ('prem', admin_push_create('Hello premium', null, null, 'premium', null, null, 'premium')),
  ('free', admin_push_create('Hello free', null, null, 'none', null, null, 'free')),
  ('later', admin_push_create('Later', null, null, 'url', null, 'https://skykeep.vercel.app', 'all', now() + interval '1 day')),
  ('cancel', admin_push_create('Cancel me', null, null, 'none', null, null, 'all', now() + interval '1 day'));
select lives_ok($$ select admin_push_cancel((select id from tests.m where k = 'cancel')) $$, 'owner cancels a scheduled message');
reset role;

update push_settings set auto_enabled = false where id = 1;
select tests.as_service();
select lives_ok($$ select push_tick() $$, 'tick runs');
reset role;
create function tests.rcp(k text) returns int language sql as $$ select recipients from public.push_messages where id = (select id from tests.m where tests.m.k = rcp.k) $$;
select is(tests.rcp('all'), 4, 'everyone: 4 phones');
select is(tests.rcp('ads'), 2, 'ads: ads member + admin');
select is(tests.rcp('org'), 3, 'organic: organic users (incl. the owner, who has no ads source)');
select is(tests.rcp('prem'), 1, 'premium: users with an active plan');
select is(tests.rcp('free'), 3, 'free: users without a plan');
select is((select status from push_messages where id = (select id from tests.m where k = 'later')), 'queued', 'scheduled message waits');
select is((select status from push_messages where id = (select id from tests.m where k = 'cancel')), 'cancelled', 'cancelled message never sent');

-- ===== sender: claim / finish =====
select tests.as_service();
create temp table claimed as select * from push_claim(1000);
reset role;
select is((select count(*)::int from claimed), 13, 'all deliveries claimed once');
select tests.as_service();
select is((select count(*)::int from push_claim(1000)), 0, 'nothing claimed twice');
select lives_ok($$ select push_finish((select jsonb_agg(jsonb_build_object('id', id, 'ok', token <> 'tok-org-bbbbbbbbbbbbbbbbbbbb',
  'unregistered', token = 'tok-org-bbbbbbbbbbbbbbbbbbbb', 'error', case when token = 'tok-org-bbbbbbbbbbbbbbbbbbbb' then 'UNREGISTERED' end)) from claimed)) $$, 'results saved');
reset role;
select is((select status from push_messages where id = (select id from tests.m where k = 'all')), 'sent', 'message finished');
select is((select sent from push_messages where id = (select id from tests.m where k = 'all')), 3, 'sent count');
select is((select failed from push_messages where id = (select id from tests.m where k = 'all')), 1, 'failed count');
select is((select count(*)::int from push_tokens where token = 'tok-org-bbbbbbbbbbbbbbbbbbbb'), 0, 'uninstalled phone token removed');
select tests.as_user('00000000-0000-0000-0000-0000000015a2'); select register_push_token('tok-org-bbbbbbbbbbbbbbbbbbbb'); reset role;
select tests.as_user('00000000-0000-0000-0000-0000000015a1');
select lives_ok($$ select push_opened((select id from tests.m where k = 'all')) $$, 'app reports an open');
reset role;
select is((select opened from push_messages where id = (select id from tests.m where k = 'all')), 1, 'open counted');
select tests.as_user('00000000-0000-0000-0000-0000000015a1');
select throws_ok($$ select push_claim(1) $$, '42501', null, 'apps cannot claim');
reset role;

-- ===== India time =====
select is(private.push_quiet((select s from push_settings s where id = 1), 5), true, '05:00 IST is quiet (03–09)');
select is(private.push_quiet((select s from push_settings s where id = 1), 9), false, '09:00 IST is not quiet');
select is(private.push_quiet((select s from push_settings s where id = 1), 2), false, '02:00 IST is not quiet');
select is((select quiet_start || '-' || quiet_end from push_settings), '3-9', 'default quiet hours 03–09 IST');
select is((select daily_hours from push_settings), '{9,14,19,0}'::int[], 'daily at 9, 14, 19, 0 IST');

-- ===== automations =====
-- make the run independent of the clock: no quiet hours, daily at every hour
update push_settings set quiet_start = 0, quiet_end = 0, daily_hours = (select array_agg(h) from generate_series(0, 23) h) where id = 1;
update push_auto set enabled_at = now() - interval '7 days' where true;
update push_tokens set created_at = now() - interval '4 hours', updated_at = now() where true;
select tests.as_service();
select flixvault_apply(jsonb_build_object(
  'channels', jsonb_build_array(jsonb_build_object('id', '00000000-0000-0000-0000-0000000015c1', 'name', 'Movies', 'audience', 'all'),
                                jsonb_build_object('id', '00000000-0000-0000-0000-0000000015c2', 'name', 'Ads Only', 'audience', 'ads')),
  'posts', jsonb_build_array(
    jsonb_build_object('id', '00000000-0000-0000-0000-0000000015d1', 'channel_id', '00000000-0000-0000-0000-0000000015c1', 'title', 'Big Film',
      'audience', 'all', 'published_at', now() - interval '1 hour', 'view_count', 500,
      'items', jsonb_build_array(jsonb_build_object('id', '00000000-0000-0000-0000-0000000015e1', 'kind', 'video', 'is_premium', true, 'thumb_url', 'https://img.test/b.jpg'))),
    jsonb_build_object('id', '00000000-0000-0000-0000-0000000015d2', 'channel_id', '00000000-0000-0000-0000-0000000015c2', 'title', 'Ads Film',
      'audience', 'all', 'published_at', now() - interval '2 hours', 'view_count', 9000, 'items', '[]'::jsonb))));
reset role;

-- payment events: an approved order, a failed order, a plan ending tomorrow
select tests.as_user('00000000-0000-0000-0000-0000000015a2');
insert into tests.m select 'order_fail', (create_order('00000000-0000-0000-0000-0000000015f1') ->> 'order_id')::uuid;
select report_result((select id from tests.m where k = 'order_fail'), 'Status=FAILURE');
reset role;
update subscriptions set ends_at = now() + interval '20 hours' where user_id = '00000000-0000-0000-0000-0000000015a3';

select tests.as_service();
select ok(private.push_automations() > 0, 'automations queued messages');
select is((select count(*)::int from push_messages where kind = 'payment_failed' and target_user = '00000000-0000-0000-0000-0000000015a2'), 1, 'payment failed message');
select is((select body from push_messages where kind = 'payment_failed'), '₹69 for Trial wasn''t charged. Try again or pick another UPI app.', 'texts filled in');
select is((select count(*)::int from push_messages where kind = 'plan_ending' and target_user = '00000000-0000-0000-0000-0000000015a3'), 1, 'Premium ending message');
select is((select count(*)::int from push_messages where kind = 'welcome' and target_user = '00000000-0000-0000-0000-0000000015a1'), 1, 'welcome for the ads user');
select is((select title || ' | ' || body from push_messages where kind = 'welcome' and target_user = '00000000-0000-0000-0000-0000000015a1'),
  'Start with today''s most watched 🔥 | Ads Film · Ads Only', 'ads user gets the most watched video they may see');
select is((select body from push_messages where kind = 'welcome' and target_user = '00000000-0000-0000-0000-0000000015a2'),
  'Big Film · Movies', 'organic user never gets an ads-only video');
select is((select count(*)::int from push_messages where auto and target_user = '00000000-0000-0000-0000-0000000015a0'), 0, 'admins never get automatic messages');
select is((select count(*)::int from push_messages where auto and target_user = '00000000-0000-0000-0000-0000000015a1' and kind not in ('payment_approved','payment_failed')), 1,
  'one marketing message per run per user');
select tests.as_service();
select is(private.push_automations(), 0, 'second run: nothing again (dedupe + 2-hour gap)');

-- Premium active after an owner-approved payment
select tests.as_user('00000000-0000-0000-0000-0000000015a1');
insert into tests.m select 'order_ok', (create_order('00000000-0000-0000-0000-0000000015f2') ->> 'order_id')::uuid;
reset role;
select tests.as_user('00000000-0000-0000-0000-0000000015a0');
select admin_mark_paid((select id from tests.m where k = 'order_ok'), '515115151515');
reset role;
select tests.as_service();
select is(private.push_automations(), 1, 'Premium active message');
select matches((select body from push_messages where kind = 'payment_approved'), '^Enjoy full videos & 2 TB cloud. Valid till [0-9]{2} [A-Z][a-z]{2} [0-9]{4}\.$', 'end date in India format');

-- daily message for a free user (after the 2-hour gap)
update push_messages set created_at = now() - interval '3 hours' where auto;
select tests.as_service();
select ok(private.push_automations() >= 1, 'daily run');
select ok(exists (select 1 from push_messages where kind = 'daily' and target_user = '00000000-0000-0000-0000-0000000015a2'
                    and dedupe_key = 'dy:00000000-0000-0000-0000-0000000015a2:' || to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD-HH24')),
  'daily message keyed by the IST hour');
select is((select count(*)::int from push_messages where kind = 'daily' and target_user = '00000000-0000-0000-0000-0000000015a3'), 0, 'premium users get no daily sales messages');

-- payment reminder for an unfinished order ~1 hour later
update push_messages set created_at = now() - interval '3 hours' where auto;
select tests.as_user('00000000-0000-0000-0000-0000000015a2');
insert into tests.m select 'order_wait', (create_order('00000000-0000-0000-0000-0000000015f2') ->> 'order_id')::uuid;
reset role;
update payment_orders set created_at = now() - interval '90 minutes' where id = (select id from tests.m where k = 'order_wait');
update payment_orders set created_at = now() - interval '1 day' where id = (select id from tests.m where k = 'order_fail');
select tests.as_service();
select ok(private.push_automations() >= 1, 'reminder run');
select is((select title from push_messages where kind = 'payment_reminder' and target_user = '00000000-0000-0000-0000-0000000015a2'), 'Your Year Plan is waiting', 'payment reminder');

-- new-video announcement (broadcast, post audience)
update push_settings set auto_enabled = true, auto_seen_at = now() - interval '1 day', daily_cap = 2 where id = 1;
select tests.as_service(); select push_tick(); reset role;
select is((select count(*)::int from push_messages where kind = 'new_videos'), 1, 'new video announced once');
select is((select audience from push_messages where kind = 'new_videos'), 'all', 'to the audience that can see it');
select tests.as_service(); select push_tick(); reset role;
select is((select count(*)::int from push_messages where kind = 'new_videos'), 1, 'not announced twice');

-- ===== admin =====
select tests.as_user('00000000-0000-0000-0000-0000000015a0');
select ok(admin_push_overview() ?& array['settings','phones','users','autos','daily_msgs','messages'], 'overview keys');
select is(jsonb_array_length(admin_push_overview() -> 'autos'), 8, 'eight automations');
select is(admin_push_overview() -> 'autos' -> 0 ->> 'kind', 'welcome', 'automations in Puffle order');
select is((select count(*)::int from jsonb_array_elements(admin_push_overview() -> 'messages') x where x ? 'target_user'), 0, 'per-user messages not listed');
select lives_ok($$ select admin_push_auto_save('welcome', false, 'Hi {title}', '{channel}') $$, 'edit an automation text');
select throws_ok($$ select admin_push_auto_save('nope', true, 'x', 'y') $$, 'Unknown automation');
select throws_ok($$ select admin_push_daily_save('{25}', '[]') $$, 'Pick at least one time');
select lives_ok($$ select admin_push_daily_save('{21,9,9}', '[{"pos":1,"title":"Top: {title}","body":"","enabled":true}]') $$, 'edit daily times and texts');
select lives_ok($$ select admin_push_settings_save(true, 3, 9, 3) $$, 'save switches');
reset role;
select is((select daily_hours from push_settings), '{9,21}'::int[], 'daily hours saved sorted');
select is((select enabled from push_auto where kind = 'welcome'), false, 'welcome switched off');
select ok(exists (select 1 from cron.job where jobname = 'push-tick' and schedule = '* * * * *'), 'push tick every minute');

select * from finish();
rollback;
