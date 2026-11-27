const test = require('node:test');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const helpers = import(pathToFileURL(path.join(__dirname, '../../assets/documents/pdf-region.mjs')).href);

test('phone PDF magnification retains high DPI within the visible canvas budget', async () => {
  const { pdfRenderRegion, PDF_CANVAS_PIXELS } = await helpers;
  // A 5x magnified A4 page would exceed the old whole-page pixel limit.
  const page = { width: 1800, height: 2545 };
  const region = pdfRenderRegion(page, { left: 700, top: 800, width: 360, height: 600 }, 3, 1);
  assert.equal(region.outputScale, 3);
  assert.ok(region.pixelWidth * region.pixelHeight <= PDF_CANVAS_PIXELS);
  assert.ok(region.left <= 700 && region.top <= 800);
  assert.ok(region.left + region.width >= 1060);
  assert.ok(region.top + region.height >= 1400);
});

test('native pinch zoom rerenders at the effective display resolution', async () => {
  const { pdfRenderRegion, PDF_CANVAS_PIXELS } = await helpers;
  const page = { width: 1200, height: 1700 };
  const one = pdfRenderRegion(page, { left: 300, top: 400, width: 360, height: 600 }, 3, 1);
  const pinch = pdfRenderRegion(page, { left: 300, top: 400, width: 120, height: 200 }, 3, 3);
  assert.equal(pinch.outputScale, one.outputScale * 3);
  assert.ok(pinch.pixelWidth * pinch.pixelHeight <= PDF_CANVAS_PIXELS);
});

test('oversized desktop regions remain bounded and clip to the page', async () => {
  const { pdfRenderRegion, PDF_CANVAS_PIXELS, visiblePdfArea } = await helpers;
  const page = { left: -10, top: -20, width: 20000, height: 30000 };
  const visible = visiblePdfArea(page, { left: 0, top: 0, right: 12000, bottom: 10000 });
  const region = pdfRenderRegion(page, visible, 4, 2);
  assert.ok(region.pixelWidth * region.pixelHeight <= PDF_CANVAS_PIXELS);
  assert.ok(region.pixelWidth <= 4096 && region.pixelHeight <= 4096);
  const corner = pdfRenderRegion({ width: 595, height: 842 }, { left: 500, top: 800, width: 95, height: 42 }, 2, 1);
  assert.equal(corner.left + corner.width, 595);
  assert.equal(corner.top + corner.height, 842);
});

test('PDF scroll retains covered regions but invalidates changed resolution', async () => {
  const { pdfRenderRegion, pdfRegionCovers } = await helpers;
  const visible = { left: 200, top: 300, width: 360, height: 600 };
  const region = pdfRenderRegion({ width: 1800, height: 2500 }, visible, 3, 1);
  assert.equal(pdfRegionCovers(region, { ...visible, top: 340 }, 3), true);
  assert.equal(pdfRegionCovers(region, { ...visible, top: 500 }, 3), false);
  assert.equal(pdfRegionCovers(region, visible, 6), false);
});

test('offscreen or invalid PDF areas cannot allocate a canvas', async () => {
  const { pdfRenderRegion, visiblePdfArea } = await helpers;
  assert.equal(visiblePdfArea({ left: 1000, top: 0, width: 500, height: 800 }, { left: 0, top: 0, right: 400, bottom: 600 }), null);
  assert.equal(pdfRenderRegion({ width: 500, height: 800 }, null), null);
  assert.equal(pdfRenderRegion({ width: 0, height: 800 }, { left: 0, top: 0, width: 500, height: 600 }), null);
  assert.equal(pdfRenderRegion({ width: 500, height: 800 }, { left: NaN, top: 0, width: 400, height: 600 }), null);
});
