import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../models/special_day.dart';
import '../models/task.dart';
import '../utils/dates.dart';
import '../utils/platform.dart';
import 'words_be.dart';
import 'words_de.dart';
import 'words_en.dart';
import 'words_es.dart';
import 'words_fr.dart';
import 'words_it.dart';
import 'words_kk.dart';
import 'words_nl.dart';
import 'words_pl.dart';
import 'words_ru.dart';
import 'words_tr.dart';
import 'words_uk.dart';

/// How a language counts: which form a noun takes after [n].
enum _Form { one, few, many }

/// One form for one, one for everything else: English, German, Spanish,
/// Italian, Dutch.
_Form _germanic(int n) => n == 1 ? _Form.one : _Form.many;

/// French counts nought as one: "0 jour", "1 jour", "2 jours".
_Form _french(int n) => n < 2 ? _Form.one : _Form.many;

/// Russian, Ukrainian and Belarusian: 1 день, 2 дня, 5 дней — and 21 день,
/// 22 дня, 11 дней.
_Form _eastSlavic(int n) {
  final tens = n % 100;
  final units = n % 10;
  if (units == 1 && tens != 11) return _Form.one;
  if (units >= 2 && units <= 4 && (tens < 12 || tens > 14)) return _Form.few;
  return _Form.many;
}

/// Polish: 1 dzień, 2 dni, 5 dni — like the East Slavic languages, except
/// that only one itself is singular: 21 dni.
_Form _polish(int n) {
  if (n == 1) return _Form.one;
  final tens = n % 100;
  final units = n % 10;
  if (units >= 2 && units <= 4 && (tens < 12 || tens > 14)) return _Form.few;
  return _Form.many;
}

/// Turkish and Kazakh: a noun after a number stays singular — "3 gün".
_Form _none(int n) => _Form.many;

/// Every word the app says, in the language of each country it keeps
/// holidays for.
///
/// One class over a table of words per language (`words_*.dart`) rather than
/// a class per language, or ARB files and a generator: twelve languages of a
/// couple of hundred strings each are data, and data is easiest kept as
/// data. A word missing from a table falls back to the English one, so a
/// new string shows up in English everywhere until it is translated, rather
/// than breaking the build.
///
/// Read through [of] on a screen, so a change of language redraws whatever
/// said anything, and through [current] where there is none — a
/// notification, the widget's copy, an isolate answering a reminder's button.
///
/// A counted word is a list of forms in its table — one, few, many — of
/// which a language gives as many as it has: English two, Russian three,
/// Turkish one.
class S {
  /// The language's code, as `Locale` and `intl` know it.
  final String code;
  final Map<String, Object> _words;
  final _Form Function(int) _form;

  const S._(this.code, this._words, this._form);

  static const _all = {
    'en': S._('en', en, _germanic),
    'be': S._('be', be, _eastSlavic),
    'de': S._('de', de, _germanic),
    'es': S._('es', es, _germanic),
    'fr': S._('fr', fr, _french),
    'it': S._('it', it, _germanic),
    'kk': S._('kk', kk, _none),
    'nl': S._('nl', nl, _germanic),
    'pl': S._('pl', pl, _polish),
    'ru': S._('ru', ru, _eastSlavic),
    'tr': S._('tr', tr, _none),
    'uk': S._('uk', uk, _eastSlavic),
  };

  static final supported = [for (final code in _all.keys) Locale(code)];

  /// Each language named in itself, for choosing between them: whichever
  /// is on screen, the way back to one's own can be read.
  static Map<String, String> get names => {
    for (final s in _all.values) s.code: s._word('languageName'),
  };

  /// The language in force, for what has no screen to ask.
  static S current = _all['en']!;

  static S of(BuildContext context) =>
      Localizations.of<S>(context, S) ?? current;

  static S forCode(String? code) => _all[code] ?? _all['en']!;

  static bool supports(String code) => _all.containsKey(code);

  /// Makes [code]'s language the one in force, here and in `intl`, which
  /// writes the dates.
  static void use(String code) {
    current = forCode(code);
    Intl.defaultLocale = current.code;
  }

  static const LocalizationsDelegate<S> delegate = _Delegate();

  /// Whether this language's own table has [key], rather than falling back
  /// to English. For the test that keeps the tables complete.
  @visibleForTesting
  bool hasOwn(String key) => _words.containsKey(key);

  /// What the table holds for [key], blanks unfilled.
  @visibleForTesting
  Object raw(String key) => _words[key] ?? en[key]!;

  /// A handful of phrases name the phone — where everything is kept, what
  /// the language follows — and are worded again for a desktop, under a
  /// key of their own (`...Desktop`, `followSystem`); the getters choose.
  String _word(String key) => (_words[key] ?? en[key]) as String;

  String _fill(String key, Map<String, Object> args) {
    var text = _word(key);
    args.forEach((name, value) => text = text.replaceAll('{$name}', '$value'));
    return text;
  }

  String _count(String key, int n, [Map<String, Object> args = const {}]) {
    final forms = (_words[key] ?? en[key]) as List<String>;
    final index = switch (_form(n)) {
      _Form.one => 0,
      _Form.few => 1,
      _Form.many => 2,
    };
    var text = forms[index < forms.length ? index : forms.length - 1];
    text = text.replaceAll('{n}', '$n');
    args.forEach((name, value) => text = text.replaceAll('{$name}', '$value'));
    return text;
  }

