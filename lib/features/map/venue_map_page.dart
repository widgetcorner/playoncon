import 'dart:async';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../../app_navigation.dart';
import '../../models/cart_position.dart';
import '../../models/event.dart';
import '../../models/venue_location.dart';
import '../../services/cart_positions_repository.dart';
import '../../services/location_service.dart';
import '../../services/locations_store.dart';
import '../../services/map_georeference.dart';
import '../../services/schedule_repository.dart';
import '../../theme/poc_theme.dart';
import 'venue_map_data.dart';

const _mapAsset = AssetImage('assets/images/venue-map.png');

/// Scale used by the "Detail" preset and the deep-link focus animation.
const double _kDetailScale = 2.0;

class VenueMapPage extends ConsumerWidget {
  const VenueMapPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locationsAsync = ref.watch(venueLocationsProvider);

    return Scaffold(
      body: locationsAsync.when(
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Venue Map')),
          body: const Center(child: CircularProgressIndicator()),
        ),
        error: (e, st) => Scaffold(
          appBar: AppBar(title: const Text('Venue Map')),
          body: Center(child: Text('Map unavailable: $e')),
        ),
        data: (locations) => _MapBody(locations: locations),
      ),
    );
  }
}

class _MapBody extends ConsumerStatefulWidget {
  final List<VenueLocation> locations;
  const _MapBody({required this.locations});

  @override
  ConsumerState<_MapBody> createState() => _MapBodyState();
}

