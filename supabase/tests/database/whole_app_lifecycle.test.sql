begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(31);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values
  (
    '70000000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'lifecycle-host@example.test',
    extensions.crypt('correct-password', extensions.gen_salt('bf')),
    now(), '{}',
    '{"display_name":"Lifecycle Host","handle":"lifecycle_host"}',
    now(), now()
  ),
  (
    '70000000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'lifecycle-member@example.test',
    extensions.crypt('correct-password', extensions.gen_salt('bf')),
    now(), '{}',
    '{"display_name":"Lifecycle Member","handle":"lifecycle_member"}',
    now(), now()
  ),
  (
    '70000000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'lifecycle-other@example.test',
    extensions.crypt('correct-password', extensions.gen_salt('bf')),
    now(), '{}',
    '{"display_name":"Lifecycle Other","handle":"lifecycle_other"}',
    now(), now()
  );

insert into public.feature_enrollments (feature_key, user_id)
values ('v2_game_flow', '70000000-0000-4000-8000-000000000002')
on conflict do nothing;

insert into public.groups (id, name, owner_id)
values (
  97001,
  'Lifecycle Group',
  '70000000-0000-4000-8000-000000000001'
);
insert into public.group_members (
  group_id, user_id, status, role, accepted_at, joined_at
)
values (
  97001,
  '70000000-0000-4000-8000-000000000002',
  'accepted',
  'member',
  now(),
  now()
);

insert into public.sessions (
  id, user_id, current_host_id, name, schema_version, ledger_version,
  phase, finalized, default_buy_in_cents, group_id
)
values (
  97100,
  '70000000-0000-4000-8000-000000000002',
  '70000000-0000-4000-8000-000000000002',
  'Transfer status game',
  2,
  2,
  'settling',
  false,
  1000,
  97001
);
insert into public.session_players (
  id, session_id, profile_id, display_name_snapshot,
  accepted_at, legacy_participant
)
values
  (
    97201, 97100, '70000000-0000-4000-8000-000000000002',
    'Lifecycle Member', now(), false
  ),
  (
    97202, 97100, '70000000-0000-4000-8000-000000000003',
    'Lifecycle Other', now(), false
  );
insert into public.finalization_revisions (
  id, session_id, revision_number, through_event_sequence,
  settlement_engine_version, settlement_mode,
  total_buy_in_cents, total_cash_out_cents, created_by
)
values (
  97301, 97100, 1, 4, 1, 'pairwise', 2000, 2000,
  '70000000-0000-4000-8000-000000000002'
);
update public.sessions
set latest_revision_id = 97301,
    phase = 'finalized',
    finalized = true
where id = 97100;
insert into public.settlement_transfers (
  id, revision_id, from_participant_id, to_participant_id, amount_cents
)
values (97401, 97301, 97202, 97201, 500);

set local role authenticated;
set local request.jwt.claim.sub =
  '70000000-0000-4000-8000-000000000001';
set local request.headers =
  '{"x-poker-ledger-version":"2.0.0"}';

select throws_ok(
  $$
    select public.transfer_group_ownership(
      97001,
      '70000000-0000-4000-8000-000000000003',
      '71000000-0000-4000-8000-000000000001'
    )
  $$,
  '22023',
  'Choose a current accepted member',
  'ownership transfers only to an accepted member'
);

select throws_ok(
  $$
    select public.request_account_deletion(
      '71000000-0000-4000-8000-000000000002'
    )
  $$,
  '22023',
  'Transfer ownership of every group before deleting your account',
  'account deletion cannot orphan a group'
);

select lives_ok(
  $$
    select public.transfer_group_ownership(
      97001,
      '70000000-0000-4000-8000-000000000002',
      '71000000-0000-4000-8000-000000000003'
    )
  $$,
  'accepted ownership transfer succeeds'
);
select is(
  (select owner_id from public.groups where id = 97001),
  '70000000-0000-4000-8000-000000000002'::uuid,
  'new owner is persisted'
);
select ok(
  exists (
    select 1 from public.group_members
    where group_id = 97001
      and user_id = '70000000-0000-4000-8000-000000000001'
      and status = 'accepted'
      and can_manage_games
  ),
  'former owner remains an explicit administrator'
);

select lives_ok(
  $$
    select public.request_account_deletion(
      '71000000-0000-4000-8000-000000000004'
    )
  $$,
  'account deletion request succeeds after transfer'
);
select ok(
  (
    select deleted_at is not null
      and deletion_scheduled_at > now()
    from public.profiles
    where id = '70000000-0000-4000-8000-000000000001'
  ),
  'deletion request starts the restore window'
);
select ok(
  (
    select banned_until = 'infinity'::timestamptz
    from auth.users
    where id = '70000000-0000-4000-8000-000000000001'
  ),
  'deletion request disables sign-in'
);

reset role;
set local role anon;
select is(
  (
    select count(*)::integer
    from public.get_restorable_account(
      'lifecycle-host@example.test',
      'correct-password'
    )
  ),
  1,
  'valid credentials reveal only the caller restorable record'
);
select is(
  (
    select count(*)::integer
    from public.get_restorable_account(
      'lifecycle-host@example.test',
      'wrong-password'
    )
  ),
  0,
  'invalid credentials do not reveal account state'
);
select is(
  (
    public.restore_deleted_account(
      'lifecycle-host@example.test',
      'correct-password'
    ) ->> 'success'
  )::boolean,
  true,
  'valid credentials restore the account'
);
select ok(
  (
    select deleted_at is null and deletion_scheduled_at is null
    from public.profiles
    where id = '70000000-0000-4000-8000-000000000001'
  ),
  'restoration clears the deletion window'
);
select ok(
  exists (
    select 1 from public.group_members
    where group_id = 97001
      and user_id = '70000000-0000-4000-8000-000000000001'
      and status = 'accepted'
      and left_at is null
      and not removed_for_account_deletion
  ),
  'restoration safely reconnects deletion-removed memberships'
);