  // ---- The screens and the menu --------------------------------------------
  String get schedule => _word('schedule');
  String get calendar => _word('calendar');
  String get done => _word('done');
  String get board => _word('board');
  String get notStarted => _word('notStarted');
  String get inProgress => _word('inProgress');
  String get settings => _word('settings');
  String get tasks => _word('tasks');
  String get search => _word('search');

  // ---- Days ----------------------------------------------------------------
  String get today => _word('today');
  String get tomorrow => _word('tomorrow');
  String get yesterday => _word('yesterday');

  /// "tomorrow" in the middle of a sentence.
  String get tomorrowInline => _word('tomorrowInline');
  String get yesterdayInline => _word('yesterdayInline');
  String get overdue => _word('overdue');
  String get noDate => _word('noDate');
  String get allDay => _word('allDay');

  // ---- Common actions ------------------------------------------------------
  String get cancel => _word('cancel');
  String get save => _word('save');
  String get clear => _word('clear');
  String get delete => _word('delete');
  String get remove => _word('remove');
  String get undo => _word('undo');

  // ---- The update banner ---------------------------------------------------
  String updateOut(String version) => _fill('updateOut', {'version': version});
  String downloading(int percent) => _fill('downloading', {'percent': percent});
  String get updateReady => _word('updateReady');
  String get updateImportantLine => _word('updateImportantLine');
  String get updateRequired => _word('updateRequired');
  String get updateImportant => _word('updateImportant');
  String get whatsNew => _word('whatsNew');
  String get later => _word('later');
  String get allowInstall => _word('allowInstall');

  /// The notification an update leaves behind: Android stops Caldo to
  /// replace it and will not let it open itself again afterwards.
  String updateInstalled(String version) =>
      _fill('updateInstalled', {'version': version});
  String get tapToOpen => _word('tapToOpen');
  String get updatesChannel => _word('updatesChannel');
  String get downloadFailed => _word('downloadFailed');
  String get update => _word('update');
  String get notNow => _word('notNow');

  // ---- Schedule and the calendar -------------------------------------------
  String get nothingScheduled => _word('nothingScheduled');
  String get nothingScheduledHint => _word('nothingScheduledHint');
  String shownForNext(int days) => _count('shownForNext', days);
  String get expandMonth => _word('expandMonth');
  String get collapseMonth => _word('collapseMonth');
  String get nothingOnDay => _word('nothingOnDay');
  String get addOneBelow => _word('addOneBelow');
  String get addWithForm => _word('addWithForm');
  String openCount(int open) => _fill('openCount', {'n': open});
  String get allClear => _word('allClear');
  String moreCount(int hidden) => _fill('moreCount', {'n': hidden});
  String get publicHoliday => _word('publicHoliday');

  // ---- Special days --------------------------------------------------------
  String get specialDays => _word('specialDays');
  String specialDaysCount(int n) => _count('specialDaysCount', n);
  String get noneYet => _word('noneYet');
  String get specialDaysNote => _word('specialDaysNote');
  String get addSpecialDay => _word('addSpecialDay');
  String get newSpecialDay => _word('newSpecialDay');
  String get editSpecialDay => _word('editSpecialDay');
  String get specialName => _word('specialName');
  String get kindBirthday => _word('kindBirthday');
  String get kindAnniversary => _word('kindAnniversary');
  String get kindOther => _word('kindOther');
  String get specialDay => _word('specialDay');
  String turnsAge(int n) => _count('turnsAge', n);
  String yearsOn(int n) => _count('yearsOn', n);
  String get remindOnTheDay => _word('remindOnTheDay');

  /// What a special day's card says under its name: what it is, and how
  /// many years it has been when that is known — "Birthday · Turns 30".
  String specialLine(SpecialKind kind, int? years) {
    final what = switch (kind) {
      SpecialKind.birthday => kindBirthday,
      SpecialKind.anniversary => kindAnniversary,
      SpecialKind.other => specialDay,
    };
    if (years == null) return what;
    return '$what · ${kind == SpecialKind.birthday ? turnsAge(years) : yearsOn(years)}';
  }

  /// "Delete "{name}"?", which is worded for nothing in particular.
  String deleteQuestion(String name) =>
      _fill('deleteGroupQuestion', {'name': name});
  String eventFrom(String time) => _fill('eventFrom', {'time': time});
  String eventUntil(String time) => _fill('eventUntil', {'time': time});
  String addTaskOn(String date) => _fill('addTaskOn', {'date': date});
  String get addTask => _word('addTask');
  String get newTask => _word('newTask');

  // ---- Done ----------------------------------------------------------------
  String get nothingDoneYet => _word('nothingDoneYet');
  String get doneHint => _word('doneHint');
  String get figureToday => _word('figureToday');
  String get figureWeek => _word('figureWeek');
  String daysInARow(int days) => _count('daysInARow', days);

