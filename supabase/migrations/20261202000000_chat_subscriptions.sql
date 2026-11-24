-- What a chat is subscribed to: things outside Caldo its worker watches,
-- telling the chat when one happens, as a message (`chat_in`'s `sender`
-- says it is an event, not the user). Asked as "every new PR, reviewer
-- get an message" — so a reviewing chat need not look every ten minutes,
-- spending a turn each time to find nothing.
--
-- For now one source: `github_pulls`, a repository's pull requests, which
-- the chat's worker reads with `gh` once a minute. `target` is the
-- repository ("owner/name"); null, the one of the chat's folder, which the
-- worker writes in once it has found it.
--
-- `seen` and `error` are the worker's: what it has told the chat of, and
-- why it could not look last time. A pull request opened before the row
-- was made is never told.
create table public.chat_subscriptions (
  id bigint generated always as identity primary key,
  chat_id uuid not null references public.chats (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  source text not null default 'github_pulls' check (source in ('github_pulls')),
  target text check (target ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'),
  -- Which happenings are told: opened (or out of draft, or reopened),
  -- pushed (new commits on an open one), closed (merged or not).
  events text[] not null default '{opened}'
    check (events <@ array['opened', 'pushed', 'closed']::text[]
           and cardinality(events) > 0),
  -- Words said after each event: what to do with it.
  note text,
  seen jsonb,
  error text,
  created_at timestamptz not null default now()
);

create index chat_subscriptions_by_chat on public.chat_subscriptions (chat_id);

alter table public.chat_subscriptions enable row level security;

create policy "own subscriptions" on public.chat_subscriptions for all to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.chats c
                where c.id = chat_id and c.user_id = (select auth.uid()))
  );

grant select, insert, update, delete on public.chat_subscriptions to authenticated;

alter publication supabase_realtime add table public.chat_subscriptions;
