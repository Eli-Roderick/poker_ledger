-- Pre-finalize ledger is host-mutable (update/delete).
-- After finalize, history stays append-only; corrections use the existing RPC.

create or replace function private.prevent_ledger_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  session_phase text;
  target_session_id bigint;
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

  if tg_table_name = 'ledger_events' then
    target_session_id := coalesce(new.session_id, old.session_id);
    select phase into session_phase
    from public.sessions
    where id = target_session_id;
    if session_phase is distinct from 'finalized' then
      if tg_op = 'DELETE' then
        return old;
      end if;
      return new;
    end if;
  end if;

  raise exception 'Financial history is append-only' using errcode = '55000';
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
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Cash-out must be greater than zero'
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
        reason = null
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
    null,
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
    'updated', false
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.delete_v2_ledger_event(
  p_session_id bigint,
  p_event_id bigint,
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
  target public.ledger_events;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'delete_v2_ledger_event',
    jsonb_build_object(
      'session_id', p_session_id,
      'event_id', p_event_id
    )
  );
  if prior is not null then
    return prior;
  end if;

  game := private.require_v2_host(p_session_id);
  if game.phase not in ('live', 'settling') then
    raise exception 'Ledger events can only be removed before finalization'
      using errcode = '22023';
  end if;

  select * into target
  from public.ledger_events
  where id = p_event_id
    and session_id = p_session_id;
  if not found then
    raise exception 'Ledger event not found' using errcode = 'P0002';
  end if;
  if target.event_type not in ('rebuy', 'cash_out') then
    raise exception 'Only rebuys and cash-outs can be removed before finalization'
      using errcode = '22023';
  end if;

  -- Drop any reversal that points at this event first (pre-finalize draft cleanup).
  delete from public.ledger_events
  where session_id = p_session_id
    and reverses_event_id = p_event_id;

  delete from public.ledger_events
  where id = p_event_id
    and session_id = p_session_id;

  update public.sessions
  set updated_at = now()
  where id = p_session_id;

  result := jsonb_build_object(
    'session_id', p_session_id,
    'event_id', p_event_id,
    'deleted', true
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

revoke all on function public.set_v2_cash_out(bigint, bigint, bigint, uuid)
  from public;
revoke all on function public.delete_v2_ledger_event(bigint, bigint, uuid)
  from public;
grant execute on function public.set_v2_cash_out(bigint, bigint, bigint, uuid)
  to authenticated;
grant execute on function public.delete_v2_ledger_event(bigint, bigint, uuid)
  to authenticated;
