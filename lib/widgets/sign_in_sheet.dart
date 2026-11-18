import 'package:flutter/material.dart';
import 'package:supabase/supabase.dart' show AuthException;

import '../l10n/strings.dart';
import '../services/account.dart';
import '../theme/app_theme.dart';
import 'date_time_pickers.dart' show SheetAction, showAppSheet;

/// Signs in with a name and a password. Returns true once signed in.
Future<bool?> showSignInSheet(BuildContext context) =>
    showAppSheet<bool>(context, child: const _AccountSheet(joining: false));

/// Makes an account from an invite — [invite] filled in when a link was
/// followed — and signs in to it. Returns true once signed in.
Future<bool?> showJoinSheet(BuildContext context, {String? invite}) =>
    showAppSheet<bool>(
      context,
      child: _AccountSheet(joining: true, invite: invite),
    );

/// Sets the address of the server this device syncs with.
Future<void> showServerSheet(BuildContext context) =>
    showAppSheet<void>(context, child: const _ServerSheet());

const signInNameKey = Key('sign-in-name');
const signInPasswordKey = Key('sign-in-password');
const signInInviteKey = Key('sign-in-invite');

/// The shortest password Auth takes (its `minimum_password_length`).
const _shortest = 6;

class _AccountSheet extends StatefulWidget {
  final bool joining;
  final String? invite;

  const _AccountSheet({required this.joining, this.invite});

  @override
  State<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<_AccountSheet> {
  late final _invite = TextEditingController(text: widget.invite ?? '');
  final _name = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _invite.dispose();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  /// What went wrong, in words. An answer the server gave that none of
  /// these covers is shown as it came, rather than as no answer at all.
  String _say(Object e, S s) {
    if (e is! AuthException) return s.syncUnreachable;
    if (e.statusCode == '403') return s.syncBadInvite;
    return switch (e.code) {
      'invalid_credentials' => s.syncBadLogin,
      'user_already_exists' => s.syncNameTaken,
      'weak_password' => s.syncShortPassword(_shortest),
      _ => e.message,
    };
  }

  /// What is wrong with the fields before anything is sent, if anything.
  String? _check(S s) {
    if (widget.joining && Account.inviteIn(_invite.text).isEmpty) {
      return s.syncBadInvite;
    }
    if (!Account.fitsName(_name.text)) return s.syncBadName;
    if (_password.text.length < _shortest) {
      return s.syncShortPassword(_shortest);
    }
    return null;
  }

  Future<void> _go() async {
    final s = S.of(context);
    if (_busy) return;
    final wrong = _check(s);
    if (wrong != null) {
      setState(() => _problem = wrong);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      if (widget.joining) {
        await Account.instance.join(_invite.text, _name.text, _password.text);
      } else {
        await Account.instance.signIn(_name.text, _password.text);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _problem = _say(e, s));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final joining = widget.joining;
    // The invite is asked for only when no link brought one.
    final askInvite = joining && (widget.invite ?? '').isEmpty;
    return _Body(
      title: joining ? s.syncJoin : s.syncSignIn,
      note: joining ? s.syncJoinNote : s.syncSignInHint,
      problem: _problem,
      field: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (askInvite) ...[
              TextField(
                key: signInInviteKey,
                controller: _invite,
                autofocus: true,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: s.syncInvite),
              ),
              const SizedBox(height: 10),
            ],
            TextField(
              key: signInNameKey,
              controller: _name,
              autofocus: !askInvite,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
              decoration: InputDecoration(labelText: s.syncName),
            ),
            const SizedBox(height: 10),
            TextField(
              key: signInPasswordKey,
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              autofillHints: [
                joining ? AutofillHints.newPassword : AutofillHints.password,
              ],
              decoration: InputDecoration(labelText: s.syncPassword),
              onSubmitted: (_) => _go(),
            ),
          ],
        ),
      ),
      action: joining ? s.syncJoinAction : s.syncSignIn,
      busy: _busy,
      onAction: _go,
    );
  }
}

class _ServerSheet extends StatefulWidget {
  const _ServerSheet();

  @override
  State<_ServerSheet> createState() => _ServerSheetState();
}

class _ServerSheetState extends State<_ServerSheet> {
  late final _address = TextEditingController(
    text: Account.instance.server.value ?? '',
  );

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await Account.instance.setServer(_address.text);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return _Body(
      title: s.syncServer,
      field: TextField(
        controller: _address,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: s.syncServer,
          hintText: 'http://192.168.1.10:54321',
        ),
        onSubmitted: (_) => _save(),
      ),
      action: s.save,
      onAction: _save,
    );
  }
}

/// A sheet of fields: a title, a line about it, the fields, what went
/// wrong if anything did, and Cancel beside the action.
class _Body extends StatelessWidget {
  final String title;
  final String? note;
  final Widget field;
  final String? problem;
  final String action;
  final bool busy;
  final VoidCallback onAction;

  const _Body({
    required this.title,
    this.note,
    required this.field,
    this.problem,
    required this.action,
    this.busy = false,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    return Padding(
      // A sheet is not lifted the way a screen is, so it makes the
      // keyboard's room out of its own height.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (note != null) ...[
              const SizedBox(height: 4),
              Text(note!, style: TextStyle(color: p.muted)),
            ],
            const SizedBox(height: 12),
            field,
            if (problem != null) ...[
              const SizedBox(height: 8),
              Text(problem!, style: TextStyle(color: AppColors.overdue)),
            ],
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                SheetAction(
                  label: s.cancel,
                  onTap: () => Navigator.of(context).pop(),
                ),
                busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : SheetAction(label: action, onTap: onAction),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