reset role;
set local role authenticated;
set local request.jwt.claim.sub =
  '70000000-0000-4000-8000-000000000002';
set local request.headers =
  '{"x-poker-ledger-version":"2.0.0"}';

select is(
  (select count(*) from public.my_games() where id = 97100),
  1::bigint,
  'my_games returns visible games through the canonical read model'
);
select is(
  (select count(*) from public.group_games(97001) where id = 97100),
  1::bigint,
  'group_games returns games attached to an accepted group'
);
select is(
  (select count(*) from public.game_participant_totals(array[97100])),
  2::bigint,
  'game participant totals returns each accepted snapshot once'
);
select is(
  (select count(*) from public.my_stats() where session_id = 97100),
  1::bigint,
  'my_stats includes finalized accepted participation'
);
select is(
  (select count(*) from public.group_stats(97001) where session_id = 97100),
  2::bigint,
  'group_stats includes all finalized group participants'
);

select throws_ok(
  $$
    insert into public.sessions (
      user_id, current_host_id, name, schema_version, ledger_version, phase
    ) values (
      '70000000-0000-4000-8000-000000000002',
      '70000000-0000-4000-8000-000000000002',
      'Direct bypass',
      2,
      2,
      'draft'
    )
  $$,
  '55000',
  'Use the transactional game API for version 2 games',
  'authenticated users cannot create V2 rows directly'
);

select lives_ok(
  $$
    select public.create_v2_session(
      'Lifecycle V2 game',
      null,
      1000,
      'USD',
      true,
      '71000000-0000-4000-8000-000000000005'
    )
  $$,
  'the server-controlled V2 create API remains usable'
);

select throws_ok(
  $$
    insert into public.session_players (
      session_id, profile_id, display_name_snapshot,
      accepted_at, legacy_participant
    )
    select id,
      '70000000-0000-4000-8000-000000000003',
      'Direct participant',
      now(),
      false
    from public.sessions
    where name = 'Lifecycle V2 game'
  $$,
  '55000',
  'Use the transactional ledger API for this game',
  'authenticated users cannot insert V2 participants directly'
);

reset role;
select private.add_participant(
  (select id from public.sessions where name = 'Lifecycle V2 game'),
  '70000000-0000-4000-8000-000000000003'
);
set local role authenticated;
set local request.jwt.claim.sub =
  '70000000-0000-4000-8000-000000000002';
set local request.headers =
  '{"x-poker-ledger-version":"2.0.0"}';

select lives_ok(
  $$
    select public.start_v2_session(
      (select id from public.sessions where name = 'Lifecycle V2 game'),
      'pairwise',
      null,
      '71000000-0000-4000-8000-000000000006',
      array[
        (
          select id from public.session_players
          where session_id = (
            select id from public.sessions
            where name = 'Lifecycle V2 game'
          )
            and profile_id =
              '70000000-0000-4000-8000-000000000003'
        )
      ]::bigint[]
    )
  $$,
  'server start can update protected V2 participant state'
);
select ok(
  (
    select paid_upfront
    from public.session_players
    where session_id = (
      select id from public.sessions where name = 'Lifecycle V2 game'
    )
      and profile_id = '70000000-0000-4000-8000-000000000003'
  ),
  'paid-upfront state is persisted through the start API'
);
select lives_ok(
  $$
    select public.begin_v2_settlement(
      (select id from public.sessions where name = 'Lifecycle V2 game'),
      '71000000-0000-4000-8000-000000000007'
    )
  $$,
  'live game enters settlement through the phase API'
);
select lives_ok(
  $$
    select public.return_v2_session_to_live(
      (select id from public.sessions where name = 'Lifecycle V2 game'),
      'Missed rebuy',
      '71000000-0000-4000-8000-000000000008'
    )
  $$,
  'unfinalized settlement can return to the live ledger'
);
select ok(
  (
    select phase = 'live' and membership_closed_at is not null
    from public.sessions
    where name = 'Lifecycle V2 game'
  ),
  'returning live never reopens membership'
);
select lives_ok(
  $$
    select public.cancel_v2_session(
      (select id from public.sessions where name = 'Lifecycle V2 game'),
      'Test cancellation',
      '71000000-0000-4000-8000-000000000009'
    )
  $$,
  'an open V2 game is cancelled without deleting its audit rows'
);

set local request.jwt.claim.sub =
  '70000000-0000-4000-8000-000000000003';
select lives_ok(
  $$
    select public.update_settlement_transfer_status(
      97401,
      'paid',
      '71000000-0000-4000-8000-000000000010'
    )
  $$,
  'payer can mark a persisted transfer paid'
);
set local request.jwt.claim.sub =
  '70000000-0000-4000-8000-000000000002';
select lives_ok(
  $$
    select public.update_settlement_transfer_status(
      97401,
      'received',
      '71000000-0000-4000-8000-000000000011'
    )
  $$,
  'recipient can confirm a persisted transfer'
);
select is(
  (
    select count(*)::integer
    from public.settlement_transfer_status_history
    where transfer_id = 97401
  ),
  2,
  'every transfer status change is retained in history'
);
set local request.jwt.claim.sub =
  '70000000-0000-4000-8000-000000000001';
select throws_ok(
  $$
    select public.update_settlement_transfer_status(
      97401,
      'disputed',
      '71000000-0000-4000-8000-000000000012'
    )
  $$,
  '42501',
  'Only a transfer participant can dispute it',
  'unrelated accounts cannot alter transfer status'
);

select * from finish();
rollback;
