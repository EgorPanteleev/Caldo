-- A rule may say how a chat begins: words said as its first message when
-- the new chat's form is left without one, so a chat whose rules already
-- hold the whole errand (a reviewer's rounds) starts working on its own
-- instead of waiting to be told "go".
--
-- Read by the app alone, which puts it in the chat's `prompt` as it is
-- made; the worker sees an ordinary first message.

alter table public.agent_rules add column opening text not null default '';
