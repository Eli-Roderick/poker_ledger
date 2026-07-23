-- Reconcile production drift vs whole_app V2 hardening:
-- 1) Role-aware session_players/legacy financial guard (unblocks start_v2_session)
-- 2) Direct V2 sessions write guard
-- 3) Game invitation notification trigger

create or replace function private.guard_legacy_financial_rows()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  game public.sessions;
  target_session_id bigint;
begin
  if tg_table_name = 'session_players' then
    target_session_id := coalesce(new.session_id, old.session_id);
  else
    select participant.session_id into target_session_id
    from public.session_players participant
    where participant.id = coalesce(
      new.session_player_id,
      old.session_player_id
    );
  end if;
  select * into game
  from public.sessions
  where id = target_session_id;
  if current_user in ('authenticated', 'anon')
     and (game.ledger_version = 2 or game.finalized) then
    raise exception 'Use the transactional ledger API for this game'
      using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists session_players_guard_financial_rows
  on public.session_players;
create trigger session_players_guard_financial_rows
  before insert or update or delete on public.session_players
  for each row execute function private.guard_legacy_financial_rows();

create or replace function private.guard_direct_v2_session_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon')
     and (
       new.ledger_version = 2
       or (tg_op = 'UPDATE' and old.ledger_version = 2)
     ) then
    raise exception 'Use the transactional game API for version 2 games'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

drop trigger if exists sessions_guard_direct_v2_write on public.sessions;
create trigger sessions_guard_direct_v2_write
  before insert or update on public.sessions
  for each row execute function private.guard_direct_v2_session_write();

create or replace function private.notify_game_invitation_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  game_name text;
  profile_name text;
  recipient uuid;
begin
  select coalesce(name, 'Poker game') into game_name
  from public.sessions where id = new.session_id;
  select coalesce(display_name, 'Poker Ledger player') into profile_name
  from public.profiles where id = new.profile_id;
  if tg_op = 'INSERT' then
    recipient := case
      when new.direction = 'host_invite' then new.profile_id
      else (
        select current_host_id from public.sessions where id = new.session_id
      )
    end;
    if recipient is not null then
      insert into public.user_notifications (
        user_id, notification_type, title, body, data
      )
      values (
        recipient,
        case
          when new.direction = 'host_invite' then 'game_invitation'
          else 'game_join_request'
        end,
        case
          when new.direction = 'host_invite' then 'Game invitation'
          else 'Game join request'
        end,
        case
          when new.direction = 'host_invite'
            then 'You were invited to ' || game_name || '.'
          else profile_name || ' requested to join ' || game_name || '.'
        end,
        jsonb_build_object(
          'session_id', new.session_id,
          'invitation_id', new.id
        )
      );
    end if;
  elsif old.status is distinct from new.status
     and new.status in ('accepted', 'declined') then
    recipient := case
      when new.direction = 'host_invite' then new.created_by
      else new.profile_id
    end;
    if recipient is not null and recipient <> auth.uid() then
      insert into public.user_notifications (
        user_id, notification_type, title, body, data
      )
      values (
        recipient,
        'game_invitation_response',
        'Game invitation updated',
        case
          when new.direction = 'host_invite'
            then profile_name || ' ' || new.status ||
              ' the invitation to ' || game_name || '.'
          else 'Your request to join ' || game_name || ' was ' ||
            new.status || '.'
        end,
        jsonb_build_object(
          'session_id', new.session_id,
          'invitation_id', new.id,
          'status', new.status
        )
      );
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists game_invitations_notify_change
  on public.game_invitations;
create trigger game_invitations_notify_change
  after insert or update of status on public.game_invitations
  for each row execute function private.notify_game_invitation_change();
