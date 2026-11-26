-- A chat's own context (asked for 2026-11-26: "every task must have
-- several types of context … parents context … project info context …
-- own context"): what the user writes for this chat alone, how to work
-- and what it is for. Its worker tells it after the project's info and
-- the context of the chats it is part of, read as they are at each start,
-- in place of the CLAUDE.md files and memory Claude no longer reads.

alter table public.chats
  add column context text not null default '';
