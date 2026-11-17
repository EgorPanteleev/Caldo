-- Accounts are made by invitation. There is no mail server to prove an
-- address with, so the login is a name and a password, and the only thing
-- standing between the public key and a new account is an invite: a code
-- made by an admin, good for one account, handed over as caldo://invite/…

create table public.invites (
  code text primary key,
  made_by uuid references auth.users (id) on delete set null,
  made_at timestamptz not null default now(),
  -- Set once an account has been made with it; the account may later be
  -- deleted, and the invite stays spent.
  used_at timestamptz,
  used_by uuid references auth.users (id) on delete set null
);

-- Who may make invites. Filled by hand (`supabase db query`); nothing a
-- client can call writes to it.
create table public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

alter table public.invites enable row level security;
alter table public.admins enable row level security;
revoke all on public.invites from anon, authenticated;
revoke all on public.admins from anon, authenticated;

-- Auth's "before user created" hook: every way an account can be made on
-- the public key — a password sign-up, a code, a provider — passes through
-- it, and one without an unused invite in its metadata is turned down.
-- Accounts made by an admin's own hand (the dashboard, the service key)
-- carry no invite and are the trigger's below to let through.
create function public.before_user_created(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  given text := upper(trim(event #>> '{user,user_metadata,invite}'));
begin
  if given is not null and exists (
    select 1 from public.invites i where i.code = given and i.used_at is null
  ) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'invite not valid'
  ));
end
$$;

revoke execute on function public.before_user_created(jsonb)
  from public, anon, authenticated;
grant execute on function public.before_user_created(jsonb)
  to supabase_auth_admin;

-- Spends the invite as the account is written. The hook only looked; two
-- sign-ups with one invite at the same moment would both have passed it,
-- and the second finds it spent here and is rolled back.
create function public.spend_invite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.invites
  set used_at = now(), used_by = new.id
  where code = upper(trim(new.raw_user_meta_data ->> 'invite'))
    and used_at is null;
  if not found then
    raise exception 'invite not valid' using errcode = '28000';
  end if;
  return new;
end
$$;

create trigger spend_invite
  after insert on auth.users
  for each row
  when (new.raw_user_meta_data ? 'invite')
  execute function public.spend_invite();

-- Twelve characters of an alphabet with no 0/O or 1/I to mistake: 60 bits,
-- past guessing at any rate the server would answer.
create function public.make_invite()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  bytes bytea := extensions.gen_random_bytes(12);
  made text := '';
begin
  if not exists (
    select 1 from public.admins a where a.user_id = auth.uid()
  ) then
    raise exception 'not an admin' using errcode = '42501';
  end if;
  for i in 0..11 loop
    made := made || substr(alphabet, get_byte(bytes, i) % 32 + 1, 1);
  end loop;
  insert into public.invites (code, made_by) values (made, auth.uid());
  return made;
end
$$;

create function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.admins a where a.user_id = auth.uid());
$$;

revoke execute on function public.make_invite() from public, anon;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.make_invite() to authenticated;
grant execute on function public.is_admin() to authenticated;
