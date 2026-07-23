-- Out / eliminated players: flag + $0 cash-out in settling.

alter table public.session_players
  add column if not exists eliminated_at timestamptz;

-- Allow cash_out of exactly 0 (eliminated / busted).
alter table public.ledger_events
  drop constraint if exists ledger_events_amount_cents_check;

alter table public.ledger_events
  add constraint ledger_events_amount_cents_check
  check (
    amount_cents <> 0
    or event_type = 'cash_out'
  );

alter table public.ledger_events
  drop constraint if exists ledger_events_check;

alter table public.ledger_events
  add constraint ledger_events_check
  check (
    (
      event_type = any (array['initial_buy_in'::text, 'rebuy'::text])
      and amount_cents > 0
    )
    or (
      event_type = 'cash_out'
      and amount_cents <= 0
    )
    or (
      event_type = any (array['reversal'::text, 'correction'::text])
    )
  );

create or replace function private.upsert_zero_cash_out(
  p_session_id bigint,
  p_participant_id bigint,
  p_actor uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  game public.sessions;
  existing public.ledger_events;
  actor_name text;
begin
  select * into game
  from public.sessions
  where id = p_session_id
  for update;

  select * into existing
  from public.ledger_events original
  where original.session_id = p_session_id
    and original.participant_id = p_participant_id
    and original.event_type = 'cash_out'
    and not exists (
      select 1 from public.ledger_events reversal
      where reversal.reverses_event_id = original.id
    )
  order by original.event_sequence desc
  limit 1;

  if found then
    if existing.amount_cents = 0 then
      return;
    end if;
    -- Non-zero cash-out already present; leave it.
    return;
  end if;

  select display_name into actor_name
  from public.profiles
  where id = p_actor;

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
    'cash_out',
    0,
    p_actor,
    actor_name,
    'Eliminated',
    null,
    extensions.gen_random_uuid()
  );

  update public.sessions
  set next_event_sequence = next_event_sequence + 1,
      updated_at = now()
  where id = p_session_id;
end;
$$;

create or replace function private.clear_zero_cash_out(
  p_session_id bigint,
  p_participant_id bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.ledger_events;
begin
  select * into target
  from public.ledger_events original
  where original.session_id = p_session_id
    and original.participant_id = p_participant_id
    and original.event_type = 'cash_out'
    and original.amount_cents = 0
    and not exists (
      select 1 from public.ledger_events reversal
      where reversal.reverses_event_id = original.id
    )
  order by original.event_sequence desc
  limit 1;
  if not found then
    return;
  end if;

  delete from public.ledger_events
  where session_id = p_session_id
    and reverses_event_id = target.id;

  delete from public.ledger_events
  where id = target.id;
end;
$$;

create or replace function public.set_v2_participant_eliminated(
  p_session_id bigint,
  p_participant_id bigint,
  p_eliminated boolean,
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
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'set_v2_participant_eliminated',
    jsonb_build_object(
      'session_id', p_session_id,
      'participant_id', p_participant_id,
      'eliminated', p_eliminated
    )
  );
  if prior is not null then
    return prior;
  end if;

  game := private.require_v2_host(p_session_id);
  if game.phase not in ('live', 'settling') then
    raise exception 'Players can only be marked out while live or settling'
      using errcode = '22023';
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

  if p_eliminated then
    update public.session_players
    set eliminated_at = coalesce(eliminated_at, now())
    where id = p_participant_id;
    if game.phase = 'settling' then
      perform private.upsert_zero_cash_out(
        p_session_id,
        p_participant_id,
        actor
      );
    end if;
  else
    update public.session_players
    set eliminated_at = null
    where id = p_participant_id;
    perform private.clear_zero_cash_out(p_session_id, p_participant_id);
  end if;

  update public.sessions
  set updated_at = now()
  where id = p_session_id;

  result := jsonb_build_object(
    'session_id', p_session_id,
    'participant_id', p_participant_id,
    'eliminated', p_eliminated
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.set_v2_cash_out(
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
  prior jsonb;
  result jsonb;
  existing public.ledger_events;
  event public.ledger_events;
  signed_amount bigint;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'set_v2_cash_out',
    jsonb_build_object(
      'session_id', p_session_id,
      'participant_id', p_participant_id,
      'amount_cents', p_amount_cents
    )
  );
  if prior is not null then
    return prior;
  end if;

  game := private.require_v2_host(p_session_id);
  if game.phase <> 'settling' then
    raise exception 'Cash-outs can only be set while settling'
      using errcode = '22023';
  end if;
  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'Cash-out cannot be negative'
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

  signed_amount := -abs(p_amount_cents);

  select * into existing
  from public.ledger_events original
  where original.session_id = p_session_id
    and original.participant_id = p_participant_id
    and original.event_type = 'cash_out'
    and not exists (
      select 1 from public.ledger_events reversal
      where reversal.reverses_event_id = original.id
    )
  order by original.event_sequence desc
  limit 1;

  if found then
    if existing.amount_cents = signed_amount then
      result := jsonb_build_object(
        'event_id', existing.id,
        'event_sequence', existing.event_sequence,
        'amount_cents', existing.amount_cents,
        'updated', false
      );
      perform private.complete_idempotent(actor, p_idempotency_key, result);
      return result;
    end if;

    update public.ledger_events
    set amount_cents = signed_amount,
        actor_id = actor,
        actor_snapshot = (
          select display_name from public.profiles where id = actor
        ),
        reason = case
          when signed_amount = 0 then coalesce(reason, 'Eliminated')
          else null
        end
    where id = existing.id
    returning * into event;

    update public.sessions
    set updated_at = now()
    where id = p_session_id;

    result := jsonb_build_object(
      'event_id', event.id,
      'event_sequence', event.event_sequence,
      'amount_cents', event.amount_cents,
      'updated', true
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
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
    'cash_out',
    signed_amount,
    actor,
    (select display_name from public.profiles where id = actor),
    case when signed_amount = 0 then 'Eliminated' else null end,
    null,
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
    'amount_cents', event.amount_cents,
    'created', true
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

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
  participant_row public.session_players;
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

  for participant_row in
    select *
    from public.session_players
    where session_id = p_session_id
      and removed_at is null
      and eliminated_at is not null
  loop
    perform private.upsert_zero_cash_out(
      p_session_id,
      participant_row.id,
      actor
    );
  end loop;

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

revoke all on function public.set_v2_participant_eliminated(
  bigint, bigint, boolean, uuid
) from public;
grant execute on function public.set_v2_participant_eliminated(
  bigint, bigint, boolean, uuid
) to authenticated;

revoke all on function public.set_v2_cash_out(bigint, bigint, bigint, uuid)
  from public;
grant execute on function public.set_v2_cash_out(bigint, bigint, bigint, uuid)
  to authenticated;

revoke all on function public.begin_v2_settlement(bigint, uuid)
  from public, anon;
grant execute on function public.begin_v2_settlement(bigint, uuid)
  to authenticated;
