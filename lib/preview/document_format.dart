import '../domain/file_types.dart';

enum DocumentFormat { text, pdf, word, spreadsheet, presentation, external }

DocumentFormat? documentFormat(String name) {
  final kind = fileKind(name);
  if (kind == FileKind.text) return DocumentFormat.text;
  if (kind == FileKind.pdf) return DocumentFormat.pdf;
  return switch (name.split('.').last.toLowerCase()) {
    'docx' => DocumentFormat.word,
    'xls' || 'xlsx' || 'xlsm' || 'xlsb' || 'ods' => DocumentFormat.spreadsheet,
    'pptx' => DocumentFormat.presentation,
    _ => isOfficeDocument(name) ? DocumentFormat.external : null,
  };
}
