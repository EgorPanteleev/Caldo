import 'dart:convert';

import 'package:caldo/l10n/strings.dart';
import 'package:caldo/mcp/agents.dart';
import 'package:caldo/screens/agents_screen.dart';
import 'package:caldo/services/agents.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('a command line', () {
    const llama = AgentSpec(
      id: 'llama',
      label: 'Llama',
      command: [
        'llama-cli',
        ['-m', '{model}'],
        ['--reasoning', '{effort}'],
        '{prompt}',
      ],
    );

    test('leaves out each part naming an empty blank, with its words', () {
      expect(
        llama.argv({'model': '~/q.gguf', 'effort': null, 'prompt': 'hi'}),
        ['llama-cli', '-m', '~/q.gguf', 'hi'],
      );
      expect(llama.argv({}), ['llama-cli']);
    });

    test('is read from agents.json as written', () {
      final spec = AgentSpec.fromJson('llama', {
        'label': 'Local',
        'command': [
          'llama-cli',
          ['-m', '{model}'],
        ],
        'models': ['a.gguf'],
        'prompt': 'type',
      });
      expect(spec.label, 'Local');
      expect(spec.models, ['a.gguf']);
      expect(spec.argv({'model': 'a.gguf'}), ['llama-cli', '-m', 'a.gguf']);
    });
  });

  group("Claude's", () {
    const claude = AgentSpec(
      id: 'claude',
      label: 'Claude',
      command: ['claude'],
      plugins: ['a@market', 'b@market'],
      pluginsOn: ['a@market'],
    );

    test('carries the choices, its hooks, and the first message last', () {
      final argv = launchOf(
        claude,
        const ChatAsk(
          id: 'x',
          agent: 'claude',
          model: 'opus',
          effort: 'high',
          permission: 'auto',
          title: 'Fix it',
          plugins: ['b@market'],
          skills: ['clean-code'],
          prompt: 'Look at the tests',
        ),
        events: "/tmp/it's.events",
      );
      String after(String flag) => argv[argv.indexOf(flag) + 1];
      expect(argv.first, 'claude');
      expect(after('--model'), 'opus');
      expect(after('--effort'), 'high');
      expect(after('--permission-mode'), 'auto');
      expect(after('-n'), 'Fix it');
      expect(after('--append-system-prompt'), contains('clean-code'));
      expect(argv.last, 'Look at the tests');
      expect(argv, isNot(contains('--resume')));

      final settings = jsonDecode(after('--settings')) as Map;
      expect(settings['enabledPlugins'], {'a@market': false, 'b@market': true});
      final stop = settings['hooks']['Stop'][0]['hooks'][0]['command'];
      // Quoted for the shell, an apostrophe and all.
      expect(stop, r"{ cat; echo; } >> '/tmp/it'\''s.events'");
    });

    test("leaves the plugins be when the chat doesn't choose", () {
      final argv = launchOf(
        claude,
        const ChatAsk(id: 'x', agent: 'claude'),
        resume: 'session-1',
      );
      expect(argv, ['claude', '--resume', 'session-1']);
    });
  });

  test("the terminal is spared Claude's private requests", () {
    final clean = TermCleaner();
    expect(clean.add('a\x1b[>4;2mb\x1b[<uc'), 'abc');
    // Cut across two pieces: held, then dropped whole.
    expect(clean.add('d\x1b[>4'), 'd');
    expect(clean.add(';2me\x1b[1mf'), 'e\x1b[1mf');
    expect(clean.add('\x1b[?2004h'), '\x1b[?2004h');

    // An ended chat's last screen stays where Claude drew it.
    final ended = TermCleaner(keepAlternate: () => true);
    expect(ended.add('\x1b[?1049hhi\x1b[?1049l'), '\x1b[?1049hhi');
  });

  group('the tab', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() {
      S.use('en');
      Agents.instance.workers = const [];
    });

    Future<void> pump(WidgetTester tester, String code, Widget home) async {
      tester.view.physicalSize = const Size(960, 1920);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(code),
          supportedLocales: S.supported,
          localizationsDelegates: const [
            S.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.dark(AppAccent.presets.first),
          home: home,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    for (final code in S.names.keys) {
      testWidgets('fits in ${S.names[code]}', (tester) async {
        final s = S.forCode(code);
        // Not signed in, as in a test: the tab says how to be.
        await pump(tester, code, const AgentsScreen());
        expect(find.text(s.agentsSignIn), findsOneWidget);

        Agents.instance.workers = [
          AgentWorker(
            id: 'w',
            name: 'a-rather-long-computer-name',
            home: '/home/someone',
            seenAt: DateTime.now(),
            dirs: const ['/home/someone', '/home/someone/dev/src/Caldo'],
            agents: const [
              AgentKind(
                id: 'claude',
                label: 'Claude',
                models: ['fable', 'opus', 'sonnet', 'haiku'],
                efforts: ['low', 'medium', 'high', 'xhigh', 'max'],
                permissions: ['auto', 'manual', 'acceptEdits', 'plan'],
                plugins: ['clangd-lsp@claude-plugins-official'],
                skills: ['clean-code'],
              ),
              AgentKind(id: 'shell', label: 'Shell', prompt: 'type'),
            ],
          ),
        ];
        await pump(tester, code, const NewChatScreen());
        expect(find.text('opus'), findsOneWidget);
        // The form's list, not a field's own scroll inside it.
        final list = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text('~/dev/src/Caldo'),
          300,
          scrollable: list,
        );
        await tester.scrollUntilVisible(
          find.text(s.chatStart),
          300,
          scrollable: list,
        );
        expect(find.text(s.chatStart), findsOneWidget);
      });
    }
  });
}