  // ---- Agents --------------------------------------------------------------
  String get agents => _word('agents');
  String get newChat => _word('newChat');
  String get agentsSignIn => _word('agentsSignIn');
  String get agentsSignInHint => _word('agentsSignInHint');
  String get agentsNoWorker => _word('agentsNoWorker');
  String get agentsNoWorkerHint => _word('agentsNoWorkerHint');
  String get noChats => _word('noChats');
  String get noChatsHint => _word('noChatsHint');
  String get chatWorker => _word('chatWorker');
  String get chatAgent => _word('chatAgent');
  String get chatModel => _word('chatModel');
  String get chatEffort => _word('chatEffort');
  String get chatFolder => _word('chatFolder');
  String get agentProjects => _word('agentProjects');
  String get newProject => _word('newProject');
  String get newSubproject => _word('newSubproject');
  String get editProject => _word('editProject');
  String get editProjects => _word('editProjects');
  String get noProjects => _word('noProjects');
  String get noProjectsHint => _word('noProjectsHint');
  String get projectName => _word('projectName');
  String get projectColour => _word('projectColour');
  String get projectContext => _word('projectContext');
  String get projectContextHint => _word('projectContextHint');
  String get projectSources => _word('projectSources');
  String get projectSourcesHint => _word('projectSourcesHint');
  String get projectAddSource => _word('projectAddSource');
  String get projectSubprojects => _word('projectSubprojects');
  String get deleteProjectQuestion => _word('deleteProjectQuestion');
  String get deleteProjectHint => _word('deleteProjectHint');
  String get chatProject => _word('chatProject');
  String get chatNoProject => _word('chatNoProject');
  String get chatOwnFolderHint => _word('chatOwnFolderHint');
  String get allProjects => _word('allProjects');
  String get untitledProject => _word('untitledProject');
  String projectFrom(String name) => _fill('projectFrom', {'name': name});
  String get chatPermission => _word('chatPermission');
  String get chatPlugins => _word('chatPlugins');
  String get chatSkills => _word('chatSkills');
  String get agentRules => _word('agentRules');
  String get editRules => _word('editRules');
  String get newRule => _word('newRule');
  String get editRule => _word('editRule');
  String get noRules => _word('noRules');
  String get noRulesHint => _word('noRulesHint');
  String get untitledRule => _word('untitledRule');
  String get ruleName => _word('ruleName');
  String get ruleBody => _word('ruleBody');
  String get ruleBodyHint => _word('ruleBodyHint');
  String get ruleOpening => _word('ruleOpening');
  String get ruleOpeningHint => _word('ruleOpeningHint');
  String get deleteRuleQuestion => _word('deleteRuleQuestion');
  String get deleteRuleHint => _word('deleteRuleHint');
  String get chatTitle => _word('chatTitle');
  String get chatPrompt => _word('chatPrompt');
  String get chatStart => _word('chatStart');
  String get sendToAgents => _word('sendToAgents');
  String get chatForEach => _word('chatForEach');
  String get chatForEachHint => _word('chatForEachHint');
  String chatStartEach(int n) => _count('chatStartEach', n);
  String chatsStarted(int n) => _count('chatsStarted', n);
  String get chatDefault => _word('chatDefault');
  String get chatOffline => _word('chatOffline');
  String get chatOther => _word('chatOther');
  String get chatMessage => _word('chatMessage');
  String get chatStop => _word('chatStop');
  String get chatAgain => _word('chatAgain');
  String get chatStarts => _word('chatStarts');
  String get chatStartsNow => _word('chatStartsNow');
  String get chatStartsWhenDue => _word('chatStartsWhenDue');
  String get chatStartsWhenDueHint => _word('chatStartsWhenDueHint');
  String get chatStartsByHand => _word('chatStartsByHand');
  String get chatStartsByHandHint => _word('chatStartsByHandHint');
  String get chatHeld => _word('chatHeld');
  String get chatCreate => _word('chatCreate');
  String get chatWaiting => _word('chatWaiting');
  String get chatStartNow => _word('chatStartNow');
  String get agentWaiting => _word('agentWaiting');
  String get agentWorking => _word('agentWorking');
  String get agentAsking => _word('agentAsking');
  String get agentReview => _word('agentReview');
  String get agentFailed => _word('agentFailed');
  String get sendToAgent => _word('sendToAgent');
  String get swipeAgent => _word('swipeAgent');
  String get agentLabel => _word('agentLabel');
  String get agentNotSent => _word('agentNotSent');
  String get chatClear => _word('chatClear');
  String get chatDelete => _word('chatDelete');
  String get deleteChatQuestion => _word('deleteChatQuestion');
  String deleteChatsQuestion(int n) => _count('deleteChatsQuestion', n);
  String get chatPin => _word('chatPin');
  String get chatUnpin => _word('chatUnpin');
  String get chatPinned => _word('chatPinned');
  String get chatMute => _word('chatMute');
  String get chatUnmute => _word('chatUnmute');
  String get chatMuted => _word('chatMuted');
  String get agentsChannel => _word('agentsChannel');
  String get agentsChannelHint => _word('agentsChannelHint');
  String get chatSelectAll => _word('chatSelectAll');
  String get chatAsked => _word('chatAsked');
  String get chatRunning => _word('chatRunning');
  String get chatAsking => _word('chatAsking');
  String get chatIdle => _word('chatIdle');
  String get chatFinished => _word('chatFinished');
  String get chatEnded => _word('chatEnded');
  String get chatFailed => _word('chatFailed');
  String get chatBigger => _word('chatBigger');
  String get chatSmaller => _word('chatSmaller');
  String get chatFromTask => _word('chatFromTask');
  String get chatOpen => _word('chatOpen');
  String chatAttach(String name) => _fill('chatAttach', {'name': name});
  String get chatAsChat => _word('chatAsChat');
  String get chatAsTerminal => _word('chatAsTerminal');
  String get chatAllow => _word('chatAllow');
  String get chatAlways => _word('chatAlways');
  String get chatDeny => _word('chatDeny');
  String get chatAllowed => _word('chatAllowed');
  String get chatAlwaysAllowed => _word('chatAlwaysAllowed');
  String get chatDenied => _word('chatDenied');
  String get chatAnswer => _word('chatAnswer');
  String get chatSkip => _word('chatSkip');
  String get chatOtherHint => _word('chatOtherHint');
  String get chatNotAnswered => _word('chatNotAnswered');
  String get chatPickAny => _word('chatPickAny');
  String get chatThinking => _word('chatThinking');
  String get chatWorking => _word('chatWorking');

