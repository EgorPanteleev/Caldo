-- The Claude and Codex logins a worker runs chats under (asked as "add
-- accounts of claude and codex, see list of it and its usages, then also
-- select it when creating" a chat, 2026-11-23).
--
-- Each worker has its own login of each (`main`: ~/.claude, ~/.codex), and
-- may have more, signed into from the app: the worker keeps each in a
-- folder of its own and starts a chat's program with it. The worker signs
-- in by the agent's own command; the app is shown the page to sign in on
-- (`login_url`, and for Codex the code to type there, `login_hint`), and
-- for Claude hands back the code the page gives (`login_code`), which the
-- worker types in and clears.
--
-- The account's limits are kept here (`usage`: limits, when heard, whether
-- refused), as the worker reads them every few minutes and as any chat on
-- the account hears them: a chat's own copy is only as new as its last
-- turn.

create table public.agent_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  worker_id uuid not null references public.workers (id) on delete cascade,
  agent text not null check (agent in ('claude', 'codex')),
  main boolean not null default false,
  -- The user's own name for it; empty for its email.
  name text not null default '',
  email text,
  plan text,
  -- new: asked for, the worker has not begun; signing_in: the page is
  -- waiting on the user; ready; signed_out: its login ended; failed.
  state text not null default 'new'
    check (state in ('new', 'signing_in', 'ready', 'signed_out', 'failed')),
  note text,
  login_url text,
  login_hint text,
  login_code text,
  usage jsonb,
  usage_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index agent_accounts_main on public.agent_accounts (worker_id, agent)
  where main;
create index agent_accounts_by_user on public.agent_accounts (user_id, created_at);

-- The account a chat runs under; none for its worker's own.
alter table public.chats add column if not exists account uuid
  references public.agent_accounts (id) on delete set null;

alter table public.agent_accounts enable row level security;

create policy "own agent accounts" on public.agent_accounts for all to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.workers w
                where w.id = worker_id and w.user_id = (select auth.uid()))
  );

grant select, insert, update, delete on public.agent_accounts to authenticated;

alter publication supabase_realtime add table public.agent_accounts;
