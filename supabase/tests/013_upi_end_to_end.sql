-- UPI order flow end to end: owner sets UPI ID + payee → create_order → proof / bank credit match → activation → my_status.
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
create table tests.o (k text primary key, id uuid, ref text, j jsonb);
grant all on tests.o to authenticated;

insert into auth.users (id, email, is_anonymous) values
  ('00000000-0000-0000-0000-0000000013a0', 'owner13@x.test', false),
  ('00000000-0000-0000-0000-0000000013a1', 'buyer13@x.test', false),
  ('00000000-0000-0000-0000-0000000013a2', 'other13@x.test', false);
insert into admins (user_id, role) values ('00000000-0000-0000-0000-0000000013a0', 'owner');
insert into private.user_sources values ('00000000-0000-0000-0000-0000000013a1', 'organic'), ('00000000-0000-0000-0000-0000000013a2', 'organic')
  on conflict (user_id) do nothing;
update plans set active = false where true;
insert into plans (id, code, name, price_inr, duration_days) values ('00000000-0000-0000-0000-0000000013f1', 'e2e_week', 'Week', 129, 7);
update app_mode set free_mode = false, plans_visible_for = 'everyone', free_plans_for = 'none' where true;
update payment_settings set upi_id = null, payee_name = null, enabled = true, activation_mode = 'manual' where true;

-- ===== 1. the owner edits UPI ID and payee (Admin › Payments) =====
select tests.as_user('00000000-0000-0000-0000-0000000013a1');
select is(payments_available(), false, 'no UPI ID yet → payments off');
select throws_ok($$ select create_order('00000000-0000-0000-0000-0000000013f1') $$, 'payments unavailable');
update payment_settings set upi_id = 'thief@okaxis', payee_name = 'Thief' where id;   -- RLS: buyers see no row
reset role;
select is((select upi_id from payment_settings), null, 'a buyer cannot change the UPI ID');

select tests.as_user('00000000-0000-0000-0000-0000000013a0');
update payment_settings set upi_id = '  owner.shop@okaxis ', payee_name = ' Owner Shop ' where id;
select is((select upi_id from payment_settings), 'owner.shop@okaxis', 'owner saved the UPI ID (trimmed)');
select is((select payee_name from payment_settings), 'Owner Shop', 'owner saved the payee name (trimmed)');
select throws_ok($$ update payment_settings set upi_id = 'not a upi id' where id $$, '23514', null, 'malformed UPI ID refused');
select ok((select count(*) from settings_audit where table_name = 'payment_settings' and field = 'upi_id') > 0, 'UPI change audited');
reset role;

-- ===== 2. create_order snapshots price, UPI ID and payee =====
select tests.as_user('00000000-0000-0000-0000-0000000013a1');
select is(plan_offers() ->> 'payee_name', 'Owner Shop', 'plans page shows "You will pay ₹X to Owner Shop"');
insert into tests.o select 'a', (j->>'order_id')::uuid, j->>'reference', j from (select create_order('00000000-0000-0000-0000-0000000013f1') j) x;
select is((select j->>'amount_paise' from tests.o where k='a'), '12900', 'amount from the server price');
select is((select j->>'upi_id' from tests.o where k='a'), 'owner.shop@okaxis', 'order pays the owner''s UPI ID');
select is((select j->>'payee_name' from tests.o where k='a'), 'Owner Shop', 'order shows the payee');
select matches((select ref from tests.o where k='a'), '^SK[0-9]{8}[0-9A-F]{8}$', 'reference SKyyyymmddXXXXXXXX');
select ok((select (j->>'expires_at')::timestamptz between now() + interval '29 minutes' and now() + interval '31 minutes' from tests.o where k='a'), 'expires in 30 minutes');
select is(create_order('00000000-0000-0000-0000-0000000013f1') ->> 'order_id', (select id::text from tests.o where k='a'), 'double tap reuses the open order');
select is(my_status() ->> 'is_premium', 'false', 'not premium before paying');
reset role;

-- a later price change never touches the open order
select tests.as_user('00000000-0000-0000-0000-0000000013a0');
update plans set price_inr = 149 where id = '00000000-0000-0000-0000-0000000013f1';
reset role;
select is((select amount_paise from payment_orders where id = (select id from tests.o where k='a')), 12900, 'price change does not change an existing order');
update plans set price_inr = 129 where id = '00000000-0000-0000-0000-0000000013f1';

-- ===== 3. the UPI app answers (cancelled), the buyer types the UTR =====
select tests.as_user('00000000-0000-0000-0000-0000000013a1');
select is(report_result((select id from tests.o where k='a'), 'Status=FAILURE_CANCELLED') ->> 'status', 'pending', 'cancelled in the UPI app → still waiting');
select is(submit_payment_proof((select ref from tests.o where k='a'), '12345') ->> 'status', 'error', 'bad UTR format refused');
select is(submit_payment_proof((select ref from tests.o where k='a'), '3131 3131 3131') ->> 'status', 'review', 'UTR accepted → verifying');
select is(order_status((select id from tests.o where k='a')) ->> 'status', 'review', 'order_status says verifying');
select is(my_status() ->> 'is_premium', 'false', 'still not premium: nobody verified the money');
reset role;

