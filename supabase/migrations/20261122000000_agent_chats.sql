-- Chats spoken to in messages: Claude (`stream-json`) and Codex (its app
-- server) say what they do as items — a message, a tool and its output, a
-- question of permission — and the app draws them as a chat, which
-- scrolls, reads at a phone's width, and is sooner than a terminal: an
-- item is a few hundred bytes, not a screen redrawn five times a second.
--
-- A chat is in its chat or its terminal (`mode`), one program at a time
-- holding its session; the app moves it between the two.

alter table public.chats
  add column mode text not null default 'terminal'
    check (mode in ('chat', 'terminal'));

-- What the agent has said, in order. An item is written again whole as it
-- changes (a tool's output come, a question answered), so it is a row by
-- its own id, not a piece appended.
create table public.chat_items (
  chat_id uuid not null references public.chats (id) on delete cascade,
  -- The agent's own id for it: a message's block, a tool call, a request.
  id text not null,
  seq integer not null,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null
    check (kind in ('user', 'text', 'thinking', 'tool', 'ask', 'note')),
  body jsonb not null default '{}',
  primary key (chat_id, id)
);

create index chat_items_in_order on public.chat_items (chat_id, seq);

alter table public.chat_items enable row level security;

create policy "own items" on public.chat_items for all to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.chats c
                where c.id = chat_id and c.user_id = (select auth.uid()))
  );

grant select, insert, update, delete on public.chat_items to authenticated;

alter publication supabase_realtime add table public.chat_items;

-- New kinds of input: an answer to a question ("<choice> <item>"), a turn
-- interrupted, a move between chat and terminal. Input to a chat is also
-- broadcast on its channel, which the worker hears in a few milliseconds
-- where a row takes a quarter of a second; the key it is sent with in
-- both says it has been taken already.
alter table public.chat_in add column key text;
alter table public.chat_in drop constraint chat_in_kind_check;
alter table public.chat_in add constraint chat_in_kind_check
  check (kind in ('keys', 'line', 'size', 'stop', 'start', 'answer',
                  'interrupt', 'mode'));

-- What a chat says and is told goes first as broadcasts on its private
-- channel, `chat:<id>` — the answer's words as they are written, each item,
-- its state, the app's input — heard and sent only by the account whose
-- chat it is.
create policy "own chat channels" on realtime.messages for all to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and exists (select 1 from public.chats c
                where 'chat:' || c.id::text = (select realtime.topic())
                  and c.user_id = (select auth.uid()))
  )
  with check (
    realtime.messages.extension = 'broadcast'
    and exists (select 1 from public.chats c
                where 'chat:' || c.id::text = (select realtime.topic())
                  and c.user_id = (select auth.uid()))
  );
