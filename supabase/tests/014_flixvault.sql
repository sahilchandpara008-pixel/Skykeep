-- Flixvault mirror: sync, SkyKeep audience rules, read RPCs (Puffle JSON shapes), follows/blocks/reports, admin.
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

insert into auth.users (id, email, is_anonymous) values
  ('00000000-0000-0000-0000-0000000014a0', 'admin14@x.test', false),
  ('00000000-0000-0000-0000-0000000014a1', 'ads14@x.test', false),
  ('00000000-0000-0000-0000-0000000014a2', 'org14@x.test', false),
  ('00000000-0000-0000-0000-0000000014a3', null, true);           -- guest from an ad (no ads access)
insert into admins (user_id, role) values ('00000000-0000-0000-0000-0000000014a0', 'content');
insert into private.user_sources values ('00000000-0000-0000-0000-0000000014a1', 'ads'),
  ('00000000-0000-0000-0000-0000000014a2', 'organic'), ('00000000-0000-0000-0000-0000000014a3', 'ads')
  on conflict (user_id) do nothing;
update profiles set is_guest = false where id in ('00000000-0000-0000-0000-0000000014a1', '00000000-0000-0000-0000-0000000014a2');

-- snapshot: channel A (all), B (ads), C (organic); posts with the same audiences
create function tests.snap(p_extra boolean default true) returns jsonb language sql as $$
  select jsonb_build_object(
    'channels', jsonb_build_array(
      jsonb_build_object('id', '00000000-0000-0000-0000-00000000c0a1', 'name', 'Alpha', 'audience', 'all', 'members_count', 50, 'rating', 4.1, 'created_at', '2026-11-01T00:00:00Z'),
      jsonb_build_object('id', '00000000-0000-0000-0000-00000000c0b1', 'name', 'Bravo', 'audience', 'ads', 'members_count', 10, 'rating', 4.9, 'created_at', '2026-11-20T00:00:00Z'),
      jsonb_build_object('id', '00000000-0000-0000-0000-00000000c0c1', 'name', 'Charlie', 'audience', 'organic', 'members_count', 5, 'rating', 3.0, 'created_at', '2026-11-10T00:00:00Z')),
    'folders', jsonb_build_array(
      jsonb_build_object('id', '00000000-0000-0000-0000-00000000f0a1', 'channel_id', '00000000-0000-0000-0000-00000000c0a1', 'name', 'Season 1', 'position', 1)),
    'posts', jsonb_build_array(
      jsonb_build_object('id', '00000000-0000-0000-0000-00000000d0a1', 'channel_id', '00000000-0000-0000-0000-00000000c0a1', 'folder_id', '00000000-0000-0000-0000-00000000f0a1',
        'title', 'Alpha one', 'audience', 'all', 'published_at', '2026-11-24T10:00:00Z', 'view_count', 900, 'like_count', 5,
        'items', jsonb_build_array(jsonb_build_object('id', '00000000-0000-0000-0000-00000000e0a1', 'kind', 'video', 'is_premium', true,
                   'thumb_url', 'https://img.test/a.jpg', 'duration_s', 120, 'position', 0, 'playable', true, 'has_preview', true))),
      jsonb_build_object('id', '00000000-0000-0000-0000-00000000d0a2', 'channel_id', '00000000-0000-0000-0000-00000000c0a1',
        'title', 'Alpha ads only', 'audience', 'ads', 'published_at', '2026-11-24T11:00:00Z', 'view_count', 10, 'like_count', 50, 'items', '[]'::jsonb),
      jsonb_build_object('id', '00000000-0000-0000-0000-00000000d0b1', 'channel_id', '00000000-0000-0000-0000-00000000c0b1',
        'title', 'Bravo clip', 'audience', 'all', 'published_at', '2026-11-23T10:00:00Z', 'items', '[]'::jsonb),
      jsonb_build_object('id', '00000000-0000-0000-0000-00000000d0c1', 'channel_id', '00000000-0000-0000-0000-00000000c0c1',
        'title', 'Charlie clip', 'audience', 'all', 'published_at', '2026-11-22T10:00:00Z', 'items', '[]'::jsonb))
    || case when p_extra then jsonb_build_array(
      jsonb_build_object('id', '00000000-0000-0000-0000-00000000d0a9', 'channel_id', '00000000-0000-0000-0000-00000000c0a1',
        'title', 'Alpha old', 'audience', 'all', 'published_at', '2026-11-01T10:00:00Z', 'items', '[]'::jsonb)) else '[]'::jsonb end)
