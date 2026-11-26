-- A project's info is written by each worker into the project's folders,
-- for Claude and Codex run there outside Caldo (ProjectFiles): heard by
-- realtime, so a change made on the phone is in the files within seconds.

alter publication supabase_realtime add table public.agent_projects;
