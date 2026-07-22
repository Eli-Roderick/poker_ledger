-- Forward-only reconciliation for RPCs omitted from the split production
-- transaction-core rollout, plus an explicit client/backend contract probe.

create or replace function public.invite_profile_to_group(
  p_group_id bigint,
  p_profile_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  invitation public.group_invitations;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'invite_profile_to_group',
    jsonb_build_object('group_id', p_group_id, 'profile_id', p_profile_id)
  );
  if prior is not null then return prior; end if;

  if not private.can_manage_group(p_group_id, actor) then
    raise exception 'You cannot manage this group' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.groups
    where id = p_group_id and archived_at is not null
  ) then
    raise exception 'Archived groups cannot add members'
      using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.profiles
    where id = p_profile_id
      and discoverable
      and deleted_at is null
      and suspended_at is null
  ) then
    raise exception 'Profile not found' using errcode = 'P0002';
  end if;
  if exists (
    select 1 from public.groups
    where id = p_group_id and owner_id = p_profile_id
  ) or exists (
    select 1 from public.group_members
    where group_id = p_group_id
      and user_id = p_profile_id
      and status = 'accepted'
      and left_at is null
  ) then
    result := jsonb_build_object('group_id', p_group_id, 'status', 'accepted');
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;

  update public.group_invitations
  set status = 'cancelled', responded_at = now()
  where group_id = p_group_id
    and profile_id = p_profile_id
    and status = 'pending';

  insert into public.group_invitations (
    group_id,
    profile_id,
    invited_by,
    status,
    expires_at
  )
  values (
    p_group_id,
    p_profile_id,
    actor,
    'pending',
    now() + interval '7 days'
  )
  returning * into invitation;

  insert into public.user_notifications (
    user_id,
    notification_type,
    title,
    body,
    data
  )
  values (
    p_profile_id,
    'group_invitation',
    'Poker group invitation',
    'You were invited to join a poker group.',
    jsonb_build_object('group_id', p_group_id, 'invitation_id', invitation.id)
  );

  result := jsonb_build_object(
    'invitation_id', invitation.id,
    'status', invitation.status
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.respond_to_group_invitation(
  p_invitation_id uuid,
  p_accept boolean,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  invitation public.group_invitations;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'respond_to_group_invitation',
    jsonb_build_object('invitation_id', p_invitation_id, 'accept', p_accept)
  );
  if prior is not null then return prior; end if;

  select * into invitation
  from public.group_invitations
  where id = p_invitation_id
  for update;
  if not found
     or invitation.profile_id <> actor
     or invitation.status <> 'pending'
     or invitation.expires_at <= now() then
    raise exception 'Invitation is no longer pending' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.groups
    where id = invitation.group_id and archived_at is not null
  ) then
    raise exception 'This group is archived' using errcode = '22023';
  end if;

  update public.group_invitations
  set status = case when p_accept then 'accepted' else 'declined' end,
      responded_at = now()
  where id = invitation.id;

  if p_accept then
    insert into public.group_members (
      group_id,
      user_id,
      joined_at,
      status,
      role,
      accepted_at,
      left_at
    )
    values (
      invitation.group_id,
      actor,
      now(),
      'accepted',
      'member',
      now(),
      null
    )
    on conflict (group_id, user_id) do update set
      status = 'accepted',
      role = 'member',
      can_manage_games = false,
      accepted_at = now(),
      left_at = null;
  end if;

  result := jsonb_build_object(
    'group_id', invitation.group_id,
    'status', case when p_accept then 'accepted' else 'declined' end
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

create or replace function public.remove_group_member(
  p_group_id bigint,
  p_profile_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor,
    p_idempotency_key,
    'remove_group_member',
    jsonb_build_object('group_id', p_group_id, 'profile_id', p_profile_id)
  );
  if prior is not null then return prior; end if;
  if not private.can_manage_group(p_group_id, actor) then
    raise exception 'You cannot manage this group' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.groups
    where id = p_group_id and archived_at is not null
  ) then
    raise exception 'Archived group membership is read-only'
      using errcode = '22023';
  end if;

  update public.group_members
  set status = 'removed',
      role = 'member',
      can_manage_games = false,
      left_at = now()
  where group_id = p_group_id
    and user_id = p_profile_id
    and status = 'accepted'
    and left_at is null;

  result := jsonb_build_object('group_id', p_group_id, 'status', 'removed');
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  return result;
end;
$$;

revoke all on function public.invite_profile_to_group(
  bigint, uuid, uuid
) from public, anon;
revoke all on function public.respond_to_group_invitation(
  uuid, boolean, uuid
) from public, anon;
revoke all on function public.remove_group_member(
  bigint, uuid, uuid
) from public, anon;
grant execute on function public.invite_profile_to_group(
  bigint, uuid, uuid
) to authenticated;
grant execute on function public.respond_to_group_invitation(
  uuid, boolean, uuid
) to authenticated;
grant execute on function public.remove_group_member(
  bigint, uuid, uuid
) to authenticated;

create or replace function public.poker_ledger_backend_contract()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select 1;
$$;

revoke all on function public.poker_ledger_backend_contract()
  from public, anon;
grant execute on function public.poker_ledger_backend_contract()
  to authenticated;

notify pgrst, 'reload schema';
