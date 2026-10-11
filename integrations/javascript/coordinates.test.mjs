import test from 'node:test';
import assert from 'node:assert/strict';
import { getPageGeometry, mapPdfBBoxToDisplay, mapDisplayBBoxToPdf } from './index.mjs';
import { validateRasterPageContext, validateRasterTransform } from './coordinates.mjs';

const crop = { x0: 10, y0: 20, x1: 110, y1: 220 };
const pdf = { x0: 20, y0: 40, x1: 50, y1: 80 };
const cases = [
  [0, [2, 0, 0, -2, -20, 440], [0.5, 0, 0, -0.5, 10, 220], 200, 400, { x0: 30, y0: 420, x1: 120, y1: 540 }],
  [90, [0, 2, 2, 0, -40, -20], [0, 0.5, 0.5, 0, 10, 20], 400, 200, { x0: 60, y0: 30, x1: 180, y1: 120 }],
  [180, [-2, 0, 0, 2, 220, -40], [-0.5, 0, 0, 0.5, 110, 20], 200, 400, { x0: 180, y0: 60, x1: 270, y1: 180 }],
  [270, [0, -2, -2, 0, 440, 220], [0, -0.5, -0.5, 0, 110, 220], 400, 200, { x0: 420, y0: 180, x1: 540, y1: 270 }],
];
function geometry([rotation, forward, inverse, width, height]) {
  return { coordinate_space: 'pdf_user_space', user_unit: 2, rotation_degrees: rotation,
    media_box: { x0: -10, y0: -20, x1: 200, y1: 300 }, crop_box: { ...crop },
    display: { box: 'crop_box', origin: 'top_left', unit: 'point', width, height, pdf_to_display: forward, display_to_pdf: inverse } };
}
for (const values of cases) test(`literal ${values[0]} degree display bbox with CropBox UserUnit and explicit scale`, () => {
  const page = geometry(values);
  const original = structuredClone({ page, pdf });
  const mapped = mapPdfBBoxToDisplay(pdf, page, { scale: 1.5 });
  assert.deepEqual(mapped, values[5]);
  assert.deepEqual(mapDisplayBBoxToPdf(mapped, page, { scale: 1.5 }), pdf);
  assert.deepEqual({ page, pdf }, original);
});

test('page geometry lookup preserves null legacy metadata and page identity', () => {
  const page = geometry(cases[0]);
  const document = { manifest: { page_count: 2 }, records: [{ record_type: 'route_trace', trace_kind: 'page_route', page_index: 1, page_geometry: page }] };
  assert.equal(getPageGeometry(document, 0), null);
  assert.equal(getPageGeometry(document, 1), page);
  document.records[0].page_geometry = null;
  assert.equal(getPageGeometry(document, 1), null);
  assert.throws(() => getPageGeometry(document, 2), RangeError);
  assert.throws(() => getPageGeometry(document, 0.5), RangeError);
  document.records.push({ ...document.records[0] });
  assert.throws(() => getPageGeometry(document, 1), /Ambiguous/u);
});

test('coordinate helpers refuse implicit scales invalid boxes and forged matrices', () => {
  const page = geometry(cases[0]);
  for (const scale of [undefined, 0, -1, Infinity, NaN, '1']) {
    assert.throws(() => mapPdfBBoxToDisplay(pdf, page, { scale }), RangeError);
    assert.throws(() => mapDisplayBBoxToPdf(pdf, page, { scale }), RangeError);
  }
  assert.throws(() => mapPdfBBoxToDisplay({ ...pdf, x0: NaN }, page, { scale: 1 }), RangeError);
  assert.throws(() => mapDisplayBBoxToPdf({ ...pdf, x1: 0 }, page, { scale: 1 }), RangeError);
  const forged = structuredClone(page);
  forged.display.pdf_to_display[4] += 1;
  assert.throws(() => mapPdfBBoxToDisplay(pdf, forged, { scale: 1 }), RangeError);
  assert.throws(() => mapPdfBBoxToDisplay(pdf, null, { scale: 1 }), RangeError);
});

test('regional raster coefficients stay precise at large positive and negative page origins', () => {
  for (const origin of [10000, -10000, 1000000]) for (const unit of [1, 2]) {
    const box = { x0: origin, y0: -origin, x1: origin + 100, y1: -origin + 200 };
    const u = unit;
    const v = 1 / u;
    const pixel = 72 / (200 * u);
    const rotations = [
      [0, [u, 0, 0, -u, -u * box.x0, u * box.y1], [v, 0, 0, -v, box.x0, box.y1], [pixel, 0, 0, -pixel, box.x0, box.y1]],
      [90, [0, u, u, 0, -u * box.y0, -u * box.x0], [0, v, v, 0, box.x0, box.y0], [0, pixel, pixel, 0, box.x0, box.y0]],
      [180, [-u, 0, 0, u, u * box.x1, -u * box.y0], [-v, 0, 0, v, box.x1, box.y0], [-pixel, 0, 0, pixel, box.x1, box.y0]],
      [270, [0, -u, -u, 0, u * box.y1, u * box.x1], [0, -v, -v, 0, box.x1, box.y1], [0, -pixel, -pixel, 0, box.x1, box.y1]],
    ];
    for (const [rotation, forward, inverse, matrix] of rotations) {
      const sideways = [90, 270].includes(rotation);
      const page = { coordinate_space: 'pdf_user_space', user_unit: unit, rotation_degrees: rotation,
        media_box: box, crop_box: box, display: { box: 'crop_box', origin: 'top_left', unit: 'point',
          width: (sideways ? 200 : 100) * unit, height: (sideways ? 100 : 200) * unit,
          pdf_to_display: forward, display_to_pdf: inverse } };
      const raster = { pixel_to_pdf: matrix, rasterizer_dpi: 200 * unit, pixel_width: 17, pixel_height: 19 };
      assert.doesNotThrow(() => validateRasterTransform(raster));
      assert.doesNotThrow(() => validateRasterPageContext(raster, page, 200));
    }
  }
});

