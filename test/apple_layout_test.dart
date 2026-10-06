import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/services/apple_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'supported horizontal placement is distinct from an unavailable API',
    () {
      expect(
        AppleLayout.fromMessage({'barEdge': 'none'}).barEdge,
        AppleBarEdge.none,
      );
      expect(AppleLayout.fromMessage(null).barEdge, AppleBarEdge.unavailable);
      expect(
        AppleLayout.fromMessage({'barEdge': 'future-edge'}).barEdge,
        AppleBarEdge.unavailable,
      );
    },
  );

  test(
    'physical edges and region coordinates survive the platform message',
    () {
      final layout = AppleLayout.fromMessage({
        'barEdge': 'right',
        'viewWidth': 820,
        'viewHeight': 900.0,
        'occlusions': [
          {'left': 740, 'top': 12, 'width': 60, 'height': 28},
        ],
        'divisions': [
          {'left': 410, 'top': 0, 'width': 0, 'height': 900},
        ],
      });
      expect(layout.barEdge, AppleBarEdge.right);
      expect(layout.viewSize, const Size(820, 900));
      expect(layout.occlusions, [const Rect.fromLTWH(740, 12, 60, 28)]);
      expect(layout.divisions, [const Rect.fromLTWH(410, 0, 0, 900)]);
      expect(
        AppleLayout.fromMessage({'barEdge': 'left'}).barEdge,
        AppleBarEdge.left,
      );
    },
  );

  test('malformed or nonfinite geometry does not poison the layout', () {
    final layout = AppleLayout.fromMessage({
      'barEdge': 'none',
      'viewWidth': double.infinity,
      'occlusions': [
        null,
        {'left': 0, 'top': double.nan, 'width': 12, 'height': 12},
        {'left': 0, 'top': 0, 'width': -1, 'height': 12},
        {'left': 0, 'top': 0, 'width': 12},
      ],
      'divisions': 'invalid',
    });
    expect(layout.viewSize, Size.zero);
    expect(layout.occlusions, isEmpty);
    expect(layout.divisions, isEmpty);
  });

  test(
    'the native stream updates during a session and cancels on dispose',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('playoncon/apple_layout');
      const codec = StandardMethodCodec();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final container = ProviderContainer();
      final updates = <AppleBarEdge>[];
      container.listen(appleLayoutProvider, (_, state) {
        final layout = state.valueOrNull;
        if (layout != null) updates.add(layout.barEdge);
      });
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['listen']);

      Future<void> send(String edge) async {
        await messenger.handlePlatformMessage(
          channel.name,
          codec.encodeSuccessEnvelope({'barEdge': edge}),
          (_) {},
        );
        await Future<void>.delayed(Duration.zero);
      }

      await send('right');
      await send('none');
      await send('left');
      expect(updates, [
        AppleBarEdge.right,
        AppleBarEdge.none,
        AppleBarEdge.left,
      ]);
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['listen', 'cancel']);
    },
  );

  test(
    'other platforms use the fallback without opening an Apple channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final layout = await container.read(appleLayoutProvider.future);
      expect(layout.barEdge, AppleBarEdge.unavailable);
    },
  );
}