class _MapBodyState extends ConsumerState<_MapBody>
    with SingleTickerProviderStateMixin {
  Size? _imageSize;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  bool _editing = false;
  late List<VenueLocation> _draft;
  String? _selectedKey; // editor-mode selection (hotspot being edited)

  // View-mode (Concept C) state.
  String? _selectedVenueKey; // pin whose info sheet is open
  bool _overview = false; // Overview ⇄ Detail zoom preset
  bool _didInitialFrame = false; // applied the Detail framing once

  // "Show on map" deep-link + zoom-preset animation share one controller.
  final TransformationController _transform = TransformationController();
  late final AnimationController _focusAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  Animation<Matrix4>? _focusTween;
  Size? _viewport;

  // Letterboxed base-image rect within the viewport (recomputed each layout).
  double _boardW = 0, _boardH = 0, _boardDx = 0, _boardDy = 0;
  // Cached label text metrics (constant font → measure once per name).
  final Map<String, Size> _labelSizeCache = {};

  // "You are here" blue dot.
  bool _locationOn = false;
  bool _pendingCenterOnLocation = false;
  bool _awaitingFirstFix = false; // just enabled; waiting on the first GPS fix

  @override
  void initState() {
    super.initState();
    _draft = List.of(widget.locations);
    _focusAnim.addListener(() {
      final t = _focusTween;
      if (t != null) _transform.value = t.value;
    });
    // Auto-enable the dot for users who already granted location, without
    // prompting anyone at launch.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final p = await Geolocator.checkPermission();
        if (mounted &&
            (p == LocationPermission.always ||
                p == LocationPermission.whileInUse)) {
          setState(() => _locationOn = true);
        }
      } catch (_) {
        // Plugin unavailable (e.g. tests) — ignore.
      }
    });
    _stream = _mapAsset.resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() {
        _imageSize =
            Size(info.image.width.toDouble(), info.image.height.toDouble());
      });
    }, onError: (e, _) {
      if (mounted) setState(() => _imageSize = const Size(1500, 1150));
    });
    _stream!.addListener(_listener!);
  }

  @override
  void didUpdateWidget(covariant _MapBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing) _draft = List.of(widget.locations);
  }

  @override
  void dispose() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _focusAnim.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// Handles a "Show on map" request: select that pin, drop to Detail, and
  /// center on it. No-op (silently) if the key isn't a known pin.
  void _focusOnHotspot(String key) {
    // Consume the request so the same hotspot can be re-targeted later.
    ref.read(mapFocusProvider.notifier).state = null;
    if (_editing) return;
    final loc = _locFor(key);
    if (loc == null) return;
    setState(() {
      _selectedVenueKey = key;
      _overview = false;
    });
    // Wait a frame so the Map tab has laid out (it may have been off-screen).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _animateToLocation(loc);
    });
  }

  VenueLocation? _locFor(String? key) {
    if (key == null) return null;
    for (final l in widget.locations) {
      if (l.key == key) return l;
    }
    return null;
  }

  void _animateToLocation(VenueLocation loc) {
    _animateToNormalized(
      loc.rect.x + loc.rect.w / 2,
      loc.rect.y + loc.rect.h / 2,
    );
  }

  /// Animates the viewer to center a normalized image point (nx, ny in 0..1)
  /// at [scale].
  void _animateToNormalized(double nx, double ny, {double scale = _kDetailScale}) {
    final m = _matrixForNormalized(nx, ny, scale);
    if (m != null) _animateToMatrix(m);
  }

  void _animateToMatrix(Matrix4 target) {
    _focusTween = Matrix4Tween(begin: _transform.value, end: target).animate(
      CurvedAnimation(parent: _focusAnim, curve: Curves.easeInOutCubic),
    );
    _focusAnim
      ..reset()
      ..forward();
  }

  /// Builds the transform that centers a normalized image point at [scale],
  /// clamped so the content still covers the viewport. Returns null before the
  /// first layout (viewport / image size unknown).
  Matrix4? _matrixForNormalized(double nx, double ny, double scale) {
    final viewport = _viewport;
    final imageSize = _imageSize;
    if (viewport == null || imageSize == null) return null;
    final vw = viewport.width;
    final vh = viewport.height;

    // Recompute the letterboxed image rect (same math as the build method).
    final imageRatio = imageSize.width / imageSize.height;
    final containerRatio = vw / vh;
    double w, h, dx, dy;
    if (containerRatio > imageRatio) {
      h = vh;
      w = h * imageRatio;
      dx = (vw - w) / 2;
      dy = 0;
    } else {
      w = vw;
      h = w / imageRatio;
      dx = 0;
      dy = (vh - h) / 2;
    }

    final cx = dx + nx * w;
    final cy = dy + ny * h;
    final tx = (vw / 2 - scale * cx).clamp(vw - scale * vw, 0.0).toDouble();
    final ty = (vh / 2 - scale * cy).clamp(vh - scale * vh, 0.0).toDouble();
    // viewport = scale * child + translation. Built directly to avoid the
    // deprecated Matrix4.translate/scale helpers.
    return Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);
  }

  /// Toggles the Overview ⇄ Detail zoom presets.
  void _toggleOverview() {
    final next = !_overview;
    setState(() => _overview = next);
    if (next) {
      // Overview = identity transform → whole letterboxed board fits.
      _animateToMatrix(Matrix4.identity());
    } else {
      final sel = _locFor(_selectedVenueKey);
      if (sel != null) {
        _animateToLocation(sel);
      } else {
        _animateToNormalized(0.4, 0.34); // re-center on the main camp
      }
    }
  }

  /// Selects a pin (opens its info sheet). If in Overview, drops to Detail and
  /// centers on it.
  void _selectVenue(VenueLocation loc) {
    setState(() {
      _selectedVenueKey = loc.key;
      _overview = false;
    });
    _animateToLocation(loc);
  }

  /// Computes the now/next status line for a venue from the live schedule.
  _VenueStatus? _statusFor(String key) {
    final now = DateTime.now();
    final events = ref
        .read(scheduleRepositoryProvider)
        .events
        .where((e) => e.locationKey == key)
        .toList();
    Event? current;
    Event? next;
    for (final e in events) {
      if (!e.startTime.isAfter(now) && e.endTime.isAfter(now)) {
        current = e;
      } else if (e.startTime.isAfter(now) &&
          _sameDay(e.startTime, now) &&
          (next == null || e.startTime.isBefore(next.startTime))) {
        next = e;
      }
    }
    if (current != null) return _VenueStatus.now(current.title);
    if (next != null) return _VenueStatus.next(next.startTime, next.title);
    return null;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _onLocatePressed() async {
    if (_locationOn) {
      // Already tracking → recenter on the current fix.
      final pos = ref.read(currentPositionProvider).value;
      if (pos == null) return;
      final p = MapGeoReference.instance.project(pos.latitude, pos.longitude);
      if (p != null) {
        if (_overview) setState(() => _overview = false);
        _animateToNormalized(p.dx, p.dy);
      } else {
        _snack('You appear to be outside the venue map.');
      }
      return;
    }
    final granted = await ensureLocationPermission();
    if (!mounted) return;
    if (!granted) {
      _snack('Location is off — enable it in Settings to see your position.');
      return;
    }
    setState(() {
      _locationOn = true;
      _pendingCenterOnLocation = true;
      _awaitingFirstFix = true;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _enterEdit() {
    setState(() {
      _editing = true;
      _draft = List.of(widget.locations);
      _selectedKey = null;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editing = false;
      _selectedKey = null;
      _draft = List.of(widget.locations);
    });
  }

  Future<void> _saveEdit() async {
    await ref.read(locationsStoreProvider).save(_draft);
    ref.invalidate(venueLocationsProvider);
    if (!mounted) return;
    setState(() {
      _editing = false;
      _selectedKey = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved hotspots to override file')),
    );
  }

  Future<void> _resetBundled() async {
    final ok = await _confirm(
      title: 'Reset to bundled hotspots?',
      message:
          'Deletes the on-device override and reloads the hotspots shipped in the asset.',
      confirmLabel: 'Reset',
      destructive: true,
    );
    if (!ok) return;
    await ref.read(locationsStoreProvider).reset();
    ref.invalidate(venueLocationsProvider);
    if (!mounted) return;
    setState(() {
      _editing = false;
      _selectedKey = null;
    });
  }

  Future<void> _copyJson() async {
    final json = LocationsStore.encode(_draft);
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Hotspot JSON copied to clipboard')),
    );
  }

  void _addHotspot() async {
    final result = await showDialog<({String key, String displayName})>(
      context: context,
      builder: (_) => const _NameDialog(
        initialKey: '',
        initialDisplayName: '',
        title: 'New hotspot',
      ),
    );
    if (result == null) return;
    if (_draft.any((l) => l.key == result.key)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Key "${result.key}" already exists')),
      );
      return;
    }
    setState(() {
      _draft.add(VenueLocation(
        key: result.key,
        displayName: result.displayName,
        rect: const NormalizedRect(x: 0.45, y: 0.45, w: 0.06, h: 0.06),
      ));
      _selectedKey = result.key;
    });
  }

  void _onHotspotTapped(VenueLocation loc) {
    // Editor-only: tap toggles which hotspot rect is selected for editing.
    // In view mode, pins are tapped via [_selectVenue] (opens the info sheet).
    setState(() => _selectedKey =
        _selectedKey == loc.key ? null : loc.key);
  }

  Future<void> _editHotspot(VenueLocation loc) async {
    final result = await showDialog<_HotspotEditAction>(
      context: context,
      builder: (_) => _HotspotEditSheet(location: loc),
    );
    if (result == null) return;
    switch (result.kind) {
      case _HotspotEditKind.rename:
        if (result.key == null || result.displayName == null) return;
        if (result.key != loc.key &&
            _draft.any((l) => l.key == result.key)) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Key "${result.key}" already exists')),
          );
          return;
        }
        setState(() {
          final i = _draft.indexWhere((l) => l.key == loc.key);
          if (i < 0) return;
          _draft[i] = _draft[i].copyWith(
            key: result.key,
            displayName: result.displayName,
          );
          _selectedKey = result.key;
        });
        break;
      case _HotspotEditKind.delete:
        setState(() {
          _draft.removeWhere((l) => l.key == loc.key);
          _selectedKey = null;
        });
        break;
    }
  }

  void _moveHotspot(VenueLocation loc, double dx, double dy, double w, double h) {
    setState(() {
      final i = _draft.indexWhere((l) => l.key == loc.key);
      if (i < 0) return;
      final old = _draft[i].rect;
      final newX = (old.x + dx / w).clamp(0.0, 1.0 - old.w);
      final newY = (old.y + dy / h).clamp(0.0, 1.0 - old.h);
      _draft[i] = _draft[i].copyWith(
        rect: old.copyWith(x: newX, y: newY),
      );
    });
  }

  void _resizeHotspot(VenueLocation loc, double dx, double dy, double w, double h) {
    setState(() {
      final i = _draft.indexWhere((l) => l.key == loc.key);
      if (i < 0) return;
      final old = _draft[i].rect;
      final newW = (old.w + dx / w).clamp(0.015, 1.0 - old.x);
      final newH = (old.h + dy / h).clamp(0.015, 1.0 - old.y);
      _draft[i] = _draft[i].copyWith(
        rect: old.copyWith(w: newW, h: newH),
      );
    });
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: destructive
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(ctx).colorScheme.error)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<MapFocusRequest?>(mapFocusProvider, (_, next) {
      if (next != null) _focusOnHotspot(next.locationKey);
    });

    if (_imageSize == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Venue Map')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final imageRatio = _imageSize!.width / _imageSize!.height;

    // "You are here" dot: only stream location once enabled (no launch prompt).
    Offset? dotNorm;
    if (_locationOn && !_editing) {
      final pos = ref.watch(currentPositionProvider).value;
      if (pos != null) {
        dotNorm = MapGeoReference.instance.project(pos.latitude, pos.longitude);
        if (dotNorm != null) {
          _awaitingFirstFix = false;
          if (_pendingCenterOnLocation) {
            _pendingCenterOnLocation = false;
            final d = dotNorm;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _animateToNormalized(d.dx, d.dy);
            });
          }
        } else if (_awaitingFirstFix) {
          // Got a fix, but it's beyond the map — they're not at the venue yet.
          _awaitingFirstFix = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _snack(
                'You\u2019re not at the venue yet — your location dot will '
                'appear on the map once you arrive.',
              );
            }
          });
        }
      }
    }

    // Selected pin + its live status drive the info sheet (view mode only).
    final selectedLoc = _editing ? null : _locFor(_selectedVenueKey);
    _VenueStatus? selectedStatus;
    if (selectedLoc != null) {
      ref.watch(scheduleRepositoryProvider); // rebuild when the schedule syncs
      selectedStatus = _statusFor(selectedLoc.key);
    }

    // Live golf-cart positions (empty map when Supabase isn't configured or in
    // editor mode — the cart layer never appears while editing hotspots).
    final carts = _editing
        ? const <String, CartPosition>{}
        : (ref.watch(cartPositionsProvider).valueOrNull ?? const {});

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit Hotspots' : 'Venue Map'),
        backgroundColor: _editing
            ? Theme.of(context).colorScheme.tertiaryContainer
            : null,
        foregroundColor: _editing
            ? Theme.of(context).colorScheme.onTertiaryContainer
            : null,
        leading: _editing
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Discard changes',
                onPressed: _cancelEdit,
              )
            : null,
        actions: _editing
            ? [
                IconButton(
                  icon: const Icon(Icons.add_location_alt_outlined),
                  tooltip: 'Add hotspot',
                  onPressed: _addHotspot,
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy JSON to clipboard',
                  onPressed: _copyJson,
                ),
                IconButton(
                  icon: const Icon(Icons.restart_alt),
                  tooltip: 'Reset to bundled',
                  onPressed: _resetBundled,
                ),
                IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: 'Save',
                  onPressed: _saveEdit,
                ),
              ]
            : (kDebugMode
                ? [
                    IconButton(
                      icon: const Icon(Icons.edit_location_alt_outlined),
                      tooltip: 'Edit hotspots',
                      onPressed: _enterEdit,
                    ),
                  ]
                : null),
      ),
      body: SafeArea(
        top: false,
        child: _editing
            ? Column(
                children: [
                  const _EditModeBanner(),
                  Expanded(child: _buildEditorBoard(imageRatio)),
                ],
              )
            : Stack(
                children: [
                  Positioned.fill(
                      child: _buildViewerBoard(imageRatio, dotNorm, carts)),
                  // Controls: Overview/Detail pill + recenter FAB (top-right).
                  Positioned(
                    top: 12,
                    right: 12,
                    child: _MapControls(
                      overview: _overview,
                      locationOn: _locationOn,
                      onToggleOverview: _toggleOverview,
                      onLocate: _onLocatePressed,
                    ),
                  ),
                  // Info sheet (bottom) when a pin is selected (Detail only).
                  if (selectedLoc != null && !_overview)
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 10,
                      child: _VenueInfoSheet(
                        location: selectedLoc,
                        meta: venueMetaFor(selectedLoc.key),
                        status: selectedStatus,
                        onClose: () =>
                            setState(() => _selectedVenueKey = null),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  void _captureLetterbox(double cw, double ch, double imageRatio) {
    _viewport = Size(cw, ch);
    final containerRatio = cw / ch;
    if (containerRatio > imageRatio) {
      _boardH = ch;
      _boardW = _boardH * imageRatio;
      _boardDx = (cw - _boardW) / 2;
      _boardDy = 0;
    } else {
      _boardW = cw;
      _boardH = _boardW / imageRatio;
      _boardDx = 0;
      _boardDy = (ch - _boardH) / 2;
    }
  }

  /// Editor board: base image + draggable hotspot rectangles, all inside the
  /// scaled InteractiveViewer (the debug calibration tool — unchanged design).
  Widget _buildEditorBoard(double imageRatio) {
    return InteractiveViewer(
      transformationController: _transform,
      maxScale: 6,
      minScale: 1.0,
      panEnabled: _selectedKey == null,
      child: LayoutBuilder(builder: (context, constraints) {
        _captureLetterbox(
            constraints.maxWidth, constraints.maxHeight, imageRatio);
        final w = _boardW, h = _boardH, dx = _boardDx, dy = _boardDy;
        return Stack(clipBehavior: Clip.none, children: [
          Positioned(
            left: dx,
            top: dy,
            width: w,
            height: h,
            child: const Image(image: _mapAsset, fit: BoxFit.fill),
          ),
          for (final loc in _draft)
            _HotspotWidget(
              location: loc,
              areaW: w,
              areaH: h,
              offsetX: dx,
              offsetY: dy,
              editing: true,
              selected: _selectedKey == loc.key,
              onTap: () => _onHotspotTapped(loc),
              onLongPress: () => _editHotspot(loc),
              onMove: (mx, my) => _moveHotspot(loc, mx, my, w, h),
              onResize: (rx, ry) => _resizeHotspot(loc, rx, ry, w, h),
            ),
        ]);
      }),
    );
  }

  /// View board (Apple-Maps style): only the base image pans/zooms inside the
  /// InteractiveViewer. Pins + labels live in a constant-size overlay that is
  /// re-projected from the live transform, with greedy label de-confliction so
  /// labels never stack on each other.
  Widget _buildViewerBoard(
    double imageRatio,
    Offset? dotNorm,
    Map<String, CartPosition> carts,
  ) {
    return LayoutBuilder(builder: (context, constraints) {
      final cw = constraints.maxWidth;
      final ch = constraints.maxHeight;
      _captureLetterbox(cw, ch, imageRatio);

      if (!_didInitialFrame) {
        _didInitialFrame = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final m = _matrixForNormalized(0.4, 0.34, _kDetailScale);
          if (m != null) _transform.value = m;
        });
      }

      return Stack(children: [
        InteractiveViewer(
          transformationController: _transform,
          maxScale: 3,
          minScale: 0.6,
          child: SizedBox(
            width: cw,
            height: ch,
            child: Stack(children: [
              Positioned(
                left: _boardDx,
                top: _boardDy,
                width: _boardW,
                height: _boardH,
                child: const Image(image: _mapAsset, fit: BoxFit.fill),
              ),
            ]),
          ),
        ),
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _transform,
            builder: (context, _) => _buildPinOverlay(cw, ch, dotNorm, carts),
          ),
        ),
      ]);
    });
  }

  /// Projects a normalized image point (0..1) to a screen offset using the
  /// current pan/zoom transform (pure scale + translate; no rotation).
  Offset _project(double nx, double ny) {
    final m = _transform.value.storage;
    final scale = m[0];
    final tx = m[12];
    final ty = m[13];
    final childX = _boardDx + nx * _boardW;
    final childY = _boardDy + ny * _boardH;
    return Offset(scale * childX + tx, scale * childY + ty);
  }

  static int _catRank(VenueCategory c) {
    switch (c) {
      case VenueCategory.stages:
        return 0;
      case VenueCategory.parties:
        return 1;
      case VenueCategory.gaming:
        return 2;
      case VenueCategory.stayEat:
        return 3;
      case VenueCategory.outdoors:
        return 4;
    }
  }

  Size _labelSize(String text) => _labelSizeCache.putIfAbsent(text, () {
        final tp = TextPainter(
          text: TextSpan(text: text, style: _kLabelTextStyle),
          maxLines: 1,
          textDirection: ui.TextDirection.ltr,
        )..layout();
        return Size(tp.width, tp.height);
      });

  Widget _buildPinOverlay(
    double cw,
    double ch,
    Offset? dotNorm,
    Map<String, CartPosition> carts,
  ) {
    const margin = 64.0;

    // Project + cull pins to those near the viewport.
    final placements = <_PinPlacement>[];
    for (final loc in widget.locations) {
      final meta = venueMetaFor(loc.key);
      final ncx = loc.rect.x + loc.rect.w / 2;
      final ncy = loc.rect.y + loc.rect.h / 2;
      final center = _project(ncx, ncy);
      if (center.dx < -margin ||
          center.dx > cw + margin ||
          center.dy < -margin ||
          center.dy > ch + margin) {
        continue;
      }
      placements.add(_PinPlacement(
        location: loc,
        meta: meta,
        color: categoryMetaFor(meta.category).color,
        center: center,
        labelLeft: ncx > 0.62,
        selected: _selectedVenueKey == loc.key,
      ));
    }

    // Reserve each pin's circle so labels don't cover other pins.
    final circleRects = <Rect>[
      for (final p in placements)
        Rect.fromCircle(center: p.center, radius: (p.selected ? 17 : 14) + 2),
    ];

    // Greedy label placement: selected first (forced), then by category rank /
    // walk time. A label shows only if it overlaps no placed label or other
    // pin. Overview hides all labels (pins collapse to plain dots).
    final visibleLabels = <String, Rect>{};
    if (!_overview) {
      final ordered = [...placements]..sort((a, b) {
          if (a.selected != b.selected) return a.selected ? -1 : 1;
          final r =
              _catRank(a.meta.category).compareTo(_catRank(b.meta.category));
          return r != 0 ? r : a.meta.walkMinutes.compareTo(b.meta.walkMinutes);
        });
      final placed = <Rect>[];
      for (final p in ordered) {
        final sz = _labelSize(p.location.displayName);
        final chipW = sz.width + 16;
        final chipH = sz.height + 8;
        final rad = p.selected ? 17.0 : 14.0;
        const gap = 5.0;
        final left = p.labelLeft
            ? p.center.dx - rad - gap - chipW
            : p.center.dx + rad + gap;
        final rect = Rect.fromLTWH(left, p.center.dy - chipH / 2, chipW, chipH);
        if (rect.right < 0 || rect.left > cw) continue;

        var collides = false;
        if (!p.selected) {
          for (final lr in placed) {
            if (rect.overlaps(lr)) {
              collides = true;
              break;
            }
          }
          if (!collides) {
            for (var i = 0; i < placements.length; i++) {
              if (placements[i].location.key != p.location.key &&
                  rect.overlaps(circleRects[i])) {
                collides = true;
                break;
              }
            }
          }
        }
        if (!collides) {
          visibleLabels[p.location.key] = rect;
          placed.add(rect);
        }
      }
    }

    // Build widgets with selected pin/label raised to the top.
    final lowerLabels = <Widget>[];
    final lowerPins = <Widget>[];
    Widget? selLabel;
    Widget? selPin;
    for (final p in placements) {
      final pinWidget = Positioned(
        left: p.center.dx - _PinIcon.hit / 2,
        top: p.center.dy - _PinIcon.hit / 2,
        child: _PinIcon(
          color: p.color,
          icon: p.meta.icon,
          selected: p.selected,
          onTap: () => _selectVenue(p.location),
        ),
      );
      Widget? labelWidget;
      final lr = visibleLabels[p.location.key];
      if (lr != null) {
        labelWidget = Positioned(
          left: lr.left,
          top: lr.top,
          child: IgnorePointer(
            child: _PinLabel(
              text: p.location.displayName,
              color: p.color,
              selected: p.selected,
            ),
          ),
        );
      }
      if (p.selected) {
        selPin = pinWidget;
        selLabel = labelWidget;
      } else {
        lowerPins.add(pinWidget);
        if (labelWidget != null) lowerLabels.add(labelWidget);
      }
    }

    final children = <Widget>[];
    if (dotNorm != null) {
      final c = _project(dotNorm.dx, dotNorm.dy);
      if (c.dx >= -margin &&
          c.dx <= cw + margin &&
          c.dy >= -margin &&
          c.dy <= ch + margin) {
        children.add(Positioned(
          left: c.dx - 20,
          top: c.dy - 20,
          width: 40,
          height: 40,
          child: const IgnorePointer(child: _LocationDot()),
        ));
      }
    }
    children
      ..addAll(lowerLabels)
      ..addAll(lowerPins);

    for (final cart in carts.values) {
      final norm = MapGeoReference.instance.project(cart.lat, cart.lng);
      if (norm == null) continue;
      final c = _project(norm.dx, norm.dy);
      if (c.dx < -margin ||
          c.dx > cw + margin ||
          c.dy < -margin ||
          c.dy > ch + margin) {
        continue;
      }
      children.add(Positioned(
        left: c.dx - 14,
        top: c.dy - 14,
        width: 28,
        height: 28,
        child: _CartMarker(cart: cart),
      ));
    }

    if (selLabel != null) children.add(selLabel);
    if (selPin != null) children.add(selPin);

    return Stack(clipBehavior: Clip.none, children: children);
  }
}

