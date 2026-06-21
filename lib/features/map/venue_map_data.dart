// ─────────────────────────────────────────────────────────────────────────
// Play On Con — Map view ("Concept C") data, Dart.
// Everything the redrawn venue map needs, beyond what's already in your repo.
//
// Two implementation paths (see design README §"Pick a base"):
//   PATH A — keep assets/images/venue-map.png. Use the pin POSITIONS already
//            in assets/data/locations.json (rect center). The Map view uses
//            kCategoryMeta + kVenueMeta below. ← this app ships PATH A.
//   PATH B — redraw the base with a CustomPainter. Then also use kVenueLayout
//            (normalized positions for the redrawn base) + kZoneLabels.
// ─────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';

enum VenueCategory { stages, gaming, parties, outdoors, stayEat }

class VenueCategoryMeta {
  final String label;
  final Color color;
  final IconData icon;
  const VenueCategoryMeta(this.label, this.color, this.icon);
}

const Map<VenueCategory, VenueCategoryMeta> kCategoryMeta = {
  VenueCategory.stages:   VenueCategoryMeta('Stages',     Color(0xFF2D5E3E), Icons.theater_comedy),
  VenueCategory.gaming:   VenueCategoryMeta('Gaming',     Color(0xFF8B6F47), Icons.casino),
  VenueCategory.parties:  VenueCategoryMeta('Parties',    Color(0xFFB46A3F), Icons.celebration),
  VenueCategory.outdoors: VenueCategoryMeta('Outdoors',   Color(0xFF5E7D3A), Icons.park),
  VenueCategory.stayEat:  VenueCategoryMeta('Stay & Eat', Color(0xFF6B5232), Icons.restaurant),
};

class VenueMeta {
  final VenueCategory category;
  final IconData icon;     // specific glyph (overrides category default)
  final int walkMinutes;   // rough estimate; tune on-site
  final String blurb;
  const VenueMeta(this.category, this.icon, this.walkMinutes, this.blurb);
}

/// Keyed by the SAME `key` used in assets/data/locations.json.
/// Unlisted keys default to [kDefaultVenueMeta] (outdoors, Icons.place).
const Map<String, VenueMeta> kVenueMeta = {
  'theater':          VenueMeta(VenueCategory.stages,   Icons.theater_comedy,        1, 'Main stage & ceremonies'),
  'chapel':           VenueMeta(VenueCategory.stages,   Icons.church,                4, 'Quiet gatherings'),
  'gaming':           VenueMeta(VenueCategory.gaming,   Icons.casino,                3, 'Open gaming & RPG rooms'),
  'mayfield':         VenueMeta(VenueCategory.parties,  Icons.celebration,           4, 'Dance floor & nightly parties'),
  'cafeteria':        VenueMeta(VenueCategory.stayEat,  Icons.restaurant,            2, 'Cafeteria & dining hall'), // "Lodge"
  'hotel-rooms':      VenueMeta(VenueCategory.stayEat,  Icons.hotel,                 5, 'Lodging'),
  'morrison-dorm':    VenueMeta(VenueCategory.stayEat,  Icons.bed,                   5, 'Lodging'),
  'alfa-dorm':        VenueMeta(VenueCategory.stayEat,  Icons.bed,                   5, 'Lodging'),
  'cottages':         VenueMeta(VenueCategory.stayEat,  Icons.cabin,                 7, 'Lodging cabins'),
  'food-truck':       VenueMeta(VenueCategory.stayEat,  Icons.lunch_dining,          2, 'Snacks & cold drinks'),
  'pool':             VenueMeta(VenueCategory.outdoors, Icons.pool,                  3, 'Swim & splash'),
  'fire-pit':         VenueMeta(VenueCategory.outdoors, Icons.local_fire_department, 3, "S'mores & campfire"),
  'dock-canoes':      VenueMeta(VenueCategory.outdoors, Icons.rowing,                4, 'Lakefront & boats'),
  'picnic-tables':    VenueMeta(VenueCategory.outdoors, Icons.deck,                  3, 'Picnic tables & Lower Mayfield'),
  'recreation-field': VenueMeta(VenueCategory.outdoors, Icons.sports_handball,       5, 'Lawn games & foam combat'),
  'sand-volleyball':  VenueMeta(VenueCategory.outdoors, Icons.sports_volleyball,     6, 'Courts by the field'),
  'archery':          VenueMeta(VenueCategory.outdoors, Icons.adjust,                6, 'Range & lessons'),
  'mini-golf':        VenueMeta(VenueCategory.outdoors, Icons.golf_course,           5, '18 holes by the field'),
  'climbing-wall':    VenueMeta(VenueCategory.outdoors, Icons.terrain,               7, 'Belayed climbs'),
};

/// Fallback for any hotspot key not present in [kVenueMeta].
const VenueMeta kDefaultVenueMeta =
    VenueMeta(VenueCategory.outdoors, Icons.place, 5, 'Around the camp');

/// Resolves the metadata for a hotspot key, falling back gracefully.
VenueMeta venueMetaFor(String key) => kVenueMeta[key] ?? kDefaultVenueMeta;

VenueCategoryMeta categoryMetaFor(VenueCategory c) => kCategoryMeta[c]!;

// ─────────────────────────────────────────────────────────────────────────
// PATH B ONLY — normalized positions (0–1) for the REDRAWN base.
// Unused by the shipped Path A map; kept for a future vector-base option.
// Coordinate space: a 560 x 500 unit board (x * 560, y * 500).
// ─────────────────────────────────────────────────────────────────────────
class VenuePos { final double nx, ny; const VenuePos(this.nx, this.ny); }

const Map<String, VenuePos> kVenueLayout = {
  'fire-pit':         VenuePos(0.446, 0.088),
  'dock-canoes':      VenuePos(0.677, 0.263),
  'hotel-rooms':      VenuePos(0.308, 0.213),
  'theater':          VenuePos(0.400, 0.275),
  'cafeteria':        VenuePos(0.200, 0.338), // Lodge
  'gaming':           VenuePos(0.077, 0.525),
  'pool':             VenuePos(0.585, 0.400),
  'picnic-tables':    VenuePos(0.615, 0.463), // Canopy
  'mayfield':         VenuePos(0.585, 0.513),
  'food-truck':       VenuePos(0.123, 0.563),
  'chapel':           VenuePos(0.400, 0.613),
  'recreation-field': VenuePos(0.815, 0.363),
  'sand-volleyball':  VenuePos(0.908, 0.388),
  'archery':          VenuePos(0.969, 0.313),
  'mini-golf':        VenuePos(0.831, 0.463),
  'climbing-wall':    VenuePos(0.846, 0.663),
  'cottages':         VenuePos(0.538, 0.713),
};

const VenuePos kYouAreHereDemo = VenuePos(0.50, 0.33); // between Theater & Pool

/// Zone captions for the redrawn base (faint labels). Position is normalized.
const List<(String, double, double)> kZoneLabels = [
  ('MAIN CAMP',     0.10, 0.45),
  ('GAMING & EATS', 0.04, 0.60),
  ('REC & SPORTS',  0.74, 0.27),
  ('THE COMMONS',   0.34, 0.67),
  ('CABINS',        0.43, 0.78),
];
