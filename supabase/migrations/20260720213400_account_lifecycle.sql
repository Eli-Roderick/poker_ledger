-- Server-controlled account deletion, restoration, ownership transfer, and
-- permanent tombstoning. Password checks are rate-limited and never expose
-- registration state without valid credentials.

revoke update (deleted_at, deletion_scheduled_at)
  on public.profiles from authenticated;

alter table public.sessions
  add column if not exists owner_unavailable_previous_phase text;
alter table public.group_members
  add column if not exists removed_for_account_deletion boolean
    not null default false;

create or replace function private.handle_unavailable_v2_host()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  game record;
  successor uuid;
  administrator_count integer;
begin
  if (
    old.deleted_at is null and new.deleted_at is not null
  ) or (
    old.suspended_at is null and new.suspended_at is not null
  ) then
    for game in
      select * from public.sessions
      where ledger_version = 2
        and current_host_id = new.id
      for update
    loop
      successor := null;
      if game.backup_host_id is not null
         and exists (
           select 1
           from public.profiles profile
           join public.session_players participant
             on participant.profile_id = profile.id
           where profile.id = game.backup_host_id
             and profile.deleted_at is null
             and profile.suspended_at is null
             and participant.session_id = game.id
             and participant.accepted_at is not null
             and participant.removed_at is null
         )
         and (
           game.group_id is null
           or exists (
             select 1
             from public.groups grouped
             where grouped.id = game.group_id
               and grouped.owner_id = game.backup_host_id
           )
           or exists (
             select 1
             from public.group_members membership
             where membership.group_id = game.group_id
               and membership.user_id = game.backup_host_id
               and membership.status = 'accepted'
               and membership.left_at is null
           )
         ) then
        successor := game.backup_host_id;
      end if;
      if game.group_id is not null then
        if successor is null then
          select grouped.owner_id into successor
          from public.groups grouped
          join public.profiles profile on profile.id = grouped.owner_id
          where grouped.id = game.group_id
            and profile.deleted_at is null
            and profile.suspended_at is null;
        end if;
        if successor is null then
          select
            count(*),
            (array_agg(membership.user_id order by membership.user_id))[1]
            into administrator_count, successor
          from public.group_members membership
          join public.profiles profile on profile.id = membership.user_id
          where membership.group_id = game.group_id
            and membership.status = 'accepted'
            and membership.left_at is null
            and membership.role = 'administrator'
            and membership.can_manage_games
            and profile.deleted_at is null
            and profile.suspended_at is null;
          if administrator_count <> 1 then
            successor := null;
          end if;
        end if;
      end if;
      update public.sessions
      set current_host_id = successor,
          owner_unavailable_previous_phase = case
            when successor is null
              and phase not in ('finalized', 'cancelled')
              then phase
            else owner_unavailable_previous_phase
          end,
          phase = case
            when successor is not null then phase
            when phase in ('finalized', 'cancelled') then phase
            when group_id is null then 'owner_unavailable_read_only'
            else 'orphaned_read_only'
          end,
          updated_at = now()
      where id = game.id;
    end loop;
  elsif old.deleted_at is not null
     and new.deleted_at is null
     and new.suspended_at is null then
    update public.sessions
    set current_host_id = new.id,
        phase = coalesce(owner_unavailable_previous_phase, phase),
        owner_unavailable_previous_phase = null,
        updated_at = now()
    where ledger_version = 2
      and user_id = new.id
      and group_id is null
      and current_host_id is null
      and phase in (
        'owner_unavailable_read_only',
        'finalized',
        'cancelled'
      );
  end if;
  return new;
end;
$$;

create table if not exists private.account_restore_attempts (
  email_digest text not null,
  attempted_at timestamptz not null default now(),
  succeeded boolean not null default false
);
create index if not exists account_restore_attempts_email_idx
  on private.account_restore_attempts(email_digest, attempted_at desc);
revoke all on private.account_restore_attempts
  from public, anon, authenticated;

