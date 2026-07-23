-- Deferred buy-in join + repair Realtime publication for live sync.

-- ---------------------------------------------------------------------------
-- Realtime foundation
-- ---------------------------------------------------------------------------
alter table public.game_invitations replica identity full;
alter table public.sessions replica identity full;
alter table public.session_players replica identity full;
alter table public.ledger_events replica identity full;
alter table public.user_notifications replica identity full;
alter table public.group_invitations replica identity full;

do $$
declare
  t text;
begin
  foreach t in array array[
    'game_invitations',
    'sessions',
    'session_players',
    'ledger_events',
    'user_notifications',
    'group_invitations'
  ]
  loop
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = t
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I',
        t
      );
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Invitation status: accepted_pending_buy_in
-- ---------------------------------------------------------------------------
alter table public.game_invitations
  drop constraint if exists game_invitations_status_check;

alter table public.game_invitations
  add constraint game_invitations_status_check
  check (
    status in (
      'pending_invitee',
      'pending_host',
      'accepted_pending_buy_in',
      'accepted',
      'declined',
      'expired',
      'cancelled'
    )
  );

drop index if exists public.game_invitations_active_uidx;
create unique index game_invitations_active_uidx
  on public.game_invitations(session_id, profile_id)
  where status in (
    'pending_invitee',
    'pending_host',
    'accepted_pending_buy_in'
  );

-- ---------------------------------------------------------------------------
-- add_participant with optional buy-in
-- ---------------------------------------------------------------------------
drop function if exists private.add_participant(bigint, uuid);

