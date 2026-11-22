-- What a chat has spent and where it stands: its tokens, cost, turns and
-- time, how full its context is, and the account's limits as last heard
-- (`ChatUsage`, lib/mcp/usage.dart). Written by the worker when a turn
-- ends and now and then during a long one; an open chat hears each change
-- on its channel first.
--
-- Not news for the list of chats: `chats_touch` stamps `updated_at` only
-- for a change of state, note or title.

alter table public.chats add column if not exists usage jsonb;
