-- A task sent to an agent to start when it is due: its chat is made at
-- once, `waiting`, with everything chosen for it, and its worker starts it
-- once the task's day or time comes. `preface` is what was said on the
-- form before the task, kept apart so the first message is written from
-- the task as it is by then, not as it was when sent.
alter table public.chats drop constraint if exists chats_state_check;
alter table public.chats add constraint chats_state_check
  check (state in ('new', 'waiting', 'running', 'asking', 'idle', 'finished',
                   'ended', 'failed'));
alter table public.chats add column preface text;