$$;

-- ===== sync =====
select tests.as_user('00000000-0000-0000-0000-0000000014a1');
select throws_ok($$ select flixvault_apply('{}'::jsonb) $$, '42501', null, 'apps cannot write the copy');
select throws_ok($$ select flixvault_feed_url() $$, '42501', null, 'apps cannot read the feed address');
reset role;
select tests.as_service();
select is(flixvault_apply(tests.snap()) ->> 'posts', '5', 'snapshot applied');
select is(flixvault_apply('{"channels": []}'::jsonb) ->> 'reason', 'empty', 'empty snapshot never wipes the copy');
select is((select count(*)::int from flixvault_posts), 5, 'copy intact after an empty answer');
update flixvault_posts set first_seen_at = now() - interval '1 day' where id = '00000000-0000-0000-0000-00000000d0a1';
select is(flixvault_apply(tests.snap(false)) ->> 'posts', '4', 'second snapshot');
select is((select count(*)::int from flixvault_posts where id = '00000000-0000-0000-0000-00000000d0a9'), 0, 'post gone from Flixvault → gone here');
select ok((select first_seen_at < now() - interval '1 hour' from flixvault_posts where id = '00000000-0000-0000-0000-00000000d0a1'), 'first_seen_at kept across syncs');
select lives_ok($$ select flixvault_sync_failed('boom') $$, 'failure recorded');
reset role;
select ok(exists (select 1 from cron.job where jobname = 'flixvault-sync' and schedule = '*/10 * * * *'), 'sync every 10 minutes');

-- ===== audience rules =====
select tests.as_user('00000000-0000-0000-0000-0000000014a1');   -- ads member
select is(fv_audience(), 'ads', 'ads member asks Flixvault as ads');
select is((select count(*)::int from flixvault_channels), 2, 'ads member: all + ads channels');
select is((select count(*)::int from flixvault_posts), 3, 'ads member: posts of visible channels, no organic channel');
select is((select count(*)::int from flixvault_items), 1, 'items follow their posts');
reset role;

select tests.as_user('00000000-0000-0000-0000-0000000014a2');   -- organic member
select is(fv_audience(), 'organic', 'organic member asks as organic');
select is((select array_agg(name order by name) from flixvault_channels), array['Alpha','Charlie'], 'organic: all + organic channels');
select is((select count(*)::int from flixvault_posts where audience = 'ads'), 0, 'organic: ads posts hidden');
reset role;

select tests.as_user('00000000-0000-0000-0000-0000000014a3');   -- ads guest: no ads access, not organic
select is((select array_agg(name order by name) from flixvault_channels), array['Alpha'], 'ads guest: audience=all only');
reset role;

update profiles set ads_access_status = 'approved' where id = '00000000-0000-0000-0000-0000000014a2';
update app_mode set free_mode = true where true;
select tests.as_user('00000000-0000-0000-0000-0000000014a2');
select is((select count(*)::int from flixvault_channels), 3, 'approved organic (free mode): ads channels too');
reset role;
update profiles set ads_access_status = 'none' where id = '00000000-0000-0000-0000-0000000014a2';
update app_mode set free_mode = false where true;

set local role anon;
select throws_ok($$ select count(*) from flixvault_posts $$, '42501', null, 'anon has no access');
reset role;

-- ===== read RPCs (Puffle shapes) =====
select tests.as_user('00000000-0000-0000-0000-0000000014a1');
select is(jsonb_array_length(fv_explore()), 3, 'explore lists visible posts');
select is(fv_explore('popular') -> 0 ->> 'title', 'Alpha ads only', 'popular = most likes first');
select is(fv_explore('most_watched') -> 0 ->> 'title', 'Alpha one', 'most_watched = most views first');
select is(jsonb_array_length(fv_explore('all', 0, 30, 'bravo')), 1, 'search by channel name');
select is(jsonb_array_length(fv_explore('all', 0, 30, '%')), 0, 'search escapes wildcards');
select ok((fv_explore('most_watched') -> 0) ?& array['id','channel_id','folder_id','title','caption','published_at','view_count','like_count','channel','items'], 'post JSON keys');
select ok((fv_explore('most_watched') -> 0 -> 'items' -> 0) ?& array['id','kind','is_premium','thumb_url','duration_s','width','height','position','playable','has_preview'], 'item JSON keys');
select is(fv_channels('top') -> 0 ->> 'name', 'Bravo', 'top rated first');
select is(fv_channels('latest') -> 0 ->> 'name', 'Bravo', 'latest first');
select is(fv_channels() -> 0 ->> 'name', 'Alpha', 'trending = most members');
select ok((fv_channels() -> 0) ?& array['id','name','description','category','icon_url','members_count','rating','created_at'], 'channel JSON keys');
select is(fv_channel('00000000-0000-0000-0000-00000000c0a1') -> 'folders' -> 0 ->> 'name', 'Season 1', 'channel has folders');
select is(jsonb_array_length(fv_channel('00000000-0000-0000-0000-00000000c0a1') -> 'posts'), 2, 'channel posts');
select is(fv_channel('00000000-0000-0000-0000-00000000c0c1'), null, 'invisible channel → null (not found)');
select is(fv_post('00000000-0000-0000-0000-00000000d0a1') ->> 'folder_id', '00000000-0000-0000-0000-00000000f0a1', 'post has folder_id');

