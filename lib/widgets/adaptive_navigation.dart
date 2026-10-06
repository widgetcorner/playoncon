import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/apple_layout.dart';
import 'apple_layout_boundary.dart';

/// Uses the scene's native bar preference, never a device or width guess.
/// The content stays in the same element slot when navigation changes edges.
class AdaptiveNavigationScaffold extends StatelessWidget {
  const AdaptiveNavigationScaffold({
    super.key,
    required this.barEdge,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.pages,
  });

  final AppleBarEdge barEdge;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<Widget> pages;

  @override
  Widget build(BuildContext context) {
    final vertical =
        barEdge == AppleBarEdge.left || barEdge == AppleBarEdge.right;
    return Scaffold(
      body: SafeArea(
        top: false,
        bottom: vertical,
        // The rail owns this strip, including its existing safe-area width.
        left: barEdge != AppleBarEdge.left,
        right: barEdge != AppleBarEdge.right,
        child: Row(
          // Native left/right are physical edges, including in RTL locales.
          textDirection: TextDirection.ltr,
          children: [
            if (barEdge == AppleBarEdge.left)
              Builder(builder: _rail)
            else
              const SizedBox.shrink(),
            Expanded(
              key: const ValueKey('destinations'),
              child: Builder(
                builder: (context) => MediaQuery.removePadding(
                  context: context,
                  // Opposite-edge padding is consumed by the outer SafeArea;
                  // the rail itself clears the content on its physical side.
                  removeLeft: true,
                  removeRight: true,
                  removeBottom: vertical,
                  child: IndexedStack(index: selectedIndex, children: pages),
                ),
              ),
            ),
            if (barEdge == AppleBarEdge.right)
              Builder(builder: _rail)
            else
              const SizedBox.shrink(),
          ],
        ),
      ),
      // An available signal with no vertical edge deliberately uses this bar.
      // Older iOS and Android retain the existing bottom-navigation fallback.
      bottomNavigationBar: vertical
          ? null
          : NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.calendar_month),
                  label: 'Schedule',
                ),
                NavigationDestination(icon: Icon(Icons.map), label: 'Map'),
                NavigationDestination(
                  icon: Icon(Icons.info_outline),
                  label: 'Info',
                ),
              ],
            ),
    );
  }

  Widget _rail(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final largeText = media.textScaler.scale(12) > 20;
    final width = math.max(
      largeText ? 72.0 : 88.0,
      barEdge == AppleBarEdge.left ? media.padding.left : media.padding.right,
    );
    final reserved = AppleReservedRegions.maybeOf(context);
    final regions = [...?reserved?.occlusions, ...?reserved?.divisions];
    final viewSize = reserved?.viewSize ?? media.size;
    final rail = NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      groupAlignment: 1,
      scrollable: true,
      minWidth: width,
      // At accessibility sizes the standard rail supplies tooltips and full
      // semantic labels without using most of a narrow window for its width.
      labelType: largeText
          ? NavigationRailLabelType.none
          : NavigationRailLabelType.all,
      backgroundColor: theme.navigationBarTheme.backgroundColor,
      indicatorColor: theme.navigationBarTheme.indicatorColor,
      selectedLabelTextStyle: theme.navigationBarTheme.labelTextStyle?.resolve({
        WidgetState.selected,
      }),
      unselectedLabelTextStyle: theme.navigationBarTheme.labelTextStyle
          ?.resolve({}),
      selectedIconTheme: theme.navigationBarTheme.iconTheme?.resolve({
        WidgetState.selected,
      }),
      unselectedIconTheme: theme.navigationBarTheme.iconTheme?.resolve({}),
      destinations: const [
        NavigationRailDestination(
          icon: Icon(Icons.calendar_month),
          label: Text('Schedule'),
        ),
        NavigationRailDestination(icon: Icon(Icons.map), label: Text('Map')),
        NavigationRailDestination(
          icon: Icon(Icons.info_outline),
          label: Text('Info'),
        ),
      ],
    );
    return SizedBox(
      width: width,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          final left = barEdge == AppleBarEdge.left
              ? 0.0
              : viewSize.width - width;
          final strip = Rect.fromLTWH(left, 0, width, height);
          var gaps = [
            Rect.fromLTRB(
              left,
              math.min(media.padding.top, height),
              left + width,
              height,
            ),
          ];
          for (final region in regions) {
            if (region.right <= strip.left ||
                region.left >= strip.right ||
                region.bottom < strip.top ||
                region.top > strip.bottom) {
              continue;
            }
            gaps = [
              for (final gap in gaps)
                if (region.bottom <= gap.top || region.top >= gap.bottom)
                  gap
                else ...[
                  if (region.top > gap.top)
                    Rect.fromLTRB(gap.left, gap.top, gap.right, region.top),
                  if (region.bottom < gap.bottom)
                    Rect.fromLTRB(
                      gap.left,
                      region.bottom,
                      gap.right,
                      gap.bottom,
                    ),
                ],
            ];
          }
          if (gaps.isEmpty) return const SizedBox.shrink();
          final usable = gaps.reduce((a, b) => b.height >= a.height ? b : a);
          if (usable.height <= 16) return const SizedBox.shrink();
          return Padding(
            padding: EdgeInsets.only(
              top: usable.top,
              bottom: height - usable.bottom,
            ),
            child: MediaQuery.removePadding(
              context: context,
              removeLeft: true,
              removeTop: true,
              removeRight: true,
              removeBottom: true,
              child: rail,
            ),
          );
        },
      ),
    );
  }
}
