#!/usr/bin/env bash
set -euo pipefail

database_url="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

psql "$database_url" -v ON_ERROR_STOP=1 <<'SQL'
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values
  ('60000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-host@example.test', '', now(), '{}', '{"display_name":"Race Host","handle":"race_host"}', now(), now()),
  ('60000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'race-player@example.test', '', now(), '{}', '{"display_name":"Race Player","handle":"race_player"}', now(), now());

insert into public.sessions (
  id, user_id, current_host_id, name, schema_version, ledger_version,
  phase, finalized, currency_code, default_buy_in_cents, next_event_sequence
)
values
  (9801, '60000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000001', 'Idempotency race', 2, 2, 'live', false, 'USD', 1000, 1),
  (9802, '60000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000001', 'Finalization race', 2, 2, 'settling', false, 'USD', 1000, 5);

insert into public.session_players (
  id, session_id, profile_id, display_name_snapshot, accepted_at,
  legacy_participant, paid_upfront
)
values
  (9811, 9801, '60000000-0000-4000-8000-000000000001', 'Race Host', now(), false, false),
  (9821, 9802, '60000000-0000-4000-8000-000000000001', 'Race Host', now(), false, false),
  (9822, 9802, '60000000-0000-4000-8000-000000000002', 'Race Player', now(), false, false);

insert into public.ledger_events (
  session_id, event_sequence, participant_id, event_type, amount_cents,
  actor_id, idempotency_key
)
values
  (9802, 1, 9821, 'initial_buy_in', 1000, '60000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000001'),
  (9802, 2, 9822, 'initial_buy_in', 1000, '60000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000002'),
  (9802, 3, 9821, 'cash_out', -1500, '60000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000003'),
  (9802, 4, 9822, 'cash_out', -500, '60000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000004');
SQL

same_request_sql=$(
  cat <<'SQL'
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',false);
select set_config('request.headers','{"x-poker-ledger-version":"1.0.0"}',false);
set role authenticated;
select public.record_v2_ledger_event(9801,9811,'rebuy',100,null,null,'62000000-0000-4000-8000-000000000001');
SQL
)

pids=()
for _ in $(seq 1 100); do
  psql "$database_url" -v ON_ERROR_STOP=1 -q -c "$same_request_sql" >/dev/null &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done

duplicate_count="$(
  psql "$database_url" -Atqc \
    "select count(*) from public.ledger_events where session_id=9801 and event_type='rebuy';"
)"
if [[ "$duplicate_count" != "1" ]]; then
  echo "Expected one idempotent event, found $duplicate_count" >&2
  exit 1
fi

finalize_sql=$(
  cat <<'SQL'
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',false);
select set_config('request.headers','{"x-poker-ledger-version":"1.0.0"}',false);
set role authenticated;
select public.finalize_v2_session(9802,null,'62000000-0000-4000-8000-000000000002');
SQL
)
write_sql=$(
  cat <<'SQL'
select set_config('request.jwt.claim.sub','60000000-0000-4000-8000-000000000001',false);
select set_config('request.headers','{"x-poker-ledger-version":"1.0.0"}',false);
set role authenticated;
select public.record_v2_ledger_event(9802,9821,'correction',100,'Race correction',null,'62000000-0000-4000-8000-000000000003');
SQL
)

set +e
psql "$database_url" -v ON_ERROR_STOP=1 -q -c "$finalize_sql" >/dev/null 2>&1 &
finalize_pid="$!"
psql "$database_url" -v ON_ERROR_STOP=1 -q -c "$write_sql" >/dev/null 2>&1 &
write_pid="$!"
wait "$finalize_pid"
finalize_status="$?"
wait "$write_pid"
write_status="$?"
set -e

if (( (finalize_status == 0) == (write_status == 0) )); then
  echo "Exactly one side of the finalization/write race must succeed" >&2
  exit 1
fi

race_valid="$(
  psql "$database_url" -Atqc "
    select (
      (finalized and not exists (
        select 1 from public.ledger_events
        where session_id=9802 and event_type='correction'
      ))
      or
      (not finalized and exists (
        select 1 from public.ledger_events
        where session_id=9802 and event_type='correction'
      ))
    )
    from public.sessions where id=9802;
  "
)"
if [[ "$race_valid" != "t" ]]; then
  echo "Finalization race produced an unserialized state" >&2
  exit 1
fi
