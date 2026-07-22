-- Transactional and resumable import for the pre-Supabase SQLite database.
-- Source IDs are mapped per verified batch so retries cannot duplicate rows.

create or replace function public.import_legacy_data(
  p_batch_id text,
  p_payload jsonb,
  p_checksum text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  batch public.legacy_import_batches;
  source_row jsonb;
  v_source_id bigint;
  v_destination_id bigint;
  v_destination_session_id bigint;
  v_destination_player_id bigint;
  v_destination_session_player_id bigint;
  expected_counts jsonb;
  imported_counts jsonb;
  expected_buy_ins bigint;
  imported_buy_ins bigint;
  expected_cash_outs bigint;
  imported_cash_outs bigint;
  expected_rebuys bigint;
  imported_rebuys bigint;
  expected_quick_adds bigint;
  imported_quick_adds bigint;
begin
  if actor is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if p_batch_id is null or btrim(p_batch_id) = ''
     or p_checksum !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid migration identity' using errcode = '22023';
  end if;
  if p_payload ->> 'source' is distinct from 'sqlite_v1' then
    raise exception 'Unsupported migration source' using errcode = '22023';
  end if;

  expected_counts := jsonb_build_object(
    'players', jsonb_array_length(coalesce(p_payload -> 'players', '[]'::jsonb)),
    'sessions', jsonb_array_length(coalesce(p_payload -> 'sessions', '[]'::jsonb)),
    'session_players', jsonb_array_length(coalesce(p_payload -> 'session_players', '[]'::jsonb)),
    'rebuys', jsonb_array_length(coalesce(p_payload -> 'rebuys', '[]'::jsonb)),
    'quick_add_entries', jsonb_array_length(coalesce(p_payload -> 'quick_add_entries', '[]'::jsonb))
  );

  select * into batch
  from public.legacy_import_batches
  where user_id = actor and batch_id = p_batch_id
  for update;
  if found then
    if batch.checksum <> p_checksum or batch.counts <> expected_counts then
      raise exception 'Migration batch identity does not match its prior payload'
        using errcode = '22023';
    end if;
    if batch.completed_at is not null then
      return jsonb_build_object(
        'verified', true,
        'checksum', batch.checksum,
        'counts', batch.counts,
        'batch_id', batch.batch_id,
        'replayed', true
      );
    end if;
  else
    insert into public.legacy_import_batches (
      user_id, batch_id, checksum, counts
    )
    values (actor, p_batch_id, p_checksum, expected_counts)
    returning * into batch;
  end if;

  for source_row in
    select value
    from jsonb_array_elements(coalesce(p_payload -> 'players', '[]'::jsonb))
  loop
    v_source_id := (source_row ->> 'source_id')::bigint;
    if v_source_id is null then
      raise exception 'Player source ID is required';
    end if;
    select lim.destination_id into v_destination_id
    from public.legacy_import_mappings lim
    where lim.batch_id = batch.id
      and lim.entity_type = 'player'
      and lim.source_id = v_source_id;
    if not found then
      insert into public.players (
        user_id, name, email, phone, notes, active, created_at
      )
      values (
        actor,
        coalesce(nullif(btrim(source_row ->> 'name'), ''), 'Legacy player'),
        nullif(btrim(source_row ->> 'email'), ''),
        nullif(btrim(source_row ->> 'phone'), ''),
        nullif(btrim(source_row ->> 'notes'), ''),
        coalesce((source_row ->> 'active')::boolean, true),
        coalesce((source_row ->> 'created_at')::timestamptz, now())
      )
      returning id into v_destination_id;
      insert into public.legacy_import_mappings (
        batch_id, entity_type, source_id, destination_id
      )
      values (batch.id, 'player', v_source_id, v_destination_id);
    end if;
  end loop;

  for source_row in
    select value
    from jsonb_array_elements(coalesce(p_payload -> 'sessions', '[]'::jsonb))
  loop
    v_source_id := (source_row ->> 'source_id')::bigint;
    select lim.destination_id into v_destination_id
    from public.legacy_import_mappings lim
    where lim.batch_id = batch.id
      and lim.entity_type = 'session'
      and lim.source_id = v_source_id;
    if not found then
      insert into public.sessions (
        user_id,
        current_host_id,
        name,
        started_at,
        ended_at,
        finalized,
        settlement_mode,
        schema_version,
        ledger_version,
        phase
      )
      values (
        actor,
        actor,
        nullif(btrim(source_row ->> 'name'), ''),
        coalesce((source_row ->> 'started_at')::timestamptz, now()),
        (source_row ->> 'ended_at')::timestamptz,
        false,
        case
          when source_row ->> 'settlement_mode' = 'banker' then 'banker'
          else 'pairwise'
        end,
        1,
        1,
        'legacy'
      )
      returning id into v_destination_id;
      insert into public.legacy_import_mappings (
        batch_id, entity_type, source_id, destination_id
      )
      values (batch.id, 'session', v_source_id, v_destination_id);
    end if;
  end loop;

  for source_row in
    select value
    from jsonb_array_elements(coalesce(p_payload -> 'session_players', '[]'::jsonb))
  loop
    v_source_id := (source_row ->> 'source_id')::bigint;
    select lim.destination_id into v_destination_id
    from public.legacy_import_mappings lim
    where lim.batch_id = batch.id
      and lim.entity_type = 'session_player'
      and lim.source_id = v_source_id;
    if found then
      continue;
    end if;

    select lim.destination_id into v_destination_session_id
    from public.legacy_import_mappings lim
    where lim.batch_id = batch.id
      and lim.entity_type = 'session'
      and lim.source_id =
        (source_row ->> 'session_source_id')::bigint;
    if not found then
      raise exception 'Missing session mapping for game-player %', v_source_id;
    end if;
    select lim.destination_id into v_destination_player_id
    from public.legacy_import_mappings lim
    where lim.batch_id = batch.id
      and lim.entity_type = 'player'
      and lim.source_id =
        (source_row ->> 'player_source_id')::bigint;
    if not found then
      raise exception 'Missing player mapping for game-player %', v_source_id;
    end if;

    insert into public.session_players (
      session_id,
      player_id,
      display_name_snapshot,
      accepted_at,
      legacy_participant,
      buy_in_cents_total,
      cash_out_cents,
      paid_upfront,
      settlement_done
    )
    select
      v_destination_session_id,
      v_destination_player_id,
      p.name,
      s.started_at,
      true,
      coalesce((source_row ->> 'buy_in_cents_total')::bigint, 0),
      (source_row ->> 'cash_out_cents')::bigint,
      coalesce((source_row ->> 'paid_upfront')::boolean, true),
      coalesce((source_row ->> 'settlement_done')::boolean, false)
    from public.players p
    cross join public.sessions s
    where p.id = v_destination_player_id
      and s.id = v_destination_session_id
    returning id into v_destination_id;
    insert into public.legacy_import_mappings (
      batch_id, entity_type, source_id, destination_id
    )
    values (batch.id, 'session_player', v_source_id, v_destination_id);
  end loop;

  for source_row in
    select value
    from jsonb_array_elements(coalesce(p_payload -> 'rebuys', '[]'::jsonb))
  loop
    v_source_id := (source_row ->> 'source_id')::bigint;
    if exists (
      select 1 from public.legacy_import_mappings lim
      where lim.batch_id = batch.id
        and lim.entity_type = 'rebuy'
        and lim.source_id = v_source_id
    ) then
      continue;
    end if;
    select lim.destination_id into v_destination_session_player_id
    from public.legacy_import_mappings lim
    where lim.batch_id = batch.id
      and lim.entity_type = 'session_player'
      and lim.source_id =
        (source_row ->> 'session_player_source_id')::bigint;
    if not found then
      raise exception 'Missing game-player mapping for rebuy %', v_source_id;
    end if;
    insert into public.rebuys (
      session_player_id, amount_cents, created_at
    )
    values (
      v_destination_session_player_id,
      (source_row ->> 'amount_cents')::bigint,
      coalesce((source_row ->> 'created_at')::timestamptz, now())
    )
    returning id into v_destination_id;
    insert into public.legacy_import_mappings (
      batch_id, entity_type, source_id, destination_id
    )
    values (batch.id, 'rebuy', v_source_id, v_destination_id);
  end loop;

  for source_row in
    select value
    from jsonb_array_elements(coalesce(p_payload -> 'quick_add_entries', '[]'::jsonb))
  loop
    v_source_id := (source_row ->> 'source_id')::bigint;
    if exists (
      select 1 from public.legacy_import_mappings lim
      where lim.batch_id = batch.id
        and lim.entity_type = 'quick_add_entry'
        and lim.source_id = v_source_id
    ) then
      continue;
    end if;
    select lim.destination_id into v_destination_player_id
    from public.legacy_import_mappings lim
    where lim.batch_id = batch.id
      and lim.entity_type = 'player'
      and lim.source_id =
        (source_row ->> 'player_source_id')::bigint;
    if not found then
      raise exception 'Missing player mapping for quick add %', v_source_id;
    end if;
    insert into public.quick_add_entries (
      user_id, player_id, amount_cents, note, created_at
    )
    values (
      actor,
      v_destination_player_id,
      (source_row ->> 'amount_cents')::bigint,
      nullif(btrim(source_row ->> 'note'), ''),
      coalesce((source_row ->> 'created_at')::timestamptz, now())
    )
    returning id into v_destination_id;
    insert into public.legacy_import_mappings (
      batch_id, entity_type, source_id, destination_id
    )
    values (batch.id, 'quick_add_entry', v_source_id, v_destination_id);
  end loop;

  -- Resolve banker references only after every game-player mapping exists.
  for source_row in
    select value
    from jsonb_array_elements(coalesce(p_payload -> 'sessions', '[]'::jsonb))
  loop
    if source_row ->> 'banker_source_session_player_id' is not null then
      select lim.destination_id into v_destination_session_id
      from public.legacy_import_mappings lim
      where lim.batch_id = batch.id
        and lim.entity_type = 'session'
        and lim.source_id = (source_row ->> 'source_id')::bigint;
      select lim.destination_id into v_destination_session_player_id
      from public.legacy_import_mappings lim
      where lim.batch_id = batch.id
        and lim.entity_type = 'session_player'
        and lim.source_id =
          (source_row ->> 'banker_source_session_player_id')::bigint;
      if not found then
        raise exception 'Missing banker game-player mapping for session %',
          source_row ->> 'source_id';
      end if;
      update public.sessions
      set banker_session_player_id = v_destination_session_player_id
      where id = v_destination_session_id;
    end if;
  end loop;

  -- Apply finalization last so finalized-row guards cannot interrupt the import.
  for source_row in
    select value
    from jsonb_array_elements(coalesce(p_payload -> 'sessions', '[]'::jsonb))
  loop
    select lim.destination_id into v_destination_session_id
    from public.legacy_import_mappings lim
    where lim.batch_id = batch.id
      and lim.entity_type = 'session'
      and lim.source_id = (source_row ->> 'source_id')::bigint;
    update public.sessions
    set finalized = coalesce((source_row ->> 'finalized')::boolean, false),
        phase = case
          when coalesce((source_row ->> 'finalized')::boolean, false)
            then 'finalized'
          else 'legacy'
        end
    where id = v_destination_session_id;
  end loop;

  select jsonb_build_object(
    'players', count(*) filter (where entity_type = 'player'),
    'sessions', count(*) filter (where entity_type = 'session'),
    'session_players', count(*) filter (where entity_type = 'session_player'),
    'rebuys', count(*) filter (where entity_type = 'rebuy'),
    'quick_add_entries', count(*) filter (where entity_type = 'quick_add_entry')
  )
  into imported_counts
  from public.legacy_import_mappings
  where batch_id = batch.id;
  if imported_counts <> expected_counts then
    raise exception 'Migration row-count reconciliation failed: % vs %',
      imported_counts, expected_counts;
  end if;

  select
    coalesce(sum((value ->> 'buy_in_cents_total')::bigint), 0),
    coalesce(sum((value ->> 'cash_out_cents')::bigint), 0)
  into expected_buy_ins, expected_cash_outs
  from jsonb_array_elements(coalesce(p_payload -> 'session_players', '[]'::jsonb));
  select
    coalesce(sum(sp.buy_in_cents_total), 0),
    coalesce(sum(sp.cash_out_cents), 0)
  into imported_buy_ins, imported_cash_outs
  from public.legacy_import_mappings lim
  join public.session_players sp on sp.id = lim.destination_id
  where lim.batch_id = batch.id
    and lim.entity_type = 'session_player';

  select coalesce(sum((value ->> 'amount_cents')::bigint), 0)
  into expected_rebuys
  from jsonb_array_elements(coalesce(p_payload -> 'rebuys', '[]'::jsonb));
  select coalesce(sum(r.amount_cents), 0)
  into imported_rebuys
  from public.legacy_import_mappings lim
  join public.rebuys r on r.id = lim.destination_id
  where lim.batch_id = batch.id and lim.entity_type = 'rebuy';

  select coalesce(sum((value ->> 'amount_cents')::bigint), 0)
  into expected_quick_adds
  from jsonb_array_elements(coalesce(p_payload -> 'quick_add_entries', '[]'::jsonb));
  select coalesce(sum(q.amount_cents), 0)
  into imported_quick_adds
  from public.legacy_import_mappings lim
  join public.quick_add_entries q on q.id = lim.destination_id
  where lim.batch_id = batch.id and lim.entity_type = 'quick_add_entry';

  if expected_buy_ins is distinct from imported_buy_ins
     or expected_cash_outs is distinct from imported_cash_outs
     or expected_rebuys is distinct from imported_rebuys
     or expected_quick_adds is distinct from imported_quick_adds then
    raise exception 'Migration financial checksum reconciliation failed';
  end if;

  update public.legacy_import_batches
  set completed_at = now(), counts = imported_counts
  where id = batch.id;

  return jsonb_build_object(
    'verified', true,
    'checksum', p_checksum,
    'counts', imported_counts,
    'batch_id', p_batch_id,
    'replayed', false,
    'financial_totals', jsonb_build_object(
      'buy_ins', imported_buy_ins,
      'cash_outs', imported_cash_outs,
      'rebuys', imported_rebuys,
      'quick_adds', imported_quick_adds
    )
  );
end;
$$;

revoke all on function public.import_legacy_data(text, jsonb, text)
  from public, anon;
grant execute on function public.import_legacy_data(text, jsonb, text)
  to authenticated;
