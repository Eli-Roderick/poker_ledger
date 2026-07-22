-- Release controls, canonical money components, phase gates, and atomic
-- correction revisions layered over the expand-only v2 transaction core.

create table if not exists public.feature_enrollments (
  feature_key text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  enrolled_at timestamptz not null default now(),
  primary key (feature_key, user_id)
);
alter table public.feature_enrollments enable row level security;
revoke all on public.feature_enrollments from anon, authenticated;

alter table public.finalization_revisions
  add column if not exists supersedes_revision_id bigint
    references public.finalization_revisions(id) on delete restrict;

create or replace function private.client_version()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (
      nullif(current_setting('request.headers', true), '')::jsonb
        ->> 'x-poker-ledger-version'
    ),
    '0.0.0'
  );
$$;

create or replace function private.version_number(p_version text)
returns bigint
language sql
immutable
set search_path = ''
as $$
  with parts as (
    select regexp_match(
      coalesce(p_version, ''),
      '^([0-9]+)[.]([0-9]+)[.]([0-9]+)'
    ) as value
  )
  select case
    when value is null then 0
    else value[1]::bigint * 1000000000000
       + value[2]::bigint * 1000000
       + value[3]::bigint
  end
  from parts;
$$;

create or replace function private.require_compatible_client()
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  minimum_version text;
  supplied_version text := private.client_version();
begin
  select value into minimum_version
  from public.app_settings
  where key = 'v2_min_client_version';
  minimum_version := coalesce(minimum_version, '1.0.0');
  if private.version_number(supplied_version)
     < private.version_number(minimum_version) then
    raise exception 'Update Poker Ledger to continue'
      using errcode = '0A000',
            detail = 'minimum=' || minimum_version;
  end if;
end;
$$;

