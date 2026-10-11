import type { PdfBBox, RichPdfDocument } from './extract.mjs';

/** PDF affine order [a,b,c,d,e,f]: x'=a*x+c*y+e, y'=b*x+d*y+f. */
export type AffineMatrix = readonly [number, number, number, number, number, number];
export interface PageGeometry {
  coordinate_space: 'pdf_user_space';
  user_unit: number;
  rotation_degrees: 0 | 90 | 180 | 270;
  media_box: PdfBBox;
  crop_box: PdfBBox;
  display: {
    box: 'crop_box';
    origin: 'top_left';
    unit: 'point';
    width: number;
    height: number;
    pdf_to_display: AffineMatrix;
    display_to_pdf: AffineMatrix;
  };
}
export interface RasterTransform {
  pixel_to_pdf: AffineMatrix;
  rasterizer_dpi: number;
  pixel_width: number;
  pixel_height: number;
}
/** Display points multiplied by this explicit host-selected scale. */
export interface DisplayScale { scale: number }
export interface DisplayBBox { x0: number; y0: number; x1: number; y1: number }
export function getPageGeometry(document: RichPdfDocument, pageIndex: number): PageGeometry | null;
export function mapPdfBBoxToDisplay(bbox: PdfBBox, geometry: PageGeometry, options: DisplayScale): DisplayBBox;
export function mapDisplayBBoxToPdf(bbox: DisplayBBox, geometry: PageGeometry, options: DisplayScale): PdfBBox;
