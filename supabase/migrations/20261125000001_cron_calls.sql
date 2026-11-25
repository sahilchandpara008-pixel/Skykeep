-- Database-driven calls to our own edge functions (like Puffle's private.meta_cron):
--  * pg_net lets pg_cron jobs POST to an edge function.
--  * private.meta_cron holds ONE row: the meta-send URL of THIS project and a random key generated here in the
--    database (never in source). Jobs send the key as header x-cron-key; functions check it with meta_cron_ok().
--  * Until the owner saves the URL (admin_set_cron_url or SQL, see docs/setup.md) no job calls anything.
create extension if not exists pg_net with schema extensions;

create table if not exists private.meta_cron (
  id  int primary key default 1 check (id = 1),
  key text not null default encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex'),
  url text not null default ''   -- https://<this project>.supabase.co/functions/v1/meta-send
);
insert into private.meta_cron (id) values (1) on conflict do nothing;
alter table private.meta_cron enable row level security;

-- edge functions (service role) check the x-cron-key header with this
create or replace function public.meta_cron_ok(p_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(p_key, '') <> '' and exists (select 1 from private.meta_cron where id = 1 and key = p_key)
$$;
revoke all on function public.meta_cron_ok(text) from public, anon, authenticated;
grant execute on function public.meta_cron_ok(text) to service_role;

-- POST {} to one of our edge functions (async; pg_net). Never raises: a job must not break the caller.
create or replace function private.call_function(p_name text, p_body jsonb default '{}'::jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
declare c private.meta_cron;
begin
  if p_name !~ '^[a-z0-9-]{2,40}$' then return false; end if;
  select * into c from private.meta_cron where id = 1;
  if c.url is null or c.url !~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/meta-send$' then return false; end if;
  perform net.http_post(url := replace(c.url, '/meta-send', '/' || p_name), body := coalesce(p_body, '{}'::jsonb),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', c.key),
    timeout_milliseconds := 55000);
  return true;
exception when others then
  raise warning 'call_function % failed: %', p_name, sqlerrm;
  return false;
end $$;

-- owner: save this project's function address once (the key never leaves the database)
create or replace function public.admin_set_cron_url(p_url text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_owner();
  if coalesce(p_url, '') <> '' and p_url !~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/meta-send$' then
    raise exception 'use https://<project ref>.supabase.co/functions/v1/meta-send';
  end if;
  update private.meta_cron set url = coalesce(p_url, '') where id = 1;
end $$;

-- owner: are the automatic jobs wired? (no key, no URL returned)
create or replace function public.admin_cron_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_owner();
  return jsonb_build_object(
    'url_set', (select url <> '' from private.meta_cron where id = 1),
    'jobs', coalesce((select jsonb_agg(jsonb_build_object('name', j.jobname, 'schedule', j.schedule) order by j.jobname)
                        from cron.job j), '[]'::jsonb));
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.admin_set_cron_url(text), public.admin_cron_status() from public, anon;
grant execute on function public.admin_set_cron_url(text), public.admin_cron_status() to authenticated;
