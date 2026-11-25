-- A turn ended with the agent asking or offering the user something:
-- `your_turn`, shown as waiting for the user rather than finished.
alter table public.chats drop constraint if exists chats_state_check;
alter table public.chats add constraint chats_state_check
  check (state in ('new', 'waiting', 'running', 'asking', 'idle', 'finished',
                   'your_turn', 'ended', 'failed'));
