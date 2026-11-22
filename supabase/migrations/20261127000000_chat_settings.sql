-- A chat's settings changed in the app: the row is updated, and this
-- tells its worker to start its program again with them, carrying on its
-- session.
alter table public.chat_in drop constraint chat_in_kind_check;
alter table public.chat_in add constraint chat_in_kind_check
  check (kind in ('keys', 'line', 'size', 'stop', 'start', 'answer',
                  'interrupt', 'mode', 'settings'));
