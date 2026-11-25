-- When each item was first said, to write beside it. Stamped by the
-- server on insert and left alone by the worker's upserts, which never
-- name it, so an item said again (a tool's output come) keeps its time.
-- Items from before this have none: the default is set after the column
-- is made, or they would all read as now.
alter table public.chat_items add column at timestamptz;
alter table public.chat_items alter column at set default now();
