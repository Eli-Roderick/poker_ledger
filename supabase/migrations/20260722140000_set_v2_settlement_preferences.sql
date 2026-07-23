-- Allow hosts to choose Pairwise/Banker (and banker paid-upfront) on the
-- settlement review page after the game is already live or settling.

create or replace function public.set_v2_settlement_preferences(
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
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'set_v2_settlement_preferences',
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
  if game.phase not in ('live', 'settling') then
    raise exception 'Settlement preferences can only change while live or settling'
      using errcode = '22023';
  end if;
  if p_settlement_mode not in ('pairwise', 'banker') then
    raise exception 'Choose a settlement mode' using errcode = '22023';
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
  if p_settlement_mode = 'pairwise' then
    if p_banker_participant_id is not null then
      raise exception 'Pairwise settlement cannot include a banker'
        using errcode = '22023';
    end if;
    if coalesce(cardinality(p_paid_upfront_participant_ids), 0) > 0 then
      raise exception 'Pairwise settlement cannot include paid-upfront selections'
        using errcode = '22023';
    end if;
  end if;
  if exists (
    select 1
    from unnest(
      coalesce(p_paid_upfront_participant_ids, '{}'::bigint[])
    ) as selected(selected_id)
    where selected.selected_id = p_banker_participant_id
       or not exists (
         select 1
         from public.session_players sp
         where sp.id = selected.selected_id
           and sp.session_id = p_session_id
           and sp.removed_at is null
       )
  ) then
    raise exception 'Paid-upfront selections must be accepted non-banker players'
      using errcode = '22023';
  end if;

  update public.session_players
  set paid_upfront = case
    when p_settlement_mode = 'banker' then id = any(
      coalesce(p_paid_upfront_participant_ids, '{}'::bigint[])
    )
    else false
  end
  where session_id = p_session_id
    and removed_at is null;

  update public.sessions
  set settlement_mode = p_settlement_mode,
      banker_session_player_id = case
        when p_settlement_mode = 'banker' then p_banker_participant_id
        else null
      end,
      updated_at = now()
  where id = p_session_id;

  result := jsonb_build_object(
    'session_id', p_session_id,
    'settlement_mode', p_settlement_mode,
    'banker_participant_id', case
      when p_settlement_mode = 'banker' then p_banker_participant_id
      else null
    end,
    'paid_upfront_participant_ids',
      case
        when p_settlement_mode = 'banker'
          then coalesce(p_paid_upfront_participant_ids, '{}'::bigint[])
        else '{}'::bigint[]
      end
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

revoke all on function public.set_v2_settlement_preferences(
  bigint, text, bigint, uuid, bigint[]
) from public, anon;
grant execute on function public.set_v2_settlement_preferences(
  bigint, text, bigint, uuid, bigint[]
) to authenticated;
