-- Flixvault content in SkyKeep: the same ads/organic split as Flixvault and Puffle.
--
-- * Anyone who came from an ad (install source = ads), guest or member, sees ads + "all" content.
-- * Approved organic users with full access (docs/rules.md) are treated as ads users, like Puffle.
-- * Everyone else is organic and sees organic + "all" content. Ads content is never shown to organic users.
--
-- This only changes the Flixvault copy (flixvault_* tables, fv_audience, flixvault-feed and push targeting
-- of Flixvault content). SkyKeep's own channels/posts rules (can_see_audience / has_ads_access) are unchanged.

create or replace function private.fv_is_ads(p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_uid is not null and (public.is_admin(p_uid) or public.source_of(p_uid) = 'ads' or public.has_ads_access(p_uid))
$$;
revoke execute on function private.fv_is_ads(uuid) from public, anon, authenticated;

create or replace function public.fv_audience()
returns text language sql stable security definer set search_path = '' as $$
  select case when private.fv_is_ads(auth.uid()) then 'ads' else 'organic' end
$$;
revoke execute on function public.fv_audience() from public, anon;
grant execute on function public.fv_audience() to authenticated;

-- one audience per user, exactly like Puffle: 'all' + the user's own audience
drop policy if exists fv_channels_read on public.flixvault_channels;
create policy fv_channels_read on public.flixvault_channels for select to authenticated
  using ((select public.is_admin())
         or (not hidden and (audience = 'all' or audience = (select public.fv_audience()))));

drop policy if exists fv_posts_read on public.flixvault_posts;
create policy fv_posts_read on public.flixvault_posts for select to authenticated
  using ((select public.is_admin())
         or (not hidden and (audience = 'all' or audience = (select public.fv_audience()))
             and exists (select 1 from public.flixvault_channels c where c.id = channel_id)));

-- Push: Flixvault content is picked per user with the same rule.
-- private.fv_aud_ok(aud, src, ads) is called with "ads" = this user's Flixvault ads flag.
create or replace function private.fv_aud_ok(p_aud text, p_src text, p_ads boolean)
returns boolean language sql immutable set search_path = '' as $$
  select p_aud = 'all' or (p_aud = 'ads' and p_ads) or (p_aud = 'organic' and not p_ads)
$$;

do $$
declare d text;
begin
  -- marketing loop: per-user ads flag
  select pg_get_functiondef('private.push_automations()'::regprocedure) into d;
  if position('public.has_ads_access(t.user_id) ads' in d) > 0 then
    execute replace(d, 'public.has_ads_access(t.user_id) ads', 'private.fv_is_ads(t.user_id) ads');
  end if;
end $$;

do $$
declare f oid; d text;
begin
  -- deliveries to the "ads" audience reach everyone who came from an ad (guests too), like Flixvault
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where p.prokind = 'f' and n.nspname in ('public', 'private')
              and pg_get_functiondef(p.oid) like '%when ''ads''     then public.can_see_audience(''ads'', t.user_id)%'
  loop
    d := pg_get_functiondef(f);
    d := replace(d, 'when ''ads''     then public.can_see_audience(''ads'', t.user_id)',
                    'when ''ads''     then private.fv_is_ads(t.user_id)');
    execute d;
  end loop;
end $$;
