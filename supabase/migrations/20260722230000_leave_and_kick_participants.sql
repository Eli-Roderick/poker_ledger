-- Leave (lobby only) and host kick (until finalize): hard-delete participant + data.
-- Does not alter account-deletion anonymization paths.

create or replace function private.delete_participant_from_game(
  p_session_id bigint,
  p_participant_id bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  participant public.session_players;
  transfer_ids bigint[];
begin
  select * into participant
  from public.session_players
  where id = p_participant_id
    and session_id = p_session_id
  for update;
  if not found then
    raise exception 'Participant not found' using errcode = 'P0002';
  end if;

  update public.sessions
  set banker_session_player_id = case
        when banker_session_player_id = p_participant_id then null
        else banker_session_player_id
      end,
      backup_host_id = case
        when participant.profile_id is not null
             and backup_host_id = participant.profile_id then null
        else backup_host_id
      end,
      updated_at = now()
  where id = p_session_id;

  select coalesce(array_agg(id), '{}'::bigint[])
  into transfer_ids
  from public.settlement_transfers
  where from_participant_id = p_participant_id
     or to_participant_id = p_participant_id;

  if cardinality(transfer_ids) > 0 then
    delete from public.settlement_transfer_status_history
    where transfer_id = any (transfer_ids);
    delete from public.settlement_transfers
    where id = any (transfer_ids);
  end if;

  -- Break self-FK on reversals before deleting the participant's events.
  delete from public.ledger_events
  where session_id = p_session_id
    and reverses_event_id in (
      select id
      from public.ledger_events
      where session_id = p_session_id
        and participant_id = p_participant_id
    );

  delete from public.ledger_events
  where session_id = p_session_id
    and participant_id = p_participant_id;

  delete from public.rebuys
  where session_player_id = p_participant_id;

  if participant.profile_id is not null then
    update public.game_invitations
    set status = 'cancelled',
        cancelled_at = coalesce(cancelled_at, now())
    where session_id = p_session_id
      and profile_id = participant.profile_id
      and status in (
        'pending_invitee',
        'pending_host',
        'accepted_pending_buy_in'
      );
  end if;

  delete from public.session_players
  where id = p_participant_id
    and session_id = p_session_id;
end;
$$;

create or replace function public.leave_v2_session(
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
  participant public.session_players;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'leave_v2_session',
    jsonb_build_object('session_id', p_session_id)
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
  if game.current_host_id = actor then
    raise exception 'The host cannot leave; cancel the game instead'
      using errcode = '22023';
  end if;
  if game.phase <> 'draft' then
    raise exception 'You can only leave while the game is in the lobby'
      using errcode = '22023';
  end if;

  select * into participant
  from public.session_players
  where session_id = p_session_id
    and profile_id = actor
    and removed_at is null
  for update;
  if not found then
    raise exception 'You are not in this game' using errcode = 'P0002';
  end if;

  perform private.delete_participant_from_game(p_session_id, participant.id);

  result := jsonb_build_object(
    'session_id', p_session_id,
    'left', true,
    'participant_id', participant.id
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation('leave_v2_session', p_session_id, game.phase);
  return result;
end;
$$;

create or replace function public.remove_v2_participant(
  p_session_id bigint,
  p_participant_id bigint,
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
    'remove_v2_participant',
    jsonb_build_object(
      'session_id', p_session_id,
      'participant_id', p_participant_id
    )
  );
  if prior is not null then
    return prior;
  end if;

  game := private.require_v2_host(p_session_id);
  if game.phase in ('finalized', 'cancelled') then
    raise exception 'Players cannot be removed after the game is finalized'
      using errcode = '22023';
  end if;
  if game.phase not in ('draft', 'live', 'settling') then
    raise exception 'Players cannot be removed in this game phase'
      using errcode = '22023';
  end if;

  select * into participant
  from public.session_players
  where id = p_participant_id
    and session_id = p_session_id
    and removed_at is null
  for update;
  if not found then
    raise exception 'Participant not found' using errcode = 'P0002';
  end if;
  if participant.profile_id is not null
     and participant.profile_id = game.current_host_id then
    raise exception 'The host cannot be removed from the game'
      using errcode = '22023';
  end if;

  perform private.delete_participant_from_game(p_session_id, participant.id);

  result := jsonb_build_object(
    'session_id', p_session_id,
    'participant_id', p_participant_id,
    'removed', true
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'remove_v2_participant',
    p_session_id,
    game.phase
  );
  return result;
end;
$$;

revoke all on function public.leave_v2_session(bigint, uuid) from public;
revoke all on function public.remove_v2_participant(bigint, bigint, uuid)
  from public;
grant execute on function public.leave_v2_session(bigint, uuid)
  to authenticated;
grant execute on function public.remove_v2_participant(bigint, bigint, uuid)
  to authenticated;
