-- Reconcile account identities and one-group legacy history, protect backup
-- host assignment, and initialize protected invitation-code material.

insert into private.app_secrets (key, value)
values (
  'join_code_pepper',
  encode(extensions.gen_random_bytes(32), 'hex')
)
on conflict (key) do nothing;

alter table public.game_invitations
  drop constraint if exists
    game_invitations_session_id_profile_id_direction_status_key;
alter table public.group_invitations
  drop constraint if exists group_invitations_group_id_profile_id_key;
create unique index if not exists game_join_codes_digest_uidx
  on public.game_join_codes(code_digest)
  where revoked_at is null;
create unique index if not exists group_invitations_active_uidx
  on public.group_invitations(group_id, profile_id)
  where status = 'pending';

create table if not exists private.legacy_reconciliation_issues (
  issue_type text not null,
  session_id bigint,
  session_player_id bigint,
  details jsonb not null default '{}'::jsonb,
  recorded_at timestamptz not null default now(),
  unique (issue_type, session_id, session_player_id)
);
revoke all on private.legacy_reconciliation_issues
  from public, anon, authenticated;

with legacy_groups as (
  select
    session_id,
    min(group_id) as group_id,
    count(*) as group_count
  from public.session_groups
  group by session_id
),
allow_finalized_reconciliation as (
  select set_config('app.allow_finalized_revision', 'on', true)
)
update public.sessions session
set group_id = legacy_groups.group_id
from legacy_groups, allow_finalized_reconciliation
where session.id = legacy_groups.session_id
  and session.ledger_version = 1
  and session.group_id is null
  and legacy_groups.group_count = 1;

select set_config('app.allow_finalized_revision', 'off', true);

insert into private.legacy_reconciliation_issues (
  issue_type,
  session_id,
  session_player_id,
  details
)
select
  'legacy_guest',
  participant.session_id,
  participant.id,
  jsonb_build_object('player_id', participant.player_id)
from public.session_players participant
where participant.legacy_participant
  and participant.profile_id is null
on conflict do nothing;

insert into private.legacy_reconciliation_issues (
  issue_type,
  session_id,
  session_player_id,
  details
)
select
  'legacy_multi_group',
  grouped.session_id,
  null,
  jsonb_build_object(
    'group_ids',
    jsonb_agg(grouped.group_id order by grouped.group_id)
  )
from public.session_groups grouped
group by grouped.session_id
having count(*) > 1
on conflict do nothing;

create or replace function private.validate_backup_host()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.backup_host_id is null then return new; end if;
  if not exists (
    select 1
    from public.profiles profile
    where profile.id = new.backup_host_id
      and profile.deleted_at is null
      and profile.suspended_at is null
  ) then
    raise exception 'Backup host profile is unavailable'
      using errcode = '22023';
  end if;
  if exists (
    select 1
    from public.session_players participant
    where participant.session_id = new.id
      and participant.profile_id = new.backup_host_id
      and participant.accepted_at is not null
      and participant.removed_at is null
  ) then
    return new;
  end if;
  if new.group_id is not null and (
    exists (
      select 1
      from public.groups grouped
      where grouped.id = new.group_id
        and grouped.owner_id = new.backup_host_id
    )
    or exists (
      select 1
      from public.group_members membership
      where membership.group_id = new.group_id
        and membership.user_id = new.backup_host_id
        and membership.status = 'accepted'
        and membership.left_at is null
        and membership.role = 'administrator'
        and membership.can_manage_games
    )
  ) then
    return new;
  end if;
  raise exception
    'Backup host must be an accepted player or authorized group manager'
    using errcode = '23514';
end;
$$;

drop trigger if exists sessions_validate_backup_host on public.sessions;
create trigger sessions_validate_backup_host
  before insert or update of backup_host_id, group_id
  on public.sessions
  for each row execute function private.validate_backup_host();

create or replace function private.add_participant(
  p_session_id bigint,
  p_profile_id uuid
)
returns public.session_players
language plpgsql
security definer
set search_path = ''
as $$
declare
  profile public.profiles;
  participant public.session_players;
  game public.sessions;
