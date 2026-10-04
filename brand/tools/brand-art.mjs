// Geometry authority for the orchid mark. orchid is the third of shellbell
// and sous: the same prompt chevron and cursor (>_), plate and gloss; where
// shellbell rings (two rays) and sous lines up (two tickets), orchid merges
// (two branches meeting in one commit over the cursor). Shellbell is
// amber-500, sous violet-400; orchid is teal-400.
// Bounds: 0..360 x 0..280, as shellbell's.
export const TEAL = '#2DD4BF';
export const TEAL_DEEP = '#0F766E'; // the mark on light backgrounds
export const INK = '#17191D';
export const PAPER = '#F8F7F4';

const CHEVRON =
  'M31 4Q36 -1 41 4L166 129Q177 140 166 151L41 276Q36 281 31 276L3 248Q-2 243 3 238L101 140L3 42Q-2 37 3 32Z';
/** @param {number} x1 @param {number} x2 @param {number} y @param {number} h */
const bar = (x1, x2, y, h) => {
  const r = Math.round(h * 0.31);
  return `M${x1 + r} ${y}H${x2 - r}Q${x2} ${y} ${x2} ${y + r}V${y + h - r}Q${x2} ${y + h} ${x2 - r} ${y + h}H${x1 + r}Q${x1} ${y + h} ${x1} ${y + h - r}V${y + r}Q${x1} ${y} ${x1 + r} ${y}Z`;
};
/** A commit. @param {number} x @param {number} y @param {number} r */
const node = (x, y, r) => `M${x - r} ${y}A${r} ${r} 0 1 0 ${x + r} ${y}A${r} ${r} 0 1 0 ${x - r} ${y}Z`;
/** A branch, drawn as a filled stroke so every part of the mark is a fill. @param {number[]} a @param {number[]} b @param {number} w */
const branch = ([x1, y1], [x2, y2], w) => {
  const len = Math.hypot(x2 - x1, y2 - y1);
  const [nx, ny] = [((y1 - y2) / len) * (w / 2), ((x2 - x1) / len) * (w / 2)];
  const p = (/** @type {number} */ v) => Math.round(v * 100) / 100;
  return `M${p(x1 + nx)} ${p(y1 + ny)}L${p(x2 + nx)} ${p(y2 + ny)}L${p(x2 - nx)} ${p(y2 - ny)}L${p(x1 - nx)} ${p(y1 - ny)}Z`;
};
const LEFT = [220, 48];
const RIGHT = [340, 48];
const MERGE = [280, 156];
const PATHS = [
  CHEVRON,
  bar(174, 360, 220, 52), // the cursor, shellbell's exactly
  branch(LEFT, MERGE, 40), // a branch
  branch(RIGHT, MERGE, 40), // and another
  node(LEFT[0], LEFT[1], 28),
  node(RIGHT[0], RIGHT[1], 28),
  node(MERGE[0], MERGE[1], 30), // meeting in one commit
];

/** @param {string} [fill] */
export function mark(fill = TEAL) {
  return PATHS.map((d) => `<path d="${d}" fill="${fill}"/>`).join('');
}
/** @param {string} title @param {string} body @param {string} [box] */
export function svg(title, body, box = '0 0 1024 1024') {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box}"><title>${title}</title>${body}</svg>\n`;
}
/** @param {string} [fill] @param {number} [width] */
export function centeredMark(fill = TEAL, width = 650) {
  const scale = width / 360;
  return `<g transform="translate(${(1024 - width) / 2} ${(1024 - 280 * scale) / 2}) scale(${scale})">${mark(fill)}</g>`;
}
// Plate and gloss: shellbell's, unchanged, so the three sit together.
export const glossDefs = `<defs>
  <linearGradient id="plate" x1="0" y1="0" x2="0.85" y2="1">
    <stop stop-color="#353942"/><stop offset="0.48" stop-color="#17191D"/><stop offset="1" stop-color="#090B0E"/>
  </linearGradient>
  <linearGradient id="glass" x1="0" y1="0" x2="0.3" y2="1">
    <stop stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="0.65" stop-color="#FFFFFF" stop-opacity="0.035"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
  </linearGradient>
  <linearGradient id="rim" x1="0" y1="0" x2="0.7" y2="1">
    <stop stop-color="#FFFFFF" stop-opacity="0.35"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.04"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.09"/>
  </linearGradient>
</defs>`;
export function plate({ rounded = false, flat = false } = {}) {
  return `<rect width="1024" height="1024" rx="${rounded ? 224 : 0}" fill="${flat ? INK : 'url(#plate)'}"/>`;
}
/** @param {boolean} [rounded] */
export function gloss(rounded = false) {
  return `<clipPath id="tileClip"><rect width="1024" height="1024" rx="${rounded ? 224 : 0}"/></clipPath>
  <g clip-path="url(#tileClip)"><path d="M0 0H1024V340Q530 540 0 455Z" fill="url(#glass)"/>
  <rect x="2" y="2" width="1020" height="1020" rx="${rounded ? 222 : 0}" fill="none" stroke="url(#rim)" stroke-width="3"/></g>`;
}
export function icon({ rounded = true, flat = false } = {}) {
  return svg(
    'orchid app icon',
    glossDefs + plate({ rounded, flat }) + centeredMark(TEAL) + (flat ? '' : gloss(rounded)),
  );
}
/** The bare symbol, transparent, for inline use. @param {string} [fill] */
export const symbol = (fill = TEAL) => svg('orchid', mark(fill), '-20 -20 400 320');
