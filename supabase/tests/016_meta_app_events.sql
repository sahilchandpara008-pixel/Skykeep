-- Meta: app events (MobileAppInstall, CompleteRegistration, ViewContent, InitiateCheckout, verified Purchase),
-- web Lead with dedupe, Meta app-ad referrers, admin settings (masked token), cron key / calls.
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
create table tests.o (k text primary key, id uuid, ref text);
grant all on tests.o to authenticated;
create function tests.ext() returns jsonb language sql as $$
  select '["a2","com.skykeep.app","10","1.0.5","14","Pixel 8","en_IN","IST","Jio","1080","2400","2.6","8","128","64","Asia/Kolkata"]'::jsonb $$;

insert into auth.users (id, email, is_anonymous) values
  ('00000000-0000-0000-0000-0000000016a0', 'owner16@x.test', false),
  ('00000000-0000-0000-0000-0000000016a1', null, true),     -- guest, will install from a Meta app ad on Google Play
  ('00000000-0000-0000-0000-0000000016a2', null, true),     -- organic Play install
  ('00000000-0000-0000-0000-0000000016a3', null, true);     -- ads APK, says no to advertising
insert into admins (user_id, role) values ('00000000-0000-0000-0000-0000000016a0', 'owner');
update plans set active = false where true;
insert into plans (id, code, name, price_inr, duration_days) values ('00000000-0000-0000-0000-0000000016f1', 'm16_gold', 'Gold', 259, 30);
update app_mode set free_mode = false, plans_visible_for = 'everyone' where true;
update payment_settings set upi_id = 'shop@okaxis', payee_name = 'Shop', activation_mode = 'instant' where true;

-- ===== owner settings: dataset, app id, token (secret) =====
select tests.as_user('00000000-0000-0000-0000-0000000016a1');
select throws_ok($$ select admin_meta_save(true, '1234567890', '987654321', null, 'EAAsecret') $$, '42501', null, 'only the owner edits Meta settings');
select is(meta_token_masked(), null, 'token hidden from users');
reset role;
select tests.as_user('00000000-0000-0000-0000-0000000016a0');
select lives_ok($$ select admin_meta_save(true, '1234567890', '987654321', 'TEST123', 'EAAsecretTOKEN9876') $$, 'owner saves dataset, app id, token');
select is(meta_token_masked(), '••••9876', 'token shown masked');
select lives_ok($$ select admin_meta_save(true, '1234567890', '987654321', 'TEST123', '') $$, 'empty token keeps the saved one');
select is(meta_token_masked(), '••••9876', 'token kept');
select is(admin_meta_overview() -> 'settings' ->> 'app_id', '987654321', 'overview shows the app id');
select ok(not (admin_meta_overview()::text like '%EAAsecret%'), 'overview never contains the token');
select ok(admin_meta_overview() ?& array['settings','funnel','recent','clicks_7d','auto_send'], 'overview keys');
reset role;
select is(meta_public(), '{"app_id": "987654321", "pixel_id": "1234567890"}'::jsonb, 'public ids for the website / app');
select is((select capi_token from private.meta_secrets), 'EAAsecretTOKEN9876', 'token stored privately');

-- ===== installs: Meta app ads from Google Play count as ads =====
select is(private.is_meta_referrer('utm_source=apps.facebook.com&utm_campaign=fb4a&utm_content=%7B%22app%22%3A1%7D'), true, 'apps.facebook.com referrer = Meta ad');
select is(private.is_meta_referrer('utm_source%3Dapps.facebook.com%26utm_campaign%3Dfb4a'), true, 'URL-encoded referrer too');
select is(private.is_meta_referrer('utm_source=instagram&utm_medium=paid'), true, 'instagram');
select is(private.is_meta_referrer('utm_source=google-play&utm_medium=organic'), false, 'Play organic is organic');
select is(private.is_meta_referrer(''), false, 'no referrer is organic');

