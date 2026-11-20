# Architecture decisions

- 2026-11-19: EsyPlayer targets Windows and Linux only.
- 2026-11-19: media_kit/libmpv is the sole playback backend.
- 2026-11-19: Riverpod owns application services and state.
- 2026-11-19: Native mpv access is confined to `MpvBackend`; UI code uses
  `PlayerBackend`.
- 2026-11-19: Drift is used for recent files and resume data, while
  shared_preferences stores lightweight settings.
- 2026-11-19: English and Italian are shipped as the initial locales.
- 2026-11-19: All libmpv property, command, and observation access is exposed
  through `MpvBackend`; the UI has no direct `NativePlayer` dependency.
- 2026-11-19: Drift stores recent media, resume offsets, and playlist entries;
  shared_preferences remains reserved for lightweight preferences.
- 2026-11-20: `file_picker` 13.x uses `cross_file` 0.3.x; keep `desktop_drop`
  on 0.8.x because 0.9.x requires incompatible `cross_file` 0.4.x.
- 2026-11-20: Player commands are organized in nested menus opened by
  right-clicking the playback surface; settings are grouped by functional area.
  The player surface remains free of branding and app-bar command clutter.
- 2026-11-21: Subtitle styling is persisted through shared_preferences and
  applied through PlayerBackend. Primary subtitles default to the bottom and
  secondary subtitles to the top; per mpv's API, their font and color styling
  is shared, while position, scale, delay, visibility, and ASS override can be
  configured independently.
- 2026-11-21: Audio and subtitle track menus are populated from media_kit's
  available-track stream, keeping track discovery inside the playback backend
  and allowing external subtitle tracks to appear as mpv reports them.
- 2026-11-21: Use native libass subtitle rendering so mpv style preferences do
  not overlap media_kit's Flutter subtitle overlay. Disable media_kit's in-video
  controls and keep all playback controls in the persistent bottom toolbar.
- Context-menu submenus open beside the active menu, align the first entry to
  the trigger point, and flip to the free side at window bounds. Compact row
  styles reduce the footprint of every menu. The root menu uses local pointer
  coordinates.
- The recent-files submenu queries and displays at most six paths. Use
  `sub-ass-override=force` by default and apply ASS overrides before other
  subtitle properties so libass honors the selected border. Migrate the old
  default once for existing preferences; the reset action restores
  `AppSettings` defaults.
- Fullscreen can be toggled by double-clicking active video. Its bottom
  controls slide out after two seconds and return when the pointer moves.
- Apply persisted subtitle properties before loading media so libass has the
  selected border and ASS override when it initializes the subtitle track.
- Position nested menus from the pointer's local row coordinate, selecting the
  last entry instead when needed to keep an entry reachable near the bottom
  edge. Anchor fullscreen controls to the full-width bottom edge with only
  their intrinsic height before sliding them away.
- Set subtitle option values through mpv's `options/<name>` properties. Do not
  send the UI-only `sub-border-style` value directly: the distributed Windows
  bundle (`media_kit_libs_windows_video` 1.0.11) reports mpv
  `0.36.0-403-g652a1dd907`, which does not recognize that option, and
  `media_kit` does not surface the failed native set. Map the choice to ASS
  `BorderStyle` via `sub-ass-force-style` (mpv 0.36) and
  `sub-ass-style-overrides` (newer mpv). Keep the fullscreen toolbar opaque
  with a theme-colored border, and pause its hide timer while hovered.
- Shortcut feedback describes the action, appears over the video for two seconds, and
  is replaced by the next shortcut. Ctrl+R/T adjust the primary subtitle scale
  by 0.1 through the backend; these changes are not persisted as preferences.
  Outside clicks dismiss the context-menu chain, whose rows are 30 pixels high.
- Subtitle preferences use a centered preview and track selector fixed above a
  scrollable, grouped settings list. The preview scales with available dialog
  space, while switching tracks returns the settings list to its beginning.
- Z/X adjust primary subtitle delay; Q/W adjust the secondary delay, correcting
  the earlier interpretation. Queue these operations and read the corresponding
  mpv property for accumulated feedback, including changes made elsewhere.
  Menu delay actions use the same path. mpv 0.36 lacks independent secondary
  delay, so report it as unsupported instead of silently changing the primary.
- On Windows replace media_kit's bundled mpv 0.36 DLL at installation with
  the SHA-256-pinned, baseline x86-64 shinchiro mpv v0.42 build, preserving
  the remaining media_kit libraries. CI verifies both subtitle delays using
  the packaged DLL. Linux continues to use the system libmpv.
- Use window_manager 0.7 and nativeapi 0.6 with Flutter 3.50/Dart 3.14;
  nativeapi 0.5.10 uses an isolate API unavailable in the stable SDK.
- Pin the unmerged media_kit_video Linux EGL fix from media-kit/media-kit#1466
  until an upstream release includes it. Version 2.0.1 falls back to software
  rendering when Flutter's EGL context is not current on the platform thread.
  On a Raspberry Pi 5, the fix enables GPU rendering and HEVC DRM decoding;
  other codecs and graphics drivers may still require software fallback.
