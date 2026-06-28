import 'dart:ui' show Offset;

class _ControlPoint {
  final double lat;
  final double lng;
  final double x; // normalized image x (0..1)
  final double y; // normalized image y (0..1)
  const _ControlPoint(this.lat, this.lng, this.x, this.y);
}

/// Maps GPS (lat/lng) to normalized venue-map-image coordinates (0..1) via an
/// affine transform least-squares–fit to surveyed control points.
///
/// The venue map is a stylized drawing, so the dot is approximate (~4% of the
/// map size at the fitted points for the current set). To recalibrate or add
/// points, edit [_points] — the fit recomputes automatically. Use landmarks
/// that already have an accurate hotspot in `assets/data/locations.json` (the
/// x/y here are those hotspot rect centers) and spread them toward the edges.
class MapGeoReference {
  MapGeoReference._(this._x, this._y);

  // Coefficients [coefLng, coefLat, const] for x and y respectively.
  final List<double> _x;
  final List<double> _y;

  static final MapGeoReference instance = _fit();

  static const _points = <_ControlPoint>[
    _ControlPoint(33.16675, -86.49314, 0.5514, 0.3808), // Pool (center)
    _ControlPoint(33.16757, -86.49599, 0.0692, 0.5615), // Main Gaming (NW)
    _ControlPoint(33.16742, -86.49389, 0.3911, 0.3557), // Theater (N-center)
    _ControlPoint(33.16710, -86.49193, 0.6674, 0.2098), // Dock & Canoes (E)
    _ControlPoint(33.16556, -86.49074, 0.8964, 0.2822), // Sand Volleyball (SE)
  ];

  /// Projects a GPS coordinate to normalized image coords, or null when the
  /// point is outside the map (beyond a small margin) — i.e. not at the venue.
  Offset? project(double lat, double lng) {
    final px = _x[0] * lng + _x[1] * lat + _x[2];
    final py = _y[0] * lng + _y[1] * lat + _y[2];
    const margin = 0.06;
    if (px < -margin || px > 1 + margin || py < -margin || py > 1 + margin) {
      return null;
    }
    return Offset(px.clamp(0.0, 1.0), py.clamp(0.0, 1.0));
  }

  static MapGeoReference _fit() {
    List<double> solve(double Function(_ControlPoint) target) {
      // Normal equations (AᵀA)·θ = Aᵀb for design rows [lng, lat, 1].
      final ata = List.generate(3, (_) => List.filled(3, 0.0));
      final atb = List.filled(3, 0.0);
      for (final p in _points) {
        final row = [p.lng, p.lat, 1.0];
        final t = target(p);
        for (var i = 0; i < 3; i++) {
          atb[i] += row[i] * t;
          for (var j = 0; j < 3; j++) {
            ata[i][j] += row[i] * row[j];
          }
        }
      }
      // Gaussian elimination on the augmented 3x4 matrix.
      final m = [for (var i = 0; i < 3; i++) [...ata[i], atb[i]]];
      for (var i = 0; i < 3; i++) {
        final piv = m[i][i];
        for (var j = i + 1; j < 3; j++) {
          final f = m[j][i] / piv;
          for (var c = i; c < 4; c++) {
            m[j][c] -= f * m[i][c];
          }
        }
      }
      final sol = List.filled(3, 0.0);
      for (var i = 2; i >= 0; i--) {
        var s = m[i][3];
        for (var j = i + 1; j < 3; j++) {
          s -= m[i][j] * sol[j];
        }
        sol[i] = s / m[i][i];
      }
      return sol;
    }

    return MapGeoReference._(solve((p) => p.x), solve((p) => p.y));
  }
}