create or replace function private.require_v2_enrollment(p_actor_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  enabled_globally boolean;
begin
  select coalesce(value::boolean, false) into enabled_globally
  from public.app_settings
  where key = 'v2_enrollment_enabled';
  if not coalesce(enabled_globally, false) then
    raise exception 'New game creation is temporarily unavailable'
      using errcode = '55000';
  end if;
  if not exists (
    select 1
    from public.feature_enrollments enrollment
    where enrollment.feature_key = 'v2_game_flow'
      and enrollment.user_id = p_actor_id
  ) then
    raise exception 'The new game flow is not enabled for this account'
      using errcode = '42501';
  end if;
end;
$$;

create or replace function private.log_v2_operation(
  p_operation text,
  p_session_id bigint,
  p_phase text
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise log 'poker_ledger operation=% session=% phase=% client=%',
    p_operation,
    p_session_id,
    p_phase,
    private.client_version();
end;
$$;

create or replace function private.event_money_components(
  p_session_id bigint,
  p_through_event_sequence bigint default null
)
returns table (
  participant_id bigint,
  input_cents bigint,
  output_cents bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    event.participant_id,
    coalesce(sum(
      case
        when event.event_type in ('initial_buy_in', 'rebuy')
          then event.amount_cents
        when event.event_type = 'correction' and event.amount_cents > 0
          then event.amount_cents
        when event.event_type = 'reversal' and original.amount_cents > 0
          then event.amount_cents
        else 0
      end
    ), 0)::bigint as input_cents,
    coalesce(sum(
      case
        when event.event_type = 'cash_out'
          then -event.amount_cents
        when event.event_type = 'correction' and event.amount_cents < 0
          then -event.amount_cents
        when event.event_type = 'reversal' and original.amount_cents < 0
          then -event.amount_cents
        else 0
      end
    ), 0)::bigint as output_cents
  from public.ledger_events event
  left join public.ledger_events original
    on original.id = event.reverses_event_id
  where event.session_id = p_session_id
    and (
      p_through_event_sequence is null
      or event.event_sequence <= p_through_event_sequence
    )
  group by event.participant_id;
$$;

create or replace function public.create_v2_session(
  p_name text,
  p_group_id bigint,
  p_default_buy_in_cents bigint,
  p_currency_code text,
  p_host_participates boolean,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  prior jsonb;
  game public.sessions;
  profile public.profiles;
  result jsonb;
begin
  perform private.require_compatible_client();
  perform private.require_v2_enrollment(actor);
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'create_v2_session',
    jsonb_build_object(
      'name', p_name,
      'group_id', p_group_id,
      'default_buy_in_cents', p_default_buy_in_cents,
      'currency_code', p_currency_code,
      'host_participates', p_host_participates
    )
  );
  if prior is not null then return prior; end if;
  if p_default_buy_in_cents <= 0 then
    raise exception 'Default buy-in must be greater than zero'
      using errcode = '22023';
  end if;
  if upper(p_currency_code) !~ '^[A-Z]{3}$' then
    raise exception 'Currency code must contain three letters'
      using errcode = '22023';
  end if;
  if p_group_id is not null
     and not public.is_accepted_group_member(p_group_id, actor) then
    raise exception 'You are not an accepted member of this group'
      using errcode = '42501';
  end if;
  if p_group_id is not null and exists (
    select 1 from public.groups
    where id = p_group_id and archived_at is not null
  ) then
    raise exception 'Archived groups cannot host new games'
      using errcode = '22023';
  end if;

  select * into profile
  from public.profiles
  where id = actor and deleted_at is null and suspended_at is null;
  if profile.handle is null then
    raise exception 'Choose a unique handle before creating a game'
      using errcode = '22023';
  end if;

  insert into public.sessions (
    user_id,
    current_host_id,
    name,
    group_id,
    schema_version,
    ledger_version,
    phase,
    finalized,
    currency_code,
    default_buy_in_cents
  )
  values (
    actor,
    actor,
    nullif(btrim(p_name), ''),
    p_group_id,
    2,
    2,
    'draft',
    false,
    upper(p_currency_code),
    p_default_buy_in_cents
  )
  returning * into game;
  if p_host_participates then
    perform private.add_participant(game.id, actor);
  end if;

  result := jsonb_build_object(
    'session_id', game.id,
    'phase', game.phase,
    'ledger_version', game.ledger_version
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation('create_v2_session', game.id, game.phase);
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
    and status in ('pending_invitee', 'pending_host');
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

create or replace function private.create_settlement_transfers(
  p_revision_id bigint,
  p_session_id bigint,
  p_mode text,
  p_banker_participant_id bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  boundary bigint;
  debtor_ids bigint[];
  debtor_amounts bigint[];
  creditor_ids bigint[];
  creditor_amounts bigint[];
  debtor_index integer := 1;
  creditor_index integer := 1;
  transfer_amount bigint;
  balance record;
begin
  select through_event_sequence into boundary
  from public.finalization_revisions
  where id = p_revision_id and session_id = p_session_id;
  if boundary is null then
    raise exception 'Revision boundary is missing';
  end if;

  if p_mode = 'banker' then
    if p_banker_participant_id is null then
      raise exception 'Banker is required';
    end if;
    for balance in
      select
        components.participant_id,
        case
          when participant.paid_upfront then components.output_cents
          else components.output_cents - components.input_cents
        end as remaining_cents
      from private.event_money_components(
        p_session_id,
        boundary
      ) components
      join public.session_players participant
        on participant.id = components.participant_id
      where components.participant_id <> p_banker_participant_id
      order by components.participant_id
    loop
      if balance.remaining_cents < 0 then
        insert into public.settlement_transfers (
          revision_id,
          from_participant_id,
          to_participant_id,
          amount_cents
        )
        values (
          p_revision_id,
          balance.participant_id,
          p_banker_participant_id,
          -balance.remaining_cents
        );
      elsif balance.remaining_cents > 0 then
        insert into public.settlement_transfers (
          revision_id,
          from_participant_id,
          to_participant_id,
          amount_cents
        )
        values (
          p_revision_id,
          p_banker_participant_id,
          balance.participant_id,
          balance.remaining_cents
        );
      end if;
    end loop;
    return;
  end if;

  select
    array_agg(participant_id order by debt_cents desc, participant_id),
    array_agg(debt_cents order by debt_cents desc, participant_id)
  into debtor_ids, debtor_amounts
  from (
    select
      participant_id,
      input_cents - output_cents as debt_cents
    from private.event_money_components(p_session_id, boundary)
    where output_cents - input_cents < 0
  ) debtors;
  select
    array_agg(participant_id order by credit_cents desc, participant_id),
    array_agg(credit_cents order by credit_cents desc, participant_id)
  into creditor_ids, creditor_amounts
  from (
    select
      participant_id,
      output_cents - input_cents as credit_cents
    from private.event_money_components(p_session_id, boundary)
    where output_cents - input_cents > 0
  ) creditors;

  while debtor_ids is not null
    and creditor_ids is not null
    and debtor_index <= array_length(debtor_ids, 1)
    and creditor_index <= array_length(creditor_ids, 1)
  loop
    transfer_amount := least(
      debtor_amounts[debtor_index],
      creditor_amounts[creditor_index]
    );
    insert into public.settlement_transfers (
      revision_id,
      from_participant_id,
      to_participant_id,
      amount_cents
    )
    values (
      p_revision_id,
      debtor_ids[debtor_index],
      creditor_ids[creditor_index],
      transfer_amount
    );
    debtor_amounts[debtor_index] :=
      debtor_amounts[debtor_index] - transfer_amount;
    creditor_amounts[creditor_index] :=
      creditor_amounts[creditor_index] - transfer_amount;
    if debtor_amounts[debtor_index] = 0 then
      debtor_index := debtor_index + 1;
    end if;
    if creditor_amounts[creditor_index] = 0 then
      creditor_index := creditor_index + 1;
    end if;
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
    jsonb_build_object(
      'session_id', p_session_id,
      'reason', p_reason
    )
  );
  if prior is not null then return prior; end if;
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
  select
    coalesce(sum(input_cents), 0),
    coalesce(sum(output_cents), 0)
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

create or replace function public.reopen_v2_session(
  p_session_id bigint,
  p_reason text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_actor();
  raise exception
    'Finalized games cannot be reopened; create an atomic correction revision'
    using errcode = '0A000';
end;
$$;

create or replace function public.correct_finalized_v2_session(
  p_session_id bigint,
  p_reason text,
  p_corrections jsonb,
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
  original public.ledger_events;
  correction jsonb;
  replacement_type text;
  replacement_amount bigint;
  sequence_number bigint;
  total_input bigint;
  total_output bigint;
  revision_number integer;
  revision public.finalization_revisions;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  if nullif(btrim(p_reason), '') is null then
    raise exception 'A correction reason is required'
      using errcode = '22023';
  end if;
  if jsonb_typeof(p_corrections) <> 'array'
     or jsonb_array_length(p_corrections) = 0 then
    raise exception 'At least one correction is required'
      using errcode = '22023';
  end if;
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'correct_finalized_v2_session',
    jsonb_build_object(
      'session_id', p_session_id,
      'reason', btrim(p_reason),
      'corrections', p_corrections
    )
  );
  if prior is not null then return prior; end if;
  game := private.require_v2_host(p_session_id);
  if game.phase <> 'finalized' or game.latest_revision_id is null then
    raise exception 'Only a finalized game can be corrected'
      using errcode = '22023';
  end if;

  sequence_number := game.next_event_sequence;
  for correction in
    select value from jsonb_array_elements(p_corrections)
  loop
    select * into original
    from public.ledger_events
    where id = (correction ->> 'reverses_event_id')::bigint
      and session_id = p_session_id
    for share;
    if not found or original.event_type = 'reversal' then
      raise exception 'Correction target is invalid' using errcode = '22023';
    end if;
    if exists (
      select 1 from public.ledger_events reversal
      where reversal.reverses_event_id = original.id
    ) then
      raise exception 'That event was already reversed'
        using errcode = '22023';
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
      sequence_number,
      original.participant_id,
      'reversal',
      -original.amount_cents,
      actor,
      (select display_name from public.profiles where id = actor),
      btrim(p_reason),
      original.id,
      extensions.gen_random_uuid()
    );
    sequence_number := sequence_number + 1;

    replacement_type := correction ->> 'replacement_type';
    if replacement_type is not null then
      replacement_amount :=
        (correction ->> 'replacement_amount_cents')::bigint;
      if replacement_type not in (
        'initial_buy_in',
        'rebuy',
        'cash_out'
      ) or replacement_amount is null or replacement_amount <= 0 then
        raise exception 'Replacement event is invalid'
          using errcode = '22023';
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
        idempotency_key
      )
      values (
        p_session_id,
        sequence_number,
        original.participant_id,
        replacement_type,
        case
          when replacement_type = 'cash_out'
            then -replacement_amount
          else replacement_amount
        end,
        actor,
        (select display_name from public.profiles where id = actor),
        btrim(p_reason),
        extensions.gen_random_uuid()
      );
      sequence_number := sequence_number + 1;
    end if;
  end loop;

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
    raise exception 'Every player needs an effective cash-out'
      using errcode = '23514';
  end if;
  select
    coalesce(sum(input_cents), 0),
    coalesce(sum(output_cents), 0)
  into total_input, total_output
  from private.event_money_components(
    p_session_id,
    sequence_number - 1
  );
  if total_input <> total_output then
    raise exception 'Corrected buy-ins and cash-outs must balance (% vs %)',
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
    sequence_number - 1,
    1,
    game.settlement_mode,
    total_input,
    total_output,
    btrim(p_reason),
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
  perform set_config('app.allow_finalized_revision', 'on', true);
  update public.sessions
  set latest_revision_id = revision.id,
      next_event_sequence = sequence_number,
      updated_at = now()
  where id = p_session_id;

  insert into public.user_notifications (
    user_id,
    notification_type,
    title,
    body,
    data
  )
  select
    participant.profile_id,
    'game_correction',
    'Finalized game corrected',
    'A finalized poker game received an audited correction.',
    jsonb_build_object(
      'session_id', p_session_id,
      'revision_id', revision.id
    )
  from public.session_players participant
  where participant.session_id = p_session_id
    and participant.profile_id is not null
    and participant.removed_at is null
    and participant.profile_id <> actor;

  result := jsonb_build_object(
    'session_id', p_session_id,
    'revision_id', revision.id,
    'revision_number', revision.revision_number,
    'total_buy_in_cents', total_input,
    'total_cash_out_cents', total_output
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'correct_finalized_v2_session',
    p_session_id,
    'finalized'
  );
  return result;
end;
$$;

create or replace function private.validate_reversal()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  original public.ledger_events;
begin
  if new.reverses_event_id is null then
    if new.event_type = 'reversal' then
      raise exception 'A reversal must reference its original event';
    end if;
    return new;
  end if;
  if new.event_type <> 'reversal' then
    raise exception 'Only reversal events may reference an original event';
  end if;
  select * into original
  from public.ledger_events
  where id = new.reverses_event_id;
  if not found
     or original.event_type = 'reversal'
     or original.session_id <> new.session_id
     or original.participant_id <> new.participant_id
     or original.amount_cents <> -new.amount_cents then
    raise exception
      'Reversal must exactly offset one non-reversal event for the same game and participant';
  end if;
  return new;
end;
$$;

revoke all on function public.begin_v2_settlement(bigint, uuid)
  from public;
revoke all on function public.correct_finalized_v2_session(
  bigint,
  text,
  jsonb,
  uuid
) from public;
grant execute on function public.begin_v2_settlement(bigint, uuid)
  to authenticated;
grant execute on function public.correct_finalized_v2_session(
  bigint,
  text,
  jsonb,
  uuid
) to authenticated;

insert into public.feature_enrollments (feature_key, user_id)
select 'v2_game_flow', user_id
from public.app_admins
on conflict do nothing;

insert into public.app_settings (key, value)
values ('v2_enrollment_enabled', 'true')
on conflict (key) do update set value = excluded.value;