create or replace function private.verified_deleted_account(
  p_email text,
  p_password text
)
returns table (
  user_id uuid,
  deleted_at timestamptz,
  deletion_scheduled_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text := lower(btrim(p_email));
  digest text := encode(
    extensions.digest(convert_to(normalized_email, 'UTF8'), 'sha256'),
    'hex'
  );
begin
  if (
    select count(*) >= 8
    from private.account_restore_attempts attempt
    where attempt.email_digest = digest
      and attempt.attempted_at > now() - interval '15 minutes'
  ) then
    return;
  end if;
  return query
  select auth_user.id, profile.deleted_at, profile.deletion_scheduled_at
  from auth.users auth_user
  join public.profiles profile on profile.id = auth_user.id
  where lower(auth_user.email) = normalized_email
    and profile.deleted_at is not null
    and profile.deletion_scheduled_at > now()
    and auth_user.encrypted_password is not null
    and extensions.crypt(
      p_password,
      auth_user.encrypted_password
    ) = auth_user.encrypted_password;
  insert into private.account_restore_attempts (email_digest, succeeded)
  values (digest, found);
end;
$$;

create or replace function public.get_restorable_account(
  restore_email text,
  restore_password text
)
returns table (
  user_id uuid,
  deleted_at timestamptz,
  deletion_scheduled_at timestamptz
)
language sql
security definer
set search_path = ''
as $$
  select * from private.verified_deleted_account(
    restore_email,
    restore_password
  );
$$;

create or replace function public.restore_deleted_account(
  restore_email text,
  restore_password text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  account record;
begin
  select * into account
  from private.verified_deleted_account(restore_email, restore_password);
  if not found then
    if exists (
      select 1
      from auth.users auth_user
      join public.profiles profile on profile.id = auth_user.id
      where lower(auth_user.email) = lower(btrim(restore_email))
        and profile.deleted_at is null
        and auth_user.encrypted_password is not null
        and extensions.crypt(
          restore_password,
          auth_user.encrypted_password
        ) = auth_user.encrypted_password
    ) then
      return jsonb_build_object(
        'success', true,
        'status', 'already_active'
      );
    end if;
    return jsonb_build_object(
      'success', false,
      'error', 'Account could not be restored'
    );
  end if;
  update public.profiles
  set deleted_at = null,
      deletion_scheduled_at = null,
      updated_at = now()
  where id = account.user_id;
  update auth.users
  set banned_until = null,
      updated_at = now()
  where id = account.user_id;
  update public.group_members
  set status = 'accepted',
      role = 'member',
      can_manage_games = false,
      accepted_at = now(),
      left_at = null,
      removed_for_account_deletion = false
  where user_id = account.user_id
    and removed_for_account_deletion;
  return jsonb_build_object('success', true);
end;
$$;

create or replace function public.transfer_group_ownership(
  p_group_id bigint,
  p_new_owner_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  grouped public.groups;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'transfer_group_ownership',
    jsonb_build_object(
      'group_id', p_group_id,
      'new_owner_id', p_new_owner_id
    )
  );
  if prior is not null then return prior; end if;
  select * into grouped
  from public.groups
  where id = p_group_id
  for update;
  if not found or grouped.owner_id <> actor then
    raise exception 'Only the current owner can transfer this group'
      using errcode = '42501';
  end if;
  if not exists (
    select 1
    from public.group_members membership
    join public.profiles profile on profile.id = membership.user_id
    where membership.group_id = p_group_id
      and membership.user_id = p_new_owner_id
      and membership.status = 'accepted'
      and membership.left_at is null
      and profile.deleted_at is null
      and profile.suspended_at is null
  ) then
    raise exception 'Choose a current accepted member'
      using errcode = '22023';
  end if;
  update public.groups
  set owner_id = p_new_owner_id,
      updated_at = now()
  where id = p_group_id;
  update public.group_members
  set status = 'removed',
      role = 'member',
      can_manage_games = false,
      left_at = now(),
      removed_for_account_deletion = true
  where group_id = p_group_id
    and user_id = p_new_owner_id;
  insert into public.group_members (
    group_id, user_id, status, role, can_manage_games,
    accepted_at, joined_at, left_at
  )
  values (
    p_group_id, actor, 'accepted', 'administrator', true,
    now(), now(), null
  )
  on conflict (group_id, user_id) do update set
    status = 'accepted',
    role = 'administrator',
    can_manage_games = true,
    accepted_at = coalesce(public.group_members.accepted_at, now()),
    left_at = null;
  result := jsonb_build_object(
    'group_id', p_group_id,
    'owner_id', p_new_owner_id
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.request_account_deletion(
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  prior jsonb;
  scheduled_at timestamptz := now() + interval '30 days';
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'request_account_deletion',
    '{}'::jsonb
  );
  if prior is not null then return prior; end if;
  if exists (
    select 1 from public.groups
    where owner_id = actor
  ) then
    raise exception 'Transfer ownership of every group before deleting your account'
      using errcode = '22023';
  end if;
  update public.group_members
  set status = 'removed',
      role = 'member',
      can_manage_games = false,
      left_at = now(),
      removed_for_account_deletion = true
  where user_id = actor
    and status = 'accepted'
    and left_at is null;
  update public.game_invitations
  set status = 'cancelled',
      cancelled_at = now()
  where profile_id = actor
    and status in ('pending_invitee', 'pending_host');
  update public.group_invitations
  set status = 'cancelled',
      responded_at = now()
  where profile_id = actor
    and status = 'pending';
  update public.profiles
  set deleted_at = coalesce(deleted_at, now()),
      deletion_scheduled_at = coalesce(deletion_scheduled_at, scheduled_at),
      discoverable = false,
      updated_at = now()
  where id = actor
  returning deletion_scheduled_at into scheduled_at;
  update auth.users
  set banned_until = 'infinity'::timestamptz,
      updated_at = now()
  where id = actor;
  result := jsonb_build_object(
    'status', 'scheduled',
    'deletion_scheduled_at', scheduled_at
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function private.prevent_ledger_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and current_setting(
       'app.allow_permanent_anonymization', true
     ) = 'on'
     and (
       to_jsonb(old) - 'actor_id' - 'actor_snapshot'
     ) = (
       to_jsonb(new) - 'actor_id' - 'actor_snapshot'
     ) then
    return new;
  end if;
  raise exception 'Financial history is append-only' using errcode = '55000';
end;
$$;

create or replace function private.finalize_expired_account_deletions()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  account record;
  finalized_count integer := 0;
  tombstone uuid;
begin
  for account in
    select profile.id
    from public.profiles profile
    where profile.deleted_at is not null
      and profile.deletion_scheduled_at <= now()
      and profile.tombstone_id is null
    for update
  loop
    if exists (
      select 1 from public.groups where owner_id = account.id
    ) then
      continue;
    end if;
    tombstone := extensions.gen_random_uuid();
    perform set_config('app.allow_permanent_anonymization', 'on', true);
    perform set_config('app.allow_finalized_revision', 'on', true);
    update public.sessions
    set current_host_id = case
          when current_host_id = account.id then null
          else current_host_id
        end,
        backup_host_id = case
          when backup_host_id = account.id then null
          else backup_host_id
        end,
        phase = case
          when user_id = account.id
               and group_id is null
               and phase = 'owner_unavailable_read_only'
            then 'orphaned_read_only'
          else phase
        end,
        owner_unavailable_previous_phase = case
          when user_id = account.id
               and group_id is null
               and phase = 'owner_unavailable_read_only'
            then null
          else owner_unavailable_previous_phase
        end,
        updated_at = now()
    where current_host_id = account.id
       or backup_host_id = account.id
       or (
         user_id = account.id
         and group_id is null
         and phase = 'owner_unavailable_read_only'
       );
    update public.session_players
    set display_name_snapshot = 'Deleted player',
        profile_id = null
    where profile_id = account.id;
    update public.players
    set linked_user_id = null,
        was_linked_to_deleted_user = true
    where linked_user_id = account.id;
    update public.players
    set name = 'Deleted player',
        email = null,
        phone = null,
        notes = null,
        active = false,
        linked_user_id = null,
        was_linked_to_deleted_user = true
    where user_id = account.id;
    update public.ledger_events
    set actor_id = null,
        actor_snapshot = 'Deleted user'
    where actor_id = account.id;
    update public.finalization_revisions
    set created_by = null
    where created_by = account.id;
    update public.settlement_transfers
    set status_updated_by = null
    where status_updated_by = account.id;
    update public.settlement_transfer_status_history
    set changed_by = null,
        changed_by_snapshot = 'Deleted user'
    where changed_by = account.id;
    delete from public.game_invitations
    where profile_id = account.id or created_by = account.id;
    delete from public.game_join_codes
    where created_by = account.id;
    delete from public.group_invitations
    where profile_id = account.id or invited_by = account.id;
    delete from public.join_code_attempts
    where profile_id = account.id;
    delete from public.idempotency_requests
    where actor_id = account.id;
    delete from public.user_notifications
    where user_id = account.id;
    delete from public.quick_add_entries
    where user_id = account.id;
    delete from public.legacy_import_mappings
    where batch_id in (
      select id
      from public.legacy_import_batches
      where user_id = account.id
    );
    delete from public.legacy_import_batches
    where user_id = account.id;
    delete from public.feature_enrollments
    where user_id = account.id;
    delete from public.app_admins
    where user_id = account.id;
    delete from public.group_members
    where user_id = account.id;
    update private.v2_operation_logs
    set actor_id = null
    where actor_id = account.id;
    delete from public.deleted_user_group_members
    where deleted_user_id = account.id;
    delete from public.deleted_user_follows
    where deleted_user_id = account.id
       or follower_id = account.id
       or following_id = account.id;
    delete from public.deleted_user_player_links
    where deleted_user_id = account.id
       or player_owner_id = account.id;
    delete from public.deleted_user_session_groups
    where deleted_user_id = account.id;
    delete from public.deleted_user_group_ownership
    where deleted_user_id = account.id
       or new_owner_id = account.id;
    delete from public.follows
    where follower_id = account.id or following_id = account.id;
    update public.profiles
    set email = null,
        display_name = 'Deleted player',
        handle = null,
        discoverable = false,
        avatar_url = null,
        is_public = false,
        tombstone_id = tombstone,
        updated_at = now()
    where id = account.id;
    update auth.users
    set email = 'deleted+' || tombstone || '@invalid.poker-ledger.local',
        raw_user_meta_data = '{}'::jsonb,
        encrypted_password = extensions.crypt(
          extensions.gen_random_uuid()::text,
          extensions.gen_salt('bf')
        ),
        banned_until = 'infinity'::timestamptz,
        updated_at = now()
    where id = account.id;
    finalized_count := finalized_count + 1;
  end loop;
  return finalized_count;
end;
$$;

create extension if not exists pg_cron with schema pg_catalog;
do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job
  from cron.job
  where jobname = 'poker-ledger-finalize-account-deletions';
  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;
  perform cron.schedule(
    'poker-ledger-finalize-account-deletions',
    '17 3 * * *',
    'select private.finalize_expired_account_deletions()'
  );
end;
$$;

revoke all on function public.get_restorable_account(text, text)
  from public;
revoke all on function public.restore_deleted_account(text, text)
  from public;
revoke all on function public.transfer_group_ownership(bigint, uuid, uuid)
  from public, anon;
revoke all on function public.request_account_deletion(uuid)
  from public, anon;
revoke all on function private.finalize_expired_account_deletions()
  from public, anon, authenticated;
grant execute on function public.get_restorable_account(text, text)
  to anon, authenticated;
grant execute on function public.restore_deleted_account(text, text)
  to anon, authenticated;
grant execute on function public.transfer_group_ownership(bigint, uuid, uuid)
  to authenticated;
grant execute on function public.request_account_deletion(uuid)
  to authenticated;
grant execute on function private.finalize_expired_account_deletions()
  to service_role;
