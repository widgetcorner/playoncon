import 'package:intl/intl.dart';

class Event {
  final String id;
  final String title;
  final DateTime startTime;
  final DateTime endTime;
  final String? locationKey;
  final String? locationDisplayName;
  final String? track;
  final String? presenter;
  final String? details;

  /// Short codes parsed from `[TAG]` tokens in the source cell.
  /// Resolved to display labels via [EventAttribute.resolve].
  final List<String> attributes;

  Event({
    required this.id,
    required this.title,
    required this.startTime,
    required this.endTime,
    this.locationKey,
    this.locationDisplayName,
    this.track,
    this.presenter,
    this.details,
    this.attributes = const [],
  });

  String get dayKey => DateFormat('yyyy-MM-dd').format(startTime);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'locationKey': locationKey,
        'locationDisplayName': locationDisplayName,
        'track': track,
        'presenter': presenter,
        'details': details,
        'attributes': attributes,
      };

  factory Event.fromJson(Map<String, dynamic> json) => Event(
        id: json['id'] as String,
        title: json['title'] as String,
        startTime: DateTime.parse(json['startTime'] as String),
        endTime: DateTime.parse(json['endTime'] as String),
        locationKey: json['locationKey'] as String?,
        locationDisplayName: json['locationDisplayName'] as String?,
        track: json['track'] as String?,
        presenter: json['presenter'] as String?,
        details: json['details'] as String?,
        attributes: (json['attributes'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const [],
      );
}
