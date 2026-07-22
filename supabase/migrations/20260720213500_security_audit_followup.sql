-- Close the remaining privilege and privacy gaps identified by the final
-- security audit. This migration is deliberately forward-safe for projects
-- where earlier V2 migrations were already applied.

alter table public.profiles
  alter column discoverable set default false;

-- Discovery is opt-in. Existing accounts predate the explicit consent prompt,
-- so they must opt in from Settings or profile setup.
update public.profiles
set discoverable = false,
    updated_at = now()
where discoverable;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_handle text := lower(new.raw_user_meta_data ->> 'handle');
begin
  if requested_handle !~ '^[a-z0-9_]{3,24}$' then
    requested_handle := null;
  end if;
  insert into public.profiles (
    id, email, display_name, handle, discoverable
  )
  values (
    new.id,
    new.email,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
      split_part(new.email, '@', 1)
    ),
    requested_handle,
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Profile creation and account lifecycle are server controlled. The client
-- can only read and update the explicitly granted non-sensitive columns.
revoke insert on public.profiles from anon, authenticated;
drop policy if exists profiles_insert_own on public.profiles;
revoke select (
  deleted_at,
  deletion_scheduled_at,
  suspended_at,
  tombstone_id
) on public.profiles from authenticated;

-- Leaving/removal and role changes must use their audited RPCs.
revoke update on public.group_members from anon, authenticated;
drop policy if exists group_members_leave_self on public.group_members;

-- Notifications permit only the read receipt to change.
revoke update on public.user_notifications from anon, authenticated;
grant update (read_at) on public.user_notifications to authenticated;

-- Public authorization helpers are needed by RLS. Prevent callers from using
-- their optional UUID arguments to probe another account's privileges.
create or replace function public.is_app_admin(
  check_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select check_user_id is not null
    and (
      auth.uid() is null
      or check_user_id = auth.uid()
    )
    and exists (
      select 1 from public.app_admins administrator
      where administrator.user_id = check_user_id
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
    and (
      auth.uid() is null
      or check_user_id = auth.uid()
    )
    and (
      exists (
        select 1
        from public.groups grouped
        where grouped.id = check_group_id
          and grouped.owner_id = check_user_id
      )
      or exists (
        select 1
        from public.group_members membership
        where membership.group_id = check_group_id
          and membership.user_id = check_user_id
          and membership.status = 'accepted'
          and membership.left_at is null
      )
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
  select check_user_id is not null
    and (
      auth.uid() is null
      or check_user_id = auth.uid()
    )
    and exists (
      select 1
      from public.sessions game
      where game.id = check_session_id
        and (
          game.user_id = check_user_id
          or game.current_host_id = check_user_id
          or exists (
            select 1
            from public.session_players participant
            where participant.session_id = game.id
              and participant.profile_id = check_user_id
              and participant.accepted_at is not null
              and participant.removed_at is null
          )
          or (
            game.group_id is not null
            and (
              exists (
                select 1
                from public.groups grouped
                where grouped.id = game.group_id
                  and grouped.owner_id = check_user_id
              )
              or exists (
                select 1
                from public.group_members membership
                where membership.group_id = game.group_id
                  and membership.user_id = check_user_id
                  and membership.status = 'accepted'
                  and membership.left_at is null
              )
            )
          )
          or (
            game.ledger_version = 1
            and exists (
              select 1
              from public.session_groups sharing
              where sharing.session_id = game.id
                and (
                  exists (
                    select 1
                    from public.groups grouped
                    where grouped.id = sharing.group_id
                      and grouped.owner_id = check_user_id
                  )
                  or exists (
                    select 1
                    from public.group_members membership
                    where membership.group_id = sharing.group_id
                      and membership.user_id = check_user_id
                      and membership.status = 'accepted'
                      and membership.left_at is null
                  )
                )
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
  select check_user_id is not null
    and (
      auth.uid() is null
      or check_user_id = auth.uid()
    )
    and exists (
      select 1
      from public.sessions game
      where game.id = check_session_id
        and game.phase not in (
          'finalized',
          'owner_unavailable_read_only',
          'orphaned_read_only',
          'cancelled'
        )
        and (
          game.current_host_id = check_user_id
          or (
            game.current_host_id is null
            and game.user_id = check_user_id
            and game.ledger_version = 1
          )
        )
    );
$$;

create or replace function public.search_discoverable_profiles(
  search_text text,
  result_limit integer,
  for_session_id bigint,
  for_group_id bigint
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
    profile.id,
    profile.handle,
    profile.display_name,
    profile.avatar_url,
    case
      when for_session_id is not null and exists (
        select 1 from public.session_players participant
        where participant.session_id = for_session_id
          and participant.profile_id = profile.id
          and participant.removed_at is null
      ) then 'participating'
      when for_session_id is not null and exists (
        select 1 from public.game_invitations invitation
        where invitation.session_id = for_session_id
          and invitation.profile_id = profile.id
          and invitation.status = 'pending_invitee'
      ) then 'invited'
      when for_session_id is not null and exists (
        select 1 from public.game_invitations invitation
        where invitation.session_id = for_session_id
          and invitation.profile_id = profile.id
          and invitation.status = 'pending_host'
      ) then 'requested'
      when for_group_id is not null and (
        exists (
          select 1 from public.groups grouped
          where grouped.id = for_group_id
            and grouped.owner_id = profile.id
        )
        or exists (
          select 1 from public.group_members membership
          where membership.group_id = for_group_id
            and membership.user_id = profile.id
            and membership.status = 'accepted'
            and membership.left_at is null
        )
      ) then 'group_member'
      when for_group_id is not null and exists (
        select 1 from public.group_invitations invitation
        where invitation.group_id = for_group_id
          and invitation.profile_id = profile.id
          and invitation.status = 'pending'
          and invitation.expires_at > now()
      ) then 'group_invited'
      when for_group_id is not null then 'not_in_group'
      else 'not_in_game'
    end
  from public.profiles profile
  where auth.uid() is not null
    and profile.id <> auth.uid()
    and (
      for_session_id is null
      or public.can_edit_session(for_session_id)
    )
    and (
      for_group_id is null
      or private.can_manage_group(for_group_id, auth.uid())
    )
    and profile.discoverable
    and profile.deleted_at is null
    and profile.suspended_at is null
    and (
      lower(coalesce(profile.handle, '')) like
        '%' || lower(btrim(search_text)) || '%'
      or lower(coalesce(profile.display_name, '')) like
        '%' || lower(btrim(search_text)) || '%'
    )
  order by
    case
      when lower(coalesce(profile.handle, '')) =
        lower(btrim(search_text)) then 0
      else 1
    end,
    lower(coalesce(profile.display_name, profile.handle, ''))
  limit least(greatest(result_limit, 1), 50);
$$;

create or replace function private.validate_reversal()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  original public.ledger_events;
begin
  if new.reverses_event_id is null then
    if new.event_type = 'reversal' then
      raise exception 'A reversal must reference its original event';
    end if;
    return new;
  end if;
  if new.event_type <> 'reversal' then
    raise exception 'Only reversal events may reference an original event';
  end if;
  select * into original
  from public.ledger_events
  where id = new.reverses_event_id;
  if not found
     or original.event_type = 'reversal'
     or original.session_id <> new.session_id
     or original.participant_id <> new.participant_id
     or original.amount_cents <> -new.amount_cents then
    raise exception
      'Reversal must exactly offset one non-reversal event for the same game and participant';
  end if;
  return new;
end;
$$;
