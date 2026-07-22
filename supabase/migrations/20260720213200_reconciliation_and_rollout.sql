-- Historical reconciliation inventory, rollout probe, and durable operation
-- telemetry. No legacy session is converted by this migration.

create table if not exists private.v2_reconciliation_findings (
  issue_key text primary key,
  issue_type text not null,
  severity text not null,
  session_id bigint,
  entity_id text,
  details jsonb not null default '{}'::jsonb,
  refreshed_at timestamptz not null default now(),
  check (severity in ('info', 'warning', 'error'))
);
revoke all on private.v2_reconciliation_findings
  from public, anon, authenticated;

create or replace function private.refresh_v2_reconciliation_findings()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  finding_count integer;
begin
  truncate private.v2_reconciliation_findings;

  insert into private.v2_reconciliation_findings (
    issue_key, issue_type, severity, session_id, entity_id, details
  )
  select
    'guest:' || participant.id,
    'unresolved_guest',
    'warning',
    participant.session_id,
    participant.id::text,
    jsonb_build_object(
      'player_id', participant.player_id,
      'display_name_snapshot', participant.display_name_snapshot
    )
  from public.session_players participant
  where participant.legacy_participant
    and participant.profile_id is null;

  insert into private.v2_reconciliation_findings (
    issue_key, issue_type, severity, entity_id, details
  )
  select
    'linked-profile:' || player.linked_user_id,
    'duplicate_linked_account_mapping',
    'warning',
    player.linked_user_id::text,
    jsonb_build_object(
      'player_ids',
      jsonb_agg(player.id order by player.id)
    )
  from public.players player
  where player.linked_user_id is not null
  group by player.linked_user_id
  having count(*) > 1;

  insert into private.v2_reconciliation_findings (
    issue_key, issue_type, severity, session_id, entity_id, details
  )
  select
    'duplicate-participant:' || participant.session_id || ':' ||
      participant.profile_id,
    'duplicate_session_account_mapping',
    'error',
    participant.session_id,
    participant.profile_id::text,
    jsonb_build_object(
      'participant_ids',
      jsonb_agg(participant.id order by participant.id)
    )
  from public.session_players participant
  where participant.profile_id is not null
    and participant.removed_at is null
  group by participant.session_id, participant.profile_id
  having count(*) > 1;

  insert into private.v2_reconciliation_findings (
    issue_key, issue_type, severity, session_id, details
  )
  select
    'multi-group:' || link.session_id,
    'legacy_multi_group_history',
    'warning',
    link.session_id,
    jsonb_build_object(
      'group_ids',
      jsonb_agg(link.group_id order by link.group_id)
    )
  from public.session_groups link
  group by link.session_id
  having count(*) > 1;

  insert into private.v2_reconciliation_findings (
    issue_key, issue_type, severity, session_id, entity_id, details
  )
  select
    'money:' || participant.id,
    'legacy_money_anomaly',
    'warning',
    participant.session_id,
    participant.id::text,
    jsonb_build_object(
      'buy_in_cents_total', participant.buy_in_cents_total,
      'cash_out_cents', participant.cash_out_cents
    )
  from public.session_players participant
  join public.sessions game on game.id = participant.session_id
  where game.ledger_version = 1
    and (
      participant.buy_in_cents_total <= 0
      or participant.cash_out_cents < 0
    );

  insert into private.v2_reconciliation_findings (
    issue_key, issue_type, severity, session_id, details
  )
  select
    'settlement:' || game.id,
    'legacy_settlement_mismatch',
    'error',
    game.id,
    jsonb_build_object(
      'buy_in_cents',
      coalesce(sum(participant.buy_in_cents_total), 0),
      'cash_out_cents',
      coalesce(sum(participant.cash_out_cents), 0)
    )
  from public.sessions game
  join public.session_players participant on participant.session_id = game.id
  where game.ledger_version = 1
    and game.finalized
  group by game.id
  having coalesce(sum(participant.buy_in_cents_total), 0)
    <> coalesce(sum(participant.cash_out_cents), 0);

  insert into private.v2_reconciliation_findings (
    issue_key, issue_type, severity, entity_id, details
  )
  select
    'missing-owner-membership:' || grouped.id,
    'missing_owner_group_membership',
    'info',
    grouped.id::text,
    jsonb_build_object('owner_id', grouped.owner_id)
  from public.groups grouped
  where not exists (
    select 1
    from public.group_members membership
    where membership.group_id = grouped.id
      and membership.user_id = grouped.owner_id
      and membership.status = 'accepted'
      and membership.left_at is null
  );

  insert into private.v2_reconciliation_findings (
    issue_key, issue_type, severity, session_id, entity_id, details
  )
  select
    'orphan-rebuy:' || rebuy.id,
    'orphan_financial_row',
    'error',
    participant.session_id,
    rebuy.id::text,
    jsonb_build_object('table', 'rebuys')
  from public.rebuys rebuy
  left join public.session_players participant
    on participant.id = rebuy.session_player_id
  where participant.id is null;

  select count(*) into finding_count
  from private.v2_reconciliation_findings;
  return finding_count;
end;
$$;

select private.refresh_v2_reconciliation_findings();

create table if not exists private.v2_operation_logs (
  id bigint generated by default as identity primary key,
  operation text not null,
  actor_id uuid,
  session_id bigint,
  phase text,
  outcome text not null default 'success',
  client_version text not null,
  created_at timestamptz not null default now()
);
create index if not exists v2_operation_logs_created_idx
  on private.v2_operation_logs(created_at desc);
create index if not exists v2_operation_logs_operation_idx
  on private.v2_operation_logs(operation, outcome, created_at desc);
revoke all on private.v2_operation_logs from public, anon, authenticated;

create or replace function private.log_v2_operation(
  p_operation text,
  p_session_id bigint,
  p_phase text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.v2_operation_logs (
    operation, actor_id, session_id, phase, client_version
  )
  values (
    p_operation, auth.uid(), p_session_id, p_phase,
    private.client_version()
  );
  raise log 'poker_ledger operation=% session=% phase=% client=% outcome=success',
    p_operation,
    p_session_id,
    p_phase,
    private.client_version();
end;
$$;

create or replace function public.v2_game_flow_available()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce((
      select value::boolean
      from public.app_settings
      where key = 'v2_enrollment_enabled'
    ), false)
    and private.version_number(private.client_version()) >=
      private.version_number(coalesce((
        select value
        from public.app_settings
        where key = 'v2_min_client_version'
      ), '1.0.0'))
    and exists (
      select 1
      from public.feature_enrollments enrollment
      where enrollment.feature_key = 'v2_game_flow'
        and enrollment.user_id = auth.uid()
    );
$$;

revoke all on function public.v2_game_flow_available()
  from public, anon;
grant execute on function public.v2_game_flow_available()
  to authenticated;
