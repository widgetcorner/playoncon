import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'csv_parser.dart' show CellMerge;

/// One tab of a Google Sheets workbook fetched via the v4 API. `rows` are the
/// tab's raw cells (only the merge anchor carries `formattedValue`; other
/// cells inside a merge come through empty); `merges` describe the merged
/// ranges so a caller can inherit anchor values and compute vertical spans.
class SheetTab {
  final String gid;
  final List<List<String>> rows;
  final List<CellMerge> merges;
  const SheetTab({
    required this.gid,
    required this.rows,
    required this.merges,
  });
}

/// Fetches a Google Sheets workbook with merged-cell metadata attached. Used
/// instead of the CSV export endpoint because CSV drops merges entirely —
/// which the Play On Con schedule relies on to indicate multi-hour events.
///
/// Only works against **native Google Sheets** documents; Google refuses
/// `includeGridData` on uploaded `.xlsx` files (returns FAILED_PRECONDITION).
class SheetsApiClient {
  static const _host = 'sheets.googleapis.com';

  final String apiKey;
  final String spreadsheetId;
  final http.Client _http;

  SheetsApiClient({
    required this.apiKey,
    required this.spreadsheetId,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// Fetches the workbook and returns only the tabs whose `sheetId` (aka gid)
  /// is in [gids], preserving the caller's order. Filtering client-side keeps
  /// the request simple — one call gets the whole workbook.
  Future<List<SheetTab>> fetchTabs(List<String> gids) async {
    final uri = Uri.https(_host, '/v4/spreadsheets/$spreadsheetId', {
      'includeGridData': 'true',
      'fields':
          'sheets(properties(sheetId),merges,data.rowData.values.formattedValue)',
      'key': apiKey,
    });

    final resp = await _http.get(uri).timeout(const Duration(seconds: 30));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException(
        'Sheets API HTTP ${resp.statusCode}: ${resp.body}',
      );
    }

    final decoded =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final sheets = decoded['sheets'] as List<dynamic>? ?? const [];
    final wanted = gids.toSet();
    final result = <SheetTab>[];

    for (final s in sheets) {
      final sm = s as Map<String, dynamic>;
      final props = sm['properties'] as Map<String, dynamic>? ?? const {};
      final gid = (props['sheetId'] ?? '').toString();
      if (!wanted.contains(gid)) continue;

      final merges = <CellMerge>[];
      for (final m in (sm['merges'] as List<dynamic>? ?? const [])) {
        final mm = m as Map<String, dynamic>;
        merges.add(CellMerge(
          startRow: (mm['startRowIndex'] as num?)?.toInt() ?? 0,
          endRow: (mm['endRowIndex'] as num?)?.toInt() ?? 0,
          startCol: (mm['startColumnIndex'] as num?)?.toInt() ?? 0,
          endCol: (mm['endColumnIndex'] as num?)?.toInt() ?? 0,
        ));
      }

      final rows = <List<String>>[];
      final data = sm['data'] as List<dynamic>? ?? const [];
      if (data.isNotEmpty) {
        final first = data.first as Map<String, dynamic>;
        final rowData = first['rowData'] as List<dynamic>? ?? const [];
        for (final r in rowData) {
          final rm = r as Map<String, dynamic>;
          final vals = rm['values'] as List<dynamic>? ?? const [];
          rows.add([
            for (final v in vals)
              ((v as Map<String, dynamic>)['formattedValue'] as String?) ?? '',
          ]);
        }
      }

      result.add(SheetTab(gid: gid, rows: rows, merges: merges));
    }

    result.sort((a, b) => gids.indexOf(a.gid).compareTo(gids.indexOf(b.gid)));
    return result;
  }

  void close() => _http.close();
}
