begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values
  ('10000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'host@example.test', '', now(), '{}', '{"display_name":"Host","handle":"host_test"}', now(), now()),
  ('10000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'player@example.test', '', now(), '{}', '{"display_name":"Player","handle":"player_test"}', now(), now()),
  ('10000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'member@example.test', '', now(), '{}', '{"display_name":"Member","handle":"member_test"}', now(), now()),
  ('10000000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'former@example.test', '', now(), '{}', '{"display_name":"Former","handle":"former_test"}', now(), now()),
  ('10000000-0000-4000-8000-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'pending@example.test', '', now(), '{}', '{"display_name":"Pending","handle":"pending_test"}', now(), now()),
  ('10000000-0000-4000-8000-000000000006', '00000000-0000-0000-8000-000000000000', 'authenticated', 'authenticated', 'outsider@example.test', '', now(), '{}', '{"display_name":"Outsider","handle":"outsider_test"}', now(), now());

insert into public.groups (id, name, owner_id)
values (
  9001,
  'RLS Test Group',
  '10000000-0000-4000-8000-000000000001'
);
insert into public.group_members (
  group_id, user_id, status, role, accepted_at, left_at
)
values
  (9001, '10000000-0000-4000-8000-000000000003', 'accepted', 'member', now(), null),
  (9001, '10000000-0000-4000-8000-000000000004', 'removed', 'member', now() - interval '2 days', now() - interval '1 day');

insert into public.sessions (
  id, user_id, current_host_id, name, group_id, schema_version,
  ledger_version, phase, finalized, default_buy_in_cents
)
values
  (9101, '10000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'Historical group game', 9001, 2, 2, 'finalized', true, 2000),
  (9102, '10000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'Current group game', 9001, 2, 2, 'live', false, 2000),
  (9103, '10000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'Private game', null, 2, 2, 'live', false, 2000);

insert into public.session_players (
  id, session_id, player_id, profile_id, display_name_snapshot,
  accepted_at, legacy_participant
)
values
  (9201, 9101, null, '10000000-0000-4000-8000-000000000001', 'Host', now(), false),
  (9202, 9101, null, '10000000-0000-4000-8000-000000000002', 'Player', now(), false),
  (9203, 9102, null, '10000000-0000-4000-8000-000000000004', 'Former', now(), false),
  (9204, 9103, null, '10000000-0000-4000-8000-000000000002', 'Player', now(), false);

insert into public.ledger_events (
  session_id, event_sequence, participant_id, event_type,
  amount_cents, actor_id, idempotency_key
)
values
  (9101, 1, 9201, 'initial_buy_in', 2000, '10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001'),
  (9101, 2, 9202, 'initial_buy_in', 2000, '10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000002'),
  (9101, 3, 9201, 'cash_out', -3000, '10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000003'),
  (9101, 4, 9202, 'cash_out', -1000, '10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000004');

insert into public.finalization_revisions (
  id, session_id, revision_number, through_event_sequence,
  settlement_engine_version, settlement_mode, total_buy_in_cents,
  total_cash_out_cents, created_by
)
values (
  9301, 9101, 1, 4, 1, 'pairwise', 4000, 4000,
  '10000000-0000-4000-8000-000000000001'
);
update public.sessions set latest_revision_id = 9301 where id = 9101;
insert into public.settlement_transfers (
  revision_id, from_participant_id, to_participant_id, amount_cents
)
values (9301, 9202, 9201, 1000);

insert into public.game_invitations (
  id, session_id, profile_id, direction, status, created_by, expires_at
)
values (
  '30000000-0000-4000-8000-000000000001',
  9103,
  '10000000-0000-4000-8000-000000000005',
  'host_invite',
  'pending_invitee',
  '10000000-0000-4000-8000-000000000001',
  now() + interval '1 day'
);

select ok(
  public.can_view_session(9101, '10000000-0000-4000-8000-000000000001'),
  'host can view the full finalized game'
);
select ok(
  public.can_view_session(9103, '10000000-0000-4000-8000-000000000002'),
  'accepted participant can view a private game'
);
select ok(
  public.can_view_session(9101, '10000000-0000-4000-8000-000000000003'),
  'current group member can view historical group games'
);
select ok(
  not public.can_view_session(9101, '10000000-0000-4000-8000-000000000004'),
  'former nonparticipant loses membership-only historical access'
);
select ok(
  public.can_view_session(9102, '10000000-0000-4000-8000-000000000004'),
  'former member retains access to a game they played'
);
select ok(
  not public.can_view_session(9103, '10000000-0000-4000-8000-000000000005'),
  'pending invitee cannot read the ledger'
);
select ok(
  not public.can_view_session(9101, '10000000-0000-4000-8000-000000000006'),
  'outsider cannot view a group ledger'
);
select ok(
  not has_column_privilege(
    'authenticated',
    'public.profiles',
    'email',
    'SELECT'
  ),
  'authenticated users cannot select profile emails'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'public.game_join_codes',
    'SELECT'
  ),
  'authenticated clients cannot read join-code digests'
);
select is(
  (
    select count(*)::integer
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and not c.relrowsecurity
  ),
  0,
  'every public table has RLS enabled'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000003',
  true
);
select is(
  (select count(*)::integer from public.ledger_events where session_id = 9101),
  4,
  'group member reads every ledger row'
);
select is(
  (select count(*)::integer from public.settlement_transfers where revision_id = 9301),
  1,
  'group member reads persisted settlement transfers'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000006',
  true
);
select is(
  (select count(*)::integer from public.ledger_events where session_id = 9101),
  0,
  'outsider receives no ledger rows through RLS'
);
update public.app_settings
set value = 'true'
where key = 'maintenance_mode';
reset role;
select is(
  (select value from public.app_settings where key = 'maintenance_mode'),
  'false',
  'non-admin cannot change server settings'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000001',
  true
);
select throws_ok(
  $$update public.ledger_events set amount_cents = 9999 where id = (select min(id) from public.ledger_events where session_id = 9101)$$,
  '42501',
  'host cannot update append-only ledger rows directly'
);
select throws_ok(
  $$delete from public.ledger_events where session_id = 9101$$,
  '42501',
  'host cannot delete append-only ledger rows directly'
);
update public.sessions set finalized = false where id = 9101;
reset role;
select is(
  (select finalized from public.sessions where id = 9101),
  true,
  'normal client updates cannot reopen a finalized game'
);

select is(
  (
    select display_name_snapshot
    from public.session_players
    where id = 9202
  ),
  'Player',
  'historical participant name is stored as a snapshot'
);

select * from finish();
rollback;
