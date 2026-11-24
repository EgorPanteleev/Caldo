-- A chat's context cleared, as Claude's /clear does: its worker puts its
-- program by once the turn under way ends and forgets its session, so the
-- next message starts afresh. Asked from the app, or by the chat's own
-- agent through Caldo's MCP server (`clear_context`).
alter table public.chat_in drop constraint chat_in_kind_check;
alter table public.chat_in add constraint chat_in_kind_check
  check (kind in ('keys', 'line', 'size', 'stop', 'start', 'answer',
                  'interrupt', 'mode', 'settings', 'clear'));