/// The blue "you are here" marker: a 15px filled dot with a white ring and a
/// pulsing translucent-blue halo (2s ease-out, infinite). The pulse is gated
/// behind reduced-motion (`MediaQuery.disableAnimations`).
class _LocationDot extends StatefulWidget {
  const _LocationDot();

  @override
  State<_LocationDot> createState() => _LocationDotState();
}

class _LocationDotState extends State<_LocationDot>
    with SingleTickerProviderStateMixin {
  static const _blue = Color(0xFF2B6CB0);

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!reduceMotion && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (reduceMotion && _pulse.isAnimating) {
      _pulse.stop();
    }

    final dot = Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _blue,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
    );

    if (reduceMotion) {
      return Center(child: dot);
    }

    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = Curves.easeOut.transform(_pulse.value);
              return Container(
                width: 15 + 25 * t,
                height: 15 + 25 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _blue.withValues(alpha: 0.30 * (1 - t)),
                ),
              );
            },
          ),
          dot,
        ],
      ),
    );
  }
}

/// Status line for a venue's info sheet, derived from the live schedule.
class _VenueStatus {
  final bool isNow;
  final DateTime? time; // start time when [isNow] is false
  final String title;
  const _VenueStatus.now(this.title)
      : isNow = true,
        time = null;
  const _VenueStatus.next(this.time, this.title) : isNow = false;
}

