-- Make fresh-database API privileges deterministic. Fresh Supabase no longer
-- auto-grants new public tables to authenticated/anon; the Flutter client and
-- RLS policies still require least-privilege table access.

-- Legacy client-writable surfaces (RLS still authorizes rows).
grant select, insert, update, delete on public.sessions to authenticated;
grant select, insert, update, delete on public.session_players to authenticated;
grant select, insert, update, delete on public.players to authenticated;
grant select, insert, update, delete on public.rebuys to authenticated;
grant select, insert, update, delete on public.quick_add_entries to authenticated;
grant select, insert, update, delete on public.groups to authenticated;
grant select, insert, delete on public.group_members to authenticated;
revoke update on public.group_members from authenticated, anon;
grant select, insert, update, delete on public.session_groups to authenticated;
grant select, insert, update, delete on public.follows to authenticated;
grant select, insert, update on public.app_settings to authenticated;

-- V2 ledger/revision/transfer tables are append-only via SECURITY DEFINER RPCs.
grant select on public.ledger_events to authenticated;
grant select on public.finalization_revisions to authenticated;
grant select on public.settlement_transfers to authenticated;
grant select on public.settlement_transfer_status_history to authenticated;
grant select on public.game_invitations to authenticated;
grant select on public.group_invitations to authenticated;
revoke insert, update, delete on public.ledger_events from authenticated, anon;
revoke insert, update, delete on public.finalization_revisions from authenticated, anon;
revoke insert, update, delete on public.settlement_transfers from authenticated, anon;
revoke insert, update, delete on public.settlement_transfer_status_history
  from authenticated, anon;
revoke insert, update, delete on public.game_invitations from authenticated, anon;
revoke insert, update, delete on public.group_invitations from authenticated, anon;

-- Notifications: clients may read and mark read only.
grant select on public.user_notifications to authenticated;
revoke update on public.user_notifications from authenticated, anon;
grant update (read_at) on public.user_notifications to authenticated;

-- Sensitive rollout/admin/join-code tables stay RPC/service-only.
revoke all on public.app_admins from anon, authenticated;
revoke all on public.feature_enrollments from anon, authenticated;
revoke all on public.game_join_codes from anon, authenticated;
revoke all on public.join_code_attempts from anon, authenticated;
revoke all on public.idempotency_requests from anon, authenticated;
revoke all on public.legacy_import_batches from anon, authenticated;

-- Sequence usage for authenticated direct inserts.
do $$
declare
  sequence_name text;
begin
  foreach sequence_name in array array[
    'sessions_id_seq',
    'session_players_id_seq',
    'players_id_seq',
    'rebuys_id_seq',
    'quick_add_entries_id_seq',
    'groups_id_seq',
    'group_members_id_seq',
    'follows_id_seq',
    'user_notifications_id_seq'
  ]
  loop
    if to_regclass('public.' || sequence_name) is not null then
      execute format(
        'grant usage, select on sequence public.%I to authenticated',
        sequence_name
      );
    end if;
  end loop;
end;
$$;
