import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/services/map_georeference.dart';

void main() {
  test('projects a control point near its mapped image position', () {
    // Pool control point → expected normalized image center ~ (0.4257, 0.3764).
    final p = MapGeoReference.instance.project(33.16675, -86.49314);
    expect(p, isNotNull);
    // Stylized map → allow the affine fit's residual (~0.04).
    expect((p!.dx - 0.4257).abs(), lessThan(0.06));
    expect((p.dy - 0.3764).abs(), lessThan(0.06));
  });

  test('returns null for a coordinate well outside the venue', () {
    expect(MapGeoReference.instance.project(40.0, -80.0), isNull);
  });
}
