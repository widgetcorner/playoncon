// ─────────────────────────────────────────────────────────────────────────
// Play On Con — Map view ("Concept C") data, Dart.
// Category and per-venue metadata for the pins drawn over
// assets/images/venue-map.png. Pin POSITIONS are not here: they come from
// assets/data/locations.json (rect center).
// ─────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';

enum VenueCategory { stages, gaming, parties, outdoors, stayEat }

class VenueCategoryMeta {
  final String label;
  final Color color;
  final Color darkColor; // one step lighter, for the dark map ground
  final IconData icon;
  const VenueCategoryMeta(this.label, this.color, this.darkColor, this.icon);

  Color colorFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkColor : color;
}

const Map<VenueCategory, VenueCategoryMeta> kCategoryMeta = {
  VenueCategory.stages:   VenueCategoryMeta('Stages',     Color(0xFF2D5E3E), Color(0xFF3E7A52), Icons.theater_comedy),
  VenueCategory.gaming:   VenueCategoryMeta('Gaming',     Color(0xFF8B6F47), Color(0xFFA08454), Icons.casino),
  VenueCategory.parties:  VenueCategoryMeta('Parties',    Color(0xFFB46A3F), Color(0xFFC97F52), Icons.celebration),
  VenueCategory.outdoors: VenueCategoryMeta('Outdoors',   Color(0xFF5E7D3A), Color(0xFF7A9A52), Icons.park),
  VenueCategory.stayEat:  VenueCategoryMeta('Stay & Eat', Color(0xFF6B5232), Color(0xFF8A6E48), Icons.restaurant),
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