select tests.as_user('00000000-0000-0000-0000-0000000016a1');
select is(record_install('inst16aaaaaaaaaa', 'play_ok', 'utm_source=apps.facebook.com&utm_campaign=fb4a', 'secret-16-aaaaaaaaaaaa'), 'ads', 'Meta app ad install → ads');
reset role;
select tests.as_user('00000000-0000-0000-0000-0000000016a2');
select is(record_install_attribution('inst16bbbbbbbbbb', 'play_ok', 'utm_source=google-play&utm_medium=organic', 'secret-16-bbbbbbbbbbbb'), 'organic', 'Play organic (Puffle RPC name)');
reset role;
select tests.as_user('00000000-0000-0000-0000-0000000016a3');
select is(record_install('inst16cccccccccc', 'apk_define', 'utm_source=meta&utm_campaign=x', 'secret-16-cccccccccccc'), 'ads', 'ads APK');
select lives_ok($$ select set_measurement_preferences(false, false) $$, 'user says no to advertising');
reset role;
select is((select status from meta_events where event_id = 'install_inst16aaaaaaaaaa'), 'queued', 'MobileAppInstall queued for the ads install');
select is((select event_name from meta_events where event_id = 'install_inst16aaaaaaaaaa'), 'MobileAppInstall', 'event name');
select is((select count(*)::int from meta_events where user_id = '00000000-0000-0000-0000-0000000016a2'), 0, 'organic install never reported');
select is((select status from meta_events where event_id = 'install_inst16cccccccccc'), 'suppressed', 'turning advertising off suppresses queued events');

-- ===== app context =====
select tests.as_user('00000000-0000-0000-0000-0000000016a1');
select throws_ok($$ select set_measurement_preferences(true, true, jsonb_build_object('install_id', 'inst16aaaaaaaaaa', 'extinfo', '["a2","com.other.app"]'::jsonb)) $$,
  'valid Android app context required');
select throws_ok($$ select set_measurement_preferences(true, true, jsonb_build_object('install_id', 'inst16bbbbbbbbbb', 'extinfo', tests.ext())) $$,
  'valid Android app context required');
select is(set_measurement_preferences(true, true, jsonb_build_object('install_id', 'inst16aaaaaaaaaa', 'extinfo', tests.ext())) ->> 'advertising', 'true', 'context saved');
reset role;
select is((select app_data -> 'extinfo' ->> 1 from meta_events where event_id = 'install_inst16aaaaaaaaaa'), 'com.skykeep.app', 'queued install got the app context');
select is((select anon_id from meta_events where event_id = 'install_inst16aaaaaaaaaa'), 'inst16aaaaaaaaaa', 'anon_id = install id');

-- ViewContent (no private data), other activity not sent
select tests.as_user('00000000-0000-0000-0000-0000000016a1');
select is(record_activity('00000000-0000-0000-0000-00000016e001', 'ViewContent', '00000000-0000-0000-0000-00000016e0ff',
  '{"screen":"Post","media_type":"video","premium":true,"title":"secret name"}'), true, 'ViewContent recorded');
select is(record_activity('00000000-0000-0000-0000-00000016e001', 'ViewContent', '00000000-0000-0000-0000-00000016e0ff'), false, 'same event id twice → once');
select is(record_activity('00000000-0000-0000-0000-00000016e002', 'AppOpen', '00000000-0000-0000-0000-00000016e0ff'), true, 'AppOpen recorded');
select throws_ok($$ select record_activity(gen_random_uuid(), 'Purchase', gen_random_uuid()) $$, 'event is not permitted');
select lives_ok($$ select record_ad_ids('inst16aaaaaaaaaa', 'XZ1.anon-id', '38400000-8cf0-11bd-b23e-10b96e40000d') $$, 'ad ids saved');
reset role;
select is((select custom_data from meta_events where event_id = 'activity-00000000-0000-0000-0000-00000016e001'),
  '{"screen": "Post", "premium": true, "media_type": "video"}'::jsonb, 'ViewContent carries only allow-listed fields');