begin
  select * into game
  from public.sessions
  where id = p_session_id
  for update;
  if not found
     or game.ledger_version <> 2
     or game.phase not in ('draft', 'live')
     or game.membership_closed_at is not null then
    raise exception 'This game is not accepting players'
      using errcode = '22023';
  end if;
  select * into profile
  from public.profiles
  where id = p_profile_id
    and deleted_at is null
    and suspended_at is null;
  if not found then
    raise exception 'Profile is unavailable' using errcode = 'P0002';
  end if;
  insert into public.session_players (
    session_id,
    player_id,
    profile_id,
    display_name_snapshot,
    accepted_at,
    legacy_participant,
    paid_upfront
  )
  values (
    p_session_id,
    null,
    p_profile_id,
    coalesce(nullif(btrim(profile.display_name), ''), profile.handle, 'Player'),
    now(),
    false,
    false
  )
  on conflict (session_id, profile_id)
    where profile_id is not null and removed_at is null
  do nothing
  returning * into participant;
  if participant.id is null then
    select * into participant
    from public.session_players
    where session_id = p_session_id
      and profile_id = p_profile_id
      and removed_at is null;
    return participant;
  end if;
  if game.phase = 'live' then
    insert into public.ledger_events (
      session_id, event_sequence, participant_id, event_type,
      amount_cents, actor_id, actor_snapshot, idempotency_key
    )
    values (
      p_session_id, game.next_event_sequence, participant.id,
      'initial_buy_in', game.default_buy_in_cents, auth.uid(),
      (select display_name from public.profiles where id = auth.uid()),
      extensions.gen_random_uuid()
    );
    update public.sessions
    set next_event_sequence = next_event_sequence + 1,
        updated_at = now()
    where id = p_session_id;
  end if;
  return participant;
end;
$$;

create or replace function public.invite_profile_to_game(
  p_session_id bigint,
  p_profile_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  game public.sessions;
  invitation public.game_invitations;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  game := private.require_v2_host(p_session_id);
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'invite_profile_to_game',
    jsonb_build_object('session_id', p_session_id, 'profile_id', p_profile_id)
  );
  if prior is not null then return prior; end if;
  if game.phase not in ('draft', 'live')
     or game.membership_closed_at is not null then
    raise exception 'Invitations are closed for this game'
      using errcode = '22023';
  end if;
  if p_profile_id = actor or not exists (
    select 1 from public.profiles
    where id = p_profile_id
      and discoverable
      and deleted_at is null
      and suspended_at is null
  ) then
    raise exception 'Profile cannot be invited' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.session_players
    where session_id = p_session_id
      and profile_id = p_profile_id
      and removed_at is null
  ) then
    raise exception 'Player is already participating'
      using errcode = '23505';
  end if;
  update public.game_invitations
  set status = 'expired', responded_at = now()
  where session_id = p_session_id
    and profile_id = p_profile_id
    and status in ('pending_invitee', 'pending_host')
    and expires_at <= now();
  if exists (
    select 1 from public.game_invitations
    where session_id = p_session_id
      and profile_id = p_profile_id
      and status in ('pending_invitee', 'pending_host')
      and expires_at > now()
  ) then
    raise exception 'An invitation is already pending'
      using errcode = '23505';
  end if;
  insert into public.game_invitations (
    session_id, profile_id, direction, status,
    created_by, expires_at
  )
  values (
    p_session_id, p_profile_id, 'host_invite', 'pending_invitee',
    actor, now() + interval '7 days'
  )
  returning * into invitation;
  result := jsonb_build_object(
    'invitation_id', invitation.id,
    'status', invitation.status,
    'expires_at', invitation.expires_at
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'invite_profile_to_game', p_session_id, game.phase
  );
  return result;
end;
$$;

