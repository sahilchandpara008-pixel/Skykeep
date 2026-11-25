-- Minimal stand-ins for Supabase-managed schemas (local PGlite check only).
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth; create schema storage; create schema cron; create schema extensions;
grant usage on schema auth, storage, public, extensions to anon, authenticated, service_role;
alter default privileges in schema extensions grant execute on functions to anon, authenticated;

create table auth.users (id uuid primary key, email text, is_anonymous boolean default false, created_at timestamptz default now());
create function auth.uid() returns uuid language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
create function auth.jwt() returns jsonb language sql stable as $$ select '{}'::jsonb $$;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;

create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as
  $$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
grant all on storage.objects to anon, authenticated;
grant select on storage.buckets to anon, authenticated;

create table cron.job (jobid bigserial primary key, jobname text unique, schedule text, command text);
create function cron.schedule(a text, b text, c text) returns bigint language sql as
  $$ insert into cron.job (jobname, schedule, command) values (a, b, c)
     on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command returning jobid $$;
create function cron.unschedule(a text) returns boolean language sql as $$ delete from cron.job where jobname = a returning true $$;

-- pg_net stand-in: remembers the requests instead of sending them
create schema net;
create table net.http_request_queue (id bigserial primary key, url text, headers jsonb, body jsonb, created_at timestamptz default now());
create function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds integer default 5000) returns bigint
  language sql as $$ insert into net.http_request_queue (url, headers, body) values (url, headers, body) returning id $$;

alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