  /// Over a message another chat's agent sent: [name] is that chat's title.
  String chatFrom(String name) => _fill('chatFrom', {'name': name});
  String get chatFromOutside => _word('chatFromOutside');

  /// Over a message telling of events a chat is subscribed to: [name] is
  /// the repository.
  String chatFromEvent(String name) => _fill('chatFromEvent', {'name': name});
  String get chatSubscriptions => _word('chatSubscriptions');
  String get chatSubscribe => _word('chatSubscribe');
  String get chatSubscription => _word('chatSubscription');
  String get chatSubRepo => _word('chatSubRepo');
  String get chatSubRepoHint => _word('chatSubRepoHint');
  String get chatSubThisRepo => _word('chatSubThisRepo');
  String get chatSubWhen => _word('chatSubWhen');
  String get chatSubOpened => _word('chatSubOpened');
  String get chatSubPushed => _word('chatSubPushed');
  String get chatSubClosed => _word('chatSubClosed');
  String get chatSubNote => _word('chatSubNote');
  String get chatSubNoteHint => _word('chatSubNoteHint');
  String chatSubHint(String worker) => _fill('chatSubHint', {'worker': worker});
  String get chatSubBadRepo => _word('chatSubBadRepo');
  String get chatInterrupt => _word('chatInterrupt');
  String get chatLater => _word('chatLater');
  String get chatLater30 => _word('chatLater30');
  String get chatAttachFiles => _word('chatAttachFiles');
  String chatFileTooBig(String name) => _fill('chatFileTooBig', {'name': name});
  String get chatFilesFailed => _word('chatFilesFailed');
  String get chatLater60 => _word('chatLater60');
  String get chatLater180 => _word('chatLater180');
  String chatLaterTomorrow(String time) =>
      _fill('chatLaterTomorrow', {'time': time});
  String get chatLaterPick => _word('chatLaterPick');
  String get chatAtLimit => _word('chatAtLimit');
  String chatCarryOnAt(String time) => _fill('chatCarryOnAt', {'time': time});
  String get chatCarryOnSoon => _word('chatCarryOnSoon');
  String get chatSendNow => _word('chatSendNow');
  String get chatLaterEdit => _word('chatLaterEdit');
  String get chatToTerminal => _word('chatToTerminal');
  String get chatToChat => _word('chatToChat');
  String get chatInTerminalNow => _word('chatInTerminalNow');
  String chatInChatNow(String agent) =>
      _fill('chatInChatNow', {'agent': agent});
  String get chatEmpty => _word('chatEmpty');
  String get chatMoveStops => _word('chatMoveStops');
  String get chatSettings => _word('chatSettings');
  String chatSettingsHint(String agent) =>
      _fill('chatSettingsHint', {'agent': agent});
  String chatSettingsOld(String name) =>
      _fill('chatSettingsOld', {'name': name});
  String get usageTitle => _word('usageTitle');
  String get usageContext => _word('usageContext');
  String usageContextShort(String share) =>
      _fill('usageContextShort', {'n': share});
  String usageTokensOnly(String n) => _fill('usageTokensOnly', {'n': n});
  String usageOf(String used, String window) =>
      _fill('usageOf', {'used': used, 'window': window});
  String get usageLimits => _word('usageLimits');
  String usageResets(String when) => _fill('usageResets', {'when': when});
  String get usageLimitReached => _word('usageLimitReached');
  String get usageLimitNear => _word('usageLimitNear');
  String get usageThisChat => _word('usageThisChat');
  String usageTurns(int n) => _fill('usageTurns', {'n': n});
  String get usageTurnsName => _word('usageTurnsName');
  String get usageWorking => _word('usageWorking');
  String get usageInput => _word('usageInput');
  String get usageOutput => _word('usageOutput');
  String get usageCacheRead => _word('usageCacheRead');
  String get usageCacheWrite => _word('usageCacheWrite');
  String get usageCost => _word('usageCost');
  String usageAsOf(String when) => _fill('usageAsOf', {'when': when});
  String usageSeconds(int n) => _fill('usageSeconds', {'n': n});
  String usageMinutes(int n) => _fill('usageMinutes', {'n': n});
  String usageHours(int h, int m) => _fill('usageHours', {'h': h, 'm': m});
  String get usageFiveHours => _word('usageFiveHours');
  String get usageWeekly => _word('usageWeekly');
  String usageDays(int n) => _fill('usageDays', {'n': n});
  String usageHoursLimit(int n) => _fill('usageHoursLimit', {'n': n});
  String get usageWeekShort => _word('usageWeekShort');

