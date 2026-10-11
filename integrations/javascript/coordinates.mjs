const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const finiteBox = box => object(box) && ['x0', 'y0', 'x1', 'y1'].every(key => Number.isFinite(box[key])) &&
  box.x0 <= box.x1 && box.y0 <= box.y1 && Number.isFinite(box.x1 - box.x0) && Number.isFinite(box.y1 - box.y0);
const close = (actual, expected) => Number.isFinite(actual) && Number.isFinite(expected) &&
  Math.abs(actual - expected) <= 64 * Number.EPSILON * Math.max(1, Math.abs(expected));
const sameMatrix = (actual, expected) => Array.isArray(actual) && actual.length === 6 && actual.every((value, index) => close(value, expected[index]));

function inverse(matrix) {
  if (!Array.isArray(matrix) || matrix.length !== 6 || !matrix.every(Number.isFinite)) throw new RangeError('Invalid affine matrix');
  const [a, b, c, d, e, f] = matrix;
  const determinant = a * d - b * c;
  if (!Number.isFinite(determinant) || determinant === 0) throw new RangeError('Noninvertible affine matrix');
  const result = [d / determinant, -b / determinant, -c / determinant, a / determinant,
    (c * f - d * e) / determinant, (b * e - a * f) / determinant];
  if (!result.every(Number.isFinite)) throw new RangeError('Invalid affine inverse');
  return result;
}

function mapBBox(matrix, bbox) {
  if (!finiteBox(bbox)) throw new RangeError('Invalid bbox');
  const [a, b, c, d, e, f] = matrix;
  const points = [[bbox.x0, bbox.y0], [bbox.x0, bbox.y1], [bbox.x1, bbox.y0], [bbox.x1, bbox.y1]]
    .map(([x, y]) => [a * x + c * y + e, b * x + d * y + f]);
  if (points.some(point => !point.every(Number.isFinite))) throw new RangeError('Nonfinite mapped bbox');
  return { x0: Math.min(...points.map(point => point[0])), y0: Math.min(...points.map(point => point[1])),
    x1: Math.max(...points.map(point => point[0])), y1: Math.max(...points.map(point => point[1])) };
}

/** Internal reader check. Matrices must describe the declared PDF page exactly. */
export function validatePageGeometry(geometry) {
  if (!object(geometry) || geometry.coordinate_space !== 'pdf_user_space' ||
      !Number.isFinite(geometry.user_unit) || geometry.user_unit <= 0 || geometry.user_unit > 75000 ||
      ![0, 90, 180, 270].includes(geometry.rotation_degrees) || !finiteBox(geometry.media_box) || !finiteBox(geometry.crop_box)) throw new RangeError('Invalid page geometry');
  const media = geometry.media_box;
  const crop = geometry.crop_box;
  if (media.x0 >= media.x1 || media.y0 >= media.y1 || crop.x0 >= crop.x1 || crop.y0 >= crop.y1 ||
      crop.x0 < media.x0 || crop.y0 < media.y0 || crop.x1 > media.x1 || crop.y1 > media.y1) throw new RangeError('Invalid page boxes');
  const u = geometry.user_unit;
  const matrices = {
    0: [u, 0, 0, -u, -u * crop.x0, u * crop.y1],
    90: [0, u, u, 0, -u * crop.y0, -u * crop.x0],
    180: [-u, 0, 0, u, u * crop.x1, -u * crop.y0],
    270: [0, -u, -u, 0, u * crop.y1, u * crop.x1],
  };
  const matrix = matrices[geometry.rotation_degrees];
  const sideways = [90, 270].includes(geometry.rotation_degrees);
  const width = (sideways ? crop.y1 - crop.y0 : crop.x1 - crop.x0) * u;
  const height = (sideways ? crop.x1 - crop.x0 : crop.y1 - crop.y0) * u;
  const display = geometry.display;
  if (!(width > 0 && height > 0) || !object(display) || display.box !== 'crop_box' || display.origin !== 'top_left' || display.unit !== 'point' ||
      !close(display.width, width) || !close(display.height, height) || !sameMatrix(display.pdf_to_display, matrix) ||
      !sameMatrix(display.display_to_pdf, inverse(matrix))) throw new RangeError('Inconsistent page display transform');
  return geometry;
}

/** Internal reader check; returns the PDF bbox of the accepted pixel image. */
export function validateRasterTransform(transform) {
  if (!object(transform) || !Number.isSafeInteger(transform.pixel_width) || !Number.isSafeInteger(transform.pixel_height) ||
      transform.pixel_width < 1 || transform.pixel_height < 1 || transform.pixel_width > 0x7fffffff || transform.pixel_height > 0x7fffffff ||
      !Number.isFinite(transform.rasterizer_dpi) || transform.rasterizer_dpi <= 0) throw new RangeError('Invalid raster transform');
  inverse(transform.pixel_to_pdf);
  const bbox = mapBBox(transform.pixel_to_pdf, { x0: 0, y0: 0, x1: transform.pixel_width, y1: transform.pixel_height });
  if (bbox.x0 >= bbox.x1 || bbox.y0 >= bbox.y1) throw new RangeError('Empty raster transform');
  return bbox;
}

