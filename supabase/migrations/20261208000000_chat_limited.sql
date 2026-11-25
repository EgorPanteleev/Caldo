-- A chat whose turn the account's usage limit refused is `limited`, apart
-- from `finished`: the app says so, with when the limit resets, and the
-- worker takes a message in it as in any ready state.
alter table public.chats drop constraint if exists chats_state_check;
alter table public.chats add constraint chats_state_check
  check (state in ('new', 'waiting', 'running', 'asking', 'idle', 'finished',
                   'your_turn', 'limited', 'ended', 'failed'));
