-- Two contexts each for a project and a chat (asked 2026-11-27: "the
-- second context for project and task: one where agents writing, second
-- where im writing my own instructions"). The ones agents keep are there
-- already: a project's info (`agent_projects.context`, its file, history
-- and update_project_info), and now a chat's notes, which its agent keeps
-- with update_chat_notes for itself after a restart or /clear. The ones the
-- user writes: a chat's own context (`chats.context`, now called its
-- instructions) and, new here, a project's instructions, which agents are
-- told and never change — nothing of theirs writes it, and it has no
-- history, as only the user changes it.

alter table public.agent_projects
  add column instructions text not null default '';

alter table public.chats
  add column notes text not null default '';
