begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(14);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values
  ('50000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'core-host@example.test', '', now(), '{}', '{"display_name":"Core Host","handle":"core_host"}', now(), now()),
  ('50000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'core-player@example.test', '', now(), '{}', '{"display_name":"Core Player","handle":"core_player"}', now(), now());

insert into public.feature_enrollments (feature_key, user_id)
values ('v2_game_flow', '50000000-0000-4000-8000-000000000001')
on conflict do nothing;

create temporary table core_test_state (
  session_id bigint,
  host_participant_id bigint,
  player_participant_id bigint,
  rebuy_event_id bigint,
  host_cash_out_event_id bigint,
  first_revision_id bigint
);
grant select, insert, update on core_test_state to authenticated;

select set_config(
  'request.jwt.claim.sub',
  '50000000-0000-4000-8000-000000000001',
  true
);
select set_config(
  'request.headers',
  '{"x-poker-ledger-version":"1.0.0"}',
  true
);
set local role authenticated;

with created as (
  select public.create_v2_session(
    'Core transaction test',
    null,
    1000,
    'USD',
    true,
    '51000000-0000-4000-8000-000000000001'
  ) as result
)
insert into core_test_state (session_id)
select (result ->> 'session_id')::bigint from created;

select is(
  (
    select count(*)::integer
    from public.sessions
    where id = (select session_id from core_test_state)
  ),
  1,
  'canary creates exactly one versioned game'
);
select is(
  (
    public.create_v2_session(
      'Core transaction test',
      null,
      1000,
      'USD',
      true,
      '51000000-0000-4000-8000-000000000001'
    ) ->> 'session_id'
  )::bigint,
  (select session_id from core_test_state),
  'exact create retry returns the stored game'
);
select throws_ok(
  $$select public.create_v2_session('Different request', null, 1000, 'USD', true, '51000000-0000-4000-8000-000000000001')$$,
  '22023',
  'reusing an idempotency key with another payload is rejected'
);
reset role;

update core_test_state state
set host_participant_id = participant.id
from public.session_players participant
where participant.session_id = state.session_id
  and participant.profile_id = '50000000-0000-4000-8000-000000000001';
with added as (
  select private.add_participant(
    (select session_id from core_test_state),
    '50000000-0000-4000-8000-000000000002'
  ) as participant
)
update core_test_state
set player_participant_id = ((added.participant).id)
from added;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '50000000-0000-4000-8000-000000000001',
  true
);
select set_config(
  'request.headers',
  '{"x-poker-ledger-version":"1.0.0"}',
  true
);

select lives_ok(
  format(
    'select public.start_v2_session(%s, %L, null, %L)',
    (select session_id from core_test_state),
    'pairwise',
    '51000000-0000-4000-8000-000000000002'
  ),
  'two accepted players can start a versioned game'
);

with event_result as (
  select public.record_v2_ledger_event(
    (select session_id from core_test_state),
    (select host_participant_id from core_test_state),
    'rebuy',
    500,
    null,
    null,
    '51000000-0000-4000-8000-000000000003'
  ) as result
)
update core_test_state
set rebuy_event_id = (event_result.result ->> 'event_id')::bigint
from event_result;
select is(
  (
    select count(*)::integer
    from public.ledger_events
    where session_id = (select session_id from core_test_state)
      and event_type = 'rebuy'
  ),
  1,
  'one rebuy is persisted'
);
select public.record_v2_ledger_event(
  (select session_id from core_test_state),
  (select host_participant_id from core_test_state),
  'rebuy',
  500,
  null,
  null,
  '51000000-0000-4000-8000-000000000003'
);
select is(
  (
    select count(*)::integer
    from public.ledger_events
    where session_id = (select session_id from core_test_state)
      and event_type = 'rebuy'
  ),
  1,
  'exact rebuy retry creates no duplicate event'
);

select public.begin_v2_settlement(
  (select session_id from core_test_state),
  '51000000-0000-4000-8000-000000000004'
);
select throws_ok(
  format(
    'select public.record_v2_ledger_event(%s,%s,%L,100,null,null,%L)',
    (select session_id from core_test_state),
    (select host_participant_id from core_test_state),
    'rebuy',
    '51000000-0000-4000-8000-000000000005'
  ),
  '22023',
  'rebuys are rejected after settlement starts'
);

with event_result as (
  select public.record_v2_ledger_event(
    (select session_id from core_test_state),
    (select host_participant_id from core_test_state),
    'cash_out',
    1500,
    null,
    null,
    '51000000-0000-4000-8000-000000000006'
  ) as result
)
update core_test_state
set host_cash_out_event_id = (event_result.result ->> 'event_id')::bigint
from event_result;
select public.record_v2_ledger_event(
  (select session_id from core_test_state),
  (select player_participant_id from core_test_state),
  'cash_out',
  1000,
  null,
  null,
  '51000000-0000-4000-8000-000000000007'
);
with finalized as (
  select public.finalize_v2_session(
    (select session_id from core_test_state),
    null,
    '51000000-0000-4000-8000-000000000008'
  ) as result
)
update core_test_state
set first_revision_id = (finalized.result ->> 'revision_id')::bigint
from finalized;

select is(
  (
    select phase
    from public.sessions
    where id = (select session_id from core_test_state)
  ),
  'finalized',
  'balanced game finalizes atomically'
);
select is(
  (
    select total_buy_in_cents
    from public.finalization_revisions
    where id = (select first_revision_id from core_test_state)
  ),
  2500::bigint,
  'revision stores effective input totals'
);
select is(
  (
    select sum(amount_cents)::bigint
    from public.settlement_transfers
    where revision_id = (select first_revision_id from core_test_state)
  ),
  500::bigint,
  'stored settlement graph matches participant net balances'
);

select public.correct_finalized_v2_session(
  (select session_id from core_test_state),
  'Correct rebuy and cash out',
  jsonb_build_array(
    jsonb_build_object(
      'reverses_event_id',
      (select rebuy_event_id from core_test_state),
      'replacement_type',
      'rebuy',
      'replacement_amount_cents',
      400
    ),
    jsonb_build_object(
      'reverses_event_id',
      (select host_cash_out_event_id from core_test_state),
      'replacement_type',
      'cash_out',
      'replacement_amount_cents',
      1400
    )
  ),
  '51000000-0000-4000-8000-000000000009'
);
select is(
  (
    select count(*)::integer
    from public.finalization_revisions
    where session_id = (select session_id from core_test_state)
  ),
  2,
  'finalized correction appends a second revision'
);
select is(
  (
    select supersedes_revision_id
    from public.finalization_revisions
    where id = (
      select latest_revision_id
      from public.sessions
      where id = (select session_id from core_test_state)
    )
  ),
  (select first_revision_id from core_test_state),
  'new revision points to the immutable prior revision'
);
select is(
  (
    select count(*)::integer
    from public.settlement_transfers
    where revision_id = (select first_revision_id from core_test_state)
  ),
  1,
  'prior revision transfer graph remains unchanged'
);
select throws_ok(
  format(
    'select public.reopen_v2_session(%s,%L,%L)',
    (select session_id from core_test_state),
    'unsafe reopen',
    '51000000-0000-4000-8000-000000000010'
  ),
  '0A000',
  'finalized games cannot be silently reopened'
);
reset role;

select * from finish();
rollback;