select is((select count(*)::int from meta_events where user_id = '00000000-0000-0000-0000-0000000016a1' and event_name not in ('MobileAppInstall','ViewContent')), 0, 'AppOpen not sent to Meta');
select is((select ad_id from installs where install_id = 'inst16aaaaaaaaaa'), '38400000-8cf0-11bd-b23e-10b96e40000d', 'advertising id stored with permission');

-- CompleteRegistration (guest adds email)
update auth.users set is_anonymous = false, email = 'ads16@x.test' where id = '00000000-0000-0000-0000-0000000016a1';
select is((select event_name from meta_events where event_id = 'reg_00000000-0000-0000-0000-0000000016a1'), 'CompleteRegistration', 'CompleteRegistration queued');

-- ===== checkout and purchase =====
select tests.as_user('00000000-0000-0000-0000-0000000016a1');
insert into tests.o select 'a', (j->>'order_id')::uuid, j->>'reference' from (select create_order('00000000-0000-0000-0000-0000000016f1') j) x;
select is(report_result((select id from tests.o where k='a'), 'Status=SUCCESS&ApprovalRefNo=616116161616&txnRef=' || (select ref from tests.o where k='a')) ->> 'status', 'paid', 'instant activation');
reset role;
select is((select value_inr from meta_events where event_id = 'checkout_' || (select id from tests.o where k='a')), 259.00, 'InitiateCheckout with the order amount');
select is((select count(*)::int from meta_events where event_name = 'Purchase'), 0, 'no Purchase from the phone''s SUCCESS');
select tests.as_user('00000000-0000-0000-0000-0000000016a0');
select admin_confirm_bank((select id from tests.o where k='a'));
reset role;
select is((select value_inr from meta_events where event_id = 'order_' || (select id from tests.o where k='a')), 259.00, 'Purchase after the owner verified it (order amount)');
select is((select custom_data ->> 'order_id' from meta_events where event_id = 'order_' || (select id from tests.o where k='a')), (select id::text from tests.o where k='a'), 'Purchase carries the order id');
select tests.as_user('00000000-0000-0000-0000-0000000016a0');
select admin_revoke_order((select id from tests.o where k='a'), 'refund');
reset role;
select is((select status from meta_events where event_id = 'order_' || (select id from tests.o where k='a')), 'suppressed', 'revoked order: Purchase never sent');

-- ===== sending =====
select tests.as_service();
create temp table c1 as select * from meta_claim_batch(50);
reset role;
select is((select count(*)::int from c1 where event_name = 'MobileAppInstall'), 1, 'install claimed (has app context)');
select is((select count(*)::int from c1 where event_name = 'Purchase'), 0, 'suppressed purchase not claimed');
select tests.as_service();
select is((select count(*)::int from meta_claim_batch(50)), 0, 'leased events are not claimed twice');
select lives_ok($$ select meta_finish((select id from c1 where event_name = 'MobileAppInstall'), 'sent', null, 'trace1') $$, 'sent');
select lives_ok($$ select meta_finish((select id from c1 where event_name = 'ViewContent'), 'retry', 'HTTP 500') $$, 'retry later');
reset role;
select is((select status from meta_events where id = (select id from c1 where event_name = 'MobileAppInstall')), 'sent', 'marked sent');
select is((select status from meta_events where id = (select id from c1 where event_name = 'ViewContent')), 'queued', 'back in the queue');
select ok((select next_attempt_at > now() from meta_events where id = (select id from c1 where event_name = 'ViewContent')), 'with back-off');
select tests.as_user('00000000-0000-0000-0000-0000000016a1');
select throws_ok($$ select meta_claim_batch(1) $$, '42501', null, 'apps cannot claim');
select throws_ok($$ select meta_sender_config() $$, '42501', null, 'apps cannot read the sender config');
reset role;

