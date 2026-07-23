-- game_join_codes.session_id is the primary key (one row per game).
-- Revoke-then-insert conflicts on regenerate; upsert the active code instead.

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
    code := upper(encode(extensions.gen_random_bytes(6), 'hex'));
    exit when not exists (
      select 1 from public.game_join_codes
      where code_digest = extensions.hmac(code, pepper, 'sha256')
        and revoked_at is null
        and expires_at > now()
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
    now() + interval '2 hours',
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
    'expires_at', now() + interval '2 hours'
  );
  perform private.complete_idempotent(actor, p_idempotency_key, result);
  perform private.log_v2_operation(
    'create_game_join_code', p_session_id, game.phase
  );
  return result;
end;
$$;

revoke all on function public.create_game_join_code(bigint, uuid)
  from public, anon;
grant execute on function public.create_game_join_code(bigint, uuid)
  to authenticated;
