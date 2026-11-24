-- A chat whose turn has ended is `finished`, apart from `idle`, ready and
-- with nothing done yet: the list could not tell a chat that had just
-- answered from one that had not begun. Both wait for the user's word.
alter table public.chats drop constraint if exists chats_state_check;
alter table public.chats add constraint chats_state_check
  check (state in ('new', 'running', 'asking', 'idle', 'finished', 'ended', 'failed'));