-- ===== website Lead with dedupe =====
select tests.as_service();
select is(record_web_attribution('Lead', '00000000-0000-0000-0000-00000016b001', true, '203.0.113.9', 'Mozilla', 'https://evil.example/d'), false, 'other sites refused');
select is(record_web_attribution('Lead', '00000000-0000-0000-0000-00000016b001', false, '203.0.113.9', 'Mozilla', 'https://skykeep.vercel.app/d'), false, 'no consent → nothing');
select is(record_web_attribution('Lead', '00000000-0000-0000-0000-00000016b001', true, '203.0.113.9', 'Mozilla', 'https://skykeep-web.vercel.app/d?fbclid=x', 'fb.1.1.abc', 'fb.1.2.def'), true, 'Lead from the download page');
select is(record_web_attribution('Lead', '00000000-0000-0000-0000-00000016b001', true, '203.0.113.9', 'Mozilla', 'https://skykeep.vercel.app/d'), false, 'same event id twice → once');
reset role;
select is((select event_id || ' ' || action_source || ' ' || source_url from meta_events where event_name = 'Lead'),
  'web-00000000-0000-0000-0000-00000016b001 website https://skykeep-web.vercel.app/d', 'event id web-<uuid> (Pixel eventID), URL without query');
select is((select count(*)::int from ad_clicks where event_id = '00000000-0000-0000-0000-00000016b001'), 1, 'click stored for matching');
set local role anon;
select throws_ok($$ select record_web_attribution('Lead', gen_random_uuid(), true, '1.1.1.1', 'x', 'https://skykeep.vercel.app/d') $$, '42501', null, 'browsers cannot call the server RPC');
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.7, 10.0.0.1", "user-agent": "Mobile Safari"}', true);
select is(record_web_measurement('Lead', '00000000-0000-0000-0000-00000016b002', true, 'abc', '', '', 'https://skykeep.vercel.app/d'), true, 'browser variant');
reset role;
select is((select client_ip from meta_events where event_id = 'web-00000000-0000-0000-0000-00000016b002'), '198.51.100.7', 'browser IP from the request');

-- dataset change => nothing old is replayed to the new dataset
select tests.as_user('00000000-0000-0000-0000-0000000016a0');
select admin_meta_save(true, '5555555555', '987654321', null, null);
reset role;
select is((select count(*)::int from meta_events where status = 'queued'), 0, 'queued events suppressed after the dataset changed');

-- ===== cron key and calls =====
select ok(exists (select 1 from cron.job where jobname = 'meta-send' and schedule = '*/5 * * * *'), 'meta-send every 5 minutes');
select ok(length((select key from private.meta_cron)) = 64, 'cron key generated in the database');
select tests.as_service();
select is(meta_cron_ok((select key from private.meta_cron)), true, 'right key accepted');
select is(meta_cron_ok('wrong'), false, 'wrong key refused');
select is(meta_cron_ok(''), false, 'empty key refused');
reset role;
select is(private.call_function('push-send'), false, 'no URL saved → nothing is called');
create table tests.k as select key from private.meta_cron;
grant select on tests.k to authenticated;
select tests.as_user('00000000-0000-0000-0000-0000000016a0');
select throws_ok($$ select admin_set_cron_url('https://evil.example/functions/v1/meta-send') $$, 'use https://<project ref>.supabase.co/functions/v1/meta-send');
select lives_ok($$ select admin_set_cron_url('https://vzeehoissxdutmxdezjf.supabase.co/functions/v1/meta-send') $$, 'owner saves the function address');
select is(admin_cron_status() ->> 'url_set', 'true', 'cron status');
select ok(not (admin_cron_status()::text like '%' || (select key from tests.k) || '%'), 'status never shows the key');
reset role;
select is(private.call_function('push-send'), true, 'call queued');
select ok(exists (select 1 from net.http_request_queue where url = 'https://vzeehoissxdutmxdezjf.supabase.co/functions/v1/push-send'
                    and headers ->> 'x-cron-key' = (select key from private.meta_cron)), 'POST to push-send with x-cron-key');
select tests.as_user('00000000-0000-0000-0000-0000000016a1');
select throws_ok($$ select admin_set_cron_url('') $$, '42501', null, 'users cannot change it');
select throws_ok($$ select meta_cron_ok('x') $$, '42501', null, 'users cannot test keys');
reset role;

select * from finish();
rollback;