/// Resolved on-screen placement for one venue pin in the overlay.
class _PinPlacement {
  final VenueLocation location;
  final VenueMeta meta;
  final Color color;
  final Offset center; // screen-space pin center
  final bool labelLeft;
  final bool selected;
  const _PinPlacement({
    required this.location,
    required this.meta,
    required this.color,
    required this.center,
    required this.labelLeft,
    required this.selected,
  });
}

/// A category pin icon: a colored circle holding a white glyph. Constant
/// screen size (does not scale with map zoom); selected pins enlarge. The
/// label is rendered separately by the overlay so it can be de-conflicted.
class _PinIcon extends StatelessWidget {
  static const double hit = 44; // ≥44pt tap target (iOS HIG / small Android)

  final Color color;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _PinIcon({
    required this.color,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final circle = selected ? 34.0 : 28.0;
    final iconSize = selected ? 19.0 : 16.0;
    final borderWidth = selected ? 3.0 : 2.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: hit,
        height: hit,
        child: Center(
          child: Container(
            width: circle,
            height: circle,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(color: Colors.white, width: borderWidth),
              boxShadow: [
                BoxShadow(
                  color: const Color(0x593A2818), // rgba(58,40,24,0.35)
                  blurRadius: selected ? 8 : 3,
                  offset: Offset(0, selected ? 3 : 1),
                ),
              ],
            ),
            child: Icon(icon, size: iconSize, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Shared text style for pin labels — also used to measure label widths for
/// collision so the rendered chip matches the reserved rect.
const TextStyle _kLabelTextStyle =
    TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800);

class _PinLabel extends StatelessWidget {
  final String text;
  final Color color;
  final bool selected;
  const _PinLabel({
    required this.text,
    required this.color,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: selected ? color : Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: selected ? Colors.white : const Color(0x668E7E63),
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x1F3A2818), blurRadius: 2),
        ],
      ),
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: _kLabelTextStyle.copyWith(
          color: selected ? Colors.white : PocColors.ink,
        ),
      ),
    );
  }
}

