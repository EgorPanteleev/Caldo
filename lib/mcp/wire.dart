/// The words the app, the worker and the database share for a chat: its
/// states, the kinds of input the app leaves it, and the kinds of item its
/// transcript is made of.
///
/// They are written as strings in the app (`services/agents.dart`), the
/// worker (`worker.dart`, `talk.dart`, `chat_tools.dart`) and the check
/// constraints of `supabase/migrations`, and a word one of them used that
/// another did not know cost a day: `chat_items_kind_check` refused a kind
/// the worker began to post, and held back every later item of the chat.
/// Here they are written once more, as the list every one of the others is
/// checked against (`test/wire_test.dart`). A new word goes here, into a
/// migration's constraint, and then into the code that uses it.
library;

abstract final class Wire {
  /// `chats.state`, from asked for to ended.
  static const chatStates = {
    'new',
    'waiting',
    'running',
    'asking',
    'idle',
    'finished',
    'your_turn',
    'limited',
    'ended',
    'failed',
  };

  /// `chat_in.kind`: what the app leaves for a chat's worker.
  static const inputKinds = {
    'keys',
    'line',
    'size',
    'stop',
    'start',
    'answer',
    'interrupt',
    'mode',
    'settings',
    'clear',
    'picture',
  };

  /// `chat_items.kind`: what a chat's transcript is made of.
  static const itemKinds = {'user', 'text', 'thinking', 'tool', 'ask', 'note'};
}