create or replace function private.add_participant(
  p_session_id bigint,
  p_profile_id uuid,
  p_buy_in_cents bigint default null
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
  buy_in_cents bigint;
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

  buy_in_cents := nullif(p_buy_in_cents, 0);
  if buy_in_cents is not null and buy_in_cents <= 0 then
    raise exception 'Buy-in must be greater than zero' using errcode = '22023';
  end if;

  insert into public.session_players (
    session_id,
    player_id,
    profile_id,
    display_name_snapshot,
    accepted_at,
    legacy_participant,
    paid_upfront,
    chosen_buy_in_cents
  )
  values (
    p_session_id,
    null,
    p_profile_id,
    coalesce(nullif(btrim(profile.display_name), ''), profile.handle, 'Player'),
    now(),
    false,
    false,
    buy_in_cents
  )
  on conflict (session_id, profile_id)
    where profile_id is not null and removed_at is null
  do nothing
  returning * into participant;

  if not found then
    select * into participant
    from public.session_players
    where session_id = p_session_id
      and profile_id = p_profile_id
      and removed_at is null;
    return participant;
  end if;

  if game.phase = 'live' then
    buy_in_cents := coalesce(buy_in_cents, game.default_buy_in_cents);
    insert into public.ledger_events (
      session_id, event_sequence, participant_id, event_type,
      amount_cents, actor_id, actor_snapshot, idempotency_key
    )
    values (
      p_session_id, game.next_event_sequence, participant.id,
      'initial_buy_in', buy_in_cents, auth.uid(),
      (select display_name from public.profiles where id = auth.uid()),
      extensions.gen_random_uuid()
    );
    update public.sessions
    set next_event_sequence = next_event_sequence + 1,
        updated_at = now()
    where id = p_session_id;

    if participant.chosen_buy_in_cents is null then
      update public.session_players
      set chosen_buy_in_cents = buy_in_cents
      where id = participant.id
      returning * into participant;
    end if;
  end if;
  return participant;
end;
$$;

-- ---------------------------------------------------------------------------
-- respond: accept → accepted_pending_buy_in (no seat)
-- ---------------------------------------------------------------------------
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
    update public.game_invitations
    set status = 'accepted_pending_buy_in',
        responded_at = now()
    where id = invitation.id;
    result := jsonb_build_object(
      'status', 'accepted_pending_buy_in',
      'session_id', invitation.session_id,
      'invitation_id', invitation.id
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

-- ---------------------------------------------------------------------------
-- Joiner confirms buy-in and seats
-- ---------------------------------------------------------------------------
create or replace function public.confirm_game_join_buy_in(
  p_invitation_id uuid,
  p_amount_cents bigint,
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
    'confirm_game_join_buy_in',
    jsonb_build_object(
      'invitation_id', p_invitation_id,
      'amount_cents', p_amount_cents
    )
  );
  if prior is not null then return prior; end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Buy-in must be greater than zero' using errcode = '22023';
  end if;

  select * into invitation
  from public.game_invitations
  where id = p_invitation_id
  for update;
  if not found then
    raise exception 'Invitation not found' using errcode = 'P0002';
  end if;
  if invitation.profile_id <> actor then
    raise exception 'Only the invited player can confirm buy-in'
      using errcode = '42501';
  end if;
  if invitation.status <> 'accepted_pending_buy_in' then
    raise exception 'Invitation is not waiting for a buy-in'
      using errcode = '22023';
  end if;

  select * into game
  from public.sessions
  where id = invitation.session_id
  for update;
  if game.phase not in ('draft', 'live')
     or game.membership_closed_at is not null then
    raise exception 'This game is not accepting players'
      using errcode = '22023';
  end if;

  participant := private.add_participant(
    invitation.session_id,
    invitation.profile_id,
    p_amount_cents
  );

  update public.game_invitations
  set status = 'accepted',
      responded_at = coalesce(responded_at, now())
  where id = invitation.id;

  result := jsonb_build_object(
    'status', 'accepted',
    'session_id', invitation.session_id,
    'participant_id', participant.id,
    'chosen_buy_in_cents', p_amount_cents
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Acceptance info for joiners before they are seated (bypass RLS)
-- ---------------------------------------------------------------------------
create or replace function public.get_v2_join_acceptance_info(
  p_session_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  game public.sessions;
  host_name text;
  invitation public.game_invitations;
begin
  perform private.require_compatible_client();

  select * into game
  from public.sessions
  where id = p_session_id
    and ledger_version = 2;
  if not found then
    raise exception 'Game not found' using errcode = 'P0002';
  end if;

  select * into invitation
  from public.game_invitations
  where session_id = p_session_id
    and profile_id = actor
    and status = 'accepted_pending_buy_in'
  order by created_at desc
  limit 1;
  if not found then
    raise exception 'No pending buy-in invitation for this game'
      using errcode = 'P0002';
  end if;

  select coalesce(
    nullif(btrim(display_name), ''),
    nullif(btrim(handle), ''),
    'Host'
  )
  into host_name
  from public.profiles
  where id = game.current_host_id;

  return jsonb_build_object(
    'session_id', game.id,
    'invitation_id', invitation.id,
    'game_name', coalesce(nullif(btrim(game.name), ''), 'Poker game'),
    'host_name', coalesce(host_name, 'Host'),
    'phase', game.phase,
    'default_buy_in_cents', game.default_buy_in_cents,
    'currency_code', coalesce(game.currency_code, 'USD')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Cancel pending buy-in when entering settlement
-- ---------------------------------------------------------------------------
create or replace function public.begin_v2_settlement(
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
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'begin_v2_settlement',
    jsonb_build_object('session_id', p_session_id)
  );
  if prior is not null then return prior; end if;
  game := private.require_v2_host(p_session_id);
  if game.phase <> 'live' then
    raise exception 'Only a live game can enter settlement'
      using errcode = '22023';
  end if;

  update public.game_join_codes
  set revoked_at = coalesce(revoked_at, now())
  where session_id = p_session_id;
  update public.game_invitations
  set status = 'cancelled', cancelled_at = now()
  where session_id = p_session_id
    and status in (
      'pending_invitee',
      'pending_host',
      'accepted_pending_buy_in'
    );
  update public.sessions
  set phase = 'settling',
      membership_closed_at = now(),
      updated_at = now()
  where id = p_session_id;

  result := jsonb_build_object(
    'session_id', p_session_id,
    'phase', 'settling'
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'begin_v2_settlement',
    p_session_id,
    'settling'
  );
  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Notify joiner when approved / they accept invite (pending buy-in)
-- ---------------------------------------------------------------------------
create or replace function private.notify_game_invitation_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  game_name text;
  profile_name text;
  recipient uuid;
begin
  select coalesce(name, 'Poker game') into game_name
  from public.sessions where id = new.session_id;
  select coalesce(display_name, 'Poker Ledger player') into profile_name
  from public.profiles where id = new.profile_id;

  if tg_op = 'INSERT' then
    recipient := case
      when new.direction = 'host_invite' then new.profile_id
      else (
        select current_host_id from public.sessions where id = new.session_id
      )
    end;
    if recipient is not null then
      insert into public.user_notifications (
        user_id, notification_type, title, body, data
      )
      values (
        recipient,
        case
          when new.direction = 'host_invite' then 'game_invitation'
          else 'game_join_request'
        end,
        case
          when new.direction = 'host_invite' then 'Game invitation'
          else 'Game join request'
        end,
        case
          when new.direction = 'host_invite'
            then 'You were invited to ' || game_name || '.'
          else profile_name || ' requested to join ' || game_name || '.'
        end,
        jsonb_build_object(
          'session_id', new.session_id,
          'invitation_id', new.id
        )
      );
    end if;
  elsif old.status is distinct from new.status then
    if new.status = 'accepted_pending_buy_in' then
      -- Joiner needs to pick buy-in (whether host approved join request
      -- or invitee accepted a host invite).
      recipient := new.profile_id;
      if recipient is not null then
        insert into public.user_notifications (
          user_id, notification_type, title, body, data
        )
        values (
          recipient,
          'game_invitation_response',
          'Confirm your buy-in',
          'You are approved for ' || game_name ||
            '. Choose your buy-in to join.',
          jsonb_build_object(
            'session_id', new.session_id,
            'invitation_id', new.id,
            'status', new.status
          )
        );
      end if;
    elsif new.status in ('accepted', 'declined') then
      recipient := case
        when new.direction = 'host_invite' then new.created_by
        else new.profile_id
      end;
      if recipient is not null and recipient <> auth.uid() then
        insert into public.user_notifications (
          user_id, notification_type, title, body, data
        )
        values (
          recipient,
          'game_invitation_response',
          'Game invitation updated',
          case
            when new.direction = 'host_invite'
              then profile_name || ' ' || new.status ||
                ' the invitation to ' || game_name || '.'
            when new.status = 'accepted'
              then profile_name || ' joined ' || game_name || '.'
            else 'Your request to join ' || game_name || ' was ' ||
              new.status || '.'
          end,
          jsonb_build_object(
            'session_id', new.session_id,
            'invitation_id', new.id,
            'status', new.status
          )
        );
      end if;
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.respond_to_game_invitation(uuid, boolean, uuid)
  from public, anon;
grant execute on function public.respond_to_game_invitation(uuid, boolean, uuid)
  to authenticated;

revoke all on function public.confirm_game_join_buy_in(uuid, bigint, uuid)
  from public;
grant execute on function public.confirm_game_join_buy_in(uuid, bigint, uuid)
  to authenticated;

revoke all on function public.get_v2_join_acceptance_info(bigint)
  from public;
grant execute on function public.get_v2_join_acceptance_info(bigint)
  to authenticated;

revoke all on function public.begin_v2_settlement(bigint, uuid)
  from public, anon;
grant execute on function public.begin_v2_settlement(bigint, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Invite / join-code: treat accepted_pending_buy_in as active
-- ---------------------------------------------------------------------------
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
      and (
        status = 'accepted_pending_buy_in'
        or (
          status in ('pending_invitee', 'pending_host')
          and expires_at > now()
        )
      )
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
  if prior is not null then
    return prior;
  end if;
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
    result := jsonb_build_object(
      'status', 'participating',
      'session_id', game.id
    );
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
    and (
      status = 'accepted_pending_buy_in'
      or (
        status in ('pending_invitee', 'pending_host')
        and expires_at > now()
      )
    )
  order by created_at desc
  limit 1;
  if found then
    result := jsonb_build_object(
      'status', invitation.status,
      'invitation_id', invitation.id,
      'session_id', game.id
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
    actor, 'infinity'::timestamptz
  )
  returning * into invitation;
  result := jsonb_build_object(
    'status', invitation.status,
    'invitation_id', invitation.id,
    'session_id', game.id
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'request_game_join_by_code', game.id, game.phase
  );
  return result;
end;
$$;

revoke all on function public.invite_profile_to_game(bigint, uuid, uuid)
  from public, anon;
revoke all on function public.request_game_join_by_code(text, uuid)
  from public, anon;
grant execute on function public.invite_profile_to_game(bigint, uuid, uuid)
  to authenticated;
grant execute on function public.request_game_join_by_code(text, uuid)
  to authenticated;