/// Top-right stacked controls: the Overview/Detail pill and a forest circular
/// recenter FAB.
class _MapControls extends StatelessWidget {
  final bool overview;
  final bool locationOn;
  final VoidCallback onToggleOverview;
  final VoidCallback onLocate;

  const _MapControls({
    required this.overview,
    required this.locationOn,
    required this.onToggleOverview,
    required this.onLocate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          elevation: 3,
          shadowColor: const Color(0x593A2818),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onToggleOverview,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    overview ? Icons.zoom_in : Icons.zoom_out_map,
                    size: 16,
                    color: PocColors.saddleDark,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    overview ? 'Detail' : 'Overview',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: PocColors.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Material(
          color: PocColors.forest,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: const Color(0x593A2818),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onLocate,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                locationOn ? Icons.my_location : Icons.location_searching,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Bottom info card for the selected pin: identity row (icon · name · blurb),
/// then — when there's a current/next session — a divider and status line.
class _VenueInfoSheet extends StatelessWidget {
  final VenueLocation location;
  final VenueMeta meta;
  final _VenueStatus? status;
  final VoidCallback onClose;

  const _VenueInfoSheet({
    required this.location,
    required this.meta,
    required this.status,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cat = categoryMetaFor(meta.category);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 6,
      shadowColor: const Color(0x593A2818),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFC8B996)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cat.color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(meta.icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        location.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: PocColors.ink,
                        ),
                      ),
                      Text(
                        meta.blurb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: PocColors.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: PocColors.inkSoft,
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (status != null) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child:
                    Divider(height: 1, thickness: 1, color: Color(0xFFD8CBA8)),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: _StatusLine(status: status),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final _VenueStatus? status;
  const _StatusLine({required this.status});

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) {
      return const Text(
        'Open all weekend',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: PocColors.inkSoft,
        ),
      );
    }
    final label = s.isNow
        ? 'Now: ${s.title}'
        : '${DateFormat('h:mm a').format(s.time!)} · ${s.title}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (s.isNow)
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: PocColors.forest,
              boxShadow: [
                BoxShadow(
                  color: PocColors.forest.withValues(alpha: 0.18),
                  blurRadius: 0,
                  spreadRadius: 3,
                ),
              ],
            ),
          )
        else
          const Icon(Icons.schedule, size: 14, color: PocColors.saddleDark),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: s.isNow ? PocColors.forestDark : PocColors.inkSoft,
            ),
          ),
        ),
      ],
    );
  }
}

