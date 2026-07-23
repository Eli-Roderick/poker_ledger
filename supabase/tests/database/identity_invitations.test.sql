begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(21);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values
  ('70000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'invite-host@example.test', '', now(), '{}', '{"display_name":"Invite Host","handle":"invite_host"}', now(), now()),
  ('70000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'invite-player@example.test', '', now(), '{}', '{"display_name":"Invite Player","handle":"invite_player"}', now(), now()),
  ('70000000-0000-4000-8000-000000000003', '00000000-0000-0000-8000-000000000000', 'authenticated', 'authenticated', 'join-player@example.test', '', now(), '{}', '{"display_name":"Join Player","handle":"join_player"}', now(), now()),
  ('70000000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'outsider@example.test', '', now(), '{}', '{"display_name":"Outsider","handle":"invite_outsider"}', now(), now());

insert into public.feature_enrollments (feature_key, user_id)
values ('v2_game_flow', '70000000-0000-4000-8000-000000000001')
on conflict do nothing;

update public.profiles
set discoverable = true
where id in (
  '70000000-0000-4000-8000-000000000002',
  '70000000-0000-4000-8000-000000000003'
);

create temporary table invitation_test_state (
  session_id bigint,
  invitation_id uuid,
  join_invitation_id uuid,
  join_code text
);
grant select, insert, update on invitation_test_state to authenticated;

select set_config(
  'request.headers',
  '{"x-poker-ledger-version":"1.0.0"}',
  true
);
select set_config(
  'request.jwt.claim.sub',
  '70000000-0000-4000-8000-000000000001',
  true
);
set local role authenticated;

with created as (
  select public.create_v2_session(
    'Invitation test', null, 2500, 'USD', true,
    '71000000-0000-4000-8000-000000000001'
  ) result
)
insert into invitation_test_state (session_id)
select (result ->> 'session_id')::bigint from created;

with invited as (
  select public.invite_profile_to_game(
    (select session_id from invitation_test_state),
    '70000000-0000-4000-8000-000000000002',
    '71000000-0000-4000-8000-000000000002'
  ) result
)
update invitation_test_state
set invitation_id = (result ->> 'invitation_id')::uuid
from invited;

select is(
  (
    select result_state
    from public.search_discoverable_profiles(
      'invite_player', 20, (select session_id from invitation_test_state)
    )
    where id = '70000000-0000-4000-8000-000000000002'
  ),
  'invited',
  'search reports a pending invitation instead of hiding the account'
);
reset role;

select set_config(
  'request.jwt.claim.sub',
  '70000000-0000-4000-8000-000000000002',
  true
);
set local role authenticated;
select is(
  public.respond_to_game_invitation(
    (select invitation_id from invitation_test_state),
    true,
    '71000000-0000-4000-8000-000000000003'
  ) ->> 'status',
  'accepted_pending_buy_in',
  'invitee accept waits for buy-in confirmation before seating'
);
reset role;

select is(
  (
    select count(*)::integer
    from public.session_players
    where session_id = (select session_id from invitation_test_state)
      and profile_id = '70000000-0000-4000-8000-000000000002'
      and not legacy_participant
  ),
  0,
  'accepting does not seat the invitee until buy-in is confirmed'
);
select is(
  (
    select count(*)::integer
    from public.ledger_events
    where session_id = (select session_id from invitation_test_state)
  ),
  0,
  'draft acceptance does not create a financial event early'
);

select set_config(
  'request.jwt.claim.sub',
  '70000000-0000-4000-8000-000000000002',
  true
);
set local role authenticated;
select is(
  public.confirm_game_join_buy_in(
    (select invitation_id from invitation_test_state),
    2500,
    '71000000-0000-4000-8000-000000000013'
  ) ->> 'status',
  'accepted',
  'invitee confirms buy-in to become seated'
);
reset role;

select is(
  (
    select count(*)::integer
    from public.session_players
    where session_id = (select session_id from invitation_test_state)
      and profile_id = '70000000-0000-4000-8000-000000000002'
      and not legacy_participant
  ),
  1,
  'confirmed buy-in creates one account-backed participant'
);
select is(
  (
    select count(*)::integer
    from public.ledger_events
    where session_id = (select session_id from invitation_test_state)
  ),
  0,
  'draft buy-in confirmation still does not create a ledger event'
);

select set_config(
  'request.jwt.claim.sub',
  '70000000-0000-4000-8000-000000000001',
  true
);
set local role authenticated;
with generated as (
  select public.create_game_join_code(
    (select session_id from invitation_test_state),
    '71000000-0000-4000-8000-000000000004'
  ) result
)
update invitation_test_state
set join_code = result ->> 'code'
from generated;

select is(
  length((select join_code from invitation_test_state)),
  6,
  'join code is exactly six uppercase letters'
);
select ok(
  (select join_code from invitation_test_state) ~ '^[A-Z]{6}$',
  'join code uses A-Z characters only'
);
reset role;
select isnt(
  (
    select encode(code_digest, 'escape')
    from public.game_join_codes
    where session_id = (select session_id from invitation_test_state)
      and revoked_at is null
  ),
  (select join_code from invitation_test_state),
  'join code plaintext is never stored'
);

select set_config(
  'request.jwt.claim.sub',
  '70000000-0000-4000-8000-000000000001',
  true
);
set local role authenticated;
select public.start_v2_session(
  (select session_id from invitation_test_state),
  'pairwise',
  null,
  '71000000-0000-4000-8000-000000000005',
  '{}'::bigint[]
);
select is(
  (
    select count(*)::integer
    from public.ledger_events
    where session_id = (select session_id from invitation_test_state)
      and event_type = 'initial_buy_in'
  ),
  2,
  'starting creates one initial buy-in for each accepted player'
);
reset role;

select set_config(
  'request.jwt.claim.sub',
  '70000000-0000-4000-8000-000000000003',
  true
);
set local role authenticated;
with requested as (
  select public.request_game_join_by_code(
    (select join_code from invitation_test_state),
    '71000000-0000-4000-8000-000000000006'
  ) result
)
update invitation_test_state
set join_invitation_id = (result ->> 'invitation_id')::uuid
from requested;
select is(
  (
    select status
    from public.game_invitations
    where id = (select join_invitation_id from invitation_test_state)
  ),
  'pending_host',
  'valid code creates a host-approved join request'
);
reset role;

select set_config(
  'request.jwt.claim.sub',
  '70000000-0000-4000-8000-000000000001',
  true
);
set local role authenticated;
select is(
  public.respond_to_game_invitation(
    (select join_invitation_id from invitation_test_state),
    true,
    '71000000-0000-4000-8000-000000000007'
  ) ->> 'status',
  'accepted_pending_buy_in',
  'host accept waits for the joiner to confirm buy-in'
);
reset role;

select is(
  (
    select count(*)::integer
    from public.ledger_events event
    join public.session_players participant
      on participant.id = event.participant_id
    where event.session_id = (select session_id from invitation_test_state)
      and participant.profile_id =
        '70000000-0000-4000-8000-000000000003'
      and event.event_type = 'initial_buy_in'
  ),
  0,
  'live host accept does not create a buy-in before confirmation'
);

select set_config(
  'request.jwt.claim.sub',
  '70000000-0000-4000-8000-000000000003',
  true
);
set local role authenticated;
select is(
  public.confirm_game_join_buy_in(
    (select join_invitation_id from invitation_test_state),
    2500,
    '71000000-0000-4000-8000-000000000014'
  ) ->> 'status',
  'accepted',
  'live joiner confirms buy-in to seat and fund'
);
reset role;

select is(
  (
    select count(*)::integer
    from public.ledger_events event
    join public.session_players participant
      on participant.id = event.participant_id
    where event.session_id = (select session_id from invitation_test_state)
      and participant.profile_id =
        '70000000-0000-4000-8000-000000000003'
      and event.event_type = 'initial_buy_in'
  ),
  1,
  'live buy-in confirmation creates exactly one initial buy-in'
);
select is(
  (
    select event.amount_cents
    from public.ledger_events event
    join public.session_players participant
      on participant.id = event.participant_id
    where event.session_id = (select session_id from invitation_test_state)
      and participant.profile_id =
        '70000000-0000-4000-8000-000000000003'
      and event.event_type = 'initial_buy_in'
  ),
  2500::bigint,
  'live join uses the confirmed buy-in amount'
);
select throws_ok(
  format(
    'update public.sessions set group_id = 1 where id = %s',
    (select session_id from invitation_test_state)
  ),
  'P0001',
  'Game group is locked',
  'A game group cannot change after creation'
);
select throws_ok(
  format(
    $$update public.sessions set backup_host_id =
      '70000000-0000-4000-8000-000000000004' where id = %s$$,
    (select session_id from invitation_test_state)
  ),
  '23514',
  'Backup host must be an accepted player or authorized group manager',
  'an unrelated account cannot become backup host'
);
select is(
  (
    select display_name_snapshot
    from public.session_players
    where session_id = (select session_id from invitation_test_state)
      and profile_id = '70000000-0000-4000-8000-000000000002'
  ),
  'Invite Player',
  'participant history stores the accepted display-name snapshot'
);
select is(
  (
    select count(*)::integer
    from private.legacy_reconciliation_issues
    where issue_type in ('legacy_guest', 'legacy_multi_group')
  ) >= 0,
  true,
  'legacy identity reconciliation inventory is queryable by trusted tests'
);

select * from finish();
rollback;