function pageAt(box, rotation = 0, unit = 1) {
  const u = unit;
  const v = 1 / u;
  const matrices = {
    0: [[u, 0, 0, -u, -u * box.x0, u * box.y1], [v, 0, 0, -v, box.x0, box.y1]],
    90: [[0, u, u, 0, -u * box.y0, -u * box.x0], [0, v, v, 0, box.x0, box.y0]],
    180: [[-u, 0, 0, u, u * box.x1, -u * box.y0], [-v, 0, 0, v, box.x1, box.y0]],
    270: [[0, -u, -u, 0, u * box.y1, u * box.x1], [0, -v, -v, 0, box.x1, box.y1]],
  };
  const sideways = [90, 270].includes(rotation);
  return { coordinate_space: 'pdf_user_space', user_unit: unit, rotation_degrees: rotation, media_box: box, crop_box: box,
    display: { box: 'crop_box', origin: 'top_left', unit: 'point', width: (sideways ? box.y1 - box.y0 : box.x1 - box.x0) * unit,
      height: (sideways ? box.x1 - box.x0 : box.y1 - box.y0) * unit, pdf_to_display: matrices[rotation][0], display_to_pdf: matrices[rotation][1] } };
}

test('regional rasters reject off-page translated extents beyond pixel rounding', () => {
  const page = pageAt({ x0: 10000, y0: -10000, x1: 10100, y1: -9800 });
  const base = { pixel_to_pdf: [0.36, 0, 0, -0.36, 10000, -9800], rasterizer_dpi: 200, pixel_width: 17, pixel_height: 19 };
  for (const matrix of [
    [0.36, 0, 0, -0.36, 10200, -9800],
    [0.36, 0, 0, -0.36, 9999.28, -9800],
    [0.36, 0, 0, -0.36, 10000, -9799.28],
    [0.36, 0, 0, -0.36, 10094.60, -9800],
    [0.36, 0, 0, -0.36, 10000, -9993.88],
  ]) {
    const raster = { ...base, pixel_to_pdf: matrix };
    assert.doesNotThrow(() => validateRasterTransform(raster));
    assert.throws(() => validateRasterPageContext(raster, page, 200), RangeError);
  }
  const outsidePixel = { ...base, pixel_width: 1, pixel_to_pdf: [0.36, 0, 0, -0.36, 10100, -9800] };
  assert.throws(() => validateRasterPageContext(outsidePixel, page, 200), RangeError);
});

test('regional raster MediaBox edges allow fractional outward pixels with large-origin cancellation', () => {
  const page = pageAt({ x0: 1000000, y0: -1000000, x1: 1000100, y1: -999800 });
  const raster = { pixel_to_pdf: [0.36, 0, 0, -0.36, 1000094.04, -999999.6], rasterizer_dpi: 200, pixel_width: 17, pixel_height: 2 };
  // The right and bottom edges extend by .16 and .32 PDF units, each < .36.
  assert.doesNotThrow(() => validateRasterPageContext(raster, page, 200));
});

test('full-page rasters reject dimension forgery even when their matrix maps the MediaBox', () => {
  const page = pageAt({ x0: 0, y0: 0, x1: 612, y1: 792 });
  for (const [width, height] of [[2549, 3300], [2550, 3301], [1, 1]]) {
    const raster = { pixel_to_pdf: [612 / width, 0, 0, -792 / height, 0, 792], rasterizer_dpi: 300, pixel_width: width, pixel_height: height };
    assert.throws(() => validateRasterPageContext(raster, page, 300, { fullPage: true }), RangeError);
  }
});

test('300 DPI letter and fractional full pages retain exact accepted dimensions and PDF bounds', () => {
  for (const rotation of [0, 90, 180, 270]) {
    const page = pageAt({ x0: 0, y0: 0, x1: 612, y1: 792 }, rotation);
    const sideways = [90, 270].includes(rotation);
    const matrices = { 0: [0.24, 0, 0, -0.24, 0, 792], 90: [0, 0.24, 0.24, 0, 0, 0],
      180: [-0.24, 0, 0, 0.24, 612, 0], 270: [0, -0.24, -0.24, 0, 612, 792] };
    const raster = { pixel_to_pdf: matrices[rotation], rasterizer_dpi: 300, pixel_width: sideways ? 3300 : 2550, pixel_height: sideways ? 2550 : 3300 };
    assert.doesNotThrow(() => validateRasterPageContext(raster, page, 300, { fullPage: true }));
  }
  const box = { x0: 10.25, y0: -20.5, x1: 20.35, y1: -0.25 };
  const fractional = { pixel_to_pdf: [(20.35 - 10.25) / 43, 0, 0, -20.25 / 85, 10.25, -0.25], rasterizer_dpi: 300, pixel_width: 43, pixel_height: 85 };
  assert.doesNotThrow(() => validateRasterPageContext(fractional, pageAt(box), 300, { fullPage: true }));
});
