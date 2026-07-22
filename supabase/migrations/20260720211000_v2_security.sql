-- Central authorization helpers and non-recursive RLS policies.

create or replace function public.is_app_admin(check_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select check_user_id is not null
    and exists (
      select 1 from public.app_admins aa
      where aa.user_id = check_user_id
    );
$$;

create or replace function public.is_accepted_group_member(
  check_group_id bigint,
  check_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select check_user_id is not null
    and exists (
      select 1
      from public.groups g
      where g.id = check_group_id
        and g.owner_id = check_user_id
    )
    or exists (
      select 1
      from public.group_members gm
      where gm.group_id = check_group_id
        and gm.user_id = check_user_id
        and gm.status = 'accepted'
        and gm.left_at is null
    );
$$;

create or replace function public.can_view_session(
  check_session_id bigint,
  check_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select check_user_id is not null and exists (
    select 1
    from public.sessions s
    where s.id = check_session_id
      and (
        s.user_id = check_user_id
        or s.current_host_id = check_user_id
        or exists (
          select 1
          from public.session_players sp
          where sp.session_id = s.id
            and sp.profile_id = check_user_id
            and sp.accepted_at is not null
            and sp.removed_at is null
        )
        or (
          s.group_id is not null
          and public.is_accepted_group_member(s.group_id, check_user_id)
        )
        or (
          s.ledger_version = 1
          and exists (
            select 1
            from public.session_groups sg
            where sg.session_id = s.id
              and public.is_accepted_group_member(sg.group_id, check_user_id)
          )
        )
      )
  );
$$;

create or replace function public.can_edit_session(
  check_session_id bigint,
  check_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select check_user_id is not null and exists (
    select 1
    from public.sessions s
    where s.id = check_session_id
      and s.phase not in (
        'finalized',
        'owner_unavailable_read_only',
        'orphaned_read_only',
        'cancelled'
      )
      and (
        s.current_host_id = check_user_id
        or (
          s.current_host_id is null
          and s.user_id = check_user_id
          and s.ledger_version = 1
        )
      )
  );
$$;

revoke all on function public.is_app_admin(uuid) from public;
revoke all on function public.is_accepted_group_member(bigint, uuid) from public;
revoke all on function public.can_view_session(bigint, uuid) from public;
revoke all on function public.can_edit_session(bigint, uuid) from public;
grant execute on function public.is_app_admin(uuid) to authenticated;
grant execute on function public.is_accepted_group_member(bigint, uuid) to authenticated;
grant execute on function public.can_view_session(bigint, uuid) to authenticated;
grant execute on function public.can_edit_session(bigint, uuid) to authenticated;

do $$
declare
  policy_row record;
begin
  for policy_row in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in (
        'profiles',
        'sessions',
        'session_players',
        'players',
        'rebuys',
        'groups',
        'group_members',
        'session_groups',
        'quick_add_entries',
        'follows',
        'app_settings',
        'game_invitations',
        'group_invitations',
        'ledger_events',
        'finalization_revisions',
        'settlement_transfers',
        'user_notifications'
      )
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      policy_row.policyname,
      policy_row.schemaname,
      policy_row.tablename
    );
  end loop;
end;
$$;

alter table public.profiles enable row level security;
alter table public.deleted_user_group_ownership enable row level security;
alter table public.deleted_user_group_members enable row level security;
alter table public.deleted_user_follows enable row level security;
alter table public.deleted_user_player_links enable row level security;
alter table public.deleted_user_session_groups enable row level security;
revoke all on public.deleted_user_group_ownership from anon, authenticated;
revoke all on public.deleted_user_group_members from anon, authenticated;
revoke all on public.deleted_user_follows from anon, authenticated;
revoke all on public.deleted_user_player_links from anon, authenticated;
revoke all on public.deleted_user_session_groups from anon, authenticated;
revoke select on public.profiles from anon, authenticated;
revoke update on public.profiles from anon, authenticated;
grant select (
  id,
  display_name,
  handle,
  discoverable,
  avatar_url,
  is_public,
  theme_mode,
  tutorial_completed,
  deleted_at,
  deletion_scheduled_at,
  created_at,
  suspended_at,
  tombstone_id
) on public.profiles to authenticated;
grant update (
  display_name,
  is_public,
  theme_mode,
  tutorial_completed,
  deleted_at,
  deletion_scheduled_at,
  handle,
  discoverable,
  avatar_url,
  updated_at
) on public.profiles to authenticated;
create policy profiles_select_own
  on public.profiles for select
  using (id = auth.uid());
create policy profiles_select_visible_relationship
  on public.profiles for select
  using (
    exists (
      select 1
      from public.sessions s
      where s.user_id = profiles.id
        and public.can_view_session(s.id)
    )
    or exists (
      select 1
      from public.game_invitations gi
      where gi.profile_id = profiles.id
        and (
          gi.profile_id = auth.uid()
          or public.can_edit_session(gi.session_id)
        )
    )
    or exists (
      select 1
      from public.group_members target_membership
      where target_membership.user_id = profiles.id
        and target_membership.status = 'accepted'
        and target_membership.left_at is null
        and public.is_accepted_group_member(target_membership.group_id)
    )
    or exists (
      select 1
      from public.groups g
      where g.owner_id = profiles.id
        and public.is_accepted_group_member(g.id)
    )
  );
create policy profiles_update_own
  on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());
create policy profiles_insert_own
  on public.profiles for insert
  with check (id = auth.uid());

create or replace view public.discoverable_profiles
with (security_barrier = true)
as
select id, handle, display_name, avatar_url
from public.profiles
where discoverable = true
  and deleted_at is null
  and suspended_at is null;

revoke all on public.discoverable_profiles from public, anon;
grant select on public.discoverable_profiles to authenticated;

create policy sessions_select_visible
  on public.sessions for select
  using (public.can_view_session(id));
create policy sessions_insert_legacy_owner
  on public.sessions for insert
  with check (
    ledger_version = 1
    and user_id = auth.uid()
    and coalesce(current_host_id, auth.uid()) = auth.uid()
  );
create policy sessions_update_legacy_owner
  on public.sessions for update
  using (
    ledger_version = 1
    and user_id = auth.uid()
    and finalized = false
  )
  with check (
    ledger_version = 1
    and user_id = auth.uid()
    and finalized = false
  );
create policy sessions_delete_empty_legacy_owner
  on public.sessions for delete
  using (
    ledger_version = 1
    and user_id = auth.uid()
    and finalized = false
    and not exists (
      select 1 from public.session_players sp where sp.session_id = id
    )
  );

create policy session_players_select_visible
  on public.session_players for select
  using (public.can_view_session(session_id));
create policy session_players_insert_legacy_owner
  on public.session_players for insert
  with check (
    exists (
      select 1 from public.sessions s
      where s.id = session_id
        and s.ledger_version = 1
        and s.user_id = auth.uid()
        and s.finalized = false
    )
  );
create policy session_players_update_legacy_owner
  on public.session_players for update
  using (
    exists (
      select 1 from public.sessions s
      where s.id = session_id
        and s.ledger_version = 1
        and s.user_id = auth.uid()
        and s.finalized = false
    )
  )
  with check (
    exists (
      select 1 from public.sessions s
      where s.id = session_id
        and s.ledger_version = 1
        and s.user_id = auth.uid()
        and s.finalized = false
    )
  );
create policy session_players_delete_legacy_owner
  on public.session_players for delete
  using (
    exists (
      select 1 from public.sessions s
      where s.id = session_id
        and s.ledger_version = 1
        and s.user_id = auth.uid()
        and s.finalized = false
    )
  );

create policy players_select_owner_or_linked
  on public.players for select
  using (
    user_id = auth.uid()
    or linked_user_id = auth.uid()
    or exists (
      select 1
      from public.session_players sp
      where sp.player_id = players.id
        and public.can_view_session(sp.session_id)
    )
  );
create policy players_insert_owner
  on public.players for insert
  with check (user_id = auth.uid());
create policy players_update_owner
  on public.players for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy players_delete_unused_owner
  on public.players for delete
  using (
    user_id = auth.uid()
    and not exists (
      select 1 from public.session_players sp where sp.player_id = id
    )
  );

create policy rebuys_select_visible
  on public.rebuys for select
  using (
    exists (
      select 1
      from public.session_players sp
      where sp.id = session_player_id
        and public.can_view_session(sp.session_id)
    )
  );
create policy rebuys_insert_legacy_owner
  on public.rebuys for insert
  with check (
    exists (
      select 1
      from public.session_players sp
      join public.sessions s on s.id = sp.session_id
      where sp.id = session_player_id
        and s.ledger_version = 1
        and s.user_id = auth.uid()
        and s.finalized = false
    )
  );
create policy rebuys_delete_legacy_owner
  on public.rebuys for delete
  using (
    exists (
      select 1
      from public.session_players sp
      join public.sessions s on s.id = sp.session_id
      where sp.id = session_player_id
        and s.ledger_version = 1
        and s.user_id = auth.uid()
        and s.finalized = false
    )
  );

create policy groups_select_member
  on public.groups for select
  using (public.is_accepted_group_member(id));
create policy groups_insert_owner
  on public.groups for insert
  with check (owner_id = auth.uid());
create policy groups_update_owner
  on public.groups for update
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy group_members_select_group
  on public.group_members for select
  using (
    user_id = auth.uid()
    or public.is_accepted_group_member(group_id)
  );
create policy group_members_leave_self
  on public.group_members for update
  using (user_id = auth.uid() and status = 'accepted')
  with check (
    user_id = auth.uid()
    and status = 'removed'
    and role = 'member'
    and can_manage_games = false
    and left_at is not null
  );

create policy session_groups_select_legacy_group
  on public.session_groups for select
  using (
    public.is_accepted_group_member(group_id)
    or public.can_view_session(session_id)
  );

create policy quick_add_select_own
  on public.quick_add_entries for select
  using (user_id = auth.uid());
create policy quick_add_insert_own
  on public.quick_add_entries for insert
  with check (user_id = auth.uid());
create policy quick_add_update_own
  on public.quick_add_entries for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy quick_add_delete_own
  on public.quick_add_entries for delete
  using (user_id = auth.uid());

alter table public.follows enable row level security;
create policy follows_select_party
  on public.follows for select
  using (follower_id = auth.uid() or following_id = auth.uid());
create policy follows_insert_self
  on public.follows for insert
  with check (follower_id = auth.uid() and following_id <> auth.uid());
create policy follows_update_recipient
  on public.follows for update
  using (following_id = auth.uid())
  with check (following_id = auth.uid());
create policy follows_delete_sender
  on public.follows for delete
  using (follower_id = auth.uid());

alter table public.app_settings enable row level security;
create policy app_settings_select
  on public.app_settings for select using (true);
create policy app_settings_insert_admin
  on public.app_settings for insert
  with check (public.is_app_admin());
create policy app_settings_update_admin
  on public.app_settings for update
  using (public.is_app_admin())
  with check (public.is_app_admin());
create policy app_settings_delete_admin
  on public.app_settings for delete
  using (public.is_app_admin());

create policy game_invitations_select_party
  on public.game_invitations for select
  using (
    profile_id = auth.uid()
    or public.can_edit_session(session_id)
  );
create policy group_invitations_select_party
  on public.group_invitations for select
  using (
    profile_id = auth.uid()
    or exists (
      select 1
      from public.groups g
      where g.id = group_id and g.owner_id = auth.uid()
    )
  );
create policy ledger_events_select_visible
  on public.ledger_events for select
  using (public.can_view_session(session_id));
create policy finalization_revisions_select_visible
  on public.finalization_revisions for select
  using (public.can_view_session(session_id));
create policy settlement_transfers_select_visible
  on public.settlement_transfers for select
  using (
    exists (
      select 1
      from public.finalization_revisions fr
      where fr.id = revision_id
        and public.can_view_session(fr.session_id)
    )
  );
create policy user_notifications_select_own
  on public.user_notifications for select
  using (user_id = auth.uid());
create policy user_notifications_update_own
  on public.user_notifications for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop function if exists public.search_discoverable_profiles(text, bigint);
create or replace function public.search_discoverable_profiles(
  search_text text,
  result_limit integer default 20,
  for_session_id bigint default null
)
returns table (
  id uuid,
  handle text,
  display_name text,
  avatar_url text,
  result_state text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.id,
    p.handle,
    p.display_name,
    p.avatar_url,
    case
      when exists (
        select 1 from public.session_players sp
        where sp.session_id = for_session_id
          and sp.profile_id = p.id
          and sp.removed_at is null
      ) then 'participating'
      when exists (
        select 1 from public.game_invitations gi
        where gi.session_id = for_session_id
          and gi.profile_id = p.id
          and gi.status = 'pending_invitee'
      ) then 'invited'
      when exists (
        select 1 from public.game_invitations gi
        where gi.session_id = for_session_id
          and gi.profile_id = p.id
          and gi.status = 'pending_host'
      ) then 'requested'
      else 'not_in_game'
    end
  from public.profiles p
  where auth.uid() is not null
    and p.id <> auth.uid()
    and p.discoverable = true
    and p.deleted_at is null
    and p.suspended_at is null
    and (
      lower(coalesce(p.handle, '')) like '%' || lower(btrim(search_text)) || '%'
      or lower(coalesce(p.display_name, '')) like '%' || lower(btrim(search_text)) || '%'
    )
  order by
    case when lower(coalesce(p.handle, '')) = lower(btrim(search_text)) then 0 else 1 end,
    lower(coalesce(p.display_name, p.handle, ''))
  limit least(greatest(result_limit, 1), 50);
$$;

revoke all on function public.search_discoverable_profiles(text, integer, bigint)
  from public, anon;
grant execute on function public.search_discoverable_profiles(text, integer, bigint)
  to authenticated;

insert into public.app_settings (key, value)
values
  ('maintenance_mode', 'false'),
  ('v2_enrollment_enabled', 'false'),
  ('v2_min_client_version', '1.0.0')
on conflict (key) do nothing;