-- follows / blocks / reports are the user's own
insert into flixvault_follows (channel_id) values ('00000000-0000-0000-0000-00000000c0a1'), ('00000000-0000-0000-0000-00000000c0b1');
select is(jsonb_array_length(fv_following()), 3, 'following: posts of followed channels');
insert into flixvault_blocks (channel_id) values ('00000000-0000-0000-0000-00000000c0b1');
select is(jsonb_array_length(fv_following()), 2, 'blocked channel left out of following');
select is((select array_agg(c.name) from flixvault_blocks b join flixvault_channels c on c.id = b.channel_id), array['Bravo'], 'blocked-channels list with names');
insert into flixvault_reports (post_id, reason) values ('00000000-0000-0000-0000-00000000d0a1', 'Spam');
select is((select count(*)::int from flixvault_reports), 0, 'users cannot read reports');
select throws_ok($$ insert into flixvault_reports (user_id, post_id, reason) values ('00000000-0000-0000-0000-0000000014a2', gen_random_uuid(), 'x') $$,
  '42501', null, 'cannot report as someone else');
update flixvault_channels set hidden = true where id = '00000000-0000-0000-0000-00000000c0a1';
reset role;
select is((select hidden from flixvault_channels where id = '00000000-0000-0000-0000-00000000c0a1'), false, 'non-admin cannot hide');

select tests.as_user('00000000-0000-0000-0000-0000000014a2');
select is((select count(*)::int from flixvault_follows), 0, 'other users'' follows are private');
reset role;

-- ===== admin =====
select tests.as_user('00000000-0000-0000-0000-0000000014a0');
select is((select count(*)::int from flixvault_reports), 1, 'admin reads reports');
update flixvault_posts set hidden = true where id = '00000000-0000-0000-0000-00000000d0a1';
select is(admin_flixvault_set_hidden('channel', '00000000-0000-0000-0000-00000000c0b1', true), true, 'admin hides a channel (RPC)');
select is((admin_flixvault_sync() ->> 'hidden_posts')::int, 1, 'sync status: hidden posts');
select is((admin_flixvault_sync() ->> 'reports_7d')::int, 1, 'sync status: reports');
select is(admin_flixvault_sync() ->> 'error', 'boom', 'sync status: last error');
select ok(admin_flixvault_sync() ?& array['last_run','last_ok','channels','posts','error','hidden_channels','hidden_posts','follows','reports_7d'], 'sync status keys');
select is((select follows from admin_flixvault_channel_stats() where channel_id = '00000000-0000-0000-0000-00000000c0a1'), 1::bigint, 'channel stats: follows');
select is((select reports from admin_flixvault_channel_stats() where channel_id = '00000000-0000-0000-0000-00000000c0a1'), 1::bigint, 'channel stats: reports');
reset role;
select tests.as_service();
select flixvault_apply(tests.snap(false));
reset role;
select is((select hidden from flixvault_posts where id = '00000000-0000-0000-0000-00000000d0a1'), true, 'sync keeps the admin''s hide');
select tests.as_user('00000000-0000-0000-0000-0000000014a1');
select is((select count(*)::int from flixvault_posts where id = '00000000-0000-0000-0000-00000000d0a1'), 0, 'hidden post gone for users');
select is((select count(*)::int from flixvault_channels where name = 'Bravo'), 0, 'hidden channel gone for users');
select throws_ok($$ select admin_flixvault_sync() $$, 'Admins only');
reset role;

select * from finish();
rollback;