create or replace function public.create_game_join_code(
  p_session_id bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  game public.sessions;
  prior jsonb;
  code text;
  pepper text;
  result jsonb;
begin
  perform private.require_compatible_client();
  game := private.require_v2_host(p_session_id);
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'create_game_join_code',
    jsonb_build_object('session_id', p_session_id)
  );
  if prior is not null then return prior; end if;
  if game.phase not in ('draft', 'live')
     or game.membership_closed_at is not null then
    raise exception 'Join codes are closed for this game'
      using errcode = '22023';
  end if;
  select value into pepper
  from private.app_secrets
  where key = 'join_code_pepper';
  if pepper is null then
    raise exception 'Join codes are temporarily unavailable'
      using errcode = '55000';
  end if;
  update public.game_join_codes
  set revoked_at = now()
  where session_id = p_session_id
    and revoked_at is null;
  loop
    code := upper(encode(extensions.gen_random_bytes(6), 'hex'));
    exit when not exists (
      select 1 from public.game_join_codes
      where code_digest = extensions.hmac(code, pepper, 'sha256')
        and revoked_at is null
    );
  end loop;
  insert into public.game_join_codes (
    session_id, code_digest, created_by, expires_at
  )
  values (
    p_session_id,
    extensions.hmac(code, pepper, 'sha256'),
    actor,
    now() + interval '2 hours'
  );
  result := jsonb_build_object(
    'session_id', p_session_id,
    'code', code,
    'expires_at', now() + interval '2 hours'
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'create_game_join_code', p_session_id, game.phase
  );
  return result;
end;
$$;

