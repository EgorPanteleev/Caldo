-- A project's context as a whole, seen and changed from the app (asked as
-- "see all context that project have and ability to edit it",
-- 2026-11-25): beside the words kept on the project, what Claude reads on
-- the worker — the user's ~/.claude/CLAUDE.md, the CLAUDE.md files of the
-- project's folders and the folders above them, and Claude's memory of
-- each folder's repository.
--
-- Those files live on the worker's disk, so the app asks it here and the
-- worker answers on the same row: `read` with the project's `sources`
-- (from ~), answered with `files` [{path, kind, source, body,
-- uncommitted}]; `write` with `path` and `body`, and `remove` with `path`
-- (a memory file only), each done only if the file still holds `was` (null:
-- isn't there), so one changed on the computer since is not written over.
-- The app takes its row away once answered.

create table public.agent_context_asks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  worker_id uuid not null references public.workers (id) on delete cascade,
  kind text not null check (kind in ('read', 'write', 'remove')),
  sources jsonb not null default '[]',
  path text,
  body text,
  was text,
  files jsonb,
  error text,
  done_at timestamptz,
  created_at timestamptz not null default now()
);

create index agent_context_asks_by_worker on public.agent_context_asks (worker_id, created_at);

alter table public.agent_context_asks enable row level security;

create policy "own context asks" on public.agent_context_asks for all to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.workers w
                where w.id = worker_id and w.user_id = (select auth.uid()))
  );

grant select, insert, update, delete on public.agent_context_asks to authenticated;

alter publication supabase_realtime add table public.agent_context_asks;
