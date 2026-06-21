import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app_navigation.dart';
import '../../models/event.dart';
import '../../models/venue_location.dart';
import '../../services/locations_store.dart';
import '../../services/schedule_repository.dart';

const _mapAsset = AssetImage('assets/images/venue-map.png');

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
  String? _selectedKey;

  // "Show on map" deep-link support.
  final TransformationController _transform = TransformationController();
  late final AnimationController _focusAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );
  Animation<Matrix4>? _focusTween;
  Size? _viewport;
  String? _highlightKey;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _draft = List.of(widget.locations);
    _focusAnim.addListener(() {
      final t = _focusTween;
      if (t != null) _transform.value = t.value;
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
    _highlightTimer?.cancel();
    _focusAnim.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// Handles a "Show on map" request: pan/zoom to the hotspot and pulse a
  /// highlight on it. No-op (silently) if the key isn't a known pin.
  void _focusOnHotspot(String key) {
    // Consume the request so the same hotspot can be re-targeted later.
    ref.read(mapFocusProvider.notifier).state = null;
    if (_editing) return;
    VenueLocation? loc;
    for (final l in widget.locations) {
      if (l.key == key) {
        loc = l;
        break;
      }
    }
    if (loc == null) return;
    final target = loc;
    _highlightTimer?.cancel();
    setState(() => _highlightKey = key);
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightKey = null);
    });
    // Wait a frame so the Map tab has laid out (it may have been off-screen).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _animateTo(target);
    });
  }

  void _animateTo(VenueLocation loc) {
    final viewport = _viewport;
    final imageSize = _imageSize;
    if (viewport == null || imageSize == null) return;
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

    const scale = 2.5;
    final cx = dx + (loc.rect.x + loc.rect.w / 2) * w;
    final cy = dy + (loc.rect.y + loc.rect.h / 2) * h;
    // Center the hotspot, then clamp so the content still covers the viewport.
    final tx = (vw / 2 - scale * cx).clamp(vw - scale * vw, 0.0).toDouble();
    final ty = (vh / 2 - scale * cy).clamp(vh - scale * vh, 0.0).toDouble();
    // viewport = scale * child + translation. Built directly to avoid the
    // deprecated Matrix4.translate/scale helpers.
    final target = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);

    _focusTween = Matrix4Tween(begin: _transform.value, end: target).animate(
      CurvedAnimation(parent: _focusAnim, curve: Curves.easeInOutCubic),
    );
    _focusAnim
      ..reset()
      ..forward();
  }

  List<VenueLocation> get _activeLocations =>
      _editing ? _draft : widget.locations;

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
    if (!_editing) {
      _showEventsForLocation(loc);
      return;
    }
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

  void _showEventsForLocation(VenueLocation loc) {
    final all = ref.read(scheduleRepositoryProvider).events;
    final atLoc = all.where((e) => e.locationKey == loc.key).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    showModalBottomSheet(
      context: context,
      builder: (_) => _LocationEventsSheet(location: loc, events: atLoc),
    );
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
      body: Column(
        children: [
          if (_editing) const _EditModeBanner(),
          Expanded(
            child: InteractiveViewer(
              transformationController: _transform,
              maxScale: 6,
              minScale: 1.0,
              panEnabled: !_editing || _selectedKey == null,
              child: LayoutBuilder(builder: (context, constraints) {
                final cw = constraints.maxWidth;
                final ch = constraints.maxHeight;
                _viewport = Size(cw, ch);
                final containerRatio = cw / ch;

                double w, h, dx, dy;
                if (containerRatio > imageRatio) {
                  h = ch;
                  w = h * imageRatio;
                  dx = (cw - w) / 2;
                  dy = 0;
                } else {
                  w = cw;
                  h = w / imageRatio;
                  dx = 0;
                  dy = (ch - h) / 2;
                }

                return Stack(children: [
                  Positioned(
                    left: dx,
                    top: dy,
                    width: w,
                    height: h,
                    child: const Image(image: _mapAsset, fit: BoxFit.fill),
                  ),
                  for (final loc in _activeLocations)
                    _HotspotWidget(
                      location: loc,
                      areaW: w,
                      areaH: h,
                      offsetX: dx,
                      offsetY: dy,
                      editing: _editing,
                      selected: _editing && _selectedKey == loc.key,
                      highlighted: !_editing && _highlightKey == loc.key,
                      onTap: () => _onHotspotTapped(loc),
                      onLongPress:
                          _editing ? () => _editHotspot(loc) : null,
                      onMove: _editing
                          ? (mx, my) => _moveHotspot(loc, mx, my, w, h)
                          : null,
                      onResize: _editing
                          ? (rx, ry) => _resizeHotspot(loc, rx, ry, w, h)
                          : null,
                    ),
                ]);
              }),
            ),
          ),
        ],
      ),
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
  final bool highlighted;
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
    this.highlighted = false,
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

    final fill = editing
        ? (selected
            ? scheme.tertiary.withValues(alpha: 0.45)
            : scheme.tertiary.withValues(alpha: 0.22))
        : (highlighted
            ? scheme.primary.withValues(alpha: 0.40)
            : const Color(0xFF2D5E3E).withValues(alpha: 0.22));
    final border = editing
        ? (selected ? scheme.tertiary : scheme.tertiary.withValues(alpha: 0.7))
        : (highlighted
            ? scheme.primary
            : const Color(0xFF2D5E3E).withValues(alpha: 0.85));
    final borderWidth = (selected || highlighted) ? 3.0 : 2.0;

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

class _LocationEventsSheet extends StatelessWidget {
  final VenueLocation location;
  final List<Event> events;
  const _LocationEventsSheet({required this.location, required this.events});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('EEE h:mm a');
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(location.displayName,
                style: Theme.of(context).textTheme.titleLarge),
          ),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Text('No events scheduled here yet.'),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: events.length,
                separatorBuilder: (ctx, i) => const Divider(height: 1),
                itemBuilder: (_, i) => ListTile(
                  title: Text(events[i].title),
                  subtitle: Text(fmt.format(events[i].startTime)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
