-- The app's language when a chat was made (`en`, `ru`, …): the worker
-- titles the chat from its first message in it, rather than in whatever
-- language the message happens to be written in. Null, for a chat made
-- before this or by the watcher, keeps the message's.

alter table public.chats add column if not exists language text;
