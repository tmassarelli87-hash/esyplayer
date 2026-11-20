// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:window_manager/window_manager.dart';

import 'player_controller.dart';
import 'player_providers.dart';
import '../../core/settings/settings_providers.dart';
import '../subtitles/subtitle_preferences_dialog.dart';

const _menuButtonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(0, 30)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.standard,
);
const _rootMenuStyle = MenuStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.all(4)),
  visualDensity: VisualDensity.compact,
);
const _submenuMenuStyle = MenuStyle(
  alignment: AlignmentDirectional.centerEnd,
  padding: WidgetStatePropertyAll(EdgeInsets.all(4)),
  visualDensity: VisualDensity.compact,
);
const _menuRowHeight = 30.0;
const _menuSurfacePadding = 4.0;
const _submenuGap = 8.0;

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, this.enableDropTarget = true});

  final bool enableDropTarget;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  final List<String> _recentFilePaths = [];
  Timer? _controlsTimer;
  Timer? _feedbackTimer;
  String? _feedback;
  Future<void> _subtitleDelayQueue = Future<void>.value();
  nativeapi.Window? _window;
  nativeapi.ListenerId? _windowListenerId;
  String? _recentFilesError;
  bool _isFullScreen = false;
  bool _controlsVisible = true;
  bool _controlsHovered = false;
  bool _recentFilesLoading = false;

  @override
  void initState() {
    super.initState();
    _window = WindowManager.instance.getCurrent();
    final window = _window;
    if (window != null) {
      _isFullScreen = window.isFullScreen;
      _windowListenerId = window.addListener(_handleWindowEvent);
      if (_isFullScreen) {
        _scheduleControlsHide();
      }
    }
  }

  void _handleWindowEvent(nativeapi.WindowEvent event) {
    if (event is nativeapi.WindowEnteredFullScreenEvent) {
      _setFullScreenState(true);
    } else if (event is nativeapi.WindowExitedFullScreenEvent) {
      _setFullScreenState(false);
    }
  }

  void _setFullScreenState(bool value) {
    if (!mounted) {
      return;
    }
    _controlsTimer?.cancel();
    _controlsHovered = false;
    setState(() {
      _isFullScreen = value;
      _controlsVisible = true;
    });
    if (value) {
      _scheduleControlsHide();
    }
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (_controlsHovered) {
      return;
    }
    _controlsTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _isFullScreen && !_controlsHovered) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _revealControls() {
    if (!_isFullScreen) {
      return;
    }
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleControlsHide();
  }

  void _setControlsHovered(bool value) {
    if (!_isFullScreen) {
      return;
    }
    _controlsHovered = value;
    _controlsTimer?.cancel();
    if (value) {
      if (!_controlsVisible) {
        setState(() => _controlsVisible = true);
      }
    } else {
      _scheduleControlsHide();
    }
  }

  void _toggleFullScreen() {
    final window = _window ?? WindowManager.instance.getCurrent();
    if (window == null) {
      return;
    }

    final value = !window.isFullScreen;
    window.isFullScreen = value;
    _setFullScreenState(value);
  }

  void _showFeedback(String message) {
    if (!mounted) return;
    _feedbackTimer?.cancel();
    setState(() => _feedback = message);
    _feedbackTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  Future<void> _runShortcut(
    Future<void> Function() action,
    String message,
  ) async {
    try {
      await action();
      _showFeedback(message);
    } catch (error) {
      _showFeedback('Errore: $error');
    }
  }

  Future<void> _adjustSubtitleDelay(
    PlayerController controller,
    int direction, {
    bool secondary = false,
  }) {
    _subtitleDelayQueue = _subtitleDelayQueue.then((_) async {
      if (!mounted) return;
      final track = secondary ? 'secondari' : 'primari';
      try {
        final property = secondary ? 'secondary-sub-delay' : 'sub-delay';
        if (secondary && (await controller.getProperty(property)).isEmpty) {
          _showFeedback('Ritardo secondario non supportato da mpv');
          return;
        }
        await controller.command([
          'add',
          property,
          direction < 0 ? '-0.1' : '0.1',
        ]);
        final rawValue = await controller.getProperty(property);
        final value = double.tryParse(rawValue);
        if (value == null || !value.isFinite) {
          throw FormatException('Ritardo sottotitoli non valido: $rawValue');
        }
        var formatted = value.abs().toStringAsFixed(6);
        formatted = formatted.replaceFirst(RegExp(r'0+$'), '');
        if (formatted.endsWith('.')) formatted += '0';
        final sign = value < 0 && formatted != '0.0' ? '−' : '+';
        _showFeedback(
          'Ritardo sottotitoli $track $sign${formatted.replaceAll('.', ',')} s',
        );
      } catch (error) {
        _showFeedback('Errore ritardo sottotitoli $track: $error');
      }
    });
    return _subtitleDelayQueue;
  }

  Future<void> _refreshRecentFiles(PlayerController controller) async {
    if (!mounted || _recentFilesLoading) {
      return;
    }
    setState(() {
      _recentFilesLoading = true;
      _recentFilesError = null;
    });
    try {
      final files = await controller.database?.recentFilesList(limit: 6) ?? [];
      if (!mounted) {
        return;
      }
      setState(() {
        _recentFilePaths
          ..clear()
          ..addAll(files.take(6).map((file) => file.path));
        _recentFilesLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _recentFilesError = error.toString();
        _recentFilesLoading = false;
      });
    }
  }

  String _recentFileLabel(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    return name.isEmpty ? path : name;
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _feedbackTimer?.cancel();
    final listenerId = _windowListenerId;
    if (listenerId != null) {
      _window?.removeListener(listenerId);
    }
    super.dispose();
  }

  Future<void> _openFile(PlayerController controller) async {
    final file = await FilePicker.pickFile(type: FileType.media);
    final path = file?.path;
    if (path != null) {
      await controller.open(path);
    }
  }

  Future<void> _openFolder(PlayerController controller) async {
    final directory = await FilePicker.pickDirectory();
    final path = directory?.toFilePath();
    if (path != null) {
      await controller.open(path);
    }
  }

  Future<void> _addFileToQueue(PlayerController controller) async {
    final file = await FilePicker.pickFile(type: FileType.media);
    final path = file?.path;
    if (path != null) {
      await controller.addToPlaylist(path);
    }
  }

  Future<void> _openPlaylist(PlayerController controller) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8', 'pls'],
    );
    final path = file?.path;
    if (path != null) {
      await controller.open(path);
    }
  }

  Future<void> _openUrl(
    BuildContext context,
    PlayerController controller,
  ) async {
    final urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Open URL'),
        content: TextField(
          controller: urlController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'https://'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, urlController.text.trim()),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) {
      await controller.open(url);
    }
  }

  String _trackLabel({
    required String id,
    String? title,
    String? language,
    String? codec,
    bool? isDefault,
  }) {
    if (id == 'auto') {
      return 'Automatico';
    }
    if (id == 'no') {
      return 'Disattivato';
    }

    return [
      if (title?.trim().isNotEmpty == true) title!.trim(),
      if (language?.trim().isNotEmpty == true) language!.trim(),
      if (codec?.trim().isNotEmpty == true) codec!.trim(),
      'ID $id',
      if (isDefault == true) 'predefinita',
    ].join(' · ');
  }

  List<Widget> _audioTrackItems(PlayerController controller) {
    final tracks = controller.tracks.audio;
    if (tracks.isEmpty) {
      return [
        const MenuItemButton(
          onPressed: null,
          style: _menuButtonStyle,
          child: Text('Nessuna traccia disponibile'),
        ),
      ];
    }
    return [
      for (final track in tracks)
        MenuItemButton(
          style: _menuButtonStyle,
          onPressed: () => controller.setAudioTrack(track.id),
          child: Text(
            _trackLabel(
              id: track.id,
              title: track.title,
              language: track.language,
              codec: track.codec,
              isDefault: track.isDefault,
            ),
          ),
        ),
    ];
  }

  List<Widget> _subtitleTrackItems(
    PlayerController controller, {
    required bool secondary,
  }) {
    final tracks = controller.tracks.subtitle;
    if (tracks.isEmpty) {
      return [
        const MenuItemButton(
          onPressed: null,
          style: _menuButtonStyle,
          child: Text('Nessuna traccia disponibile'),
        ),
      ];
    }
    return [
      for (final track in tracks)
        MenuItemButton(
          style: _menuButtonStyle,
          onPressed: () => secondary
              ? controller.setSecondarySubtitleTrack(track.id)
              : controller.setSubtitleTrack(track.id),
          child: Text(
            _trackLabel(
              id: track.id,
              title: track.title,
              language: track.language,
              codec: track.codec,
              isDefault: track.isDefault,
            ),
          ),
        ),
    ];
  }

  Future<void> _propertyDialog(
    BuildContext context,
    PlayerController controller,
  ) async {
    final nameController = TextEditingController();
    final valueController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Set mpv property'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(hintText: 'property'),
            ),
            TextField(
              controller: valueController,
              decoration: const InputDecoration(hintText: 'value'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (result == true &&
        nameController.text.trim().isNotEmpty &&
        valueController.text.trim().isNotEmpty) {
      await controller.setProperty(
        nameController.text.trim(),
        valueController.text.trim(),
      );
    }
  }

  Future<void> _extraOptionsDialog(BuildContext context, WidgetRef ref) async {
    final settings = ref.read(appSettingsProvider);
    final controller = TextEditingController(
      text: await settings.getExtraMpvOptions() ?? '',
    );
    if (!context.mounted) {
      return;
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Extra mpv options'),
        content: TextField(
          controller: controller,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'key=value, one per line',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == true) {
      await settings.setExtraMpvOptions(controller.text);
    }
  }

  Future<void> _showFavorites(
    BuildContext context,
    WidgetRef ref,
    PlayerController controller,
  ) async {
    final favorites = await ref.read(appSettingsProvider).getFavorites();
    if (!context.mounted) {
      return;
    }
    final path = await _choosePath(context, 'Preferiti', favorites);
    if (path != null) {
      await controller.open(path);
    }
  }

  Future<String?> _choosePath(
    BuildContext context,
    String title,
    List<String> paths,
  ) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 480,
          child: paths.isEmpty
              ? const Text('Nessun elemento disponibile.')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final path in paths)
                      ListTile(
                        dense: true,
                        title: Text(path, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(dialogContext, path),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Chiudi'),
          ),
        ],
      ),
    );
  }

  Future<void> _showMediaInfo(
    BuildContext context,
    PlayerController controller,
  ) async {
    final title = await controller.getProperty('media-title');
    final duration = await controller.getProperty('duration');
    final dimensions = await controller.getProperty('video-params');
    final decoder = await controller.getProperty('hwdec-current');
    final droppedFrames = await controller.getProperty('frame-drop-count');
    if (!context.mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Informazioni media'),
        content: Text(
          'Titolo: $title\nDurata: $duration\nVideo: $dimensions\n'
          'Decodifica hardware attiva: '
          '${decoder.isEmpty ? 'non disponibile' : decoder}\n'
          'Fotogrammi scartati: '
          '${droppedFrames.isEmpty ? 'non disponibile' : droppedFrames}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Chiudi'),
          ),
        ],
      ),
    );
  }

  Future<void> _commandDialog(
    BuildContext context,
    PlayerController controller,
  ) async {
    final commandController = TextEditingController();
    final command = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Comando mpv'),
        content: TextField(
          controller: commandController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'es. cycle deinterlace'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, commandController.text.trim()),
            child: const Text('Esegui'),
          ),
        ],
      ),
    );
    if (command != null && command.trim().isNotEmpty) {
      await controller.command(command.trim().split(RegExp(r'\s+')));
    }
  }

  Future<void> _loadSubtitle(PlayerController controller) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt', 'sub'],
    );
    final path = file?.path;
    if (path != null) {
      await controller.loadSubtitle(path);
    }
  }

  Future<void> _subtitlePreferencesDialog(
    BuildContext context,
    WidgetRef ref,
    PlayerController controller,
  ) async {
    final settings = ref.read(appSettingsProvider);
    final currentValues = await settings.getSubtitlePreferences();
    if (!context.mounted) {
      return;
    }

    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) =>
          SubtitlePreferencesDialog(initialValues: currentValues),
    );
    if (values == null) {
      return;
    }

    final borderStyleChanged =
        values['sub-border-style'] != currentValues['sub-border-style'] ||
        values['sub-ass-override'] != currentValues['sub-ass-override'];
    await controller.applySubtitlePreferences(
      values,
      refreshActiveTracks: borderStyleChanged,
    );
    await settings.setSubtitlePreferences(values);
  }

  List<Widget> _contextMenu(
    BuildContext context,
    WidgetRef ref,
    PlayerController controller,
  ) {
    final window = WindowManager.instance.getCurrent();
    final currentSource = controller.currentSource;
    MenuItemButton item(
      String label,
      VoidCallback? onPressed, {
      String? shortcut,
    }) => MenuItemButton(
      style: _menuButtonStyle,
      onPressed: onPressed,
      trailingIcon: shortcut == null
          ? null
          : Text(
              shortcut,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
      child: Text(label),
    );
    Widget submenu(
      String label,
      List<Widget> children, {
      VoidCallback? onOpen,
    }) => _PositionedSubmenu(
      label: label,
      menuChildren: children,
      onOpen: onOpen,
    );

    final recentFileItems = _recentFilesLoading
        ? [item('Caricamento…', null)]
        : _recentFilesError != null
        ? [item('Errore: $_recentFilesError', null)]
        : _recentFilePaths.isEmpty
        ? [item('Nessun file recente', null)]
        : [
            for (final path in _recentFilePaths.take(6))
              MenuItemButton(
                style: _menuButtonStyle,
                onPressed: () => controller.open(path),
                child: Tooltip(
                  message: path,
                  child: Text(
                    _recentFileLabel(path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ];

    return [
      submenu('Apri', [
        item('File…', () => _openFile(controller), shortcut: 'Ctrl+F'),
        item('Cartella…', () => _openFolder(controller)),
        item('URL o stream…', () => _openUrl(context, controller)),
        item('Playlist M3U/PLS…', () => _openPlaylist(controller)),
        submenu(
          'File recenti',
          recentFileItems,
          onOpen: () => _refreshRecentFiles(controller),
        ),
      ]),
      submenu('Riproduci', [
        item(
          controller.isPlaying ? 'Pausa' : 'Riproduci',
          controller.playOrPause,
          shortcut: 'Spazio',
        ),
        item('Stop', controller.stop),
        item('Elemento precedente', controller.previous),
        item('Elemento successivo', controller.next, shortcut: 'Shift+.'),
        item('Indietro di 10 secondi', () {
          final target = controller.position - const Duration(seconds: 10);
          controller.seek(target.isNegative ? Duration.zero : target);
        }, shortcut: '←'),
        item('Avanti di 10 secondi', () {
          controller.seek(controller.position + const Duration(seconds: 10));
        }, shortcut: '→'),
        item('Indietro di 1 minuto', () {
          final target = controller.position - const Duration(minutes: 1);
          controller.seek(target.isNegative ? Duration.zero : target);
        }, shortcut: '↓'),
        item('Avanti di 1 minuto', () {
          controller.seek(controller.position + const Duration(minutes: 1));
        }, shortcut: '↑'),
        item('Indietro di 10 minuti', () {
          final target = controller.position - const Duration(minutes: 10);
          controller.seek(target.isNegative ? Duration.zero : target);
        }, shortcut: 'PgGiù'),
        item('Avanti di 10 minuti', () {
          controller.seek(controller.position + const Duration(minutes: 10));
        }, shortcut: 'PgSu'),
        item(
          'Avanza di un fotogramma',
          () => controller.command(['frame-step']),
          shortcut: '.',
        ),
        item(
          'Indietro di un fotogramma',
          () => controller.command(['frame-back-step']),
          shortcut: ',',
        ),
        submenu('Velocità', [
          for (final rate in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0])
            item(
              '$rate×',
              () => controller.setRate(rate),
              shortcut: rate == 1 ? 'Backspace' : null,
            ),
        ]),
        item('Imposta punto A del loop', () {
          final seconds = controller.position.inMilliseconds / 1000;
          controller.setProperty('ab-loop-a', '$seconds');
        }),
        item('Imposta punto B del loop', () {
          final seconds = controller.position.inMilliseconds / 1000;
          controller.setProperty('ab-loop-b', '$seconds');
        }),
        item('Disattiva loop A-B', () async {
          await controller.setProperty('ab-loop-a', 'no');
          await controller.setProperty('ab-loop-b', 'no');
        }),
      ]),
      submenu('Video', [
        item(
          'Schermata',
          () => controller.command(['screenshot', 'subtitles']),
          shortcut: 'S',
        ),
        item(
          'Capitolo successivo',
          () => controller.command(['add', 'chapter', '1']),
        ),
        submenu('Proporzioni', [
          item(
            'Automatiche',
            () => controller.setProperty('video-aspect-override', '-1'),
          ),
          item(
            '16:9',
            () => controller.setProperty('video-aspect-override', '1.7778'),
          ),
          item(
            '4:3',
            () => controller.setProperty('video-aspect-override', '1.3333'),
          ),
        ]),
        submenu('Accelerazione hardware', [
          for (final decoder in ['auto', 'no', 'vaapi', 'nvdec', 'd3d11va'])
            item(decoder, () => controller.setProperty('hwdec', decoder)),
        ]),
        item(
          'Proprietà e filtri video…',
          () => _propertyDialog(context, controller),
        ),
      ]),
      submenu('Audio', [
        submenu('Traccia audio', _audioTrackItems(controller)),
        item(
          'Traccia audio successiva',
          () => controller.command(['cycle', 'aid']),
          shortcut: 'K',
        ),
        item(
          'Traccia audio precedente',
          () => controller.command(['cycle', 'aid', 'down']),
          shortcut: 'Shift+K',
        ),
        item('Muto / attiva audio', controller.toggleMute, shortcut: 'M'),
        submenu('Volume', [
          item(
            'Diminuisci volume',
            () => controller.setVolume(
              (controller.volume - 5).clamp(0, 200).toDouble(),
            ),
            shortcut: '9',
          ),
          item(
            'Aumenta volume',
            () => controller.setVolume(
              (controller.volume + 5).clamp(0, 200).toDouble(),
            ),
            shortcut: '0',
          ),
          for (final volume in [50, 100, 150, 200])
            item('$volume%', () => controller.setVolume(volume.toDouble())),
        ]),
        item(
          'Proprietà e filtri audio…',
          () => _propertyDialog(context, controller),
        ),
      ]),
      submenu('Sottotitoli', [
        item(
          'Traccia sottotitoli successiva',
          () => controller.command(['cycle', 'sid']),
          shortcut: 'J',
        ),
        item(
          'Traccia sottotitoli precedente',
          () => controller.command(['cycle', 'sid', 'down']),
          shortcut: 'Shift+J',
        ),
        submenu(
          'Sottotitolo primario',
          _subtitleTrackItems(controller, secondary: false),
        ),
        submenu(
          'Sottotitolo secondario',
          _subtitleTrackItems(controller, secondary: true),
        ),
        item('Carica file esterno…', () => _loadSubtitle(controller)),
        item(
          'Ritardo sottotitoli primari −0,1 s',
          () => _adjustSubtitleDelay(controller, -1),
          shortcut: 'Z',
        ),
        item(
          'Ritardo sottotitoli primari +0,1 s',
          () => _adjustSubtitleDelay(controller, 1),
          shortcut: 'X',
        ),
        item(
          'Ritardo sottotitoli secondari −0,1 s',
          () => _adjustSubtitleDelay(controller, -1, secondary: true),
          shortcut: 'Q',
        ),
        item(
          'Ritardo sottotitoli secondari +0,1 s',
          () => _adjustSubtitleDelay(controller, 1, secondary: true),
          shortcut: 'W',
        ),
        submenu('Dimensione', [
          item(
            'Aumenta dimensione',
            () => controller.command(['add', 'sub-scale', '0.1']),
            shortcut: 'Ctrl+R',
          ),
          item(
            'Diminuisci dimensione',
            () => controller.command(['add', 'sub-scale', '-0.1']),
            shortcut: 'Ctrl+T',
          ),
          for (final size in [75, 100, 125, 150, 200])
            item('$size%', () => controller.setSubtitleSize(size)),
        ]),
        item(
          'Preferenze sottotitoli…',
          () => _subtitlePreferencesDialog(context, ref, controller),
        ),
      ]),
      submenu('Preferiti', [
        item(
          'Aggiungi file corrente',
          currentSource == null
              ? null
              : () => ref.read(appSettingsProvider).addFavorite(currentSource),
        ),
        item('Apri preferito…', () => _showFavorites(context, ref, controller)),
        item(
          'Rimuovi file corrente',
          currentSource == null
              ? null
              : () =>
                    ref.read(appSettingsProvider).removeFavorite(currentSource),
        ),
      ]),
      submenu('Playlist', [
        item('Aggiungi file alla coda…', () => _addFileToQueue(controller)),
        item('Apri playlist M3U/PLS…', () => _openPlaylist(controller)),
        item('Elemento precedente', controller.previous, shortcut: 'Shift+,'),
        item('Elemento successivo', controller.next, shortcut: 'Shift+.'),
      ]),
      submenu('Visualizza', [
        item('Schermata intera', _toggleFullScreen, shortcut: 'F'),
        item('Sempre in primo piano', () {
          if (window != null) {
            window.isAlwaysOnTop = !window.isAlwaysOnTop;
          }
        }),
        item(
          'Modalità compatta',
          () => window?.setSize(
            const nativeapi.Size(width: 480, height: 270),
            true,
          ),
        ),
        item(
          'Statistiche mpv',
          () => controller.command([
            'script-binding',
            'stats/display-stats-toggle',
          ]),
        ),
        item('Informazioni media…', () => _showMediaInfo(context, controller)),
      ]),
      submenu('Opzioni', [
        submenu('Generali', [
          item(
            'Opzioni mpv aggiuntive…',
            () => _extraOptionsDialog(context, ref),
          ),
          item('Comando mpv…', () => _commandDialog(context, controller)),
          item('Proprietà mpv…', () => _propertyDialog(context, controller)),
        ]),
        submenu('Aspetto e lingua', [
          item('Tema di sistema', () {
            ref.read(themeModeProvider.notifier).state = ThemeMode.system;
          }),
          item('Tema chiaro', () async {
            ref.read(themeModeProvider.notifier).state = ThemeMode.light;
            await ref.read(appSettingsProvider).setDarkMode(false);
          }),
          item('Tema scuro', () async {
            ref.read(themeModeProvider.notifier).state = ThemeMode.dark;
            await ref.read(appSettingsProvider).setDarkMode(true);
          }),
          item('Lingua: Italiano', () async {
            ref.read(localeProvider.notifier).state = 'it';
            await ref.read(appSettingsProvider).setLocale('it');
          }),
          item('Language: English', () async {
            ref.read(localeProvider.notifier).state = 'en';
            await ref.read(appSettingsProvider).setLocale('en');
          }),
        ]),
        submenu('Riproduzione', [
          submenu('Velocità predefinita', [
            for (final rate in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
              item('$rate×', () => controller.setRate(rate)),
          ]),
          item('Riprendi da posizione salvata', () async {
            final resume = await controller.database?.resumePosition(
              currentSource ?? '',
            );
            if (resume != null) {
              await controller.seek(resume);
            }
          }),
        ]),
        submenu('Video', [
          item(
            'Decoder, proporzioni, filtri…',
            () => _propertyDialog(context, controller),
          ),
          item(
            'Deinterlacciamento',
            () => controller.command(['cycle', 'deinterlace']),
          ),
        ]),
        submenu('Audio', [
          item('Ritardo audio…', () => _propertyDialog(context, controller)),
          item(
            'Equalizzatore e normalizzazione…',
            () => _propertyDialog(context, controller),
          ),
        ]),
        submenu('Sottotitoli', [
          item(
            'Preferenze sottotitoli…',
            () => _subtitlePreferencesDialog(context, ref, controller),
          ),
        ]),
      ]),
      item('Informazioni su EsyPlayer', () {
        showAboutDialog(
          context: context,
          applicationName: 'EsyPlayer',
          applicationVersion: '1.0.0',
          applicationLegalese: 'GPL-3.0-or-later',
        );
      }),
    ];
  }

  String _format(Duration value) {
    final totalSeconds = value.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(playerControllerProvider);
    final videoController = controller.backend.videoController;

    final durationSeconds = controller.duration.inMilliseconds / 1000;
    final positionSeconds = controller.position.inMilliseconds / 1000;
    final double seekMax = durationSeconds > 0 ? durationSeconds : 1;
    final seekValue = positionSeconds.clamp(0, seekMax).toDouble();
    final videoSurface = GestureDetector(
      onDoubleTap: controller.currentSource == null ? null : _toggleFullScreen,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: videoController == null
                ? const Center(
                    child: Text(
                      'Nessun media caricato',
                      style: TextStyle(color: Colors.white),
                    ),
                  )
                : Video(controller: videoController, controls: NoVideoControls),
          ),
          if (_feedback != null)
            Positioned(
              top: 16,
              right: 16,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Text(
                      _feedback!,
                      key: const ValueKey('shortcut-feedback'),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    final theme = Theme.of(context);
    final controls = Container(
      key: const ValueKey('playback-toolbar'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.primary, width: 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          IconButton(
            tooltip: controller.isPlaying ? 'Pausa' : 'Riproduci',
            onPressed: controller.playOrPause,
            icon: Icon(controller.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          IconButton(
            tooltip: 'Stop',
            onPressed: controller.stop,
            icon: const Icon(Icons.stop),
          ),
          IconButton(
            tooltip: 'Elemento precedente',
            onPressed: controller.previous,
            icon: const Icon(Icons.skip_previous),
          ),
          Expanded(
            child: Slider(
              value: seekValue,
              min: 0,
              max: seekMax,
              label: _format(Duration(seconds: seekValue.round())),
              onChanged: (value) =>
                  controller.seek(Duration(seconds: value.round())),
            ),
          ),
          IconButton(
            tooltip: 'Elemento successivo',
            onPressed: controller.next,
            icon: const Icon(Icons.skip_next),
          ),
          IconButton(
            tooltip: 'Schermo intero',
            onPressed: _toggleFullScreen,
            icon: const Icon(Icons.fullscreen),
          ),
          IconButton(
            tooltip: controller.isMuted ? 'Attiva audio' : 'Disattiva audio',
            onPressed: controller.toggleMute,
            icon: Icon(controller.isMuted ? Icons.volume_off : Icons.volume_up),
          ),
          SizedBox(
            width: 164,
            child: Slider(
              value: controller.volume.clamp(0, 200).toDouble(),
              min: 0,
              max: 200,
              onChanged: controller.setVolume,
            ),
          ),
          Text(
            '${_format(controller.position)} / '
            '${_format(controller.duration)}',
          ),
        ],
      ),
    );
    final playerBody = _isFullScreen
        ? Stack(
            fit: StackFit.expand,
            children: [
              videoSurface,
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ClipRect(
                  child: AnimatedSlide(
                    offset: _controlsVisible
                        ? Offset.zero
                        : const Offset(0, 1.05),
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeIn,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: MouseRegion(
                        onEnter: (_) => _setControlsHovered(true),
                        onExit: (_) => _setControlsHovered(false),
                        child: controls,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          )
        : Column(
            children: [
              Expanded(child: videoSurface),
              controls,
            ],
          );

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _SeekIntent(
          Duration(seconds: -10),
        ),
        SingleActivator(LogicalKeyboardKey.arrowRight): _SeekIntent(
          Duration(seconds: 10),
        ),
        SingleActivator(LogicalKeyboardKey.arrowDown): _SeekIntent(
          Duration(minutes: -1),
        ),
        SingleActivator(LogicalKeyboardKey.arrowUp): _SeekIntent(
          Duration(minutes: 1),
        ),
        SingleActivator(LogicalKeyboardKey.pageDown): _SeekIntent(
          Duration(minutes: -10),
        ),
        SingleActivator(LogicalKeyboardKey.pageUp): _SeekIntent(
          Duration(minutes: 10),
        ),
        SingleActivator(LogicalKeyboardKey.comma): _PlayerActionIntent(
          _PlayerAction.frameBackStep,
        ),
        SingleActivator(LogicalKeyboardKey.period): _PlayerActionIntent(
          _PlayerAction.frameStep,
        ),
        SingleActivator(LogicalKeyboardKey.comma, shift: true):
            _PlayerActionIntent(_PlayerAction.previousItem),
        SingleActivator(LogicalKeyboardKey.period, shift: true):
            _PlayerActionIntent(_PlayerAction.nextItem),
        SingleActivator(LogicalKeyboardKey.keyF): _PlayerActionIntent(
          _PlayerAction.fullscreen,
        ),
        SingleActivator(LogicalKeyboardKey.keyS): _PlayerActionIntent(
          _PlayerAction.screenshot,
        ),
        SingleActivator(LogicalKeyboardKey.keyM): _PlayerActionIntent(
          _PlayerAction.mute,
        ),
        SingleActivator(LogicalKeyboardKey.keyK): _PlayerActionIntent(
          _PlayerAction.nextAudio,
        ),
        SingleActivator(LogicalKeyboardKey.keyK, shift: true):
            _PlayerActionIntent(_PlayerAction.previousAudio),
        SingleActivator(LogicalKeyboardKey.keyJ): _PlayerActionIntent(
          _PlayerAction.nextSubtitle,
        ),
        SingleActivator(LogicalKeyboardKey.keyJ, shift: true):
            _PlayerActionIntent(_PlayerAction.previousSubtitle),
        SingleActivator(LogicalKeyboardKey.digit9): _PlayerActionIntent(
          _PlayerAction.volumeDown,
        ),
        SingleActivator(LogicalKeyboardKey.digit0): _PlayerActionIntent(
          _PlayerAction.volumeUp,
        ),
        SingleActivator(LogicalKeyboardKey.keyZ): _PlayerActionIntent(
          _PlayerAction.subtitleDelayDown,
        ),
        SingleActivator(LogicalKeyboardKey.keyX): _PlayerActionIntent(
          _PlayerAction.subtitleDelayUp,
        ),
        SingleActivator(LogicalKeyboardKey.keyQ): _PlayerActionIntent(
          _PlayerAction.secondarySubtitleDelayDown,
        ),
        SingleActivator(LogicalKeyboardKey.keyW): _PlayerActionIntent(
          _PlayerAction.secondarySubtitleDelayUp,
        ),
        SingleActivator(LogicalKeyboardKey.keyR, control: true):
            _PlayerActionIntent(_PlayerAction.subtitleSizeUp),
        SingleActivator(LogicalKeyboardKey.keyT, control: true):
            _PlayerActionIntent(_PlayerAction.subtitleSizeDown),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => _runShortcut(
              controller.playOrPause,
              controller.isPlaying ? 'Pausa' : 'Riproduci',
            ),
          ),
          _SeekIntent: CallbackAction<_SeekIntent>(
            onInvoke: (intent) {
              final target = controller.position + intent.offset;
              final seconds = intent.offset.inSeconds;
              return _runShortcut(
                () =>
                    controller.seek(target.isNegative ? Duration.zero : target),
                'Salto ${seconds > 0 ? '+' : ''}$seconds s',
              );
            },
          ),
          _PlayerActionIntent: CallbackAction<_PlayerActionIntent>(
            onInvoke: (intent) {
              switch (intent.action) {
                case _PlayerAction.fullscreen:
                  _toggleFullScreen();
                  _showFeedback(
                    _isFullScreen ? 'Schermata intera' : 'Modalità finestra',
                  );
                  return null;
                case _PlayerAction.screenshot:
                  return _runShortcut(
                    () => controller.command(['screenshot', 'subtitles']),
                    'Schermata salvata',
                  );
                case _PlayerAction.mute:
                  return _runShortcut(
                    controller.toggleMute,
                    controller.isMuted ? 'Audio attivato' : 'Audio disattivato',
                  );
                case _PlayerAction.previousItem:
                  return _runShortcut(
                    controller.previous,
                    'Elemento precedente',
                  );
                case _PlayerAction.nextItem:
                  return _runShortcut(controller.next, 'Elemento successivo');
                case _PlayerAction.previousAudio:
                  return _runShortcut(
                    () => controller.command(['cycle', 'aid', 'down']),
                    'Traccia audio precedente',
                  );
                case _PlayerAction.nextAudio:
                  return _runShortcut(
                    () => controller.command(['cycle', 'aid']),
                    'Traccia audio successiva',
                  );
                case _PlayerAction.previousSubtitle:
                  return _runShortcut(
                    () => controller.command(['cycle', 'sid', 'down']),
                    'Traccia sottotitoli precedente',
                  );
                case _PlayerAction.nextSubtitle:
                  return _runShortcut(
                    () => controller.command(['cycle', 'sid']),
                    'Traccia sottotitoli successiva',
                  );
                case _PlayerAction.frameBackStep:
                  return _runShortcut(
                    () => controller.command(['frame-back-step']),
                    'Fotogramma precedente',
                  );
                case _PlayerAction.frameStep:
                  return _runShortcut(
                    () => controller.command(['frame-step']),
                    'Fotogramma successivo',
                  );
                case _PlayerAction.volumeDown:
                  final volume = (controller.volume - 5)
                      .clamp(0, 200)
                      .toDouble();
                  return _runShortcut(
                    () => controller.setVolume(volume),
                    'Volume ${volume.round()}%',
                  );
                case _PlayerAction.volumeUp:
                  final volume = (controller.volume + 5)
                      .clamp(0, 200)
                      .toDouble();
                  return _runShortcut(
                    () => controller.setVolume(volume),
                    'Volume ${volume.round()}%',
                  );
                case _PlayerAction.subtitleDelayDown:
                  return _adjustSubtitleDelay(controller, -1);
                case _PlayerAction.subtitleDelayUp:
                  return _adjustSubtitleDelay(controller, 1);
                case _PlayerAction.secondarySubtitleDelayDown:
                  return _adjustSubtitleDelay(controller, -1, secondary: true);
                case _PlayerAction.secondarySubtitleDelayUp:
                  return _adjustSubtitleDelay(controller, 1, secondary: true);
                case _PlayerAction.subtitleSizeDown:
                  return _runShortcut(
                    () => controller.command(['add', 'sub-scale', '-0.1']),
                    'Dimensione sottotitoli −10%',
                  );
                case _PlayerAction.subtitleSizeUp:
                  return _runShortcut(
                    () => controller.command(['add', 'sub-scale', '0.1']),
                    'Dimensione sottotitoli +10%',
                  );
              }
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: MenuAnchor(
              style: _rootMenuStyle,
              menuChildren: _contextMenu(context, ref, controller),
              builder: (context, menuController, child) => Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  if (event.kind != ui.PointerDeviceKind.touch &&
                      event.buttons == kSecondaryMouseButton) {
                    if (menuController.isOpen) menuController.close();
                    menuController.open(position: event.localPosition);
                  } else if (menuController.isOpen) {
                    menuController.close();
                  }
                },
                child: MouseRegion(
                  onHover: (_) => _revealControls(),
                  child: child,
                ),
              ),
              child: widget.enableDropTarget
                  ? DropTarget(
                      onDragDone: (details) {
                        if (details.files.isNotEmpty) {
                          controller.open(details.files.first.path);
                        }
                      },
                      child: playerBody,
                    )
                  : playerBody,
            ),
          ),
        ),
      ),
    );
  }
}

class _PositionedSubmenu extends StatefulWidget {
  const _PositionedSubmenu({
    required this.label,
    required this.menuChildren,
    this.onOpen,
  });

  final String label;
  final List<Widget> menuChildren;
  final VoidCallback? onOpen;

  @override
  State<_PositionedSubmenu> createState() => _PositionedSubmenuState();
}

class _PositionedSubmenuState extends State<_PositionedSubmenu> {
  final _triggerKey = GlobalKey();
  Offset? _pointerPosition;

  void _open(MenuController controller, Offset localPosition) {
    if (controller.isOpen) {
      return;
    }

    final renderObject = _triggerKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return;
    }

    final mediaQuery = MediaQuery.of(context);
    final clickY = renderObject.localToGlobal(localPosition).dy;
    final menuHeight =
        widget.menuChildren.length * _menuRowHeight + 2 * _menuSurfacePadding;
    final safeBottom =
        mediaQuery.size.height -
        mediaQuery.padding.bottom -
        mediaQuery.viewInsets.bottom;
    final opensFromLastItem =
        clickY + menuHeight - _menuSurfacePadding - _menuRowHeight / 2 >
        safeBottom;
    final itemIndex = opensFromLastItem && widget.menuChildren.isNotEmpty
        ? widget.menuChildren.length - 1
        : 0;
    final menuTop =
        localPosition.dy -
        _menuSurfacePadding -
        _menuRowHeight / 2 -
        itemIndex * _menuRowHeight;

    controller.open(
      position: Offset(renderObject.size.width + _submenuGap, menuTop),
    );
  }

  Offset _centerPosition() {
    final size = _triggerKey.currentContext?.size;
    return Offset(0, (size?.height ?? _menuRowHeight) / 2);
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: widget.menuChildren,
      style: _submenuMenuStyle,
      alignmentOffset: const Offset(_submenuGap, 0),
      onOpen: widget.onOpen,
      builder: (context, controller, child) => Listener(
        onPointerDown: (event) => _pointerPosition = event.localPosition,
        child: MouseRegion(
          onHover: (event) {
            _pointerPosition = event.localPosition;
            _open(controller, event.localPosition);
          },
          child: MenuItemButton(
            key: _triggerKey,
            closeOnActivate: false,
            style: _menuButtonStyle,
            onPressed: () =>
                _open(controller, _pointerPosition ?? _centerPosition()),
            trailingIcon: const Icon(Icons.arrow_right, size: 22),
            child: Text(widget.label),
          ),
        ),
      ),
    );
  }
}

class _SeekIntent extends Intent {
  const _SeekIntent(this.offset);

  final Duration offset;
}

enum _PlayerAction {
  fullscreen,
  screenshot,
  mute,
  previousItem,
  nextItem,
  previousAudio,
  nextAudio,
  previousSubtitle,
  nextSubtitle,
  frameBackStep,
  frameStep,
  volumeDown,
  volumeUp,
  subtitleDelayDown,
  subtitleDelayUp,
  secondarySubtitleDelayDown,
  secondarySubtitleDelayUp,
  subtitleSizeDown,
  subtitleSizeUp,
}

class _PlayerActionIntent extends Intent {
  const _PlayerActionIntent(this.action);

  final _PlayerAction action;
}
