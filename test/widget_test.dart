// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:esyplayer/features/player/player_controller.dart';
import 'package:esyplayer/features/player/player_screen.dart';
import 'package:esyplayer/main.dart';
import 'package:esyplayer/core/player/fake_backend.dart';
import 'package:esyplayer/core/settings/settings.dart';
import 'package:esyplayer/features/player/player_providers.dart';
import 'package:esyplayer/features/subtitles/subtitle_preferences_dialog.dart';

class RecordingBackend extends FakeBackend {
  final commands = <List<String>>[];
  bool failCommand = false;
  bool invalidDelay = false;
  bool supportsSecondaryDelay = true;

  @override
  Future<void> command(List<String> arguments) async {
    if (failCommand) throw StateError('command failed');
    commands.add(arguments);
    if (arguments.length == 3 &&
        arguments[0] == 'add' &&
        (arguments[1] == 'sub-delay' ||
            arguments[1] == 'secondary-sub-delay')) {
      final name = arguments[1];
      final current = double.parse(properties[name] ?? '0');
      properties[name] = '${current + double.parse(arguments[2])}';
    }
  }

  @override
  Future<String> getProperty(String name) {
    if (invalidDelay && name == 'sub-delay') return Future.value('unavailable');
    if (name == 'secondary-sub-delay') {
      return Future.value(
        supportsSecondaryDelay ? properties[name] ?? '0' : '',
      );
    }
    return super.getProperty(name);
  }
}

class BlockingDelayBackend extends RecordingBackend {
  final firstCommand = Completer<void>();
  var started = 0;

  @override
  Future<void> command(List<String> arguments) async {
    started++;
    if (started == 1) await firstCommand.future;
    await super.command(arguments);
  }
}

