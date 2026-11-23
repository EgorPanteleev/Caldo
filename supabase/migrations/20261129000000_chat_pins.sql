-- A chat pinned to the top of the list (`Agents.pin`): when, so the last
-- pinned stands first; null if it is not. Not news for the list:
-- `chats_touch` stamps `updated_at` only for a change of state, note or
-- title, so pinning and letting go leave a chat's place among the rest.
alter table public.chats add column if not exists pinned_at timestamptz;
