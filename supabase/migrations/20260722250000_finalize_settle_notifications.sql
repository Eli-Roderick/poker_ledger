-- Notify each player of settle-up dues on finalize + Home open-transfers RPC.

create or replace function private.format_cents_usd(p_amount_cents bigint)
returns text
language sql
immutable
set search_path = ''
as $$
  select '$' || to_char(coalesce(p_amount_cents, 0) / 100.0, 'FM999999990.00');
$$;

create or replace function private.notify_settlement_dues(
  p_session_id bigint,
  p_revision_id bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  game_name text;
  participant_row public.session_players;
  body_text text;
  line text;
  transfer_row record;
begin
  select coalesce(nullif(btrim(name), ''), 'Poker game')
  into game_name
  from public.sessions
  where id = p_session_id;

  for participant_row in
    select *
    from public.session_players
    where session_id = p_session_id
      and removed_at is null
      and profile_id is not null
  loop
    body_text := '';
    for transfer_row in
      select
        transfer.amount_cents,
        transfer.from_participant_id,
        transfer.to_participant_id,
        case
          when transfer.from_participant_id = participant_row.id
            then coalesce(creditor.display_name_snapshot, 'Player')
          else coalesce(debtor.display_name_snapshot, 'Player')
        end as counterparty_name,
        case
          when transfer.from_participant_id = participant_row.id
            then 'owe'
          else 'owed'
        end as direction
      from public.settlement_transfers transfer
      join public.session_players debtor
        on debtor.id = transfer.from_participant_id
      join public.session_players creditor
        on creditor.id = transfer.to_participant_id
      where transfer.revision_id = p_revision_id
        and (
          transfer.from_participant_id = participant_row.id
          or transfer.to_participant_id = participant_row.id
        )
      order by transfer.id
    loop
      if transfer_row.direction = 'owe' then
        line :=
          'You owe '
          || transfer_row.counterparty_name
          || ' '
          || private.format_cents_usd(transfer_row.amount_cents)
          || '.';
      else
        line :=
          transfer_row.counterparty_name
          || ' owes you '
          || private.format_cents_usd(transfer_row.amount_cents)
          || '.';
      end if;
      body_text := case
        when body_text = '' then line
        else body_text || E'\n' || line
      end;
    end loop;

    if body_text = '' then
      continue;
    end if;

    insert into public.user_notifications (
      user_id,
      notification_type,
      title,
      body,
      data
    )
    values (
      participant_row.profile_id,
      'settlement_due',
      'Settle up — ' || game_name,
      body_text,
      jsonb_build_object(
        'session_id', p_session_id,
        'revision_id', p_revision_id
      )
    );
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
  total_input bigint;
  total_output bigint;
  revision_number integer;
  boundary bigint;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'finalize_v2_session',
    jsonb_build_object('session_id', p_session_id, 'reason', p_reason)
  );
  if prior is not null then
    return prior;
  end if;
  game := private.require_v2_host(p_session_id);
  if game.phase <> 'settling' then
    raise exception 'Only a game in settlement can be finalized'
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
            select 1
            from public.ledger_events reversal
            where reversal.reverses_event_id = cash_out.id
          )
      )
  ) then
    raise exception 'Every player needs a cash-out before finalization'
      using errcode = '23514';
  end if;

  boundary := game.next_event_sequence - 1;
  select coalesce(sum(input_cents), 0), coalesce(sum(output_cents), 0)
  into total_input, total_output
  from private.event_money_components(p_session_id, boundary);
  if total_input <> total_output then
    raise exception 'Buy-ins and cash-outs must balance (% vs %)',
      total_input,
      total_output
      using errcode = '23514';
  end if;

  select coalesce(max(fr.revision_number), 0) + 1
  into revision_number
  from public.finalization_revisions fr
  where fr.session_id = p_session_id;

  insert into public.finalization_revisions (
    session_id,
    revision_number,
    through_event_sequence,
    settlement_engine_version,
    settlement_mode,
    total_buy_in_cents,
    total_cash_out_cents,
    reason,
    created_by,
    supersedes_revision_id
  )
  values (
    p_session_id,
    revision_number,
    boundary,
    1,
    game.settlement_mode,
    total_input,
    total_output,
    nullif(btrim(p_reason), ''),
    actor,
    game.latest_revision_id
  )
  returning * into revision;

  perform private.create_settlement_transfers(
    revision.id,
    p_session_id,
    game.settlement_mode,
    game.banker_session_player_id
  );
  perform private.notify_settlement_dues(p_session_id, revision.id);

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
    'total_buy_in_cents', total_input,
    'total_cash_out_cents', total_output
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'finalize_v2_session',
    p_session_id,
    'finalized'
  );
  return result;
end;
$$;

create or replace function public.my_open_settlement_transfers()
returns table (
  transfer_id bigint,
  session_id bigint,
  game_name text,
  amount_cents bigint,
  status text,
  direction text,
  counterparty_name text,
  from_participant_id bigint,
  to_participant_id bigint,
  my_participant_id bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
begin
  perform private.require_compatible_client();
  return query
  select
    transfer.id as transfer_id,
    game.id as session_id,
    coalesce(nullif(btrim(game.name), ''), 'Poker game') as game_name,
    transfer.amount_cents,
    transfer.status,
    case
      when transfer.from_participant_id = me.id then 'owe'
      else 'owed'
    end as direction,
    case
      when transfer.from_participant_id = me.id
        then coalesce(creditor.display_name_snapshot, 'Player')
      else coalesce(debtor.display_name_snapshot, 'Player')
    end as counterparty_name,
    transfer.from_participant_id,
    transfer.to_participant_id,
    me.id as my_participant_id
  from public.settlement_transfers transfer
  join public.finalization_revisions revision
    on revision.id = transfer.revision_id
  join public.sessions game
    on game.id = revision.session_id
  join public.session_players me
    on me.session_id = game.id
   and me.profile_id = actor
   and me.removed_at is null
  join public.session_players debtor
    on debtor.id = transfer.from_participant_id
  join public.session_players creditor
    on creditor.id = transfer.to_participant_id
  where game.phase = 'finalized'
    and game.latest_revision_id = revision.id
    and transfer.status in ('pending', 'paid', 'disputed')
    and (
      transfer.from_participant_id = me.id
      or transfer.to_participant_id = me.id
    )
  order by transfer.created_at desc, transfer.id desc;
end;
$$;

revoke all on function public.finalize_v2_session(bigint, text, uuid)
  from public, anon;
grant execute on function public.finalize_v2_session(bigint, text, uuid)
  to authenticated;

revoke all on function public.my_open_settlement_transfers() from public;
grant execute on function public.my_open_settlement_transfers()
  to authenticated;
