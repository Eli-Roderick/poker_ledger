-- Permanent 6-letter A–Z join codes + never-expiring join requests.
-- Also publish game_invitations for host Realtime lobby updates.

create or replace function public.create_game_join_code(
  p_session_id bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  game public.sessions;
  prior jsonb;
  code text;
  pepper text;
  result jsonb;
  random_bytes bytea;
  i integer;
begin
  perform private.require_compatible_client();
  game := private.require_v2_host(p_session_id);
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'create_game_join_code',
    jsonb_build_object('session_id', p_session_id)
  );
  if prior is not null then
    return prior;
  end if;
  if game.phase not in ('draft', 'live')
     or game.membership_closed_at is not null then
    raise exception 'Join codes are closed for this game'
      using errcode = '22023';
  end if;
  select value into pepper
  from private.app_secrets
  where key = 'join_code_pepper';
  if pepper is null then
    raise exception 'Join codes are temporarily unavailable'
      using errcode = '55000';
  end if;

  loop
    random_bytes := extensions.gen_random_bytes(6);
    code := '';
    for i in 0..5 loop
      code := code || chr(65 + (get_byte(random_bytes, i) % 26));
    end loop;
    exit when not exists (
      select 1 from public.game_join_codes
      where code_digest = extensions.hmac(code, pepper, 'sha256')
        and revoked_at is null
        and session_id <> p_session_id
    );
  end loop;

  insert into public.game_join_codes (
    session_id, code_digest, created_by, expires_at, revoked_at
  )
  values (
    p_session_id,
    extensions.hmac(code, pepper, 'sha256'),
    actor,
    'infinity'::timestamptz,
    null
  )
  on conflict (session_id) do update set
    code_digest = excluded.code_digest,
    expires_at = excluded.expires_at,
    revoked_at = null,
    created_by = excluded.created_by,
    created_at = now();

  result := jsonb_build_object(
    'session_id', p_session_id,
    'code', code,
    'expires_at', null
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'create_game_join_code', p_session_id, game.phase
  );
  return result;
end;
$$;

create or replace function public.request_game_join_by_code(
  p_code text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.require_actor();
  normalized_code text := upper(regexp_replace(p_code, '[^A-Z0-9]', '', 'g'));
  pepper text;
  join_code public.game_join_codes;
  game public.sessions;
  invitation public.game_invitations;
  prior jsonb;
  result jsonb;
begin
  perform private.require_compatible_client();
  prior := private.begin_idempotent(
    actor, p_idempotency_key, 'request_game_join_by_code',
    jsonb_build_object('code', normalized_code)
  );
  if prior is not null then
    return prior;
  end if;
  if (
    select count(*) >= 8
    from public.join_code_attempts
    where profile_id = actor
      and attempted_at > now() - interval '15 minutes'
  ) then
    raise exception 'Too many join-code attempts; try again later'
      using errcode = '42900';
  end if;
  select value into pepper
  from private.app_secrets
  where key = 'join_code_pepper';
  if pepper is null then
    raise exception 'Join codes are temporarily unavailable'
      using errcode = '55000';
  end if;
  select * into join_code
  from public.game_join_codes
  where code_digest = extensions.hmac(normalized_code, pepper, 'sha256')
    and revoked_at is null
    and expires_at > now()
  for update;
  if not found then
    insert into public.join_code_attempts (profile_id, succeeded)
    values (actor, false);
    result := jsonb_build_object(
      'status', 'invalid',
      'message', 'Code is invalid or expired'
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;
  insert into public.join_code_attempts (profile_id, succeeded)
  values (actor, true);
  select * into game
  from public.sessions
  where id = join_code.session_id
  for update;
  if game.ledger_version <> 2
     or game.phase not in ('draft', 'live')
     or game.membership_closed_at is not null then
    result := jsonb_build_object(
      'status', 'unavailable',
      'message', 'This game is no longer accepting players'
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;
  if exists (
    select 1 from public.session_players
    where session_id = game.id
      and profile_id = actor
      and removed_at is null
  ) then
    result := jsonb_build_object(
      'status', 'participating',
      'session_id', game.id
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;
  update public.game_invitations
  set status = 'expired', responded_at = now()
  where session_id = game.id
    and profile_id = actor
    and status in ('pending_invitee', 'pending_host')
    and expires_at <= now();
  select * into invitation
  from public.game_invitations
  where session_id = game.id
    and profile_id = actor
    and status in ('pending_invitee', 'pending_host')
    and expires_at > now()
  order by created_at desc
  limit 1;
  if found then
    result := jsonb_build_object(
      'status', invitation.status,
      'invitation_id', invitation.id,
      'session_id', game.id
    );
    perform private.complete_idempotent(actor, p_idempotency_key, result);
    return result;
  end if;
  insert into public.game_invitations (
    session_id, profile_id, direction, status,
    created_by, expires_at
  )
  values (
    game.id, actor, 'join_request', 'pending_host',
    actor, 'infinity'::timestamptz
  )
  returning * into invitation;
  result := jsonb_build_object(
    'status', invitation.status,
    'invitation_id', invitation.id,
    'session_id', game.id
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'request_game_join_by_code', game.id, game.phase
  );
  return result;
end;
$$;

revoke all on function public.create_game_join_code(bigint, uuid)
  from public, anon;
revoke all on function public.request_game_join_by_code(text, uuid)
  from public, anon;
grant execute on function public.create_game_join_code(bigint, uuid)
  to authenticated;
grant execute on function public.request_game_join_by_code(text, uuid)
  to authenticated;

-- Realtime: hosts watching a game should see join requests promptly.
alter table public.game_invitations replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'game_invitations'
  ) then
    alter publication supabase_realtime add table public.game_invitations;
  end if;
end;
$$;
