-- Transactional write boundary for ledger_version = 2 games. Legacy open
-- games continue to use their original columns until explicitly migrated.

create unique index if not exists game_join_codes_digest_uidx
  on public.game_join_codes(code_digest)
  where revoked_at is null;

alter table public.game_invitations
  drop constraint if exists game_invitations_session_id_profile_id_direction_status_key;
alter table public.group_invitations
  drop constraint if exists group_invitations_group_id_profile_id_key;
create unique index if not exists group_invitations_active_uidx
  on public.group_invitations(group_id, profile_id)
  where status = 'pending';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_handle_format_check'
  ) then
    alter table public.profiles
      add constraint profiles_handle_format_check
      check (
        handle is null
        or (
          char_length(handle) between 3 and 24
          and handle ~ '^[a-z0-9_]+$'
        )
      );
  end if;
end;
$$;

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

create or replace function private.require_actor()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  return actor;
end;
$$;

create or replace function private.require_v2_host(p_session_id bigint)
returns public.sessions
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  game public.sessions;
begin
  select * into game
  from public.sessions
  where id = p_session_id
  for update;

  if not found or game.ledger_version <> 2 then
    raise exception 'Game not found' using errcode = 'P0002';
  end if;
  if game.current_host_id is distinct from actor then
    raise exception 'Only the current host can perform this action'
      using errcode = '42501';
  end if;
  return game;
end;
$$;

