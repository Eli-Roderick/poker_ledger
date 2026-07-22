begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(2);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values (
  '70000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  'banker-host@example.test',
  '',
  now(),
  '{}',
  '{"display_name":"Banker Host","handle":"banker_host"}',
  now(),
  now()
);

insert into public.sessions (
  id, user_id, current_host_id, schema_version, ledger_version, phase,
  finalized, settlement_mode, banker_session_player_id,
  default_buy_in_cents, next_event_sequence
)
values (
  9901,
  '70000000-0000-4000-8000-000000000001',
  '70000000-0000-4000-8000-000000000001',
  2,
  2,
  'settling',
  false,
  'banker',
  null,
  1000,
  7
);
insert into public.session_players (
  id, session_id, display_name_snapshot, accepted_at,
  legacy_participant, paid_upfront
)
values
  (9911, 9901, 'Banker', now(), false, false),
  (9912, 9901, 'Paid upfront', now(), false, true),
  (9913, 9901, 'Unpaid', now(), false, false);
update public.sessions set banker_session_player_id = 9911 where id = 9901;

insert into public.ledger_events (
  session_id, event_sequence, participant_id, event_type,
  amount_cents, actor_id, idempotency_key
)
values
  (9901, 1, 9911, 'initial_buy_in', 1000, '70000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000001'),
  (9901, 2, 9912, 'initial_buy_in', 1000, '70000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000002'),
  (9901, 3, 9913, 'initial_buy_in', 1000, '70000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000003'),
  (9901, 4, 9911, 'cash_out', -1000, '70000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000004'),
  (9901, 5, 9912, 'cash_out', -1200, '70000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000005'),
  (9901, 6, 9913, 'cash_out', -800, '70000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000006');
insert into public.finalization_revisions (
  id, session_id, revision_number, through_event_sequence,
  settlement_engine_version, settlement_mode, total_buy_in_cents,
  total_cash_out_cents, created_by
)
values (
  9921,
  9901,
  1,
  6,
  1,
  'banker',
  3000,
  3000,
  '70000000-0000-4000-8000-000000000001'
);
select private.create_settlement_transfers(9921, 9901, 'banker', 9911);

select is(
  (
    select amount_cents
    from public.settlement_transfers
    where revision_id = 9921
      and from_participant_id = 9911
      and to_participant_id = 9912
  ),
  1200::bigint,
  'banker returns the full cash-out to a paid-upfront participant'
);
select is(
  (
    select amount_cents
    from public.settlement_transfers
    where revision_id = 9921
      and from_participant_id = 9913
      and to_participant_id = 9911
  ),
  200::bigint,
  'unpaid participant settles only their net with the banker'
);

select * from finish();
rollback;