  // ---- Agent accounts ------------------------------------------------------
  String get agentAccounts => _word('agentAccounts');
  String get addAccount => _word('addAccount');
  String get accountsNone => _word('accountsNone');
  String get accountsNoneHint => _word('accountsNoneHint');
  String get accountsReinstall => _word('accountsReinstall');
  String get accountOwn => _word('accountOwn');
  String get accountStarting => _word('accountStarting');
  String get accountSigningIn => _word('accountSigningIn');
  String get accountReady => _word('accountReady');
  String get accountSignedOut => _word('accountSignedOut');
  String get accountFailed => _word('accountFailed');
  String get accountSignIn => _word('accountSignIn');
  String get accountSignInAgain => _word('accountSignInAgain');
  String get accountRename => _word('accountRename');
  String accountRemoveQuestion(String name) =>
      _fill('accountRemoveQuestion', {'name': name});
  String accountRemoveHint(String worker) =>
      _fill('accountRemoveHint', {'worker': worker});
  String get accountNoLimits => _word('accountNoLimits');
  String get accountWaitingPage => _word('accountWaitingPage');
  String get accountWaitingCodex => _word('accountWaitingCodex');
  String get accountClaudeSteps => _word('accountClaudeSteps');
  String get accountCodexSteps => _word('accountCodexSteps');
  String get accountOpenPage => _word('accountOpenPage');
  String get accountCopyLink => _word('accountCopyLink');
  String get accountLinkCopied => _word('accountLinkCopied');
  String get accountCode => _word('accountCode');
  String get accountSend => _word('accountSend');
  String get accountName => _word('accountName');
  String get accountNameHint => _word('accountNameHint');
  String accountAddHint(String worker) =>
      _fill('accountAddHint', {'worker': worker});
  String get chatAccount => _word('chatAccount');
  String get usageResetSince => _word('usageResetSince');

  // ---- The vault -----------------------------------------------------------
  String get vault => _word('vault');
  String get vaultLooking => _word('vaultLooking');
  String get vaultSetUpTitle => _word('vaultSetUpTitle');
  String get vaultSetUpNote => _word('vaultSetUpNote');
  String get vaultMasterPassword => _word('vaultMasterPassword');
  String get vaultRepeatPassword => _word('vaultRepeatPassword');
  String get vaultFingerSwitch => _word('vaultFingerSwitch');
  String get vaultFingerHint => _word('vaultFingerHint');
  String get vaultCreate => _word('vaultCreate');
  String vaultPasswordShort(int n) => _fill('vaultPasswordShort', {'n': n});
  String get vaultPasswordsDiffer => _word('vaultPasswordsDiffer');
  String get vaultLocked => _word('vaultLocked');
  String get vaultUnlockHint => _word('vaultUnlockHint');
  String get vaultUnlock => _word('vaultUnlock');
  String get vaultUseFinger => _word('vaultUseFinger');
  String get vaultWrongPassword => _word('vaultWrongPassword');
  String get vaultFingerGone => _word('vaultFingerGone');
  String get vaultFingerFailed => _word('vaultFingerFailed');
  String get vaultForgot => _word('vaultForgot');
  String get vaultForgotQuestion => _word('vaultForgotQuestion');
  String get vaultForgotWarning => _word('vaultForgotWarning');
  String get vaultDelete => _word('vaultDelete');
  String get vaultNew => _word('vaultNew');
  String get vaultSettings => _word('vaultSettings');
  String get vaultLock => _word('vaultLock');
  String get vaultEmpty => _word('vaultEmpty');
  String get vaultEmptyHint => _word('vaultEmptyHint');
  String get vaultSearch => _word('vaultSearch');
  String vaultSealedElsewhere(int n) => _count('vaultSealedElsewhere', n);
  String get vaultOtherPassword => _word('vaultOtherPassword');
  String get vaultOtherNote => _word('vaultOtherNote');
  String get vaultCopyPassword => _word('vaultCopyPassword');
  String get vaultCopy => _word('vaultCopy');
  String vaultCopied(int seconds) => _count('vaultCopied', seconds);
  String get vaultShow => _word('vaultShow');
  String get vaultHide => _word('vaultHide');
  String get vaultDeleteQuestion => _word('vaultDeleteQuestion');
  String get vaultName => _word('vaultName');
  String get vaultNameMissing => _word('vaultNameMissing');
  String get vaultLogin => _word('vaultLogin');
  String get vaultPassword => _word('vaultPassword');
  String get vaultWebsite => _word('vaultWebsite');
  String get vaultField => _word('vaultField');
  String get vaultFieldName => _word('vaultFieldName');
  String get vaultFieldValue => _word('vaultFieldValue');
  String get vaultAddField => _word('vaultAddField');
  String get vaultNotes => _word('vaultNotes');
  String get vaultEdit => _word('vaultEdit');
  String get vaultGenerate => _word('vaultGenerate');
  String vaultLength(int n) => _fill('vaultLength', {'n': n});
  String get vaultDigits => _word('vaultDigits');
  String get vaultSymbols => _word('vaultSymbols');
  String get vaultUse => _word('vaultUse');
  String get vaultLockAfter => _word('vaultLockAfter');
  String get vaultLockAtOnce => _word('vaultLockAtOnce');
  String vaultMinutes(int n) => _count('vaultMinutes', n);
  String get vaultChangePassword => _word('vaultChangePassword');
  String get vaultChangeNote => _word('vaultChangeNote');
  String get vaultCurrentPassword => _word('vaultCurrentPassword');
  String get vaultNewPassword => _word('vaultNewPassword');
  String get vaultPasswordChanged => _word('vaultPasswordChanged');

