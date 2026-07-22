begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(5);

create temporary table expected_backend_functions (signature text primary key);
insert into expected_backend_functions (signature)
values
  ('public.poker_ledger_backend_contract()'),
  ('public.my_games()'),
  ('public.visible_games()'),
  ('public.group_games(bigint)'),
  ('public.game_participant_totals(bigint[])'),
  ('public.my_stats()'),
  ('public.group_stats(bigint)'),
  ('public.can_edit_v2_session(bigint)'),
  ('public.v2_game_flow_available()'),
  ('public.search_discoverable_profiles(text,integer,bigint,bigint)'),
  ('public.invite_profile_to_game(bigint,uuid,uuid)'),
  ('public.create_game_join_code(bigint,uuid)'),
  ('public.request_game_join_by_code(text,uuid)'),
  ('public.respond_to_game_invitation(uuid,boolean,uuid)'),
  ('public.return_v2_session_to_live(bigint,text,uuid)'),
  ('public.cancel_v2_session(bigint,text,uuid)'),
  ('public.set_v2_backup_host(bigint,uuid,uuid)'),
  ('public.update_settlement_transfer_status(bigint,text,uuid)'),
  ('public.archive_group(bigint,uuid)'),
  ('public.invite_profile_to_group(bigint,uuid,uuid)'),
  ('public.respond_to_group_invitation(uuid,boolean,uuid)'),
  ('public.remove_group_member(bigint,uuid,uuid)'),
  ('public.set_group_member_game_manager(bigint,uuid,boolean,uuid)'),
  ('public.leave_group(bigint,uuid)'),
  ('public.transfer_group_ownership(bigint,uuid,uuid)'),
  ('public.request_account_deletion(uuid)'),
  ('public.add_legacy_rebuy(bigint,bigint,uuid)'),
  ('public.set_legacy_cash_out(bigint,bigint,uuid)');

select is(
  public.poker_ledger_backend_contract(),
  1,
  'backend contract publishes the client-compatible version'
);
select is(
  (
    select count(*)::integer
    from expected_backend_functions
    where to_regprocedure(signature) is null
  ),
  0,
  'every production-reachable backend function exists'
);
select is(
  (
    select count(*)::integer
    from expected_backend_functions
    where not has_function_privilege(
      'authenticated',
      to_regprocedure(signature),
      'execute'
    )
  ),
  0,
  'authenticated users can execute every client backend function'
);
select is(
  (
    select count(*)::integer
    from expected_backend_functions
    where has_function_privilege(
      'anon',
      to_regprocedure(signature),
      'execute'
    )
  ),
  0,
  'anonymous users cannot execute authenticated backend functions'
);
select ok(
  to_regprocedure('public.get_restorable_account(text,text)') is not null
    and to_regprocedure('public.restore_deleted_account(text,text)') is not null
    and has_function_privilege(
      'anon',
      'public.get_restorable_account(text,text)',
      'execute'
    )
    and has_function_privilege(
      'anon',
      'public.restore_deleted_account(text,text)',
      'execute'
    ),
  'credential-verified restoration remains available before sign-in'
);

select * from finish();
rollback;
