-- Either party can mark a transfer paid; publish settlement_transfers for Realtime sync.

create or replace function public.update_settlement_transfer_status(
  p_transfer_id bigint,
  p_status text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  transfer public.settlement_transfers;
  revision public.finalization_revisions;
  game public.sessions;
  payer_profile_id uuid;
  recipient_profile_id uuid;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'update_settlement_transfer_status',
    jsonb_build_object('transfer_id', p_transfer_id, 'status', p_status)
  );
  if prior is not null then return prior; end if;
  if p_status not in ('paid', 'received', 'disputed') then
    raise exception 'Unsupported transfer status' using errcode = '22023';
  end if;
  select * into transfer
  from public.settlement_transfers
  where id = p_transfer_id
  for update;
  if not found then
    raise exception 'Settlement transfer not found' using errcode = 'P0002';
  end if;
  select * into revision
  from public.finalization_revisions
  where id = transfer.revision_id;
  select * into game
  from public.sessions
  where id = revision.session_id;
  if game.phase <> 'finalized'
     or game.latest_revision_id <> revision.id then
    raise exception 'Only transfers in the current finalized revision can change'
      using errcode = '22023';
  end if;
  if exists (
    select 1 from public.groups grouped
    where grouped.id = game.group_id
      and grouped.archived_at is not null
  ) then
    raise exception 'Archived group games are read-only'
      using errcode = '55000';
  end if;
  select profile_id into payer_profile_id
  from public.session_players
  where id = transfer.from_participant_id;
  select profile_id into recipient_profile_id
  from public.session_players
  where id = transfer.to_participant_id;
  if transfer.status = p_status then
    result := jsonb_build_object(
      'transfer_id', transfer.id,
      'status', transfer.status
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;
  if p_status = 'paid' and not (
    actor in (payer_profile_id, recipient_profile_id)
    and transfer.status in ('pending', 'disputed')
  ) then
    raise exception 'Only a transfer participant can mark this transfer paid'
      using errcode = '42501';
  elsif p_status = 'received' and not (
    recipient_profile_id = actor
    and transfer.status = 'paid'
  ) then
    raise exception 'The recipient can confirm only a paid transfer'
      using errcode = '42501';
  elsif p_status = 'disputed' and not (
    actor in (payer_profile_id, recipient_profile_id)
    and transfer.status <> 'received'
  ) then
    raise exception 'Only a transfer participant can dispute it'
      using errcode = '42501';
  end if;
  insert into public.settlement_transfer_status_history (
    transfer_id, previous_status, new_status, changed_by
  )
  values (transfer.id, transfer.status, p_status, actor);
  update public.settlement_transfers
  set status = p_status,
      status_updated_by = actor,
      status_updated_at = now()
  where id = transfer.id;
  result := jsonb_build_object(
    'transfer_id', transfer.id,
    'status', p_status
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'update_settlement_transfer_status', game.id, game.phase
  );
  return result;
end;
$$;

revoke all on function public.update_settlement_transfer_status(
  bigint, text, uuid
) from public, anon;
grant execute on function public.update_settlement_transfer_status(
  bigint, text, uuid
) to authenticated;

alter table public.settlement_transfers replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'settlement_transfers'
  ) then
    alter publication supabase_realtime add table public.settlement_transfers;
  end if;
end;
$$;