create or replace function public.request_game_join_by_code(
  p_code text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  normalized_code text := upper(regexp_replace(p_code, '[^A-Z0-9]', '', 'g'));
  pepper text;
  join_code public.game_join_codes;
  game public.sessions;
  invitation public.game_invitations;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'request_game_join_by_code',
    jsonb_build_object('code', normalized_code)
  );
  if prior is not null then return prior; end if;
  if (
    select count(*) >= 8
    from public.join_code_attempts
    where profile_id = actor
      and attempted_at > now() - interval '15 minutes'
  ) then
    raise exception 'Too many join-code attempts; try again later'
      using errcode = '42900';
  end if;
  select value into pepper
  from private.app_secrets
  where key = 'join_code_pepper';
  if pepper is null then
    raise exception 'Join codes are temporarily unavailable'
      using errcode = '55000';
  end if;
  select * into join_code
  from public.game_join_codes
  where code_digest = extensions.hmac(normalized_code, pepper, 'sha256')
    and revoked_at is null
    and expires_at > now()
  for update;
  if not found then
    insert into public.join_code_attempts (profile_id, succeeded)
    values (actor, false);
    result := jsonb_build_object(
      'status', 'invalid',
      'message', 'Code is invalid or expired'
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;
  insert into public.join_code_attempts (profile_id, succeeded)
  values (actor, true);
  select * into game
  from public.sessions
  where id = join_code.session_id
  for update;
  if game.ledger_version <> 2
     or game.phase not in ('draft', 'live')
     or game.membership_closed_at is not null then
    result := jsonb_build_object(
      'status', 'unavailable',
      'message', 'This game is no longer accepting players'
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;
  if exists (
    select 1 from public.session_players
    where session_id = game.id
      and profile_id = actor
      and removed_at is null
  ) then
    result := jsonb_build_object('status', 'participating');
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;
  update public.game_invitations
  set status = 'expired', responded_at = now()
  where session_id = game.id
    and profile_id = actor
    and status in ('pending_invitee', 'pending_host')
    and expires_at <= now();
  select * into invitation
  from public.game_invitations
  where session_id = game.id
    and profile_id = actor
    and status in ('pending_invitee', 'pending_host')
    and expires_at > now()
  order by created_at desc
  limit 1;
  if found then
    result := jsonb_build_object(
      'status', invitation.status,
      'invitation_id', invitation.id
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;
  insert into public.game_invitations (
    session_id, profile_id, direction, status,
    created_by, expires_at
  )
  values (
    game.id, actor, 'join_request', 'pending_host',
    actor, least(join_code.expires_at, now() + interval '2 hours')
  )
  returning * into invitation;
  result := jsonb_build_object(
    'status', invitation.status,
    'invitation_id', invitation.id
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'request_game_join_by_code', game.id, game.phase
  );
  return result;
end;
$$;

create or replace function public.respond_to_game_invitation(
  p_invitation_id uuid,
  p_accept boolean,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  invitation public.game_invitations;
  game public.sessions;
  participant public.session_players;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'respond_to_game_invitation',
    jsonb_build_object(
      'invitation_id', p_invitation_id,
      'accept', p_accept
    )
  );
  if prior is not null then return prior; end if;
  select * into invitation
  from public.game_invitations
  where id = p_invitation_id
  for update;
  if not found then
    raise exception 'Invitation not found' using errcode = 'P0002';
  end if;
  select * into game
  from public.sessions
  where id = invitation.session_id
  for update;
  if invitation.status not in ('pending_invitee', 'pending_host')
     or invitation.expires_at <= now()
     or game.phase not in ('draft', 'live')
     or game.membership_closed_at is not null then
    raise exception 'Invitation is no longer actionable'
      using errcode = '22023';
  end if;
  if (
    invitation.status = 'pending_invitee'
    and invitation.profile_id <> actor
  ) or (
    invitation.status = 'pending_host'
    and game.current_host_id <> actor
  ) then
    raise exception 'Not authorized to respond to this invitation'
      using errcode = '42501';
  end if;
  if p_accept then
    participant := private.add_participant(
      invitation.session_id,
      invitation.profile_id
    );
    update public.game_invitations
    set status = 'accepted', responded_at = now()
    where id = invitation.id;
    result := jsonb_build_object(
      'status', 'accepted',
      'participant_id', participant.id
    );
  else
    update public.game_invitations
    set status = 'declined', responded_at = now()
    where id = invitation.id;
    result := jsonb_build_object('status', 'declined');
  end if;
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'respond_to_game_invitation',
    invitation.session_id,
    game.phase
  );
  return result;
end;
$$;

revoke all on function public.invite_profile_to_game(bigint, uuid, uuid)
  from public, anon;
revoke all on function public.create_game_join_code(bigint, uuid)
  from public, anon;
revoke all on function public.request_game_join_by_code(text, uuid)
  from public, anon;
revoke all on function public.respond_to_game_invitation(uuid, boolean, uuid)
  from public, anon;
grant execute on function public.invite_profile_to_game(bigint, uuid, uuid)
  to authenticated;
grant execute on function public.create_game_join_code(bigint, uuid)
  to authenticated;
grant execute on function public.request_game_join_by_code(text, uuid)
  to authenticated;
grant execute on function public.respond_to_game_invitation(uuid, boolean, uuid)
  to authenticated;

create or replace function private.can_manage_group(
  p_group_id bigint,
  p_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.groups grouped
    where grouped.id = p_group_id
      and grouped.owner_id = p_actor_id
  ) or exists (
    select 1 from public.group_members membership
    where membership.group_id = p_group_id
      and membership.user_id = p_actor_id
      and membership.status = 'accepted'
      and membership.left_at is null
      and membership.role = 'administrator'
      and membership.can_manage_games
  );
$$;

create or replace function public.leave_group(
  p_group_id bigint,
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
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'leave_group',
    jsonb_build_object('group_id', p_group_id)
  );
  if prior is not null then return prior; end if;
  if exists (
    select 1 from public.groups
    where id = p_group_id and owner_id = actor
  ) then
    raise exception 'Transfer ownership before leaving this group'
      using errcode = '22023';
  end if;
  update public.group_members
  set status = 'removed',
      role = 'member',
      can_manage_games = false,
      left_at = now()
  where group_id = p_group_id
    and user_id = actor
    and status = 'accepted'
    and left_at is null;
  if not found then
    raise exception 'Active membership not found' using errcode = 'P0002';
  end if;
  result := jsonb_build_object('group_id', p_group_id, 'status', 'left');
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

revoke all on function public.leave_group(bigint, uuid) from public, anon;
grant execute on function public.leave_group(bigint, uuid) to authenticated;