-- ===== 4. the bank's credit SMS arrives → matched by UTR → activated =====
select tests.as_service();
select is(bank_credit_received('313131313131', 12900, 'Rs 129.00 credited UPI Ref 313131313131') ->> 'result', 'paid', 'bank credit matches the UTR and amount');
reset role;
select is((select status from payment_orders where id = (select id from tests.o where k='a')), 'paid', 'order paid');
select is((select bank_verified from payment_orders where id = (select id from tests.o where k='a')), true, 'bank verified');
select is((select count(*)::int from subscriptions where order_id = (select id from tests.o where k='a')), 1, 'exactly one subscription');
select ok((select ends_at between now() + interval '7 days' - interval '1 minute' and now() + interval '7 days' + interval '1 minute'
             from subscriptions where order_id = (select id from tests.o where k='a')), 'plan lasts 7 days');
select ok((select array_agg(new_status order by id) from payment_order_events where order_id = (select id from tests.o where k='a'))
          @> array['pending','review','paid'], 'every status change logged');

select tests.as_user('00000000-0000-0000-0000-0000000013a1');
select is(order_status((select id from tests.o where k='a')) ->> 'status', 'paid', 'app sees paid');
select is(my_status() ->> 'is_premium', 'true', 'my_status: premium');
select is(my_status() ->> 'can_play_premium', 'true', 'my_status: can_play_premium');
select is(my_status() ->> 'has_plan', 'true', 'my_status: has plan');
select is(my_status() ->> 'plan_name', 'Week', 'my_status: plan name');
select is((my_status() ->> 'quota_bytes')::bigint, 2199023255552, 'my_status: 2 TB');
select is((select count(*)::int from payment_orders where user_id = '00000000-0000-0000-0000-0000000013a1'), 1, 'buyer sees own order history');
reset role;

-- ===== 5. renewal stacks on the current end date; a used UTR never pays twice =====
select tests.as_user('00000000-0000-0000-0000-0000000013a1');
insert into tests.o select 'b', (j->>'order_id')::uuid, j->>'reference', j from (select create_order('00000000-0000-0000-0000-0000000013f1') j) x;
select is(submit_payment_proof((select ref from tests.o where k='b'), '313131313131') ->> 'error', 'this UTR was already used for another payment', 'same UTR refused for a second order');
reset role;
select tests.as_user('00000000-0000-0000-0000-0000000013a0');
select lives_ok($$ select admin_mark_paid((select id from tests.o where k='b'), '424242424242') $$, 'owner marks the renewal paid with the bank UTR');
reset role;
select ok((select max(ends_at) from subscriptions where user_id = '00000000-0000-0000-0000-0000000013a1')
          > now() + interval '14 days' - interval '1 minute', 'renewal extends from the current end (14 days)');
select is((select bank_verified from payment_orders where id = (select id from tests.o where k='b')), true, 'mark paid counts as bank verified');

-- ===== 6. instant mode: the UPI app's SUCCESS for this exact order activates (owner checks later) =====
update payment_settings set activation_mode = 'instant' where true;
select tests.as_user('00000000-0000-0000-0000-0000000013a2');
insert into tests.o select 'c', (j->>'order_id')::uuid, j->>'reference', j from (select create_order('00000000-0000-0000-0000-0000000013f1') j) x;
select is(report_result((select id from tests.o where k='c'), 'Status=SUCCESS&txnRef=WRONGREF&ApprovalRefNo=515151515151') ->> 'status', 'pending',
  'SUCCESS for another reference is never activated');
select is(my_status() ->> 'is_premium', 'false', 'still not premium');
reset role;
select tests.as_user('00000000-0000-0000-0000-0000000013a2');
insert into tests.o select 'd', (j->>'order_id')::uuid, j->>'reference', j from (select create_order('00000000-0000-0000-0000-0000000013f1') j) x;
select is(report_result((select id from tests.o where k='d'), 'Status=SUCCESS&txnRef=' || (select ref from tests.o where k='d') || '&ApprovalRefNo=616161616161') ->> 'status',
  'paid', 'SUCCESS with this order''s reference → active now');
select is(my_status() ->> 'is_premium', 'true', 'instant buyer is premium');
reset role;
select tests.as_user('00000000-0000-0000-0000-0000000013a0');
select ok(exists (select 1 from admin_orders('verify_today') where id = (select id from tests.o where k='d')), 'instant order listed under "verify against bank"');
reset role;

-- ===== 7. clearing the UPI ID stops payments everywhere =====
select tests.as_user('00000000-0000-0000-0000-0000000013a0');
update payment_settings set upi_id = '' where id;
select is(payments_available(), false, 'Clear UPI ID → payments off');
reset role;

select * from finish();
rollback;
