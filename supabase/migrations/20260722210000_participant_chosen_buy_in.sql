-- Per-player chosen buy-in for draft lobby edits and first-set on live join.

alter table public.session_players
  add column if not exists chosen_buy_in_cents bigint;

alter table public.session_players
  drop constraint if exists session_players_chosen_buy_in_cents_check;

alter table public.session_players
  add constraint session_players_chosen_buy_in_cents_check
  check (
    chosen_buy_in_cents is null
    or chosen_buy_in_cents > 0
  );

create or replace function public.set_v2_buy_in(
  p_session_id bigint,
  p_participant_id bigint,
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
  game public.sessions;
  participant public.session_players;
  prior jsonb;
  result jsonb;
  buy_in_event public.ledger_events;
  is_host boolean;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'set_v2_buy_in',
    jsonb_build_object(
      'session_id', p_session_id,
      'participant_id', p_participant_id,
      'amount_cents', p_amount_cents
    )
  );
  if prior is not null then
    return prior;
  end if;

  select * into game
  from public.sessions
  where id = p_session_id
  for update;
  if not found or game.ledger_version <> 2 then
    raise exception 'Game not found' using errcode = 'P0002';
  end if;

  select * into participant
  from public.session_players
  where id = p_participant_id
    and session_id = p_session_id
    and removed_at is null
  for update;
  if not found then
    raise exception 'Player is not active in this game' using errcode = 'P0002';
  end if;

  is_host := game.current_host_id = actor
    or game.backup_host_id = actor;
  if not is_host and participant.profile_id is distinct from actor then
    raise exception 'Only the host or that player can set this buy-in'
      using errcode = '42501';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Buy-in must be greater than zero' using errcode = '22023';
  end if;

  if game.phase = 'draft' then
    update public.session_players
    set chosen_buy_in_cents = p_amount_cents
    where id = participant.id;

    update public.sessions
    set updated_at = now()
    where id = p_session_id;

    result := jsonb_build_object(
      'session_id', p_session_id,
      'participant_id', p_participant_id,
      'chosen_buy_in_cents', p_amount_cents,
      'phase', game.phase
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;

  if game.phase = 'live' then
    -- First-set only after mid-live join (accept popup). Lobby edits are draft-only.
    if participant.chosen_buy_in_cents is not null then
      raise exception 'Buy-ins cannot be changed after the game is live'
        using errcode = '22023';
    end if;

    select * into buy_in_event
    from public.ledger_events original
    where original.session_id = p_session_id
      and original.participant_id = p_participant_id
      and original.event_type = 'initial_buy_in'
      and not exists (
        select 1 from public.ledger_events reversal
        where reversal.reverses_event_id = original.id
      )
    order by original.event_sequence
    limit 1;

    if not found then
      raise exception 'Initial buy-in not found for this player'
        using errcode = 'P0002';
    end if;

    update public.session_players
    set chosen_buy_in_cents = p_amount_cents
    where id = participant.id;

    update public.ledger_events
    set amount_cents = abs(p_amount_cents),
        actor_id = actor,
        actor_snapshot = (
          select display_name from public.profiles where id = actor
        )
    where id = buy_in_event.id;

    update public.sessions
    set updated_at = now()
    where id = p_session_id;

    result := jsonb_build_object(
      'session_id', p_session_id,
      'participant_id', p_participant_id,
      'chosen_buy_in_cents', p_amount_cents,
      'event_id', buy_in_event.id,
      'phase', game.phase
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;

  raise exception 'Buy-ins can only be set in the lobby or right after joining a live game'
    using errcode = '22023';
end;
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
  if not found then
    select * into participant
    from public.session_players
    where session_id = p_session_id
      and profile_id = p_profile_id
      and removed_at is null;
    return participant;
  end if;
  if game.phase = 'live' then
    buy_in_cents := coalesce(
      participant.chosen_buy_in_cents,
      game.default_buy_in_cents
    );
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
  end if;
  return participant;
end;
$$;

create or replace function public.start_v2_session(
  p_session_id bigint,
  p_settlement_mode text,
  p_banker_participant_id bigint default null,
  p_idempotency_key uuid default null,
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
  player_row record;
  sequence_number bigint;
  prior jsonb;
  result jsonb;
  idem uuid := coalesce(p_idempotency_key, extensions.gen_random_uuid());
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    idem,
    'start_v2_session',
    jsonb_build_object(
      'session_id', p_session_id,
      'settlement_mode', p_settlement_mode,
      'banker_participant_id', p_banker_participant_id,
      'paid_upfront_participant_ids',
        coalesce(p_paid_upfront_participant_ids, '{}'::bigint[])
    )
  );
  if prior is not null then
    return prior;
  end if;

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
    from unnest(
      coalesce(p_paid_upfront_participant_ids, '{}'::bigint[])
    ) as selected(selected_id)
    where not exists (
      select 1
      from public.session_players sp
      where sp.id = selected.selected_id
        and sp.session_id = p_session_id
        and sp.removed_at is null
    )
  ) then
    raise exception 'Paid-upfront selections must be accepted players'
      using errcode = '22023';
  end if;
  update public.session_players
  set paid_upfront = id = any(
    coalesce(p_paid_upfront_participant_ids, '{}'::bigint[])
  ),
      chosen_buy_in_cents = coalesce(chosen_buy_in_cents, game.default_buy_in_cents)
  where session_id = p_session_id
    and removed_at is null;

  sequence_number := game.next_event_sequence;
  for player_row in
    select id, chosen_buy_in_cents
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
      player_row.id,
      'initial_buy_in',
      coalesce(player_row.chosen_buy_in_cents, game.default_buy_in_cents),
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
  perform private.complete_idempotent(actor, idem, result);
  return result;
end;
$$;

revoke all on function public.set_v2_buy_in(bigint, bigint, bigint, uuid)
  from public;
grant execute on function public.set_v2_buy_in(bigint, bigint, bigint, uuid)
  to authenticated;

revoke all on function public.start_v2_session(
  bigint, text, bigint, uuid, bigint[]
) from public, anon;
grant execute on function public.start_v2_session(
  bigint, text, bigint, uuid, bigint[]
) to authenticated;
