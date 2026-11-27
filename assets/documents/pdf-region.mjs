// Render a bounded visible part of the page instead of reducing the resolution
// of an entire magnified page. Coordinates are in the page's CSS pixels.
export const PDF_CANVAS_PIXELS = 6 * 1024 * 1024;
const MAX_CANVAS_SIDE = 4096;

export function visiblePdfArea(page, clip) {
  const left = Math.max(0, clip.left - page.left);
  const top = Math.max(0, clip.top - page.top);
  const right = Math.min(page.width, clip.right - page.left);
  const bottom = Math.min(page.height, clip.bottom - page.top);
  if (![left, top, right, bottom].every(Number.isFinite) || right <= left || bottom <= top) return null;
  return { left, top, width: right - left, height: bottom - top };
}

export function pdfRenderRegion(page, visible, devicePixelRatio = 1, visualScale = 1) {
  if (!visible || ![visible.left, visible.top].every(Number.isFinite) ||
      ![page.width, page.height, visible.width, visible.height].every(value => Number.isFinite(value) && value > 0)) return null;
  const density = Number.isFinite(devicePixelRatio) && devicePixelRatio > 0 ? devicePixelRatio : 1;
  const magnification = Number.isFinite(visualScale) && visualScale > 0 ? visualScale : 1;
  const padding = 96 / magnification;
  const left = Math.max(0, Math.floor(visible.left - padding));
  const top = Math.max(0, Math.floor(visible.top - padding));
  const right = Math.min(page.width, Math.ceil(visible.left + visible.width + padding));
  const bottom = Math.min(page.height, Math.ceil(visible.top + visible.height + padding));
  const width = right - left, height = bottom - top;
  if (width <= 0 || height <= 0) return null;
  const outputScale = Math.min(
    density * magnification,
    Math.sqrt(PDF_CANVAS_PIXELS / (width * height)),
    MAX_CANVAS_SIDE / width,
    MAX_CANVAS_SIDE / height,
  );
  return {
    left, top, width, height, outputScale,
    pixelWidth: Math.max(1, Math.floor(width * outputScale)),
    pixelHeight: Math.max(1, Math.floor(height * outputScale)),
  };
}

export function pdfRegionCovers(region, visible, outputScale) {
  return !!region && !!visible && Math.abs(region.outputScale - outputScale) < .001 &&
    region.left <= visible.left && region.top <= visible.top &&
    region.left + region.width >= visible.left + visible.width &&
    region.top + region.height >= visible.top + visible.height;
}
