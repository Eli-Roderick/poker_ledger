\set ON_ERROR_STOP on

do $$
declare
  signature text;
  required_signatures constant text[] := array[
    'public.poker_ledger_backend_contract()',
    'public.my_games()',
    'public.visible_games()',
    'public.group_games(bigint)',
    'public.game_participant_totals(bigint[])',
    'public.my_stats()',
    'public.group_stats(bigint)',
    'public.can_edit_v2_session(bigint)',
    'public.v2_game_flow_available()',
    'public.search_discoverable_profiles(text,integer,bigint,bigint)',
    'public.invite_profile_to_game(bigint,uuid,uuid)',
    'public.create_game_join_code(bigint,uuid)',
    'public.request_game_join_by_code(text,uuid)',
    'public.respond_to_game_invitation(uuid,boolean,uuid)',
    'public.return_v2_session_to_live(bigint,text,uuid)',
    'public.cancel_v2_session(bigint,text,uuid)',
    'public.set_v2_backup_host(bigint,uuid,uuid)',
    'public.set_v2_settlement_preferences(bigint,text,bigint,uuid,bigint[])',
    'public.update_settlement_transfer_status(bigint,text,uuid)',
    'public.archive_group(bigint,uuid)',
    'public.invite_profile_to_group(bigint,uuid,uuid)',
    'public.respond_to_group_invitation(uuid,boolean,uuid)',
    'public.remove_group_member(bigint,uuid,uuid)',
    'public.set_group_member_game_manager(bigint,uuid,boolean,uuid)',
    'public.leave_group(bigint,uuid)',
    'public.transfer_group_ownership(bigint,uuid,uuid)',
    'public.get_restorable_account(text,text)',
    'public.restore_deleted_account(text,text)',
    'public.request_account_deletion(uuid)',
    'public.add_legacy_rebuy(bigint,bigint,uuid)',
    'public.set_legacy_cash_out(bigint,bigint,uuid)'
  ];
begin
  foreach signature in array required_signatures loop
    if to_regprocedure(signature) is null then
      raise exception 'Missing required backend function: %', signature;
    end if;
  end loop;
  if public.poker_ledger_backend_contract() < 1 then
    raise exception 'Poker Ledger backend contract is too old';
  end if;
end;
$$;