  /// Over Android's fingerprint prompt.
  String get vaultPromptTitle => _word('vaultPromptTitle');

  // ---- Search --------------------------------------------------------------
  String get searchField => _word('searchField');
  String get searchYourTasks => _word('searchYourTasks');
  String get searchHint => _word('searchHint');
  String get nothingFound => _word('nothingFound');
  String noTaskMentions(String query) =>
      _fill('noTaskMentions', {'query': query});

  // ---- Settings ------------------------------------------------------------
  String get pageScreens => _word('pageScreens');
  String get sectionShown => _word('sectionShown');
  String get shownHint => _word('shownHint');
  String get pageGeneral => _word('pageGeneral');
  String get startScreen => _word('startScreen');
  String get timesWritten => _word('timesWritten');
  String get language => _word('language');
  String followPhone(String language) =>
      _fill(onDesktop ? 'followSystem' : 'followPhone', {'language': language});
  String get pageAppearance => _word('pageAppearance');
  String get theme => _word('theme');
  String get themeDark => _word('themeDark');
  String get themeLight => _word('themeLight');
  String get themeSystem => _word('themeSystem');
  String get accent => _word('accent');
  String get weekStartsMonday => _word('weekStartsMonday');
  String get weeksMonSun => _word('weeksMonSun');
  String get weeksSunSat => _word('weeksSunSat');
  String get showHolidays => _word('showHolidays');
  String get holidaysOn => _word('holidaysOn');
  String get holidaysOff => _word('holidaysOff');
  String followDevice(String country) =>
      _fill('followDevice', {'country': country});
  String get followDeviceUnsupported => _word('followDeviceUnsupported');
  String get holidayCountry => _word('holidayCountry');

