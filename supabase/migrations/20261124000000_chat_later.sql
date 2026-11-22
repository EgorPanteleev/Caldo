-- Messages written now to be said to a chat later: by the clock, so they
-- go while the phone is away. Kept apart from chat_in, which a worker
-- empties as it reads — one from before this would have said them at once,
-- or dropped them; it leaves this table alone, and the app offers it only
-- to a worker that says it reads it (an agent's `later`).
--
-- The worker deletes a row as it says it, so a row still here has not
-- been said; putting it away from the app is taking it back.
create table public.chat_later (
  id bigint generated always as identity primary key,
  chat_id uuid not null references public.chats (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  data text not null,
  send_at timestamptz not null,
  -- Said with this key, as typed input is: the chat's item is `u<key>`.
  key text not null,
  created_at timestamptz not null default now()
);

create index chat_later_by_chat on public.chat_later (chat_id, send_at);

alter table public.chat_later enable row level security;

create policy "own later" on public.chat_later for all to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.chats c
                where c.id = chat_id and c.user_id = (select auth.uid()))
  );

grant select, insert, update, delete on public.chat_later to authenticated;

alter publication supabase_realtime add table public.chat_later;