/** Internal reader check when page and requested raster settings are known. */
export function validateRasterPageContext(transform, geometry, requestedDpi, { fullPage = false } = {}) {
  validatePageGeometry(geometry);
  const mapped = validateRasterTransform(transform);
  if (!Number.isFinite(requestedDpi) || requestedDpi <= 0 || !close(transform.rasterizer_dpi, requestedDpi * geometry.user_unit)) throw new RangeError('Inconsistent raster DPI');
  const sideways = [90, 270].includes(geometry.rotation_degrees);
  const media = geometry.media_box;
  if (fullPage) {
    // Match the native/Poppler extent arithmetic before rounding. Dividing DPI
    // first can turn a letter page's 3300-pixel height into 3300 + epsilon.
    const width = Math.ceil((sideways ? media.y1 - media.y0 : media.x1 - media.x0) * transform.rasterizer_dpi / 72);
    const height = Math.ceil((sideways ? media.x1 - media.x0 : media.y1 - media.y0) * transform.rasterizer_dpi / 72);
    if (transform.pixel_width !== width || transform.pixel_height !== height) throw new RangeError('Inconsistent full-page raster dimensions');
  } else {
    if (mapped.x1 <= media.x0 || mapped.y1 <= media.y0 || mapped.x0 >= media.x1 || mapped.y0 >= media.y1) throw new RangeError('Regional raster does not intersect the MediaBox');
    const pixelX = Math.abs(transform.pixel_to_pdf[0]) + Math.abs(transform.pixel_to_pdf[2]);
    const pixelY = Math.abs(transform.pixel_to_pdf[1]) + Math.abs(transform.pixel_to_pdf[3]);
    for (const key of ['x0', 'y0', 'x1', 'y1']) {
      const outside = key[1] === '0' ? media[key] - mapped[key] : mapped[key] - media[key];
      const tolerance = 64 * Number.EPSILON * Math.max(1, Math.abs(media[key]), Math.abs(mapped[key]));
      if (outside >= (key[0] === 'x' ? pixelX : pixelY) + tolerance) throw new RangeError('Regional raster exceeds the MediaBox');
    }
  }
  const bbox = fullPage ? media : mapped;
  // Regional coefficients come from the DPI grid. Recovering them by
  // subtracting large translated corners loses precision at page origins.
  const sx = fullPage ? (sideways ? bbox.y1 - bbox.y0 : bbox.x1 - bbox.x0) / transform.pixel_width : 72 / transform.rasterizer_dpi;
  const sy = fullPage ? (sideways ? bbox.x1 - bbox.x0 : bbox.y1 - bbox.y0) / transform.pixel_height : 72 / transform.rasterizer_dpi;
  const matrices = {
    0: [sx, 0, 0, -sy, bbox.x0, bbox.y1],
    90: [0, sx, sy, 0, bbox.x0, bbox.y0],
    180: [-sx, 0, 0, sy, bbox.x1, bbox.y0],
    270: [0, -sx, -sy, 0, bbox.x1, bbox.y1],
  };
  if (!sameMatrix(transform.pixel_to_pdf, matrices[geometry.rotation_degrees])) throw new RangeError('Inconsistent raster page orientation');
}

/** Returns explicit geometry when available, otherwise null for legacy/null records. */
export function getPageGeometry(document, pageIndex) {
  if (!Number.isSafeInteger(pageIndex) || pageIndex < 0 || !object(document) || !Array.isArray(document.records) ||
      !Number.isSafeInteger(document.manifest?.page_count) || pageIndex >= document.manifest.page_count) throw new RangeError('Invalid page index');
  const routes = document.records.filter(record => record.record_type === 'route_trace' && record.trace_kind === 'page_route' && record.page_index === pageIndex);
  if (routes.length > 1) throw new RangeError('Ambiguous page geometry');
  const geometry = routes[0]?.page_geometry;
  return geometry == null ? null : validatePageGeometry(geometry);
}

function displayScale(options) {
  const scale = options?.scale;
  if (!Number.isFinite(scale) || scale <= 0) throw new RangeError('An explicit positive display scale is required');
  return scale;
}

/** Display points times caller-selected scale; does not mutate PDF-space evidence. */
export function mapPdfBBoxToDisplay(bbox, geometry, options) {
  validatePageGeometry(geometry);
  const scale = displayScale(options);
  const mapped = mapBBox(geometry.display.pdf_to_display, bbox);
  const result = Object.fromEntries(Object.entries(mapped).map(([key, value]) => [key, value * scale]));
  if (!finiteBox(result)) throw new RangeError('Nonfinite display bbox');
  return result;
}

export function mapDisplayBBoxToPdf(bbox, geometry, options) {
  validatePageGeometry(geometry);
  const scale = displayScale(options);
  if (!finiteBox(bbox)) throw new RangeError('Invalid display bbox');
  return mapBBox(geometry.display.display_to_pdf, Object.fromEntries(Object.entries(bbox).map(([key, value]) => [key, value / scale])));
}
