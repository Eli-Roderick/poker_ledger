begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(9);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values
  ('72000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rollout-host@example.test', '', now(), '{}', '{"display_name":"Rollout Host","handle":"rollout_host"}', now(), now()),
  ('72000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rollout-control@example.test', '', now(), '{}', '{"display_name":"Rollout Control","handle":"rollout_control"}', now(), now());

insert into public.feature_enrollments (feature_key, user_id)
values ('v2_game_flow', '72000000-0000-4000-8000-000000000001')
on conflict do nothing;

delete from public.feature_enrollments
where feature_key = 'v2_game_flow'
  and user_id = '72000000-0000-4000-8000-000000000002';

insert into public.players (user_id, name)
values ('72000000-0000-4000-8000-000000000001', 'Unresolved guest');
insert into public.sessions (user_id, name, finalized)
values (
  '72000000-0000-4000-8000-000000000001',
  'Open legacy control',
  false
);
insert into public.session_players (
  session_id, player_id, buy_in_cents_total,
  legacy_participant, display_name_snapshot
)
select
  session.id, player.id, 1000, true, 'Unresolved guest'
from public.sessions session
cross join public.players player
where session.name = 'Open legacy control'
  and player.name = 'Unresolved guest';

select set_config(
  'request.headers',
  '{"x-poker-ledger-version":"1.0.0"}',
  true
);
select set_config(
  'request.jwt.claim.sub',
  '72000000-0000-4000-8000-000000000001',
  true
);
set local role authenticated;
select ok(
  public.v2_game_flow_available(),
  'enrolled account sees the v2 creation flow'
);
reset role;

select set_config(
  'request.jwt.claim.sub',
  '72000000-0000-4000-8000-000000000002',
  true
);
set local role authenticated;
select isnt(
  public.v2_game_flow_available(),
  true,
  'unenrolled account remains on the legacy creation flow'
);
reset role;

update public.app_settings
set value = 'false'
where key = 'v2_enrollment_enabled';
set local role authenticated;
select isnt(
  public.v2_game_flow_available(),
  true,
  'emergency switch immediately hides v2 creation'
);
reset role;

select set_config(
  'request.jwt.claim.sub',
  '72000000-0000-4000-8000-000000000001',
  true
);
set local role authenticated;
select throws_ok(
  $$select public.create_v2_session(
    'Disabled attempt', null, 1000, 'USD', true,
    '72100000-0000-4000-8000-000000000001'
  )$$,
  '55000',
  'New game creation is temporarily unavailable',
  'emergency switch blocks the server write even if UI is stale'
);
reset role;

update public.app_settings
set value = 'true'
where key = 'v2_enrollment_enabled';
set local role authenticated;
select lives_ok(
  $$select public.create_v2_session(
    'Canary game', null, 1000, 'USD', true,
    '72100000-0000-4000-8000-000000000002'
  )$$,
  'enrolled cohort can create one complete-flow game'
);
reset role;

select is(
  (
    select count(*)::integer
    from private.v2_operation_logs
    where operation = 'create_v2_session'
      and actor_id = '72000000-0000-4000-8000-000000000001'
  ),
  1,
  'successful canary writes durable operation telemetry'
);
select is(
  (
    select ledger_version
    from public.sessions
    where name = 'Open legacy control'
  ),
  1,
  'an open legacy game is never converted during rollout'
);
select ok(
  private.refresh_v2_reconciliation_findings() >= 1,
  'reconciliation refresh reports at least one finding'
);
select ok(
  exists (
    select 1
    from private.v2_reconciliation_findings
    where issue_type = 'unresolved_guest'
      and session_id = (
        select id from public.sessions where name = 'Open legacy control'
      )
  ),
  'reconciliation inventory reports unresolved historical guests'
);

select * from finish();
rollback;
