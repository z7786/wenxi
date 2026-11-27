/* SheetJS parses spreadsheet bytes in a worker, away from scrolling and UI. */
importScripts('vendor/xlsx.full.min.js');
let workbook;
const rowLimit = 10000;
const columnLimit = 256;
self.onmessage = function (event) {
  const message = event.data;
  try {
    if (message.type === 'open') {
      workbook = XLSX.read(message.bytes, {
        type: 'array', dense: true, sheetRows: rowLimit,
        cellHTML: false, cellStyles: false, cellFormula: false, bookVBA: false,
      });
      if (!workbook.SheetNames.length) throw new Error('表格没有工作表');
      self.postMessage({ id: message.id, sheets: workbook.SheetNames });
      return;
    }
    if (message.type !== 'page' || !workbook) throw new Error('表格尚未读取');
    const sheet = workbook.Sheets[workbook.SheetNames[message.sheet]];
    if (!sheet) throw new Error('工作表不存在');
    const rawRange = XLSX.utils.decode_range(sheet['!fullref'] || sheet['!ref'] || 'A1');
    const readRange = XLSX.utils.decode_range(sheet['!ref'] || 'A1');
    const rows = sheet['!ref'] ? Math.min(rawRange.e.r + 1, rowLimit) : 0;
    const columns = sheet['!ref'] ? Math.min(rawRange.e.c + 1, columnLimit) : 0;
    const start = Math.max(0, Math.min(rows, Number(message.start) || 0));
    const stop = Math.min(rows, start + 200);
    const values = [];
    for (let row = start; row < stop; row++) {
      const cells = [];
      for (let col = 0; col < columns; col++) {
        const cell = sheet['!data'] ? sheet['!data'][row]?.[col] : sheet[XLSX.utils.encode_cell({ r: row, c: col })];
        // File text is returned as strings; the page renders it with textContent.
        cells.push(cell ? String(cell.w ?? XLSX.utils.format_cell(cell)).slice(0, 10000) : '');
      }
      values.push(cells);
    }
    self.postMessage({
      id: message.id, rows, columns, start, stop, values,
      headers: Array.from({ length: columns }, (_, index) => XLSX.utils.encode_col(index)),
      truncated: rawRange.e.r >= rowLimit || rawRange.e.c >= columnLimit || readRange.e.r >= rowLimit,
    });
  } catch (error) {
    self.postMessage({ id: message.id, error: '无法读取表格，可能已加密或文件损坏' });
  }
};
