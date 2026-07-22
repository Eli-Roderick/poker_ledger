begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(15);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values
  ('d0000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'audit-host@example.test', '', now(), '{}', '{"display_name":"Audit Host","handle":"audit_host"}', now(), now()),
  ('d0000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'audit-target@example.test', '', now(), '{}', '{"display_name":"Audit Target","handle":"audit_target"}', now(), now()),
  ('d0000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'audit-outsider@example.test', '', now(), '{}', '{"display_name":"Audit Outsider","handle":"audit_outsider"}', now(), now());

update public.profiles
set discoverable = true
where id = 'd0000000-0000-4000-8000-000000000002';

insert into public.app_admins (user_id)
values ('d0000000-0000-4000-8000-000000000001');

insert into public.groups (id, name, owner_id)
values (
  9701,
  'Security audit group',
  'd0000000-0000-4000-8000-000000000001'
);
insert into public.group_members (
  group_id, user_id, status, role, accepted_at
)
values (
  9701,
  'd0000000-0000-4000-8000-000000000002',
  'accepted',
  'member',
  now()
);

insert into public.sessions (
  id, user_id, current_host_id, name, group_id, schema_version,
  ledger_version, phase, finalized, default_buy_in_cents
)
values (
  9702,
  'd0000000-0000-4000-8000-000000000001',
  'd0000000-0000-4000-8000-000000000001',
  'Security audit game',
  9701,
  2,
  2,
  'live',
  false,
  1000
);
insert into public.session_players (
  id, session_id, profile_id, display_name_snapshot,
  accepted_at, legacy_participant
)
values (
  9703,
  9702,
  'd0000000-0000-4000-8000-000000000001',
  'Audit Host',
  now(),
  false
);
insert into public.ledger_events (
  id, session_id, event_sequence, participant_id, event_type,
  amount_cents, actor_id, idempotency_key
)
values (
  9704,
  9702,
  1,
  9703,
  'initial_buy_in',
  1000,
  'd0000000-0000-4000-8000-000000000001',
  'd1000000-0000-4000-8000-000000000001'
);

select is(
  (
    select discoverable
    from public.profiles
    where id = 'd0000000-0000-4000-8000-000000000003'
  ),
  false,
  'new profiles are not discoverable before explicit opt-in'
);
select ok(
  not has_table_privilege('authenticated', 'public.profiles', 'INSERT'),
  'authenticated clients cannot insert profile rows'
);
select ok(
  not has_column_privilege(
    'authenticated', 'public.profiles', 'deleted_at', 'SELECT'
  ),
  'authenticated clients cannot read account-deletion state'
);
select ok(
  not has_column_privilege(
    'authenticated', 'public.profiles', 'suspended_at', 'SELECT'
  ),
  'authenticated clients cannot read suspension state'
);
select ok(
  not has_column_privilege(
    'authenticated', 'public.profiles', 'deleted_at', 'UPDATE'
  ),
  'authenticated clients cannot directly request deletion'
);
select ok(
  has_column_privilege(
    'authenticated', 'public.profiles', 'discoverable', 'UPDATE'
  ),
  'authenticated clients retain the explicit discovery preference'
);
select ok(
  not has_table_privilege(
    'authenticated', 'public.group_members', 'UPDATE'
  ),
  'membership changes require an audited RPC'
);
select ok(
  has_column_privilege(
    'authenticated', 'public.user_notifications', 'read_at', 'UPDATE'
  ),
  'notification read receipts remain writable'
);
select ok(
  not has_column_privilege(
    'authenticated', 'public.user_notifications', 'body', 'UPDATE'
  ),
  'notification content is not client-writable'
);

select set_config(
  'request.jwt.claim.sub',
  'd0000000-0000-4000-8000-000000000003',
  true
);
set local role authenticated;
select ok(
  not public.is_app_admin(
    'd0000000-0000-4000-8000-000000000001'
  ),
  'an authenticated caller cannot probe another user admin status'
);
select ok(
  not public.is_accepted_group_member(
    9701,
    'd0000000-0000-4000-8000-000000000002'
  ),
  'an authenticated caller cannot probe another user membership'
);
select ok(
  not public.can_view_session(
    9702,
    'd0000000-0000-4000-8000-000000000001'
  ),
  'an authenticated caller cannot probe another user game access'
);
select is(
  (
    select count(*)::integer
    from public.search_discoverable_profiles(
      'audit_target', 20, 9702, null
    )
  ),
  0,
  'a non-host cannot inspect game invitation state through search'
);
select is(
  (
    select count(*)::integer
    from public.search_discoverable_profiles(
      'audit_target', 20, null, 9701
    )
  ),
  0,
  'a non-manager cannot inspect group invitation state through search'
);
reset role;

select throws_ok(
  $$insert into public.ledger_events (
      session_id, event_sequence, participant_id, event_type,
      amount_cents, actor_id, reverses_event_id, idempotency_key
    ) values (
      9702, 2, 9703, 'cash_out', -1000,
      'd0000000-0000-4000-8000-000000000001',
      9704,
      'd1000000-0000-4000-8000-000000000002'
    )$$,
  'P0001',
  'Only reversal events may reference an original event'
);

select * from finish();
rollback;
