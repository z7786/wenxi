import { visiblePdfArea, pdfRenderRegion, pdfRegionCovers } from './pdf-region.mjs';

const content = document.getElementById('content');
const toolbar = document.getElementById('toolbar');
const options = new URLSearchParams(location.search);
document.documentElement.dataset.theme = options.get('theme') === 'dark' ? 'dark' : 'light';
for (const key of ['background', 'surface', 'text', 'muted', 'line', 'accent']) {
  const value = options.get(key);
  if (/^[0-9a-f]{6}$/i.test(value || '')) document.documentElement.style.setProperty(`--${key}`, `#${value}`);
}
let bridgeReady = !!window.flutter_inappwebview;
let pendingStatus;
let closing = false;
const cleanups = [];

function status(value) {
  pendingStatus = value;
  if (bridgeReady && window.flutter_inappwebview) {
    window.flutter_inappwebview.callHandler('documentStatus', value).catch(() => {});
  }
  document.documentElement.dataset.documentStatus = value.status;
}
window.addEventListener('flutterInAppWebViewPlatformReady', () => {
  bridgeReady = true;
  if (pendingStatus) status(pendingStatus);
});
function fail() {
  if (closing) return;
  document.getElementById('error').hidden = false;
  document.getElementById('error').textContent = '无法读取此文档，请重试或使用其他应用打开。';
  status({ status: 'error' });
}
function notice(text) {
  const panel = document.getElementById('notice');
  panel.textContent = text;
  panel.hidden = !text;
}
function element(tag, text, attributes = {}) {
  const node = document.createElement(tag);
  if (text != null) node.textContent = text;
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
  return node;
}
function button(label, action) {
  const node = element('button', label, { type: 'button' });
  node.addEventListener('click', () => Promise.resolve(action()).catch(fail));
  toolbar.append(node);
  return node;
}
function script(path) {
  return new Promise((resolve, reject) => {
    const node = element('script', null, { src: path });
    node.onload = resolve;
    node.onerror = reject;
    document.head.append(node);
  });
}
async function bytes() {
  const response = await fetch('document', { credentials: 'omit', cache: 'no-store' });
  if (!response.ok) throw new Error('Document read failed');
  return response.arrayBuffer();
}