  /// A country's name, in this language when the table has it.
  String country(String code, String english) =>
      (_words['country.$code'] as String?) ?? english;
  String get showEvents => _word('showEvents');
  String get eventsOn => _word('eventsOn');
  String get eventsOff => _word('eventsOff');
  String get calendarsRefused => _word('calendarsRefused');
  String get noCalendars => _word('noCalendars');
  String get pageTasks => _word('pageTasks');
  String get completedShown => _word('completedShown');
  String get completedHidden => _word('completedHidden');
  String get showCompleted => _word('showCompleted');
  String get showCompletedHint => _word('showCompletedHint');
  String get clearCompleted => _word('clearCompleted');
  String get clearCompletedHint => _word('clearCompletedHint');
  String get clearCompletedQuestion => _word('clearCompletedQuestion');
  String get clearCompletedWarning => _word('clearCompletedWarning');
  String get nothingToClear => _word('nothingToClear');
  String removedCompleted(int count) => _count('removedCompleted', count);
  String get pageReminders => _word('pageReminders');
  String get remindWhenDue => _word('remindWhenDue');
  String get remindOn => _word('remindOn');
  String get remindOff => _word('remindOff');
  String get timedTasks => _word('timedTasks');
  String get allDayTasks => _word('allDayTasks');
  String get sectionAbout => _word('sectionAbout');
  String get about => _word('about');
  String get aboutSynced => _word('aboutSynced');
  String version(String version) => _fill('version', {'version': version});
  String get pageSync => _word('pageSync');
  String get syncOff => _word('syncOff');
  String get syncSignIn => _word('syncSignIn');
  String get syncSignInHint => _word('syncSignInHint');
  String get syncUnreachable => _word('syncUnreachable');
  String get syncName => _word('syncName');
  String get syncPassword => _word('syncPassword');
  String get syncJoin => _word('syncJoin');
  String get syncJoinHint => _word('syncJoinHint');
  String get syncJoinNote => _word('syncJoinNote');
  String get syncJoinAction => _word('syncJoinAction');
  String get syncInvite => _word('syncInvite');
  String get syncBadLogin => _word('syncBadLogin');
  String get syncBadInvite => _word('syncBadInvite');
  String get syncNameTaken => _word('syncNameTaken');
  String get syncBadName => _word('syncBadName');
  String syncShortPassword(int n) => _fill('syncShortPassword', {'n': n});
  String get syncMakeInvite => _word('syncMakeInvite');
  String get syncMakeInviteHint => _word('syncMakeInviteHint');
  String get syncInviteMade => _word('syncInviteMade');
  String get syncCopy => _word('syncCopy');
  String get syncCopied => _word('syncCopied');
  String get syncServer => _word('syncServer');
  String get syncServerNone => _word('syncServerNone');
  String get syncServerFirst => _word('syncServerFirst');
  String get syncNow => _word('syncNow');
  String syncLast(String time) => _fill('syncLast', {'time': time});
  String get syncNever => _word('syncNever');
  String get syncing => _word('syncing');
  String get syncFailed => _word('syncFailed');
  String get syncSignOut => _word('syncSignOut');
  String get syncSignOutHint => _word('syncSignOutHint');
  String get syncDelete => _word('syncDelete');
  String get syncDeleteQuestion => _word('syncDeleteQuestion');
  String get syncDeleteNote => _word('syncDeleteNote');
  String get syncNote => _word('syncNote');
  String get pageBackup => _word('pageBackup');
  String get backupNever => _word('backupNever');
  String backupLast(String day) => _fill('backupLast', {'day': day});
  String get backupSave => _word('backupSave');
  String get backupSaveHint => _word('backupSaveHint');
  String get backupRestore => _word('backupRestore');
  String get backupRestoreHint => _word('backupRestoreHint');
  String get backupNote =>
      _word(onDesktop ? 'backupNoteDesktop' : 'backupNote');
  String get backupSaved => _word('backupSaved');
  String get backupNotSaved => _word('backupNotSaved');
  String get backupAuto => _word('backupAuto');
  String get backupAutoOff => _word('backupAutoOff');
  String get backupDaily => _word('backupDaily');
  String get backupWeekly => _word('backupWeekly');
  String get backupFolder => _word('backupFolder');
  String get backupAutoFailed => _word('backupAutoFailed');
  String get backupAutoNote =>
      _word(onDesktop ? 'backupAutoNoteDesktop' : 'backupAutoNote');
  String get backupNotCaldo => _word('backupNotCaldo');
  String get backupNewer => _word('backupNewer');
  String get backupUnreadable => _word('backupUnreadable');
  String get restoreQuestion => _word('restoreQuestion');
  String restoreWarning({
    required String day,
    required int tasks,
    required int groups,
  }) => _fill('restoreWarning', {
    'day': day,
    'tasks': _count('backupTasks', tasks),
    'groups': _count('backupGroups', groups),
  });
  String get restore => _word('restore');
  String restored(int count) => _count('restored', count);

  // ---- The task form -------------------------------------------------------
  String get editTask => _word('editTask');
  String get taskField => _word('taskField');
  String get required => _word('required');
  String get notesField => _word('notesField');
  String get sectionSubtasks => _word('sectionSubtasks');
  String get addSubtask => _word('addSubtask');
  String get sectionAttachments => _word('sectionAttachments');
  String get attachPhoto => _word('attachPhoto');
  String get attachCamera => _word('attachCamera');
  String get attachFile => _word('attachFile');
  String get attachmentMissing =>
      _word(onDesktop ? 'attachmentMissingDesktop' : 'attachmentMissing');
  String get noAppOpens =>
      _word(onDesktop ? 'noAppOpensDesktop' : 'noAppOpens');
  String tooBigToAttach(String name) => _fill('tooBigToAttach', {'name': name});
  String get openInApp => _word('openInApp');
  String kilobytes(String n) => _fill('kilobytes', {'n': n});
  String megabytes(String n) => _fill('megabytes', {'n': n});
  String get allGroups => _word('allGroups');
  String get newGroup => _word('newGroup');
  String get editGroup => _word('editGroup');
  String get groupName => _word('groupName');
  String get sectionGroup => _word('sectionGroup');
  String get sectionGroups => _word('sectionGroups');
  String deleteGroupQuestion(String name) =>
      _fill('deleteGroupQuestion', {'name': name});
  String groupTasksMoveTo(String group) =>
      _fill('groupTasksMoveTo', {'group': group});
  String get personal => _word('personal');
  String get dueDate => _word('dueDate');
  String get time => _word('time');
  String get none => _word('none');
  String get endsAt => _word('endsAt');
  String get endBeforeStart => _word('endBeforeStart');
  String get dayAsList => _word('dayAsList');
  String get dayAsHours => _word('dayAsHours');
  String get putOffDay => _word('putOffDay');
  String get pickDay => _word('pickDay');
  String get repeatLabel => _word('repeatLabel');