void main() {
  testWidgets('shows application title', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerBackendProvider.overrideWithValue(FakeBackend())],
        child: const EsyPlayerApp(home: Scaffold(body: Text('EsyPlayer'))),
      ),
    );
    expect(find.text('EsyPlayer'), findsOneWidget);
  });

  testWidgets('right click opens grouped player menu', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(FakeBackend()),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Nessun media caricato')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Apri'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Opzioni'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_right), findsWidgets);

    await tester.tap(find.text('Opzioni'));
    await tester.pumpAndSettle();
    expect(find.text('Aspetto e lingua'), findsOneWidget);

    await gesture.up();
  });

  testWidgets('media information reports the active hardware decoder', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..properties['hwdec-current'] = 'drm'
      ..properties['frame-drop-count'] = '3';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(backend),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Nessun media caricato')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Visualizza'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Informazioni media…'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Decodifica hardware attiva: drm'),
      findsOneWidget,
    );
    expect(find.textContaining('Fotogrammi scartati: 3'), findsOneWidget);
    await gesture.up();
  });

  testWidgets('keyboard shortcuts are shown and control the player', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = PlayerController(backend);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerControllerProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(backend.position, const Duration(seconds: 10));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(backend.playing, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pumpAndSettle();
    expect(backend.properties['mute'], 'yes');

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Nessun media caricato')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Riproduci'));
    await tester.pumpAndSettle();
    expect(find.text('Spazio'), findsOneWidget);
    expect(find.text('←'), findsOneWidget);

    await gesture.up();
  });

  testWidgets('shortcuts show temporary feedback and adjust subtitle scale', (
    tester,
  ) async {
    final backend = RecordingBackend();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(backend),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('Riproduci'), findsOneWidget);
    final video = tester.getRect(find.byType(Stack).first);
    final feedback = tester.getRect(
      find.byKey(const ValueKey('shortcut-feedback')),
    );
    expect(feedback.right, lessThanOrEqualTo(video.right));
    expect(feedback.top, greaterThanOrEqualTo(video.top));
    expect(feedback.center.dx, greaterThan(video.center.dx));

    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(backend.commands.last, ['add', 'sub-delay', '0.1']);
    expect(find.text('Ritardo sottotitoli primari +0,1 s'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.byKey(const ValueKey('shortcut-feedback')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(backend.commands.last, ['add', 'sub-scale', '0.1']);
    expect(find.text('Dimensione sottotitoli +10%'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(backend.commands.last, ['add', 'sub-scale', '-0.1']);
    expect(find.text('Dimensione sottotitoli −10%'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('shortcut-feedback')), findsNothing);
    backend.failCommand = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.pump();
    expect(
      find.textContaining('Errore ritardo sottotitoli primari: Bad state'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('subtitle delay shortcuts track both accumulated values', (
    tester,
  ) async {
    final backend = RecordingBackend()
      ..properties['sub-delay'] = '0.35'
      ..properties['secondary-sub-delay'] = '1.2';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(backend),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(find.text('Ritardo sottotitoli primari +0,45 s'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pump();
    expect(backend.commands.last, ['add', 'secondary-sub-delay', '0.1']);
    expect(find.text('Ritardo sottotitoli secondari +1,3 s'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.pump();
    expect(find.text('Ritardo sottotitoli primari +0,35 s'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.pump();
    expect(backend.commands.last, ['add', 'secondary-sub-delay', '-0.1']);
    expect(find.text('Ritardo sottotitoli secondari +1,2 s'), findsOneWidget);
    expect(double.parse(backend.properties['sub-delay']!), closeTo(0.35, 1e-9));

    backend.properties['secondary-sub-delay'] = '-0.3';
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.pump();
    expect(find.text('Ritardo sottotitoli secondari −0,4 s'), findsOneWidget);
    backend.properties['secondary-sub-delay'] = '-0.1';
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pump();
    expect(find.text('Ritardo sottotitoli secondari +0,0 s'), findsOneWidget);
    backend.invalidDelay = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('Ritardo sottotitoli non valido'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('subtitle menu applies the same accumulated delay feedback', (
    tester,
  ) async {
    final backend = RecordingBackend()..properties['sub-delay'] = '0.2';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(backend),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );
    final gesture = await tester.startGesture(
      const Offset(250, 200),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sottotitoli'));
    await tester.pumpAndSettle();
    expect(find.text('Z'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    expect(find.text('Q'), findsOneWidget);
    expect(find.text('W'), findsOneWidget);
    await tester.tap(find.text('Ritardo sottotitoli primari −0,1 s'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Ritardo sottotitoli primari +0,1 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    final secondGesture = await tester.startGesture(
      const Offset(250, 200),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondGesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sottotitoli'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ritardo sottotitoli secondari +0,1 s'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Ritardo sottotitoli secondari +0,1 s'), findsOneWidget);
    expect(backend.commands.last, ['add', 'secondary-sub-delay', '0.1']);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'unsupported secondary delay is reported without changing primary',
    (tester) async {
      final backend = RecordingBackend()
        ..supportsSecondaryDelay = false
        ..properties['sub-delay'] = '0.4';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerControllerProvider.overrideWith(
              (ref) => PlayerController(backend),
            ),
          ],
          child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expect(
        find.text('Ritardo secondario non supportato da mpv'),
        findsOneWidget,
      );
      expect(backend.commands, isEmpty);
      expect(backend.properties['sub-delay'], '0.4');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      expect(find.text('Ritardo sottotitoli primari +0,5 s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('rapid subtitle delay adjustments are processed in order', (
    tester,
  ) async {
    final backend = BlockingDelayBackend();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(backend),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pump();
    expect(backend.started, 1);
    backend.firstCommand.complete();
    await tester.pump();
    await tester.pump();
    expect(backend.commands.length, 2);
    expect(backend.commands.last, ['add', 'secondary-sub-delay', '0.1']);
    expect(backend.properties['sub-delay'], '0.1');
    expect(find.text('Ritardo sottotitoli secondari +0,1 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('outside click closes root and nested menus', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(FakeBackend()),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );

    final gesture = await tester.startGesture(
      const Offset(250, 200),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sottotitoli'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dimensione'));
    await tester.pumpAndSettle();
    expect(find.text('Ctrl+R'), findsOneWidget);
    expect(find.text('Ctrl+T'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('Apri'), findsNothing);
    expect(find.text('Dimensione'), findsNothing);
    expect(find.text('Ctrl+R'), findsNothing);
  });

  testWidgets('recent files are nested under Open', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(FakeBackend()),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Nessun media caricato')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apri'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File recenti'));
    await tester.pumpAndSettle();

    expect(find.text('Nessun file recente'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_right), findsWidgets);
    await gesture.up();
  });

  testWidgets('submenus remain vertically reachable from their trigger', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(FakeBackend()),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Nessun media caricato')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    final triggerItem = tester.getRect(
      find.ancestor(
        of: find.text('Video'),
        matching: find.byType(MenuItemButton),
      ),
    );
    final openItem = tester.getRect(
      find.ancestor(
        of: find.text('Apri'),
        matching: find.byType(MenuItemButton),
      ),
    );
    final optionsItem = tester.getRect(
      find.ancestor(
        of: find.text('Opzioni'),
        matching: find.byType(MenuItemButton),
      ),
    );
    final mainMenu = Rect.fromLTRB(
      openItem.left,
      openItem.top,
      openItem.right,
      optionsItem.bottom,
    );
    final clickY = triggerItem.top + 8;
    await tester.tapAt(Offset(triggerItem.center.dx, clickY));
    await tester.pumpAndSettle();

    final firstItem = tester.getRect(
      find.ancestor(
        of: find.text('Schermata'),
        matching: find.byType(MenuItemButton),
      ),
    );
    final lastItem = tester.getRect(
      find.ancestor(
        of: find.text('Proprietà e filtri video…'),
        matching: find.byType(MenuItemButton),
      ),
    );
    expect(firstItem.top <= clickY && clickY <= firstItem.bottom, isTrue);
    expect((firstItem.center.dy - clickY).abs(), lessThan(1));
    expect(triggerItem.center.dy, lessThanOrEqualTo(lastItem.bottom));
    expect(
      firstItem.left >= mainMenu.right || lastItem.right <= mainMenu.left,
      isTrue,
    );
    expect(firstItem.height, lessThanOrEqualTo(30));
    expect(triggerItem.height, lessThanOrEqualTo(30));

    await gesture.up();
  });

  testWidgets('submenus flip to the free side at the window edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(FakeBackend()),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );

    final gesture = await tester.startGesture(
      const Offset(996, 350),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    final openItem = tester.getRect(
      find.ancestor(
        of: find.text('Apri'),
        matching: find.byType(MenuItemButton),
      ),
    );
    final optionsItem = tester.getRect(
      find.ancestor(
        of: find.text('Opzioni'),
        matching: find.byType(MenuItemButton),
      ),
    );
    final videoItem = tester.getRect(
      find.ancestor(
        of: find.text('Video'),
        matching: find.byType(MenuItemButton),
      ),
    );
    await tester.tap(find.text('Video'));
    await tester.pumpAndSettle();

    final lastItem = tester.getRect(
      find.ancestor(
        of: find.text('Proprietà e filtri video…'),
        matching: find.byType(MenuItemButton),
      ),
    );
    expect(openItem.left, greaterThanOrEqualTo(0));
    expect(optionsItem.right, lessThanOrEqualTo(1000));
    expect(videoItem.top, greaterThanOrEqualTo(0));
    expect(videoItem.bottom, lessThanOrEqualTo(700));
    expect(lastItem.right, lessThanOrEqualTo(openItem.left));
    expect(lastItem.bottom, lessThanOrEqualTo(700));

    await gesture.up();
  });

  testWidgets('playback controls are confined to the bottom toolbar', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(
            (ref) => PlayerController(FakeBackend()),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );

    expect(find.byTooltip('Stop'), findsOneWidget);
    expect(find.byTooltip('Elemento precedente'), findsOneWidget);
    expect(find.byTooltip('Elemento successivo'), findsOneWidget);
    expect(find.byTooltip('Schermo intero'), findsOneWidget);
    expect(find.text('00:00 / 00:00'), findsOneWidget);

    final toolbar = find.byKey(const ValueKey('playback-toolbar'));
    final theme = Theme.of(tester.element(toolbar));
    final decoration =
        tester.widget<Container>(toolbar).decoration! as BoxDecoration;
    expect(decoration.color!.a, 1);
    final border = decoration.border! as Border;
    expect(border.top.color, theme.colorScheme.primary);
    expect(border.left.color, theme.colorScheme.primary);
    expect(border.right.color, theme.colorScheme.primary);
    expect(border.bottom.color, theme.colorScheme.primary);
    expect(
      tester.getSize(find.byType(Slider).last).width,
      greaterThanOrEqualTo(164),
    );
  });

  testWidgets('track menus list and select available media tracks', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..availableTracks = const Tracks(
        video: [],
        audio: [
          AudioTrack('auto', null, null),
          AudioTrack('no', null, null),
          AudioTrack('1', 'English', 'en', codec: 'aac', isDefault: true),
        ],
        subtitle: [
          SubtitleTrack('auto', null, null),
          SubtitleTrack('no', null, null),
          SubtitleTrack('2', 'Italian', 'it', codec: 'subrip', isDefault: true),
          SubtitleTrack('3', 'French', 'fr', codec: 'subrip'),
        ],
      );
    final controller = PlayerController(backend);
    await controller.open('test://media');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerControllerProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: PlayerScreen(enableDropTarget: false)),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> openContextMenu() async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Nessun media caricato')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await openContextMenu();
    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Traccia audio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English · en · aac · ID 1 · predefinita'));
    await tester.pumpAndSettle();
    expect(backend.properties['aid'], '1');

    await openContextMenu();
    await tester.tap(find.text('Sottotitoli'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sottotitolo primario'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Italian · it · subrip · ID 2 · predefinita'));
    await tester.pumpAndSettle();
    expect(backend.properties['sid'], '2');

    await openContextMenu();
    await tester.tap(find.text('Sottotitoli'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sottotitolo secondario'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('French · fr · subrip · ID 3'));
    await tester.pumpAndSettle();
    expect(backend.properties['secondary-sid'], '3');
  });

  testWidgets('subtitle preferences restore their defaults', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late Future<Map<String, String>?> result;
    final initialValues = Map<String, String>.of(
      AppSettings.subtitlePreferenceDefaults,
    )..['sub-font'] = 'Custom font';

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  result = showDialog<Map<String, String>>(
                    context: context,
                    builder: (_) =>
                        SubtitlePreferencesDialog(initialValues: initialValues),
                  );
                },
                child: const Text('Open preferences'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open preferences'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ripristina predefinite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();

    expect(await result, AppSettings.subtitlePreferenceDefaults);
  });

  for (final size in [const Size(1200, 900), const Size(600, 450)]) {
    testWidgets('subtitle preview stays above settings at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubtitlePreferencesDialog(
              initialValues: AppSettings.subtitlePreferenceDefaults,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final preview = find.byKey(const ValueKey('subtitle-preview'));
      final list = find.byKey(const ValueKey('subtitle-settings-list'));
      final initialRect = tester.getRect(preview);
      expect(initialRect.bottom, lessThan(tester.getTopLeft(list).dy));
      expect(initialRect.center.dx, closeTo(size.width / 2, 4));
      expect(find.text('Sottotitolo primario'), findsWidgets);

      await tester.tap(find.text('Mostra sottotitoli primari'));
      await tester.pump();
      expect(find.text('Sottotitolo primario'), findsNothing);
      await tester.drag(list, const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(tester.getRect(preview), initialRect);

      await tester.tap(find.text('Secondario'));
      await tester.pumpAndSettle();
      expect(tester.getRect(preview), initialRect);
      if (size.height < 500) {
        await tester.drag(list, const Offset(0, -160));
        await tester.pumpAndSettle();
      }
      expect(find.text('Mostra seconda traccia'), findsOneWidget);
      await tester.tap(find.text('Primario'));
      await tester.pumpAndSettle();
      expect(find.text('Mostra sottotitoli primari'), findsOneWidget);
      expect(find.text('Sottotitolo primario'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('subtitle preferences fit a small window with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: SubtitlePreferencesDialog(
            initialValues: AppSettings.subtitlePreferenceDefaults,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('subtitle-preview')), findsOneWidget);
    expect(find.text('Salva'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('subtitle-settings-list')))
          .height,
      greaterThan(0),
    );
    final list = find.byKey(const ValueKey('subtitle-settings-list'));
    for (var i = 0; i < 10; i++) {
      await tester.drag(list, const Offset(0, -250));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Secondario'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.drag(list, const Offset(0, -250));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('changing subtitle border forces ASS style overrides', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late Future<Map<String, String>?> result;
    final initialValues = Map<String, String>.of(
      AppSettings.subtitlePreferenceDefaults,
    )..['sub-ass-override'] = 'no';

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  result = showDialog<Map<String, String>>(
                    context: context,
                    builder: (_) =>
                        SubtitlePreferencesDialog(initialValues: initialValues),
                  );
                },
                child: const Text('Open preferences'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open preferences'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bordo e ombra'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Riquadro opaco').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Riquadro opaco'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bordo e ombra').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();

    final savedValues = await result;
    expect(savedValues?['sub-border-style'], 'outline-and-shadow');
    expect(savedValues?['sub-ass-override'], 'force');
  });
}