async function pdf() {
  const pdfjs = await import('./vendor/pdf.min.mjs');
  pdfjs.GlobalWorkerOptions.workerSrc = new URL('./vendor/pdf.worker.min.mjs', import.meta.url).href;
  const task = pdfjs.getDocument({
    url: new URL('document', window.location.href).href,
    cMapUrl: new URL('vendor/cmaps/', window.location.href).href,
    standardFontDataUrl: new URL('vendor/standard_fonts/', window.location.href).href,
    wasmUrl: new URL('vendor/wasm/', window.location.href).href,
    cMapPacked: true, withCredentials: false, enableXfa: false,
    disableAutoFetch: true, disableStream: true, rangeChunkSize: 256 * 1024,
    maxImageSize: 24 * 1024 * 1024, canvasMaxAreaInBytes: 24 * 1024 * 1024,
    disableWorkerRendering: true,
  });
  cleanups.push(() => task.destroy());
  task.onPassword = (update, reason) => {
    const password = window.prompt(reason === pdfjs.PasswordResponses.INCORRECT_PASSWORD ? '密码不正确，请重新输入 PDF 密码' : '请输入 PDF 文档密码');
    if (password == null) { task.destroy(); fail(); } else update(password);
  };
  const doc = await task.promise;
  let pageNumber = 1, zoom = 1, epoch = 0, renderTask, currentPage, currentNumber = 0, currentScale = 0, painted, overviewReady = false;
  const viewport = element('div', null, { class: 'pdf-viewport' });
  const pageBox = element('div', null, { class: 'pdf-page' });
  const canvas = element('canvas', null, { class: 'pdf-detail' });
  const overview = element('canvas', null, { class: 'pdf-overview', 'aria-hidden': 'true' });
  pageBox.append(canvas, overview); viewport.append(pageBox); content.append(viewport);
  const previous = button('上一页', () => render(pageNumber - 1));
  const input = element('input', null, { type: 'number', min: '1', max: String(doc.numPages), 'aria-label': '页码' });
  toolbar.append(input, element('span', `/ ${doc.numPages}`));
  const next = button('下一页', () => render(pageNumber + 1));
  button('缩小', () => { zoom = Math.max(.5, zoom - .25); return render(pageNumber); });
  button('放大', () => { zoom = Math.min(5, zoom + .25); return render(pageNumber); });
  button('适合宽度', () => { zoom = 1; return render(pageNumber); });
  input.addEventListener('change', () => render(Number(input.value)).catch(fail));
  toolbar.hidden = false;
  let chain = Promise.resolve();
  let timer;
  function render(number) {
    const value = Number.isFinite(number) ? Math.floor(number) : pageNumber;
    pageNumber = Math.max(1, Math.min(doc.numPages, value));
    input.value = String(pageNumber);
    previous.disabled = pageNumber === 1;
    next.disabled = pageNumber === doc.numPages;
    const token = ++epoch, selected = pageNumber, selectedZoom = zoom;
    clearTimeout(timer); timer = null;
    renderTask?.cancel();
    chain = chain.catch(() => {}).then(async () => {
      if (closing || token !== epoch) return;
      const changedPage = currentNumber !== selected;
      if (changedPage) {
        currentPage?.cleanup();
        currentPage = null; currentNumber = 0; currentScale = 0; painted = null;
        canvas.width = canvas.height = overview.width = overview.height = 1;
        overviewReady = false;
        const loaded = await doc.getPage(selected);
        if (closing || token !== epoch) { loaded.cleanup(); return; }
        currentPage = loaded; currentNumber = selected;
      }
      const page = currentPage;
      const original = page.getViewport({ scale: 1 });
      const width = Math.max(1, content.clientWidth - 24);
      const scale = width / original.width * selectedZoom;
      const view = page.getViewport({ scale });
      const changedScale = currentScale !== scale;
      const oldWidth = Number.parseFloat(pageBox.style.width) || view.width;
      const oldHeight = Number.parseFloat(pageBox.style.height) || view.height;
      const anchorX = (content.scrollLeft + content.clientWidth / 2) / oldWidth;
      const anchorY = (content.scrollTop + content.clientHeight / 2) / oldHeight;
      pageBox.style.width = `${view.width}px`;
      pageBox.style.height = `${view.height}px`;
      pageBox.dataset.zoom = String(selectedZoom);
      if (changedPage) {
        content.scrollTop = content.scrollLeft = 0;
      } else if (changedScale) {
        painted = null;
        content.scrollLeft = Math.max(0, anchorX * view.width - content.clientWidth / 2);
        content.scrollTop = Math.max(0, anchorY * view.height - content.clientHeight / 2);
      }
      currentScale = scale;
      // Retain a small whole-page image underneath the sharp visible region.
      // Fast panning then shows content instead of empty patches while drawing.
      if (!overviewReady) {
        const output = Math.min(1, Math.sqrt(1024 * 1024 / (view.width * view.height)));
        overview.width = Math.max(1, Math.floor(view.width * output));
        overview.height = Math.max(1, Math.floor(view.height * output));
        renderTask = page.render({ canvas: overview, viewport: view, transform: [output, 0, 0, output, 0, 0], annotationMode: pdfjs.AnnotationMode.DISABLE });
        try { await renderTask.promise; } catch (error) {
          if (error?.name === 'RenderingCancelledException') return;
          throw error;
        }
        if (closing || token !== epoch) return;
        overviewReady = true;
      }
      const pageBounds = pageBox.getBoundingClientRect();
      const contentBounds = content.getBoundingClientRect();
      const visual = window.visualViewport;
      const clip = {
        left: Math.max(contentBounds.left, visual?.offsetLeft || 0),
        top: Math.max(contentBounds.top, visual?.offsetTop || 0),
        right: Math.min(contentBounds.right, (visual?.offsetLeft || 0) + (visual?.width || window.innerWidth)),
        bottom: Math.min(contentBounds.bottom, (visual?.offsetTop || 0) + (visual?.height || window.innerHeight)),
      };
      const visible = visiblePdfArea(pageBounds, clip);
      const region = pdfRenderRegion(view, visible, window.devicePixelRatio, visual?.scale);
      if (!region || pdfRegionCovers(painted, visible, region.outputScale)) return;
      painted = null;
      canvas.setAttribute('aria-label', `第 ${selected} 页`);
      canvas.width = region.pixelWidth; canvas.height = region.pixelHeight;
      canvas.style.left = `${region.left}px`; canvas.style.top = `${region.top}px`;
      canvas.style.width = `${region.width}px`; canvas.style.height = `${region.height}px`;
      canvas.dataset.outputScale = String(region.outputScale);
      const output = region.outputScale;
      renderTask = page.render({
        canvas, viewport: view,
        transform: [output, 0, 0, output, -region.left * output, -region.top * output],
        annotationMode: pdfjs.AnnotationMode.DISABLE,
      });
      try { await renderTask.promise; } catch (error) {
        if (error?.name === 'RenderingCancelledException') return;
        throw error;
      }
      if (!closing && token === epoch) {
        painted = region;
        canvas.dataset.renderEpoch = String(token);
        status({ status: 'ready' });
      }
    });
    return chain;
  }
  let refreshing = false, pendingRefresh = false;
  const refresh = () => {
    pendingRefresh = true;
    if (timer || refreshing || closing) return;
    timer = setTimeout(async () => {
      timer = null; refreshing = true; pendingRefresh = false;
      try {
        // Do not cancel every in-flight drawing during a continuous scroll.
        await chain.catch(() => {});
        if (!closing) await render(pageNumber);
      } catch (_) { fail(); }
      finally { refreshing = false; if (pendingRefresh) refresh(); }
    }, 80);
  };
  window.addEventListener('resize', refresh);
  content.addEventListener('scroll', refresh, { passive: true });
  window.visualViewport?.addEventListener('resize', refresh);
  window.visualViewport?.addEventListener('scroll', refresh);
  cleanups.push(() => {
    ++epoch; clearTimeout(timer);
    window.removeEventListener('resize', refresh); content.removeEventListener('scroll', refresh);
    window.visualViewport?.removeEventListener('resize', refresh); window.visualViewport?.removeEventListener('scroll', refresh);
    renderTask?.cancel(); currentPage?.cleanup(); canvas.width = canvas.height = overview.width = overview.height = 1;
  });
  await render(1);
}

