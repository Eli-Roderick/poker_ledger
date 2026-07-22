-- Private logical snapshot taken before the additive v2 migration. This is not
-- a replacement for a platform backup, but provides a transaction-local,
-- restorable copy of every Poker Ledger row touched by the redesign.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.poker_ledger_backups (
  backup_key text primary key,
  created_at timestamptz not null default now(),
  payload jsonb not null
);
revoke all on private.poker_ledger_backups from public, anon, authenticated;

insert into private.poker_ledger_backups (backup_key, payload)
select
  'pre_v2_20260720',
  jsonb_build_object(
    'profiles', coalesce((select jsonb_agg(to_jsonb(t)) from public.profiles t), '[]'::jsonb),
    'players', coalesce((select jsonb_agg(to_jsonb(t)) from public.players t), '[]'::jsonb),
    'sessions', coalesce((select jsonb_agg(to_jsonb(t)) from public.sessions t), '[]'::jsonb),
    'session_players', coalesce((select jsonb_agg(to_jsonb(t)) from public.session_players t), '[]'::jsonb),
    'rebuys', coalesce((select jsonb_agg(to_jsonb(t)) from public.rebuys t), '[]'::jsonb),
    'quick_add_entries', coalesce((select jsonb_agg(to_jsonb(t)) from public.quick_add_entries t), '[]'::jsonb),
    'groups', coalesce((select jsonb_agg(to_jsonb(t)) from public.groups t), '[]'::jsonb),
    'group_members', coalesce((select jsonb_agg(to_jsonb(t)) from public.group_members t), '[]'::jsonb),
    'session_groups', coalesce((select jsonb_agg(to_jsonb(t)) from public.session_groups t), '[]'::jsonb),
    'follows', coalesce((select jsonb_agg(to_jsonb(t)) from public.follows t), '[]'::jsonb),
    'app_settings', coalesce((select jsonb_agg(to_jsonb(t)) from public.app_settings t), '[]'::jsonb),
    'deleted_user_group_members', coalesce((select jsonb_agg(to_jsonb(t)) from public.deleted_user_group_members t), '[]'::jsonb),
    'deleted_user_follows', coalesce((select jsonb_agg(to_jsonb(t)) from public.deleted_user_follows t), '[]'::jsonb),
    'deleted_user_player_links', coalesce((select jsonb_agg(to_jsonb(t)) from public.deleted_user_player_links t), '[]'::jsonb),
    'deleted_user_session_groups', coalesce((select jsonb_agg(to_jsonb(t)) from public.deleted_user_session_groups t), '[]'::jsonb),
    'deleted_user_group_ownership', coalesce((select jsonb_agg(to_jsonb(t)) from public.deleted_user_group_ownership t), '[]'::jsonb)
  )
on conflict (backup_key) do nothing;
