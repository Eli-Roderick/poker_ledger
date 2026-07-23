-- Production drift checks for V2 guards/triggers.
-- Run against Poker Ledger prod after forward migrations.
-- INFO advisors for RLS-enabled tables with no policies (app_admins,
-- deleted_user_*) are intentional deny-by-default and not listed here.

\set ON_ERROR_STOP on

do $$
begin
  if position(
    'current_user' in pg_get_functiondef(
      'private.guard_legacy_financial_rows()'::regprocedure
    )
  ) = 0 then
    raise exception
      'guard_legacy_financial_rows missing current_user role bypass';
  end if;

  if to_regprocedure('private.guard_direct_v2_session_write()') is null then
    raise exception 'missing private.guard_direct_v2_session_write()';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.sessions'::regclass
      and tgname = 'sessions_guard_direct_v2_write'
      and not tgisinternal
  ) then
    raise exception 'missing sessions_guard_direct_v2_write trigger';
  end if;

  if to_regprocedure('private.notify_game_invitation_change()') is null then
    raise exception 'missing private.notify_game_invitation_change()';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.game_invitations'::regclass
      and tgname = 'game_invitations_notify_change'
      and not tgisinternal
  ) then
    raise exception 'missing game_invitations_notify_change trigger';
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'game_invitations'
  ) then
    raise exception 'game_invitations not in supabase_realtime publication';
  end if;

  if (
    select count(*)
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename in (
        'game_invitations',
        'sessions',
        'session_players',
        'ledger_events',
        'user_notifications',
        'group_invitations',
        'settlement_transfers'
      )
  ) <> 7 then
    raise exception
      'supabase_realtime publication missing required V2 sync tables';
  end if;
end;
$$;