async function word() {
  await script('vendor/jszip.min.js');
  await script('vendor/docx-preview.min.js');
  await window.docx.renderAsync(await bytes(), content, null, {
    ignoreWidth: false, ignoreHeight: false, breakPages: true,
    ignoreLastRenderedPageBreak: false, renderAltChunks: false,
    renderChanges: false, renderComments: false, useBase64URL: true,
    renderHeaders: true, renderFooters: true,
  });
  const pages = [...content.querySelectorAll('section.docx')].map(page => {
    const width = page.offsetWidth, height = page.offsetHeight;
    const wrap = element('div', null, { class: 'docx-sheet' });
    page.before(wrap); wrap.append(page);
    return { page, wrap, width, height };
  });
  let zoom = 1;
  function fit() {
    const available = Math.max(240, document.documentElement.clientWidth - 24);
    for (const { page, wrap, width, height } of pages) {
      const scale = Math.min(1, available / width) * zoom;
      // CSS zoom lays out text/SVG at the new scale rather than stretching a
      // layer rasterized for the previous size.
      page.style.zoom = String(scale);
      wrap.style.width = `${width * scale}px`;
      wrap.style.height = `${height * scale}px`;
    }
  }
  button('缩小', () => { zoom = Math.max(.5, zoom - .25); fit(); });
  button('放大', () => { zoom = Math.min(5, zoom + .25); fit(); });
  button('适合宽度', () => { zoom = 1; fit(); });
  toolbar.hidden = false;
  window.addEventListener('resize', fit);
  cleanups.push(() => window.removeEventListener('resize', fit));
  fit();
  status({ status: 'ready' });
}

