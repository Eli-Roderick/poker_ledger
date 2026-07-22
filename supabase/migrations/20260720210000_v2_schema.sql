-- Poker Ledger v2 additive schema. Existing games remain ledger_version = 1;
-- only server-created canary games may use ledger_version = 2.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.app_secrets (
  key text primary key,
  value text not null,
  created_at timestamptz not null default now()
);
revoke all on private.app_secrets from public, anon, authenticated;

insert into private.app_secrets (key, value)
values ('join_code_pepper', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;

alter table public.profiles
  add column if not exists handle text,
  add column if not exists discoverable boolean not null default false,
  add column if not exists avatar_url text,
  add column if not exists suspended_at timestamptz,
  add column if not exists tombstone_id uuid,
  add column if not exists updated_at timestamptz not null default now();

create unique index if not exists profiles_handle_normalized_uidx
  on public.profiles (lower(handle))
  where handle is not null and deleted_at is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_handle_format_check'
  ) then
    alter table public.profiles
      add constraint profiles_handle_format_check
      check (
        handle is null
        or (
          char_length(handle) between 3 and 24
          and handle ~ '^[a-z0-9_]+$'
        )
      );
  end if;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_handle text := lower(new.raw_user_meta_data ->> 'handle');
begin
  if requested_handle !~ '^[a-z0-9_]{3,24}$' then
    requested_handle := null;
  end if;
  insert into public.profiles (
    id,
    email,
    display_name,
    handle,
    discoverable
  )
  values (
    new.id,
    new.email,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
      split_part(new.email, '@', 1)
    ),
    requested_handle,
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

alter table public.groups
  add column if not exists archived_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

alter table public.group_members
  add column if not exists status text not null default 'accepted',
  add column if not exists role text not null default 'member',
  add column if not exists can_manage_games boolean not null default false,
  add column if not exists accepted_at timestamptz,
  add column if not exists left_at timestamptz;

update public.group_members
set accepted_at = coalesce(accepted_at, joined_at)
where status = 'accepted';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'group_members_status_check'
  ) then
    alter table public.group_members
      add constraint group_members_status_check
      check (status in ('pending', 'accepted', 'declined', 'removed'));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'group_members_role_check'
  ) then
    alter table public.group_members
      add constraint group_members_role_check
      check (role in ('member', 'administrator'));
  end if;
end;
$$;

alter table public.sessions
  add column if not exists group_id bigint references public.groups(id)
    on delete restrict,
  add column if not exists schema_version integer not null default 1,
  add column if not exists ledger_version integer not null default 1,
  add column if not exists phase text not null default 'legacy',
  add column if not exists mode_confirmed_at timestamptz,
  add column if not exists current_host_id uuid references auth.users(id)
    on delete set null,
  add column if not exists backup_host_id uuid references auth.users(id)
    on delete set null,
  add column if not exists currency_code text not null default 'USD',
  add column if not exists default_buy_in_cents bigint not null default 2000,
  add column if not exists next_event_sequence bigint not null default 1,
  add column if not exists latest_revision_id bigint,
  add column if not exists membership_closed_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

update public.sessions
set current_host_id = user_id
where current_host_id is null;

update public.sessions
set phase = case when finalized then 'finalized' else 'legacy' end
where ledger_version = 1;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'sessions_version_check'
  ) then
    alter table public.sessions
      add constraint sessions_version_check
      check (schema_version >= 1 and ledger_version in (1, 2));
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'sessions_phase_check'
  ) then
    alter table public.sessions
      add constraint sessions_phase_check
      check (
        phase in (
          'legacy',
          'draft',
          'live',
          'settling',
          'finalized',
          'owner_unavailable_read_only',
          'orphaned_read_only',
          'cancelled'
        )
      );
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'sessions_currency_check'
  ) then
    alter table public.sessions
      add constraint sessions_currency_check
      check (currency_code ~ '^[A-Z]{3}$');
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'sessions_buy_in_check'
  ) then
    alter table public.sessions
      add constraint sessions_buy_in_check
      check (default_buy_in_cents >= 0);
  end if;
end;
$$;

alter table public.session_players
  add column if not exists profile_id uuid references public.profiles(id)
    on delete set null,
  add column if not exists display_name_snapshot text,
  add column if not exists accepted_at timestamptz,
  add column if not exists legacy_participant boolean not null default true,
  add column if not exists removed_at timestamptz,
  alter column player_id drop not null;

update public.session_players sp
set
  profile_id = p.linked_user_id,
  display_name_snapshot = coalesce(sp.display_name_snapshot, p.name),
  accepted_at = coalesce(sp.accepted_at, s.started_at)
from public.players p, public.sessions s
where p.id = sp.player_id
  and s.id = sp.session_id
  and sp.display_name_snapshot is null;