create or replace function private.begin_idempotent(
  p_actor_id uuid,
  p_key uuid,
  p_operation text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  inserted_count integer;
  existing public.idempotency_requests;
  request_hash text := encode(
    extensions.digest(
      convert_to(p_operation || ':' || p_request::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
begin
  insert into public.idempotency_requests (
    actor_id,
    idempotency_key,
    operation,
    request_hash
  )
  values (p_actor_id, p_key, p_operation, request_hash)
  on conflict (actor_id, idempotency_key) do nothing;

  get diagnostics inserted_count = row_count;
  if inserted_count = 1 then
    return null;
  end if;

  select * into existing
  from public.idempotency_requests
  where actor_id = p_actor_id
    and idempotency_key = p_key
  for update;

  if existing.operation <> p_operation
     or existing.request_hash <> request_hash then
    raise exception 'Idempotency key was already used for another request'
      using errcode = '22023';
  end if;
  if existing.status = 'completed' then
    return existing.result;
  end if;
  raise exception 'Matching request is still processing'
    using errcode = '55P03';
end;
$$;

create or replace function private.complete_idempotent(
  p_actor_id uuid,
  p_key uuid,
  p_result jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.idempotency_requests
  set status = 'completed',
      result = p_result,
      completed_at = now()
  where actor_id = p_actor_id
    and idempotency_key = p_key;
$$;

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
      session_id,
      event_sequence,
      participant_id,
      event_type,
      amount_cents,
      actor_id,
      actor_snapshot,
      idempotency_key
    )
    values (
      p_session_id,
      game.next_event_sequence,
      participant.id,
      'initial_buy_in',
      game.default_buy_in_cents,
      auth.uid(),
      (
        select display_name
        from public.profiles
        where id = auth.uid()
      ),
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

create or replace function public.create_v2_session(
  p_name text,
  p_group_id bigint,
  p_default_buy_in_cents bigint,
  p_currency_code text,
  p_host_participates boolean,
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
  game public.sessions;
  profile public.profiles;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'create_v2_session',
    jsonb_build_object(
      'name', p_name,
      'group_id', p_group_id,
      'default_buy_in_cents', p_default_buy_in_cents,
      'currency_code', p_currency_code,
      'host_participates', p_host_participates
    )
  );
  if prior is not null then return prior; end if;

  if p_default_buy_in_cents <= 0 then
    raise exception 'Default buy-in must be greater than zero'
      using errcode = '22023';
  end if;
  if upper(p_currency_code) !~ '^[A-Z]{3}$' then
    raise exception 'Currency code must contain three letters'
      using errcode = '22023';
  end if;
  if p_group_id is not null
     and not public.is_accepted_group_member(p_group_id, actor) then
    raise exception 'You are not an accepted member of this group'
      using errcode = '42501';
  end if;
  if p_group_id is not null
     and exists (
       select 1 from public.groups
       where id = p_group_id and archived_at is not null
     ) then
    raise exception 'Archived groups cannot host new games'
      using errcode = '22023';
  end if;

  insert into public.sessions (
    user_id,
    current_host_id,
    name,
    group_id,
    schema_version,
    ledger_version,
    phase,
    finalized,
    currency_code,
    default_buy_in_cents
  )
  values (
    actor,
    actor,
    nullif(btrim(p_name), ''),
    p_group_id,
    2,
    2,
    'draft',
    false,
    upper(p_currency_code),
    p_default_buy_in_cents
  )
  returning * into game;

  if p_host_participates then
    select * into profile from public.profiles where id = actor;
    if profile.handle is null then
      raise exception 'Choose a unique handle before creating a game'
        using errcode = '22023';
    end if;
    perform private.add_participant(game.id, actor);
  end if;

  result := jsonb_build_object(
    'session_id', game.id,
    'phase', game.phase,
    'ledger_version', game.ledger_version
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
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
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'invite_profile_to_game',
    jsonb_build_object('session_id', p_session_id, 'profile_id', p_profile_id)
  );
  if prior is not null then return prior; end if;

  game := private.require_v2_host(p_session_id);
  if game.phase not in ('draft', 'live')
     or game.membership_closed_at is not null then
    raise exception 'Invitations are closed for this game'
      using errcode = '22023';
  end if;
  if p_profile_id = actor then
    raise exception 'The host can join from the lobby'
      using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = p_profile_id
      and discoverable
      and deleted_at is null
      and suspended_at is null
  ) then
    raise exception 'Profile not found' using errcode = 'P0002';
  end if;

  update public.game_invitations
  set status = 'cancelled', cancelled_at = now()
  where session_id = p_session_id
    and profile_id = p_profile_id
    and status in ('pending_invitee', 'pending_host');

  insert into public.game_invitations (
    session_id,
    profile_id,
    direction,
    status,
    created_by,
    expires_at
  )
  values (
    p_session_id,
    p_profile_id,
    'host_invite',
    'pending_invitee',
    actor,
    now() + interval '24 hours'
  )
  returning * into invitation;

  insert into public.user_notifications (
    user_id,
    notification_type,
    title,
    body,
    data
  )
  values (
    p_profile_id,
    'game_invitation',
    'Poker game invitation',
    'You were invited to join a poker game.',
    jsonb_build_object('session_id', p_session_id, 'invitation_id', invitation.id)
  );

  result := jsonb_build_object(
    'invitation_id', invitation.id,
    'status', invitation.status,
    'expires_at', invitation.expires_at
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
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
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'create_game_join_code',
    jsonb_build_object('session_id', p_session_id)
  );
  if prior is not null then return prior; end if;

  game := private.require_v2_host(p_session_id);
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

  loop
    code := upper(encode(extensions.gen_random_bytes(6), 'hex'));
    exit when not exists (
      select 1 from public.game_join_codes
      where code_digest = extensions.hmac(code, pepper, 'sha256')
        and revoked_at is null
        and expires_at > now()
    );
  end loop;

  insert into public.game_join_codes (
    session_id,
    code_digest,
    expires_at,
    revoked_at,
    created_by
  )
  values (
    p_session_id,
    extensions.hmac(code, pepper, 'sha256'),
    now() + interval '2 hours',
    null,
    actor
  )
  on conflict (session_id) do update set
    code_digest = excluded.code_digest,
    expires_at = excluded.expires_at,
    revoked_at = null,
    created_by = excluded.created_by,
    created_at = now();

  result := jsonb_build_object(
    'session_id', p_session_id,
    'code', code,
    'expires_at', now() + interval '2 hours'
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
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
  normalized_code text := upper(btrim(p_code));
  pepper text;
  game_code public.game_join_codes;
  game public.sessions;
  invitation public.game_invitations;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'request_game_join_by_code',
    jsonb_build_object('code', normalized_code)
  );
  if prior is not null then return prior; end if;

  if (
    select count(*)
    from public.join_code_attempts
    where profile_id = actor
      and attempted_at > now() - interval '15 minutes'
  ) >= 8 then
    raise exception 'Too many join-code attempts. Try again later.'
      using errcode = 'P0001';
  end if;

  select value into pepper
  from private.app_secrets
  where key = 'join_code_pepper';
  if pepper is null then
    raise exception 'Join codes are temporarily unavailable'
      using errcode = '55000';
  end if;

  select * into game_code
  from public.game_join_codes
  where code_digest = extensions.hmac(
    normalized_code,
    pepper,
    'sha256'
  )
    and expires_at > now()
    and revoked_at is null;

  if not found then
    insert into public.join_code_attempts(profile_id, succeeded)
    values (actor, false);
    result := jsonb_build_object('status', 'invalid');
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;

  insert into public.join_code_attempts(profile_id, succeeded)
  values (actor, true);

  select * into game
  from public.sessions
  where id = game_code.session_id
  for update;
  if game.phase not in ('draft', 'live')
     or game.ledger_version <> 2
     or game.membership_closed_at is not null then
    raise exception 'This game is no longer accepting players'
      using errcode = '22023';
  end if;
  if exists (
    select 1 from public.session_players
    where session_id = game.id
      and profile_id = actor
      and removed_at is null
  ) then
    result := jsonb_build_object(
      'session_id', game.id,
      'status', 'accepted'
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;

  update public.game_invitations
  set status = 'cancelled', cancelled_at = now()
  where session_id = game.id
    and profile_id = actor
    and status in ('pending_invitee', 'pending_host');

  insert into public.game_invitations (
    session_id,
    profile_id,
    direction,
    status,
    created_by,
    expires_at
  )
  values (
    game.id,
    actor,
    'join_request',
    'pending_host',
    actor,
    least(game_code.expires_at, now() + interval '24 hours')
  )
  returning * into invitation;

  insert into public.user_notifications (
    user_id,
    notification_type,
    title,
    body,
    data
  )
  values (
    game.current_host_id,
    'game_join_request',
    'New game join request',
    'A player requested to join your poker game.',
    jsonb_build_object('session_id', game.id, 'invitation_id', invitation.id)
  );

  result := jsonb_build_object(
    'session_id', game.id,
    'invitation_id', invitation.id,
    'status', invitation.status
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
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
    actor,
    p_idempotency_key,
    'respond_to_game_invitation',
    jsonb_build_object('invitation_id', p_invitation_id, 'accept', p_accept)
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
    raise exception 'Invitation is no longer pending' using errcode = '22023';
  end if;
  if invitation.direction = 'host_invite'
     and invitation.profile_id <> actor then
    raise exception 'Only the invitee can respond' using errcode = '42501';
  end if;
  if invitation.direction = 'join_request'
     and game.current_host_id <> actor then
    raise exception 'Only the host can respond' using errcode = '42501';
  end if;

  update public.game_invitations
  set status = case when p_accept then 'accepted' else 'declined' end,
      responded_at = now()
  where id = invitation.id;

  if p_accept then
    participant := private.add_participant(
      invitation.session_id,
      invitation.profile_id
    );
  end if;

  result := jsonb_build_object(
    'session_id', invitation.session_id,
    'status', case when p_accept then 'accepted' else 'declined' end,
    'participant_id', participant.id
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.start_v2_session(
  p_session_id bigint,
  p_settlement_mode text,
  p_banker_participant_id bigint,
  p_idempotency_key uuid,
  p_paid_upfront_participant_ids bigint[] default '{}'::bigint[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  game public.sessions;
  participant record;
  sequence_number bigint;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'start_v2_session',
    jsonb_build_object(
      'session_id', p_session_id,
      'settlement_mode', p_settlement_mode,
      'banker_participant_id', p_banker_participant_id,
      'paid_upfront_participant_ids', p_paid_upfront_participant_ids
    )
  );
  if prior is not null then return prior; end if;

  game := private.require_v2_host(p_session_id);
  if game.phase <> 'draft' then
    raise exception 'Only a draft game can start' using errcode = '22023';
  end if;
  if p_settlement_mode not in ('pairwise', 'banker') then
    raise exception 'Choose a settlement mode' using errcode = '22023';
  end if;
  if (
    select count(*) from public.session_players
    where session_id = p_session_id and removed_at is null
  ) < 2 then
    raise exception 'At least two accepted players are required'
      using errcode = '22023';
  end if;
  if p_settlement_mode = 'banker'
     and not exists (
       select 1 from public.session_players
       where id = p_banker_participant_id
         and session_id = p_session_id
         and removed_at is null
     ) then
    raise exception 'Choose an accepted player as banker'
      using errcode = '22023';
  end if;
  if exists (
    select 1
    from unnest(p_paid_upfront_participant_ids) selected_id
    where not exists (
      select 1
      from public.session_players participant
      where participant.id = selected_id
        and participant.session_id = p_session_id
        and participant.removed_at is null
    )
  ) then
    raise exception 'Paid-upfront selections must be accepted players'
      using errcode = '22023';
  end if;
  update public.session_players
  set paid_upfront = id = any(p_paid_upfront_participant_ids)
  where session_id = p_session_id
    and removed_at is null;

  sequence_number := game.next_event_sequence;
  for participant in
    select id
    from public.session_players
    where session_id = p_session_id and removed_at is null
    order by id
  loop
    insert into public.ledger_events (
      session_id,
      event_sequence,
      participant_id,
      event_type,
      amount_cents,
      actor_id,
      actor_snapshot,
      idempotency_key
    )
    values (
      p_session_id,
      sequence_number,
      participant.id,
      'initial_buy_in',
      game.default_buy_in_cents,
      actor,
      (select display_name from public.profiles where id = actor),
      extensions.gen_random_uuid()
    );
    sequence_number := sequence_number + 1;
  end loop;

  update public.sessions
  set phase = 'live',
      settlement_mode = p_settlement_mode,
      banker_session_player_id = case
        when p_settlement_mode = 'banker' then p_banker_participant_id
        else null
      end,
      mode_confirmed_at = now(),
      next_event_sequence = sequence_number,
      updated_at = now()
  where id = p_session_id;

  result := jsonb_build_object(
    'session_id', p_session_id,
    'phase', 'live',
    'next_event_sequence', sequence_number
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.record_v2_ledger_event(
  p_session_id bigint,
  p_participant_id bigint,
  p_event_type text,
  p_amount_cents bigint,
  p_reason text,
  p_reverses_event_id bigint,
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
  event public.ledger_events;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'record_v2_ledger_event',
    jsonb_build_object(
      'session_id', p_session_id,
      'participant_id', p_participant_id,
      'event_type', p_event_type,
      'amount_cents', p_amount_cents,
      'reason', p_reason,
      'reverses_event_id', p_reverses_event_id
    )
  );
  if prior is not null then return prior; end if;

  game := private.require_v2_host(p_session_id);
  if p_event_type not in ('rebuy', 'cash_out', 'reversal', 'correction') then
    raise exception 'Unsupported event type' using errcode = '22023';
  end if;
  if (p_event_type = 'rebuy' and game.phase <> 'live')
     or (p_event_type = 'cash_out' and game.phase <> 'settling')
     or (
       p_event_type in ('reversal', 'correction')
       and game.phase not in ('live', 'settling')
     ) then
    raise exception 'That financial event is not valid in this game phase'
      using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.session_players
    where id = p_participant_id
      and session_id = p_session_id
      and removed_at is null
  ) then
    raise exception 'Player is not active in this game' using errcode = 'P0002';
  end if;
  if p_event_type = 'cash_out'
     and exists (
       select 1
       from public.ledger_events original
       where original.session_id = p_session_id
         and original.participant_id = p_participant_id
         and original.event_type = 'cash_out'
         and not exists (
           select 1 from public.ledger_events reversal
           where reversal.reverses_event_id = original.id
         )
     ) then
    raise exception 'Player already has a cash-out'
      using errcode = '22023';
  end if;

  insert into public.ledger_events (
    session_id,
    event_sequence,
    participant_id,
    event_type,
    amount_cents,
    actor_id,
    actor_snapshot,
    reason,
    reverses_event_id,
    idempotency_key
  )
  values (
    p_session_id,
    game.next_event_sequence,
    p_participant_id,
    p_event_type,
    case
      when p_event_type = 'rebuy' then abs(p_amount_cents)
      when p_event_type = 'cash_out' then -abs(p_amount_cents)
      else p_amount_cents
    end,
    actor,
    (select display_name from public.profiles where id = actor),
    nullif(btrim(p_reason), ''),
    p_reverses_event_id,
    p_idempotency_key
  )
  returning * into event;

  update public.sessions
  set next_event_sequence = next_event_sequence + 1,
      updated_at = now()
  where id = p_session_id;

  result := jsonb_build_object(
    'event_id', event.id,
    'event_sequence', event.event_sequence,
    'amount_cents', event.amount_cents
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function private.create_settlement_transfers(
  p_revision_id bigint,
  p_session_id bigint,
  p_mode text,
  p_banker_participant_id bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  debtor_ids bigint[];
  debtor_amounts bigint[];
  creditor_ids bigint[];
  creditor_amounts bigint[];
  debtor_index integer := 1;
  creditor_index integer := 1;
  transfer_amount bigint;
  balance record;
begin
  if p_mode = 'banker' then
    if p_banker_participant_id is null then
      raise exception 'Banker is required';
    end if;
    for balance in
      select
        participant_id,
        -sum(amount_cents)::bigint as net_cents
      from public.ledger_events
      where session_id = p_session_id
      group by participant_id
      order by participant_id
    loop
      if balance.participant_id = p_banker_participant_id then
        continue;
      elsif balance.net_cents < 0 then
        insert into public.settlement_transfers (
          revision_id, from_participant_id, to_participant_id, amount_cents
        ) values (
          p_revision_id,
          balance.participant_id,
          p_banker_participant_id,
          -balance.net_cents
        );
      elsif balance.net_cents > 0 then
        insert into public.settlement_transfers (
          revision_id, from_participant_id, to_participant_id, amount_cents
        ) values (
          p_revision_id,
          p_banker_participant_id,
          balance.participant_id,
          balance.net_cents
        );
      end if;
    end loop;
    return;
  end if;

  select
    array_agg(participant_id order by participant_id),
    array_agg((-net_cents)::bigint order by participant_id)
  into debtor_ids, debtor_amounts
  from (
    select participant_id, -sum(amount_cents)::bigint as net_cents
    from public.ledger_events
    where session_id = p_session_id
    group by participant_id
    having -sum(amount_cents) < 0
  ) debtors;

  select
    array_agg(participant_id order by participant_id),
    array_agg(net_cents::bigint order by participant_id)
  into creditor_ids, creditor_amounts
  from (
    select participant_id, -sum(amount_cents)::bigint as net_cents
    from public.ledger_events
    where session_id = p_session_id
    group by participant_id
    having -sum(amount_cents) > 0
  ) creditors;

  while debtor_ids is not null
    and creditor_ids is not null
    and debtor_index <= array_length(debtor_ids, 1)
    and creditor_index <= array_length(creditor_ids, 1)
  loop
    transfer_amount := least(
      debtor_amounts[debtor_index],
      creditor_amounts[creditor_index]
    );
    insert into public.settlement_transfers (
      revision_id, from_participant_id, to_participant_id, amount_cents
    ) values (
      p_revision_id,
      debtor_ids[debtor_index],
      creditor_ids[creditor_index],
      transfer_amount
    );
    debtor_amounts[debtor_index] :=
      debtor_amounts[debtor_index] - transfer_amount;
    creditor_amounts[creditor_index] :=
      creditor_amounts[creditor_index] - transfer_amount;
    if debtor_amounts[debtor_index] = 0 then
      debtor_index := debtor_index + 1;
    end if;
    if creditor_amounts[creditor_index] = 0 then
      creditor_index := creditor_index + 1;
    end if;
  end loop;
end;
$$;

create or replace function public.finalize_v2_session(
  p_session_id bigint,
  p_reason text,
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
  revision public.finalization_revisions;
  total_positive bigint;
  total_negative bigint;
  revision_number integer;
  prior jsonb;
  result jsonb;
begin
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'finalize_v2_session',
    jsonb_build_object(
      'session_id', p_session_id,
      'reason', p_reason
    )
  );
  if prior is not null then return prior; end if;

  game := private.require_v2_host(p_session_id);
  if game.phase <> 'live' then
    raise exception 'Only a live game can be finalized'
      using errcode = '22023';
  end if;
  if exists (
    select 1
    from public.session_players participant
    where participant.session_id = p_session_id
      and participant.removed_at is null
      and not exists (
        select 1
        from public.ledger_events cash_out
        where cash_out.session_id = p_session_id
          and cash_out.participant_id = participant.id
          and cash_out.event_type = 'cash_out'
          and not exists (
            select 1 from public.ledger_events reversal
            where reversal.reverses_event_id = cash_out.id
          )
      )
  ) then
    raise exception 'Every player needs a cash-out before finalization'
      using errcode = '22023';
  end if;

  select
    coalesce(sum(amount_cents) filter (where amount_cents > 0), 0),
    coalesce(-sum(amount_cents) filter (where amount_cents < 0), 0)
  into total_positive, total_negative
  from public.ledger_events
  where session_id = p_session_id;

  if total_positive <> total_negative then
    raise exception 'Buy-ins and cash-outs must balance (% vs %)',
      total_positive, total_negative
      using errcode = '23514';
  end if;

  select coalesce(max(fr.revision_number), 0) + 1
  into revision_number
  from public.finalization_revisions fr
  where fr.session_id = p_session_id;

  update public.finalization_revisions
  set superseded_at = now()
  where session_id = p_session_id
    and superseded_at is null;

  insert into public.finalization_revisions (
    session_id,
    revision_number,
    through_event_sequence,
    settlement_engine_version,
    settlement_mode,
    total_buy_in_cents,
    total_cash_out_cents,
    reason,
    created_by
  )
  values (
    p_session_id,
    revision_number,
    game.next_event_sequence - 1,
    1,
    game.settlement_mode,
    total_positive,
    total_negative,
    nullif(btrim(p_reason), ''),
    actor
  )
  returning * into revision;

  perform private.create_settlement_transfers(
    revision.id,
    p_session_id,
    game.settlement_mode,
    game.banker_session_player_id
  );

  update public.sessions
  set phase = 'finalized',
      finalized = true,
      ended_at = coalesce(ended_at, now()),
      latest_revision_id = revision.id,
      updated_at = now()
  where id = p_session_id;

  result := jsonb_build_object(
    'session_id', p_session_id,
    'revision_id', revision.id,
    'revision_number', revision.revision_number,
    'total_buy_in_cents', total_positive,
    'total_cash_out_cents', total_negative
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.reopen_v2_session(
  p_session_id bigint,
  p_reason text,
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
  result jsonb;
begin
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'reopen_v2_session',
    jsonb_build_object('session_id', p_session_id, 'reason', p_reason)
  );
  if prior is not null then return prior; end if;

  game := private.require_v2_host(p_session_id);
  if game.phase <> 'finalized' or game.latest_revision_id is null then
    raise exception 'Only a finalized game can be reopened'
      using errcode = '22023';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'A correction reason is required'
      using errcode = '22023';
  end if;

  perform set_config('app.allow_finalized_revision', 'on', true);
  update public.sessions
  set phase = 'live',
      finalized = false,
      updated_at = now()
  where id = p_session_id;

  result := jsonb_build_object(
    'session_id', p_session_id,
    'phase', 'live',
    'previous_revision_id', game.latest_revision_id,
    'reason', btrim(p_reason)
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.archive_group(
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
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'archive_group',
    jsonb_build_object('group_id', p_group_id)
  );
  if prior is not null then return prior; end if;

  if not exists (
    select 1 from public.groups
    where id = p_group_id and owner_id = actor
    for update
  ) then
    raise exception 'Only the group owner can archive this group'
      using errcode = '42501';
  end if;
  if exists (
    select 1 from public.sessions
    where group_id = p_group_id
      and ledger_version = 2
      and phase in ('draft', 'live', 'settling')
  ) then
    raise exception 'Finalize or cancel open group games first'
      using errcode = '22023';
  end if;

  update public.groups
  set archived_at = coalesce(archived_at, now()),
      updated_at = now()
  where id = p_group_id;

  result := jsonb_build_object('group_id', p_group_id, 'archived', true);
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

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
    select 1
    from public.groups g
    where g.id = p_group_id
      and g.owner_id = p_actor_id
  ) or exists (
    select 1
    from public.group_members gm
    where gm.group_id = p_group_id
      and gm.user_id = p_actor_id
      and gm.status = 'accepted'
      and gm.left_at is null
      and gm.role = 'administrator'
      and gm.can_manage_games
  );
$$;

create or replace function public.invite_profile_to_group(
  p_group_id bigint,
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
  invitation public.group_invitations;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'invite_profile_to_group',
    jsonb_build_object('group_id', p_group_id, 'profile_id', p_profile_id)
  );
  if prior is not null then return prior; end if;

  if not private.can_manage_group(p_group_id, actor) then
    raise exception 'You cannot manage this group' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.groups
    where id = p_group_id and archived_at is not null
  ) then
    raise exception 'Archived groups cannot add members'
      using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = p_profile_id
      and discoverable
      and deleted_at is null
      and suspended_at is null
  ) then
    raise exception 'Profile not found' using errcode = 'P0002';
  end if;
  if exists (
    select 1 from public.groups
    where id = p_group_id and owner_id = p_profile_id
  ) or exists (
    select 1 from public.group_members
    where group_id = p_group_id
      and user_id = p_profile_id
      and status = 'accepted'
      and left_at is null
  ) then
    result := jsonb_build_object('group_id', p_group_id, 'status', 'accepted');
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;

  update public.group_invitations
  set status = 'cancelled', responded_at = now()
  where group_id = p_group_id
    and profile_id = p_profile_id
    and status = 'pending';

  insert into public.group_invitations (
    group_id,
    profile_id,
    invited_by,
    status,
    expires_at
  )
  values (
    p_group_id,
    p_profile_id,
    actor,
    'pending',
    now() + interval '7 days'
  )
  returning * into invitation;

  insert into public.user_notifications (
    user_id,
    notification_type,
    title,
    body,
    data
  )
  values (
    p_profile_id,
    'group_invitation',
    'Poker group invitation',
    'You were invited to join a poker group.',
    jsonb_build_object('group_id', p_group_id, 'invitation_id', invitation.id)
  );

  result := jsonb_build_object(
    'invitation_id', invitation.id,
    'status', invitation.status
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.respond_to_group_invitation(
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
  invitation public.group_invitations;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'respond_to_group_invitation',
    jsonb_build_object('invitation_id', p_invitation_id, 'accept', p_accept)
  );
  if prior is not null then return prior; end if;

  select * into invitation
  from public.group_invitations
  where id = p_invitation_id
  for update;
  if not found
     or invitation.profile_id <> actor
     or invitation.status <> 'pending'
     or invitation.expires_at <= now() then
    raise exception 'Invitation is no longer pending' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.groups
    where id = invitation.group_id and archived_at is not null
  ) then
    raise exception 'This group is archived' using errcode = '22023';
  end if;

  update public.group_invitations
  set status = case when p_accept then 'accepted' else 'declined' end,
      responded_at = now()
  where id = invitation.id;

  if p_accept then
    insert into public.group_members (
      group_id,
      user_id,
      joined_at,
      status,
      role,
      accepted_at,
      left_at
    )
    values (
      invitation.group_id,
      actor,
      now(),
      'accepted',
      'member',
      now(),
      null
    )
    on conflict (group_id, user_id) do update set
      status = 'accepted',
      role = 'member',
      accepted_at = now(),
      left_at = null;
  end if;

  result := jsonb_build_object(
    'group_id', invitation.group_id,
    'status', case when p_accept then 'accepted' else 'declined' end
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.remove_group_member(
  p_group_id bigint,
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
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'remove_group_member',
    jsonb_build_object('group_id', p_group_id, 'profile_id', p_profile_id)
  );
  if prior is not null then return prior; end if;
  if not private.can_manage_group(p_group_id, actor) then
    raise exception 'You cannot manage this group' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.groups
    where id = p_group_id and archived_at is not null
  ) then
    raise exception 'Archived group membership is read-only'
      using errcode = '22023';
  end if;

  update public.group_members
  set status = 'removed', left_at = now()
  where group_id = p_group_id
    and user_id = p_profile_id
    and status = 'accepted'
    and left_at is null;

  result := jsonb_build_object('group_id', p_group_id, 'status', 'removed');
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
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
    actor,
    p_idempotency_key,
    'leave_group',
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
  set status = 'removed', left_at = now()
  where group_id = p_group_id
    and user_id = actor
    and status = 'accepted'
    and left_at is null;

  result := jsonb_build_object('group_id', p_group_id, 'status', 'left');
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
  raise exception 'Financial history is append-only' using errcode = '55000';
end;
$$;

create or replace function private.handle_unavailable_v2_host()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  game record;
  successor uuid;
begin
  if (
    old.deleted_at is null and new.deleted_at is not null
  ) or (
    old.suspended_at is null and new.suspended_at is not null
  ) then
    for game in
      select *
      from public.sessions
      where ledger_version = 2
        and current_host_id = new.id
      for update
    loop
      successor := null;
      if game.group_id is not null then
        if game.backup_host_id is not null
           and exists (
             select 1 from public.profiles p
             where p.id = game.backup_host_id
               and p.deleted_at is null
               and p.suspended_at is null
           )
           and public.is_accepted_group_member(
             game.group_id,
             game.backup_host_id
           ) then
          successor := game.backup_host_id;
        end if;

        if successor is null then
          select g.owner_id into successor
          from public.groups g
          join public.profiles p on p.id = g.owner_id
          where g.id = game.group_id
            and p.deleted_at is null
            and p.suspended_at is null;
        end if;

        if successor is null then
          select gm.user_id into successor
          from public.group_members gm
          join public.profiles p on p.id = gm.user_id
          where gm.group_id = game.group_id
            and gm.status = 'accepted'
            and gm.left_at is null
            and gm.role = 'administrator'
            and gm.can_manage_games
            and p.deleted_at is null
            and p.suspended_at is null
          order by gm.accepted_at, gm.id
          limit 1;
        end if;
      end if;

      update public.sessions
      set current_host_id = successor,
          phase = case
            when successor is not null then phase
            when phase = 'finalized' then phase
            when group_id is null then 'owner_unavailable_read_only'
            else 'orphaned_read_only'
          end,
          updated_at = now()
      where id = game.id;
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_handle_unavailable_v2_host
  on public.profiles;
create trigger profiles_handle_unavailable_v2_host
  after update of deleted_at, suspended_at on public.profiles
  for each row execute function private.handle_unavailable_v2_host();

drop trigger if exists ledger_events_append_only on public.ledger_events;
create trigger ledger_events_append_only
  before update or delete on public.ledger_events
  for each row execute function private.prevent_ledger_mutation();
drop trigger if exists revisions_append_only on public.finalization_revisions;
create trigger revisions_append_only
  before delete on public.finalization_revisions
  for each row execute function private.prevent_ledger_mutation();
drop trigger if exists transfers_no_delete on public.settlement_transfers;
create trigger transfers_no_delete
  before delete on public.settlement_transfers
  for each row execute function private.prevent_ledger_mutation();

create or replace function private.guard_legacy_financial_rows()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  game public.sessions;
  target_session_id bigint;
begin
  if tg_table_name = 'session_players' then
    target_session_id := coalesce(new.session_id, old.session_id);
  else
    select sp.session_id into target_session_id
    from public.session_players sp
    where sp.id = coalesce(new.session_player_id, old.session_player_id);
  end if;
  select * into game from public.sessions where id = target_session_id;
  if game.ledger_version = 2 or game.finalized then
    raise exception 'Use the transactional ledger API for this game'
      using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists session_players_guard_financial_rows on public.session_players;
create trigger session_players_guard_financial_rows
  before update or delete on public.session_players
  for each row execute function private.guard_legacy_financial_rows();
drop trigger if exists rebuys_guard_financial_rows on public.rebuys;
create trigger rebuys_guard_financial_rows
  before insert or update or delete on public.rebuys
  for each row execute function private.guard_legacy_financial_rows();

create or replace function private.guard_finalized_session()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.finalized
     and current_setting('app.allow_finalized_revision', true) is distinct from 'on'
     and to_jsonb(old) is distinct from to_jsonb(new) then
    raise exception 'Finalized games are immutable; create a correction revision'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

drop trigger if exists sessions_guard_finalized on public.sessions;
create trigger sessions_guard_finalized
  before update on public.sessions
  for each row execute function private.guard_finalized_session();

revoke all on function public.create_v2_session(text, bigint, bigint, text, boolean, uuid) from public;
revoke all on function public.invite_profile_to_game(bigint, uuid, uuid) from public;
revoke all on function public.create_game_join_code(bigint, uuid) from public;
revoke all on function public.request_game_join_by_code(text, uuid) from public;
revoke all on function public.respond_to_game_invitation(uuid, boolean, uuid) from public;
revoke all on function public.start_v2_session(
  bigint,
  text,
  bigint,
  uuid,
  bigint[]
) from public;
revoke all on function public.record_v2_ledger_event(bigint, bigint, text, bigint, text, bigint, uuid) from public;
revoke all on function public.finalize_v2_session(bigint, text, uuid) from public;
revoke all on function public.reopen_v2_session(bigint, text, uuid) from public;
revoke all on function public.archive_group(bigint, uuid) from public;
revoke all on function public.invite_profile_to_group(bigint, uuid, uuid) from public;
revoke all on function public.respond_to_group_invitation(uuid, boolean, uuid) from public;
revoke all on function public.remove_group_member(bigint, uuid, uuid) from public;
revoke all on function public.leave_group(bigint, uuid) from public;

grant execute on function public.create_v2_session(text, bigint, bigint, text, boolean, uuid) to authenticated;
grant execute on function public.invite_profile_to_game(bigint, uuid, uuid) to authenticated;
grant execute on function public.create_game_join_code(bigint, uuid) to authenticated;
grant execute on function public.request_game_join_by_code(text, uuid) to authenticated;
grant execute on function public.respond_to_game_invitation(uuid, boolean, uuid) to authenticated;
grant execute on function public.start_v2_session(
  bigint,
  text,
  bigint,
  uuid,
  bigint[]
) to authenticated;
grant execute on function public.record_v2_ledger_event(bigint, bigint, text, bigint, text, bigint, uuid) to authenticated;
grant execute on function public.finalize_v2_session(bigint, text, uuid) to authenticated;
grant execute on function public.reopen_v2_session(bigint, text, uuid) to authenticated;
grant execute on function public.archive_group(bigint, uuid) to authenticated;
grant execute on function public.invite_profile_to_group(bigint, uuid, uuid) to authenticated;
grant execute on function public.respond_to_group_invitation(uuid, boolean, uuid) to authenticated;
grant execute on function public.remove_group_member(bigint, uuid, uuid) to authenticated;
grant execute on function public.leave_group(bigint, uuid) to authenticated;