async function spreadsheet() {
  const worker = new Worker('sheet-worker.js');
  let id = 0, selected = 0, start = 0, view, requestVersion = 0, zoom = 1;
  const pending = new Map();
  worker.onmessage = event => {
    const callback = pending.get(event.data.id);
    pending.delete(event.data.id);
    if (event.data.error) callback?.reject(new Error(event.data.error));
    else callback?.resolve(event.data);
  };
  worker.onerror = () => {
    for (const callback of pending.values()) callback.reject(new Error('Spreadsheet worker failed'));
    pending.clear(); fail();
  };
  cleanups.push(() => { worker.terminate(); pending.clear(); });
  function request(message, transfer = []) {
    return new Promise((resolve, reject) => { const key = ++id; pending.set(key, { resolve, reject }); worker.postMessage({ ...message, id: key }, transfer); });
  }
  const buffer = await bytes();
  const opened = await request({ type: 'open', bytes: buffer }, [buffer]);
  const select = element('select', null, { 'aria-label': '工作表' });
  opened.sheets.forEach((name, index) => select.append(element('option', name, { value: String(index) })));
  toolbar.append(select);
  const previous = button('上一页', () => page(Math.max(0, start - 200)));
  const count = element('span'); toolbar.append(count);
  const next = button('下一页', () => page(start + 200));
  function fit() {
    const table = content.querySelector('table.sheet');
    if (table) table.style.zoom = String(zoom);
  }
  button('缩小', () => { zoom = Math.max(.5, zoom - .25); fit(); });
  button('放大', () => { zoom = Math.min(5, zoom + .25); fit(); });
  button('还原缩放', () => { zoom = 1; fit(); });
  select.onchange = () => { selected = Number(select.value); page(0).catch(fail); };
  toolbar.hidden = false;
  async function page(first) {
    const token = ++requestVersion;
    const result = await request({ type: 'page', sheet: selected, start: first });
    if (closing || token !== requestVersion) return;
    view = result; start = result.start;
    previous.disabled = start === 0;
    next.disabled = result.stop >= result.rows;
    count.textContent = `${result.rows ? start + 1 : 0}–${result.stop} / ${result.rows} 行`;
    notice(result.truncated ? '大表格仅预览前 10000 行、256 列；完整内容请使用其他应用打开。' : '');
    const scroller = element('div', null, { class: 'sheet-scroll' });
    if (!view.rows) scroller.append(element('div', '工作表为空', { class: 'empty' }));
    else {
      const table = element('table', null, { class: 'sheet' });
      const header = element('tr'); header.append(element('th', '行'));
      result.headers.forEach(name => header.append(element('th', name)));
      table.append(header);
      result.values.forEach((cells, index) => {
        const row = element('tr'); row.append(element('th', String(start + index + 1)));
        cells.forEach(value => row.append(element('td', value)));
        table.append(row);
      });
      scroller.append(table);
    }
    content.replaceChildren(scroller);
    fit();
    status({ status: 'ready' });
  }
  await page(0);
}

async function presentation() {
  content.classList.add('presentation');
  await script('vendor/pptxjs.umd.js');
  const viewer = new window.PPTXjs.PptxViewer(content, {
    mode: 'slideshow', scale: 'contain', mediaProcess: false, externalMedia: false,
    keyboard: true, incremental: true, gap: 12,
    slideshow: { nav: false, autoplay: false, transition: 'none' },
    limits: { maxUncompressedSize: 96 * 1024 * 1024, maxEntries: 10000 },
  });
  cleanups.push(() => viewer.destroy());
  button('上一页', () => viewer.prev());
  const count = element('span'); toolbar.append(count);
  button('下一页', () => viewer.next());
  let zoom = 1;
  function fit() {
    const slide = viewer.result;
    if (!slide) return;
    const scale = Math.min(
      Math.max(1, content.clientWidth - 4) / slide.width,
      Math.max(1, content.clientHeight - 2) / slide.height,
    ) * zoom;
    viewer.setOptions({ scale });
    viewer.element.style.minWidth = `${slide.width * scale}px`;
    viewer.element.style.minHeight = `${slide.height * scale}px`;
  }
  button('缩小', () => { zoom = Math.max(.5, zoom - .25); fit(); });
  button('放大', () => { zoom = Math.min(5, zoom + .25); fit(); });
  button('适合屏幕', () => { zoom = 1; content.scrollTop = content.scrollLeft = 0; fit(); });
  viewer.on('slidechange', ({ index }) => { count.textContent = `${index + 1} / ${viewer.slideCount}`; });
  toolbar.hidden = false;
  await viewer.load(await bytes());
  window.addEventListener('resize', fit);
  cleanups.push(() => window.removeEventListener('resize', fit));
  fit();
  count.textContent = `${viewer.currentIndex + 1} / ${viewer.slideCount}`;
  status({ status: 'ready' });
}

// Document hyperlinks are data, never an instruction to leave the local viewer.
document.addEventListener('click', event => {
  if (event.target.closest?.('a')) event.preventDefault();
}, true);
window.addEventListener('pagehide', () => {
  closing = true;
  for (const cleanup of cleanups.reverse()) { try { Promise.resolve(cleanup()).catch(() => {}); } catch (_) {} }
  content.replaceChildren();
}, { once: true });

try {
  const response = await fetch('info.json', { credentials: 'omit', cache: 'no-store' });
  if (!response.ok) throw new Error('Document metadata unavailable');
  const info = await response.json();
  document.title = info.name;
  await ({ pdf, word, spreadsheet, presentation }[info.format] || (() => { throw new Error('Unsupported document'); }))();
} catch (_) { fail(); }

