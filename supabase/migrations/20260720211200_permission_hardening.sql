-- Immediate legacy safety fixes. These preserve the legacy money tables while
-- making finalization atomic and finalized financial history immutable.

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

  select * into game
  from public.sessions
  where id = target_session_id;
  if game.ledger_version = 2 or game.finalized then
    raise exception 'Use the transactional ledger API for this game'
      using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists session_players_guard_financial_rows
  on public.session_players;
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
     and current_setting('app.allow_finalized_revision', true)
       is distinct from 'on'
     and to_jsonb(old) is distinct from to_jsonb(new) then
    raise exception
      'Finalized games are immutable; create a correction revision'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

drop trigger if exists sessions_guard_finalized on public.sessions;
create trigger sessions_guard_finalized
  before update on public.sessions
  for each row execute function private.guard_finalized_session();

create or replace function public.finalize_legacy_session(
  p_session_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  game public.sessions;
  participant_count integer;
  missing_cash_outs integer;
  total_buy_ins bigint;
  total_cash_outs bigint;
begin
  if actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  select * into game
  from public.sessions
  where id = p_session_id
  for update;
  if not found then
    raise exception 'Game not found' using errcode = 'P0002';
  end if;
  if game.ledger_version <> 1 then
    raise exception 'Use the versioned finalization API for this game'
      using errcode = '22023';
  end if;
  if game.user_id <> actor
     or coalesce(game.current_host_id, game.user_id) <> actor then
    raise exception 'Only the game host can finalize'
      using errcode = '42501';
  end if;
  if game.finalized then
    return jsonb_build_object(
      'session_id', game.id,
      'finalized', true,
      'replayed', true
    );
  end if;

  select
    count(*)::integer,
    count(*) filter (where sp.cash_out_cents is null)::integer,
    coalesce(sum(sp.buy_in_cents_total), 0),
    coalesce(sum(sp.cash_out_cents), 0)
  into
    participant_count,
    missing_cash_outs,
    total_buy_ins,
    total_cash_outs
  from public.session_players sp
  where sp.session_id = p_session_id;

  if participant_count < 2 then
    raise exception 'At least two players are required'
      using errcode = '23514';
  end if;
  if missing_cash_outs > 0 then
    raise exception 'Every player needs a cash-out before finalization'
      using errcode = '23514';
  end if;
  if total_buy_ins <> total_cash_outs then
    raise exception 'Buy-ins and cash-outs must balance (% vs %)',
      total_buy_ins, total_cash_outs
      using errcode = '23514';
  end if;

  update public.sessions
  set
    finalized = true,
    ended_at = coalesce(ended_at, now()),
    phase = 'finalized',
    updated_at = now()
  where id = p_session_id;

  return jsonb_build_object(
    'session_id', p_session_id,
    'finalized', true,
    'replayed', false,
    'total_buy_ins_cents', total_buy_ins,
    'total_cash_outs_cents', total_cash_outs
  );
end;
$$;

revoke all on function public.finalize_legacy_session(bigint)
  from public, anon;
grant execute on function public.finalize_legacy_session(bigint)
  to authenticated;
