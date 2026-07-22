begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(7);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values (
  '40000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  'migration@example.test',
  '',
  now(),
  '{}',
  '{"display_name":"Migration Test","handle":"migration_test"}',
  now(),
  now()
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '40000000-0000-4000-8000-000000000001',
  true
);

create temporary table migration_results(result jsonb);
insert into migration_results
select public.import_legacy_data(
  'legacy-test-batch',
  '{
    "source":"sqlite_v1",
    "players":[
      {"source_id":1,"name":"Alice","email":null,"phone":null,"notes":null,"active":true,"created_at":"2026-01-01T00:00:00Z"},
      {"source_id":2,"name":"Bob","email":null,"phone":null,"notes":null,"active":true,"created_at":"2026-01-01T00:00:00Z"}
    ],
    "sessions":[
      {"source_id":10,"name":"Imported game","started_at":"2026-01-02T00:00:00Z","ended_at":"2026-01-02T03:00:00Z","finalized":true,"settlement_mode":"pairwise","banker_source_session_player_id":null}
    ],
    "session_players":[
      {"source_id":20,"session_source_id":10,"player_source_id":1,"buy_in_cents_total":2000,"cash_out_cents":3000,"paid_upfront":true,"settlement_done":false},
      {"source_id":21,"session_source_id":10,"player_source_id":2,"buy_in_cents_total":2000,"cash_out_cents":1000,"paid_upfront":true,"settlement_done":false}
    ],
    "rebuys":[
      {"source_id":30,"session_player_source_id":20,"amount_cents":500,"created_at":"2026-01-02T01:00:00Z"}
    ],
    "quick_add_entries":[
      {"source_id":40,"player_source_id":1,"amount_cents":125,"note":"Legacy adjustment","created_at":"2026-01-03T00:00:00Z"}
    ]
  }'::jsonb,
  repeat('a', 64)
);

select ok(
  (select (result ->> 'verified')::boolean from migration_results),
  'first migration is verified'
);
select is(
  (select result -> 'counts' from migration_results),
  '{"players":2,"sessions":1,"session_players":2,"rebuys":1,"quick_add_entries":1}'::jsonb,
  'all imported entity counts reconcile'
);

truncate migration_results;
insert into migration_results
select public.import_legacy_data(
  'legacy-test-batch',
  '{
    "source":"sqlite_v1",
    "players":[
      {"source_id":1,"name":"Alice","email":null,"phone":null,"notes":null,"active":true,"created_at":"2026-01-01T00:00:00Z"},
      {"source_id":2,"name":"Bob","email":null,"phone":null,"notes":null,"active":true,"created_at":"2026-01-01T00:00:00Z"}
    ],
    "sessions":[
      {"source_id":10,"name":"Imported game","started_at":"2026-01-02T00:00:00Z","ended_at":"2026-01-02T03:00:00Z","finalized":true,"settlement_mode":"pairwise","banker_source_session_player_id":null}
    ],
    "session_players":[
      {"source_id":20,"session_source_id":10,"player_source_id":1,"buy_in_cents_total":2000,"cash_out_cents":3000,"paid_upfront":true,"settlement_done":false},
      {"source_id":21,"session_source_id":10,"player_source_id":2,"buy_in_cents_total":2000,"cash_out_cents":1000,"paid_upfront":true,"settlement_done":false}
    ],
    "rebuys":[
      {"source_id":30,"session_player_source_id":20,"amount_cents":500,"created_at":"2026-01-02T01:00:00Z"}
    ],
    "quick_add_entries":[
      {"source_id":40,"player_source_id":1,"amount_cents":125,"note":"Legacy adjustment","created_at":"2026-01-03T00:00:00Z"}
    ]
  }'::jsonb,
  repeat('a', 64)
);
select ok(
  (select (result ->> 'replayed')::boolean from migration_results),
  'exact retry returns the stored batch result'
);
reset role;

select is(
  (
    select count(*)::integer
    from public.legacy_import_mappings m
    join public.legacy_import_batches b on b.id = m.batch_id
    where b.batch_id = 'legacy-test-batch'
  ),
  7,
  'retry creates no duplicate mappings'
);
select is(
  (
    select count(*)::integer
    from public.players
    where user_id = '40000000-0000-4000-8000-000000000001'
  ),
  2,
  'retry creates no duplicate players'
);
select is(
  (
    select sum(sp.buy_in_cents_total)::bigint
    from public.session_players sp
    join public.sessions s on s.id = sp.session_id
    where s.user_id = '40000000-0000-4000-8000-000000000001'
  ),
  4000::bigint,
  'imported buy-in checksum matches'
);
select is(
  (
    select sum(sp.cash_out_cents)::bigint
    from public.session_players sp
    join public.sessions s on s.id = sp.session_id
    where s.user_id = '40000000-0000-4000-8000-000000000001'
  ),
  4000::bigint,
  'imported cash-out checksum matches'
);

select * from finish();
rollback;
