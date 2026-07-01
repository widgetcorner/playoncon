import 'package:intl/intl.dart';

/// A single line inside a merged event cell of the form `Label - H:MM AM/PM`.
/// Used for multi-phase entries like `Loooot!` where the merged cell runs
/// 3–5 PM but the sheet author wrote sub-steps inside it
/// (`Learn to Play - 3 PM`, `Tournament - 3:30 PM`).
class ScheduleItem {
  final String label;
  final DateTime time;
  const ScheduleItem({required this.label, required this.time});

  Map<String, dynamic> toJson() => {
        'label': label,
        'time': time.toIso8601String(),
      };

  factory ScheduleItem.fromJson(Map<String, dynamic> json) => ScheduleItem(
        label: json['label'] as String,
        time: DateTime.parse(json['time'] as String),
      );
}

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

  /// Optional in-cell sub-schedule (e.g. Learn to Play → Tournament).
  final List<ScheduleItem> subSchedule;

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
    this.subSchedule = const [],
  });

  String get dayKey {
    final anchor = startTime.hour < 3
        ? startTime.subtract(const Duration(days: 1))
        : startTime;
    return DateFormat('yyyy-MM-dd').format(anchor);
  }

  Event copyWith({
    String? details,
  }) =>
      Event(
        id: id,
        title: title,
        startTime: startTime,
        endTime: endTime,
        locationKey: locationKey,
        locationDisplayName: locationDisplayName,
        track: track,
        presenter: presenter,
        details: details ?? this.details,
        attributes: attributes,
        subSchedule: subSchedule,
      );

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
        'subSchedule': subSchedule.map((s) => s.toJson()).toList(),
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
        subSchedule: (json['subSchedule'] as List<dynamic>?)
                ?.map((e) => ScheduleItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}