  /// A rule written out: "Every day", "Every 2 weeks · Mon, Thu", "Every
  /// month · last day · until 31 Dec". Pieces after the first are joined
  /// with a dot rather than built into one sentence, which twelve
  /// languages' grammar would each want built differently.
  String repeatName(Repeat repeat) {
    if (repeat.isNone) return _word('repeat.none');
    final weekdaysOnly = setEquals(
      repeat.weekdays,
      Repeat.weekdaysOnly.weekdays,
    );
    final base = repeat.every > 1
        ? _count('repeatEvery.${repeat.unit.name}', repeat.every)
        : repeat.unit == RepeatUnit.week && weekdaysOnly
        ? _word('repeat.weekdays')
        : _word('repeat.${_plainKey[repeat.unit]}');
    final until = repeat.until;
    return [
      base,
      if (repeat.unit == RepeatUnit.week &&
          repeat.weekdays.isNotEmpty &&
          !(weekdaysOnly && repeat.every == 1))
        [
          for (final d in repeat.weekdays.toList()..sort()) weekdayShort(d),
        ].join(', '),
      if (repeat.unit == RepeatUnit.month && repeat.monthEnd)
        _word('repeatLastDay'),
      if (until != null) _fill('repeatUntil', {'date': Dates.shortDay(until)}),
      if (repeat.left case final left?) _count('repeatLeft', left),
    ].join(' · ');
  }

  static const _plainKey = {
    RepeatUnit.day: 'daily',
    RepeatUnit.week: 'weekly',
    RepeatUnit.month: 'monthly',
    RepeatUnit.year: 'yearly',
  };

  /// A weekday's short name, by `DateTime.weekday`: "Mon", "пн".
  String weekdayShort(int weekday) =>
      DateFormat.E().format(DateTime(2024, 1, weekday));

  String unitName(RepeatUnit unit) => _word('unit.${unit.name}');
  String get repeatEveryLabel => _word('repeatEveryLabel');
  String repeatOnDay(int day) => _fill('repeatOnDay', {'n': day});
  String get repeatOnLastDay => _word('repeatOnLastDay');
  String get repeatEnds => _word('repeatEnds');
  String get endsOn => _word('endsOn');
  String endsAfter(int n) => _count('endsAfter', n);
  String remindLead(String lead) => _fill('remindLead', {'lead': lead});
  String remindOnDayAt(String time) => _fill('remindOnDayAt', {'time': time});
  String get remindDayBefore => _word('remindDayBefore');
  String get reminderLabel => _word('reminderLabel');
  String get noReminder => _word('noReminder');
  String get claudeLabel => _word('claudeLabel');
  String get claudeNone => _word('claudeNone');
  String get sectionPriority => _word('sectionPriority');
  String priorityName(Priority priority) => _word('priority.${priority.name}');
  String get sectionColour => _word('sectionColour');
  String get customColour => _word('customColour');
  String get list => _word('list');
  String get deleteTaskQuestion => _word('deleteTaskQuestion');
  String willBeRemoved(String title) =>
      _fill('willBeRemoved', {'title': title});

  // ---- Several tasks at once -----------------------------------------------
  String selectedCount(int n) => _count('selectedCount', n);
  String get moveToDay => _word('moveToDay');
  String get moveToGroup => _word('moveToGroup');
  String get markDone => _word('markDone');
  String get markNotDone => _word('markNotDone');
  String get clearSelection => _word('clearSelection');
  String get select => _word('select');
  String deleteTasksQuestion(int n) => _count('deleteTasksQuestion', n);
  String get cannotBeUndone => _word('cannotBeUndone');

  // ---- Reminders and how far ahead -----------------------------------------
  String get atTheTime => _word('atTheTime');
  String minutesBefore(int minutes) => _fill('minutesBefore', {'n': minutes});
  String hoursBefore(int hours) =>
      hours == 1 ? _word('hourBefore') : _count('hoursBefore', hours);
  String daysBefore(int days) =>
      days == 1 ? _word('dayBefore') : _count('daysBefore', days);
  String weeksBefore(int weeks) =>
      weeks == 1 ? _word('weekBefore') : _count('weeksBefore', weeks);
  String get selectTime => _word('selectTime');
  String get nextWeek => _word('nextWeek');
  String get nextMonth => _word('nextMonth');
  String get previousMonth => _word('previousMonth');
  String get reminderDone => _word('reminderDone');
  String snoozeMinutes(int minutes) => _fill('snoozeMinutes', {'n': minutes});
  String get snoozeHour => _word('snoozeHour');
  String get reminderDismiss => _word('reminderDismiss');
  String get fullScreenReminders => _word('fullScreenReminders');
  String get fullScreenOn => _word('fullScreenOn');
  String get fullScreenOff => _word('fullScreenOff');
  String get fullScreenOffer => _word('fullScreenOffer');
  String get allow => _word('allow');
  String get reminderChannel => _word('reminderChannel');
  String get reminderChannelHint => _word('reminderChannelHint');

  /// What a reminder says under the title: when the task is due, from where
  /// the reminder stands — [day] is null for the same day, [time] for an
  /// all-day task.
  String dueLine({String? day, String? time, required bool past}) {
    final head = past ? 'wasDue' : 'due';
    if (time == null) {
      return day == null
          ? _word('due.today')
          : _fill('$head.day', {'day': day});
    }
    return day == null
        ? _fill('$head.at', {'time': time})
        : _fill('$head.dayAt', {'day': day, 'time': time});
  }
}

class _Delegate extends LocalizationsDelegate<S> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) => S.supports(locale.languageCode);

  @override
  Future<S> load(Locale locale) {
    S.use(locale.languageCode);
    return SynchronousFuture(S.current);
  }

  @override
  bool shouldReload(_Delegate old) => false;
}
