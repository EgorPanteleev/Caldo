-- Agents: Claude, Codex, a model run on the user's own machine, or a plain
-- shell, each run in a terminal on one of the user's computers (a worker,
-- `caldo-mcp watch`) and watched and typed into from the app.
--
-- Not synced rows: a chat is only any use with the network up, so it lives
-- here and nowhere else. A worker says what it can run; the app asks one
-- for a chat; the worker runs it, writes what the terminal shows into
-- chat_out, and takes keys and sizes from chat_in.

create table public.workers (
  -- Chosen by the worker and kept on its computer, so a worker started
  -- again is the same worker.
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null,
  -- What it can run: [{id, label, models, efforts, permissions, plugins,
  -- skills, prompt}], and folders worth offering.
  agents jsonb not null default '[]',
  dirs jsonb not null default '[]',
  home text,
  -- Touched every half minute while it runs: older than that by much, it
  -- is not there.
  seen_at timestamptz not null default now()
);

create table public.chats (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  worker_id uuid references public.workers (id) on delete set null,
  agent text not null,
  title text not null default '',
  model text,
  effort text,
  dir text,
  permission text,
  plugins jsonb,
  skills jsonb not null default '[]',
  prompt text not null default '',
  -- The task this chat does, for one handed over from a task.
  task_uuid uuid,
  -- new: asked for, not yet started; running; asking (waiting on the user,
  -- a permission say); idle (done with its turn); ended; failed.
  state text not null default 'new'
    check (state in ('new', 'running', 'asking', 'idle', 'ended', 'failed')),
  note text,
  cols integer not null default 80 check (cols between 10 and 500),
  rows integer not null default 24 check (rows between 5 and 300),
  -- The agent's own session, to take up again after it ended.
  session text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index chats_by_user on public.chats (user_id, updated_at desc);

-- What the terminal wrote, in order. A snapshot is the whole screen and
-- its scrollback as it stood, written from time to time, so the app need
-- read from the latest one on, and what came before it can go.
create table public.chat_out (
  chat_id uuid not null references public.chats (id) on delete cascade,
  seq integer not null,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  data text not null,
  snap boolean not null default false,
  primary key (chat_id, seq)
);

create index chat_out_snaps on public.chat_out (chat_id, seq) where snap;

-- What the app sends: keys as the terminal would have them, a line to
-- paste and submit, a new size, stop, start again. Taken by the worker
-- and deleted.
create table public.chat_in (
  id bigint generated always as identity primary key,
  chat_id uuid not null references public.chats (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in ('keys', 'line', 'size', 'stop', 'start')),
  data text,
  cols integer,
  rows integer,
  created_at timestamptz not null default now()
);

create index chat_in_by_chat on public.chat_in (chat_id, id);

create function public.chats_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger chats_touch before update on public.chats
  for each row execute function public.chats_touch();

-- Each account its own, wholly: the app and the worker sign in as the same
-- user.
alter table public.workers enable row level security;
alter table public.chats enable row level security;
alter table public.chat_out enable row level security;
alter table public.chat_in enable row level security;

create policy "own workers" on public.workers for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own chats" on public.chats for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- A row may only be put on a chat of the same account's.
create policy "own output" on public.chat_out for all to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.chats c
                where c.id = chat_id and c.user_id = (select auth.uid()))
  );
create policy "own input" on public.chat_in for all to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.chats c
                where c.id = chat_id and c.user_id = (select auth.uid()))
  );

grant select, insert, update, delete on public.workers, public.chats,
  public.chat_out, public.chat_in to authenticated;

alter publication supabase_realtime add table public.workers, public.chats,
  public.chat_out, public.chat_in;
