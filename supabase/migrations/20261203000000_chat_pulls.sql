-- Which chat opened which pull request: noted by the chat's worker when it
-- sees a `gh pr create` go by with GitHub's link in its output, so a chat
-- told of a pull request (a reviewer, by subscription) can talk to the
-- chat it came from. Asked for (2026-11-24) in place of each description
-- naming its chat: the repository is public, and so is a description.
--
-- One row a pull request: the first chat to show it keeps it (a second
-- `gh pr create` on the branch prints the same link). Read by the worker
-- for subscription events and by the MCP tool `pull_chat`.
create table public.chat_pulls (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  repo text not null check (repo ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'),
  number int not null check (number > 0),
  chat_id uuid not null references public.chats (id) on delete cascade,
  url text,
  created_at timestamptz not null default now(),
  primary key (user_id, repo, number)
);

create index chat_pulls_by_chat on public.chat_pulls (chat_id);

alter table public.chat_pulls enable row level security;

create policy "own pull requests" on public.chat_pulls for all to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.chats c
                where c.id = chat_id and c.user_id = (select auth.uid()))
  );

grant select, insert, update, delete on public.chat_pulls to authenticated;
