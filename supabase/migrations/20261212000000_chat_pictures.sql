-- An agent's picture goes through its worker so it takes its place in the
-- chat history alongside streamed answers and tool calls.
alter table public.chat_in drop constraint chat_in_kind_check;
alter table public.chat_in add constraint chat_in_kind_check
  check (kind in ('keys', 'line', 'size', 'stop', 'start', 'answer',
                  'interrupt', 'mode', 'settings', 'clear', 'picture'));
