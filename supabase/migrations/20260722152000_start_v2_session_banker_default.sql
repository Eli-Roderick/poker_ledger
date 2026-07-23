-- Allow pairwise start when PostgREST omits null p_banker_participant_id.

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
  )
  where session_id = p_session_id
    and removed_at is null;

  sequence_number := game.next_event_sequence;
  for player_row in
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
      player_row.id,
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
  perform private.complete_idempotent(actor, idem, result);
  return result;
end;
$$;

revoke all on function public.start_v2_session(
  bigint, text, bigint, uuid, bigint[]
) from public, anon;
grant execute on function public.start_v2_session(
  bigint, text, bigint, uuid, bigint[]
) to authenticated;
