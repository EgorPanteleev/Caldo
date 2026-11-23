-- A message one chat's agent sends another (Caldo's MCP tool
-- `message_chat`): a `line` like the app's, saying who it is from —
-- {chat, title, waits}: the chat sending it (null for an assistant outside
-- Caldo's chats), its title then, and whether its agent waits on the
-- answer. The worker tells the agent so, and keeps it on the user item for
-- the app to draw. RLS is `chat_in`'s own: both chats are the account's.
alter table public.chat_in add column sender jsonb;