create unique index if not exists session_players_profile_uidx
  on public.session_players(session_id, profile_id)
  where profile_id is not null and removed_at is null;

create table if not exists public.app_admins (
  user_id uuid primary key,
  created_at timestamptz not null default now()
);

create table if not exists public.feature_enrollments (
  feature_key text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  enrolled_at timestamptz not null default now(),
  primary key (feature_key, user_id)
);

insert into public.app_admins (user_id)
values
  ('95749686-83df-4847-bce3-a8965f77b87c'),
  ('ab2da640-4831-43ef-be62-059553dcf5c0'),
  ('89a6ed48-238d-4999-bb93-0406276fdf97'),
  ('369d866d-6af9-4961-b8fb-29805423ca69')
on conflict do nothing;

insert into public.feature_enrollments (feature_key, user_id)
select 'v2_game_flow', administrator.user_id
from public.app_admins administrator
join auth.users auth_user on auth_user.id = administrator.user_id
on conflict do nothing;

create table if not exists public.game_invitations (
  id uuid primary key default gen_random_uuid(),
  session_id bigint not null references public.sessions(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  direction text not null,
  status text not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  responded_at timestamptz,
  cancelled_at timestamptz,
  check (direction in ('host_invite', 'join_request')),
  check (status in ('pending_invitee', 'pending_host', 'accepted', 'declined', 'expired', 'cancelled'))
);

create unique index if not exists game_invitations_active_uidx
  on public.game_invitations(session_id, profile_id)
  where status in ('pending_invitee', 'pending_host');

create table if not exists public.game_join_codes (
  session_id bigint primary key references public.sessions(id) on delete cascade,
  code_digest bytea not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.join_code_attempts (
  id bigint generated by default as identity primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  attempted_at timestamptz not null default now(),
  succeeded boolean not null default false
);

create index if not exists join_code_attempts_profile_time_idx
  on public.join_code_attempts(profile_id, attempted_at desc);

create table if not exists public.group_invitations (
  id uuid primary key default gen_random_uuid(),
  group_id bigint not null references public.groups(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  invited_by uuid not null references auth.users(id) on delete restrict,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  responded_at timestamptz,
  check (status in ('pending', 'accepted', 'declined', 'expired', 'cancelled'))
);

create unique index if not exists group_invitations_active_uidx
  on public.group_invitations(group_id, profile_id)
  where status = 'pending';

create table if not exists public.idempotency_requests (
  actor_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key uuid not null,
  operation text not null,
  request_hash text not null,
  status text not null default 'processing',
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (actor_id, idempotency_key),
  check (status in ('processing', 'completed', 'failed'))
);

create table if not exists public.ledger_events (
  id bigint generated by default as identity primary key,
  session_id bigint not null references public.sessions(id) on delete restrict,
  event_sequence bigint not null,
  participant_id bigint not null references public.session_players(id)
    on delete restrict,
  event_type text not null,
  amount_cents bigint not null check (amount_cents <> 0),
  actor_id uuid references auth.users(id) on delete set null,
  actor_snapshot text,
  reason text,
  reverses_event_id bigint references public.ledger_events(id)
    on delete restrict,
  idempotency_key uuid not null,
  created_at timestamptz not null default now(),
  unique (session_id, event_sequence),
  unique (actor_id, idempotency_key),
  unique (reverses_event_id),
  check (event_type in ('initial_buy_in', 'rebuy', 'cash_out', 'reversal', 'correction')),
  check (
    (event_type in ('initial_buy_in', 'rebuy') and amount_cents > 0)
    or (event_type = 'cash_out' and amount_cents < 0)
    or (event_type in ('reversal', 'correction'))
  ),
  check (
    (event_type in ('reversal', 'correction') and reason is not null and btrim(reason) <> '')
    or event_type not in ('reversal', 'correction')
  )
);

create index if not exists ledger_events_session_sequence_idx
  on public.ledger_events(session_id, event_sequence);
create index if not exists ledger_events_participant_idx
  on public.ledger_events(participant_id, event_sequence);

create table if not exists public.finalization_revisions (
  id bigint generated by default as identity primary key,
  session_id bigint not null references public.sessions(id) on delete restrict,
  revision_number integer not null,
  through_event_sequence bigint not null,
  settlement_engine_version integer not null,
  settlement_mode text not null,
  total_buy_in_cents bigint not null,
  total_cash_out_cents bigint not null,
  reason text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  superseded_at timestamptz,
  unique (session_id, revision_number),
  check (settlement_mode in ('pairwise', 'banker')),
  check (total_buy_in_cents = total_cash_out_cents)
);

alter table public.finalization_revisions
  add column if not exists supersedes_revision_id bigint
    references public.finalization_revisions(id) on delete restrict;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'sessions_latest_revision_id_fkey'
  ) then
    alter table public.sessions
      add constraint sessions_latest_revision_id_fkey
      foreign key (latest_revision_id)
      references public.finalization_revisions(id)
      on delete restrict;
  end if;
end;
$$;

create table if not exists public.settlement_transfers (
  id bigint generated by default as identity primary key,
  revision_id bigint not null references public.finalization_revisions(id)
    on delete restrict,
  from_participant_id bigint not null references public.session_players(id)
    on delete restrict,
  to_participant_id bigint not null references public.session_players(id)
    on delete restrict,
  amount_cents bigint not null check (amount_cents > 0),
  status text not null default 'pending',
  status_updated_by uuid references auth.users(id) on delete set null,
  status_updated_at timestamptz,
  created_at timestamptz not null default now(),
  check (from_participant_id <> to_participant_id),
  check (status in ('pending', 'paid', 'received', 'disputed'))
);

create index if not exists settlement_transfers_revision_idx
  on public.settlement_transfers(revision_id);

create table if not exists public.user_notifications (
  id bigint generated by default as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  notification_type text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists user_notifications_user_created_idx
  on public.user_notifications(user_id, created_at desc);

create table if not exists public.legacy_import_batches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  batch_id text not null,
  checksum text not null,
  counts jsonb not null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, batch_id)
);

create table if not exists public.legacy_import_mappings (
  batch_id uuid not null references public.legacy_import_batches(id)
    on delete cascade,
  entity_type text not null,
  source_id bigint not null,
  destination_id bigint not null,
  primary key (batch_id, entity_type, source_id)
);

create index if not exists sessions_group_started_idx
  on public.sessions(group_id, started_at desc)
  where group_id is not null;
create index if not exists sessions_current_host_phase_idx
  on public.sessions(current_host_id, phase);
create index if not exists session_players_profile_idx
  on public.session_players(profile_id, session_id)
  where profile_id is not null;
create index if not exists group_members_active_idx
  on public.group_members(group_id, user_id)
  where status = 'accepted' and left_at is null;

alter table public.app_admins enable row level security;
alter table public.feature_enrollments enable row level security;
alter table public.game_invitations enable row level security;
alter table public.game_join_codes enable row level security;
alter table public.join_code_attempts enable row level security;
alter table public.group_invitations enable row level security;
alter table public.idempotency_requests enable row level security;
alter table public.ledger_events enable row level security;
alter table public.finalization_revisions enable row level security;
alter table public.settlement_transfers enable row level security;
alter table public.user_notifications enable row level security;
alter table public.legacy_import_batches enable row level security;
alter table public.legacy_import_mappings enable row level security;

revoke all on public.app_admins from anon, authenticated;
revoke all on public.feature_enrollments from anon, authenticated;
revoke all on public.game_join_codes from anon, authenticated;
revoke all on public.join_code_attempts from anon, authenticated;
revoke all on public.idempotency_requests from anon, authenticated;
revoke insert, update, delete on public.ledger_events from anon, authenticated;
revoke insert, update, delete on public.finalization_revisions from anon, authenticated;
revoke insert, update, delete on public.settlement_transfers from anon, authenticated;
revoke all on public.legacy_import_batches from anon, authenticated;
revoke all on public.legacy_import_mappings from anon, authenticated;

create or replace function private.prevent_v2_group_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.ledger_version = 2
     and old.group_id is distinct from new.group_id
     and (
       old.phase <> 'draft'
       or exists (
         select 1 from public.game_invitations gi
         where gi.session_id = old.id
       )
       or exists (
         select 1 from public.session_players sp
         where sp.session_id = old.id and sp.legacy_participant = false
       )
       or exists (
         select 1 from public.ledger_events le
         where le.session_id = old.id
       )
     )
  then
    raise exception 'Game group is locked';
  end if;
  return new;
end;
$$;

drop trigger if exists sessions_prevent_v2_group_change on public.sessions;
create trigger sessions_prevent_v2_group_change
  before update of group_id on public.sessions
  for each row execute function private.prevent_v2_group_change();

create or replace function private.validate_reversal()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  original public.ledger_events;
begin
  if new.reverses_event_id is null then
    if new.event_type = 'reversal' then
      raise exception 'A reversal must reference its original event';
    end if;
    return new;
  end if;

  select * into original
  from public.ledger_events
  where id = new.reverses_event_id;
  if not found
     or original.session_id <> new.session_id
     or original.participant_id <> new.participant_id
     or original.amount_cents <> -new.amount_cents
  then
    raise exception 'Reversal must exactly offset an event for the same game and participant';
  end if;
  return new;
end;
$$;

drop trigger if exists ledger_events_validate_reversal on public.ledger_events;
create trigger ledger_events_validate_reversal
  before insert on public.ledger_events
  for each row execute function private.validate_reversal();