class _EditModeBanner extends StatelessWidget {
  const _EditModeBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: DefaultTextStyle(
        style: TextStyle(
          color: Theme.of(context).colorScheme.onTertiaryContainer,
          fontSize: 12,
        ),
        child: const Text(
          'Drag a hotspot to move it. Drag the corner to resize. '
          'Tap to select; long-press to rename or delete.',
        ),
      ),
    );
  }
}

class _HotspotWidget extends StatelessWidget {
  final VenueLocation location;
  final double areaW;
  final double areaH;
  final double offsetX;
  final double offsetY;
  final bool editing;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final void Function(double dx, double dy)? onMove;
  final void Function(double dx, double dy)? onResize;

  const _HotspotWidget({
    required this.location,
    required this.areaW,
    required this.areaH,
    required this.offsetX,
    required this.offsetY,
    required this.editing,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.onMove,
    this.onResize,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final left = offsetX + location.rect.x * areaW;
    final top = offsetY + location.rect.y * areaH;
    final width = location.rect.w * areaW;
    final height = location.rect.h * areaH;

    final fill = selected
        ? scheme.tertiary.withValues(alpha: 0.45)
        : scheme.tertiary.withValues(alpha: 0.22);
    final border =
        selected ? scheme.tertiary : scheme.tertiary.withValues(alpha: 0.7);
    final borderWidth = selected ? 3.0 : 2.0;

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        onPanUpdate: onMove == null
            ? null
            : (d) => onMove!(d.delta.dx, d.delta.dy),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Tooltip(
              message: location.displayName,
              preferBelow: false,
              child: Container(
                decoration: BoxDecoration(
                  shape: editing ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius:
                      editing ? BorderRadius.circular(4) : null,
                  color: fill,
                  border: Border.all(color: border, width: borderWidth),
                ),
                child: editing
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Text(
                            location.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 9,
                              color: scheme.onTertiaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
            ),
            if (editing && onResize != null)
              Positioned(
                right: -8,
                bottom: -8,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) => onResize!(d.delta.dx, d.delta.dy),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: scheme.tertiary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: const Icon(
                      Icons.open_in_full,
                      size: 10,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _HotspotEditKind { rename, delete }

class _HotspotEditAction {
  final _HotspotEditKind kind;
  final String? key;
  final String? displayName;
  const _HotspotEditAction.rename(this.key, this.displayName)
      : kind = _HotspotEditKind.rename;
  const _HotspotEditAction.delete()
      : kind = _HotspotEditKind.delete,
        key = null,
        displayName = null;
}

class _HotspotEditSheet extends StatefulWidget {
  final VenueLocation location;
  const _HotspotEditSheet({required this.location});

  @override
  State<_HotspotEditSheet> createState() => _HotspotEditSheetState();
}

class _HotspotEditSheetState extends State<_HotspotEditSheet> {
  late final TextEditingController _key;
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: widget.location.key);
    _name = TextEditingController(text: widget.location.displayName);
  }

  @override
  void dispose() {
    _key.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit hotspot'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _key,
            decoration: const InputDecoration(
              labelText: 'Key (slug, used to match events)',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Display name (matches the sheet venue text)',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(
            context,
            const _HotspotEditAction.delete(),
          ),
          child: const Text('Delete'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final k = _key.text.trim();
            final n = _name.text.trim();
            if (k.isEmpty || n.isEmpty) return;
            Navigator.pop(context, _HotspotEditAction.rename(k, n));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  final String initialKey;
  final String initialDisplayName;
  final String title;
  const _NameDialog({
    required this.initialKey,
    required this.initialDisplayName,
    required this.title,
  });

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _key;
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: widget.initialKey);
    _name = TextEditingController(text: widget.initialDisplayName);
    _name.addListener(_autoSlug);
  }

  void _autoSlug() {
    if (_key.text.isEmpty) {
      final slug = _name.text
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-|-$'), '');
      _key.value = TextEditingValue(text: slug);
    }
  }

  @override
  void dispose() {
    _name.removeListener(_autoSlug);
    _key.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Display name (matches the sheet venue text)',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            decoration: const InputDecoration(
              labelText: 'Key (slug, used to match events)',
              helperText: 'Auto-generated; edit if needed',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final k = _key.text.trim();
            final n = _name.text.trim();
            if (k.isEmpty || n.isEmpty) return;
            Navigator.pop(context, (key: k, displayName: n));
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Live golf-cart marker on the venue map. Distinct from venue category pins
/// (color + glyph) and from the blue "you are here" dot. Tapping/long-pressing
/// reveals the cart name + driver, when known.
class _CartMarker extends StatelessWidget {
  final CartPosition cart;
  const _CartMarker({required this.cart});

  @override
  Widget build(BuildContext context) {
    final label = cart.displayName ?? 'Cart';
    final tip = cart.driverName == null || cart.driverName!.isEmpty
        ? label
        : '$label — ${cart.driverName}';
    return Tooltip(
      message: tip,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFFFC107),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: const Center(
          child: Icon(
            Icons.electric_rickshaw,
            size: 16,
            color: Color(0xFF2E4E2E),
          ),
        ),
      ),
    );
  }
}
