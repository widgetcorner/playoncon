// Rebuild the two App Store creative placements from editable SVG sources.
// Requires Node.js and sharp. POC_SHARP_MODULE may point to an existing module.
import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const require = createRequire(import.meta.url);
const sharp = require(process.env.POC_SHARP_MODULE || 'sharp');
const output = dirname(fileURLToPath(import.meta.url));
const project = resolve(output, '../../..');
const locale = 'en-US';
const palette = {
  forest: '#2D5E3E', deep: '#1F4530', night: '#173925', cream: '#F0E9D8',
  moss: '#8FC79A', saddle: '#8B6F47', rust: '#AD7044', lake: '#527A63',
};
const sourcePaths = {
  logo: 'assets/branding/poc-logo.png',
  schedule: 'design/app-store/iphone/01-all-sessions.png',
  map: 'design/app-store/iphone/04-venue-map.png',
};
const buffers = Object.fromEntries(await Promise.all(Object.entries(sourcePaths).map(async ([name, path]) => [name, await readFile(resolve(project, path))])));
const data = name => `data:image/png;base64,${buffers[name].toString('base64')}`;
const hash = buffer => createHash('sha256').update(buffer).digest('hex');
const text = (x, y, value, size, fill = palette.cream, extras = '') =>
  `<text x="${x}" y="${y}" fill="${fill}" font-size="${size}" font-family="Arial Rounded MT Bold, Arial, sans-serif" font-weight="700" ${extras}>${value}</text>`;
const body = (x, y, value, size, fill = palette.cream, extras = '') =>
  `<text x="${x}" y="${y}" fill="${fill}" font-size="${size}" font-family="Arial, sans-serif" ${extras}>${value}</text>`;

function tree(x, y, size, fill, opacity = 1) {
  return `<g transform="translate(${x} ${y}) scale(${size})" fill="${fill}" opacity="${opacity}">
    <path d="M0 0 L-43 64 H-24 L-64 119 H-36 L-87 179 H-9 V207 H9 V179 H87 L36 119 H64 L24 64 H43 Z"/>
  </g>`;
}

function star(x, y, size, opacity = 1) {
  return `<path d="M0 -20 L5 -6 L20 0 L5 6 L0 20 L-5 6 L-20 0 L-5 -6 Z" transform="translate(${x} ${y}) scale(${size})" fill="${palette.cream}" opacity="${opacity}"/>`;
}

function dice(x, y, size, angle = 0) {
  return `<g transform="translate(${x} ${y}) rotate(${angle}) scale(${size})" stroke="${palette.moss}" stroke-width="3" stroke-linejoin="round" fill="none" opacity=".36">
    <path d="M0 -53 L50 -17 L31 43 L-31 43 L-50 -17 Z M0 -53 L-20 -8 L20 -8 Z M-50 -17 L-20 -8 L-31 43 M50 -17 L20 -8 L31 43 M-31 43 L0 17 L31 43 M-20 -8 L0 17 L20 -8 M-50 -17 L0 17 L50 -17"/>
  </g>`;
}

function contours(width, height) {
  const paths = [];
  for (let i = 0; i < 11; i++) {
    const off = i * 71;
    paths.push(`<path d="M${-500 + off} ${-110 + off} C${390 + off} ${-720 + off}, ${1490 + off} ${-490 + off}, ${1550 + off} ${220 + off} S${2950 + off} ${680 + off}, ${width + 410 + off} ${50 + off}"/>`);
  }
  for (let i = 0; i < 7; i++) {
    const off = i * 74;
    paths.push(`<path d="M${-250 - off} ${height - 60 - off} C${510 + off} ${height - 740 - off}, ${1220 + off} ${height - 360 - off}, ${1980 + off} ${height - 150 - off} S${3290 + off} ${height + 280 - off}, ${width + 430 + off} ${height - 360 - off}"/>`);
  }
  return `<g stroke="${palette.moss}" stroke-width="3" opacity=".085" fill="none">${paths.join('')}</g>`;
}

function defs() {
  return `<defs>
    <radialGradient id="glow" cx="66%" cy="43%" r="70%"><stop stop-color="${palette.forest}"/><stop offset="1" stop-color="${palette.night}"/></radialGradient>
    <linearGradient id="shore" x1="0" y1="0" x2="0" y2="1"><stop stop-color="${palette.lake}"/><stop offset="1" stop-color="${palette.deep}"/></linearGradient>
    <filter id="badge-shadow" x="-50%" y="-50%" width="200%" height="200%"><feDropShadow dx="0" dy="20" stdDeviation="24" flood-color="#07190E" flood-opacity=".26"/></filter>
    <filter id="phone-shadow" x="-50%" y="-50%" width="200%" height="200%"><feDropShadow dx="0" dy="30" stdDeviation="26" flood-color="#05180D" flood-opacity=".4"/></filter>
    <pattern id="grain" width="37" height="43" patternUnits="userSpaceOnUse"><circle cx="4" cy="13" r="1" fill="${palette.cream}" opacity=".055"/><circle cx="28" cy="31" r=".8" fill="${palette.cream}" opacity=".05"/></pattern>
  </defs>`;
}

function backdrop(width, height, kind) {
  const base = `<rect width="${width}" height="${height}" fill="url(#glow)"/>${contours(width, height)}<rect width="${width}" height="${height}" fill="url(#grain)"/>`;
  const lower = kind === 'header' ? 1280 : 2200;
  return `${base}
    <path d="M0 ${lower + 140} C520 ${lower - 20}, 970 ${lower - 70}, 1570 ${lower + 80} S2670 ${lower + 80}, 3840 ${lower - 20} V${height} H0Z" fill="url(#shore)" opacity=".76"/>
    <path d="M0 ${lower + 305} C720 ${lower + 58}, 1030 ${lower + 335}, 1700 ${lower + 165} S2980 ${lower + 245}, 3840 ${lower + 85} V${height} H0Z" fill="${palette.night}"/>
    ${tree(185, lower - 600, 3.8, palette.night)}
    ${tree(510, lower - 480, 2.8, palette.deep)}
    ${tree(3480, lower - 560, 3.6, palette.night)}
    ${tree(3720, lower - 690, 4.5, palette.deep)}
    ${tree(3160, lower - 250, 2.4, palette.night)}
    <g stroke="${palette.moss}" opacity=".2" stroke-width="3" fill="none"><path d="M580 ${lower + 100} Q800 ${lower + 45} 960 ${lower + 103}"/><path d="M2560 ${lower + 120} Q2800 ${lower + 170} 3090 ${lower + 95}"/></g>
    ${star(746, kind === 'header' ? 560 : 540, 1.8, .32)}
    ${star(3160, kind === 'header' ? 450 : 520, 1.5, .28)}
    ${star(2990, kind === 'header' ? 1210 : 1870, 1.1, .3)}
    ${dice(625, kind === 'header' ? 390 : 1560, 1.65, -12)}
    ${dice(3230, kind === 'header' ? 810 : 1820, 1.5, 18)}
  `;
}

function badge(x, y, size) {
  return `<g filter="url(#badge-shadow)"><circle cx="${x + size / 2}" cy="${y + size / 2}" r="${size / 2 + 6}" fill="${palette.cream}"/><image x="${x}" y="${y}" width="${size}" height="${size}" href="${data('logo')}"/></g>`;
}

function phone(name, x, y, width, key) {
  const screenHeight = width * 2622 / 1206;
  const border = 12;
  return `<defs><clipPath id="screen-${key}"><rect x="${x}" y="${y}" width="${width}" height="${screenHeight}" rx="45"/></clipPath></defs>
    <g filter="url(#phone-shadow)"><rect x="${x - border}" y="${y - border}" width="${width + 2 * border}" height="${screenHeight + 2 * border}" rx="56" fill="#18201B" stroke="#9BA89C" stroke-width="3"/>
    <image x="${x}" y="${y}" width="${width}" height="${screenHeight}" href="${data(name)}" clip-path="url(#screen-${key})"/></g>`;
}

function header() {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="1646" viewBox="0 0 3840 1646" role="img" aria-label="Play On Con. Camp. Con. Community. Forest landscape and convention badge.">
    ${defs()}${backdrop(3840, 1646, 'header')}
    <g id="header-brand-copy">
      ${body(1140, 625, 'CAMP. CON. COMMUNITY.', 46, palette.moss, 'font-weight="700" letter-spacing="6"')}
      ${text(1126, 850, 'PLAY ON', 176, palette.cream, 'letter-spacing="-5"')}
      ${text(1126, 1045, 'CON', 176, palette.cream, 'letter-spacing="-5"')}
    </g>
    ${badge(2120, 540, 570)}
    ${star(2045, 680, 1.2, .55)}
  </svg>`;
}

function search() {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="2560" viewBox="0 0 3840 2560" role="img" aria-label="Play On Con: Your con, in your pocket. Schedule, saved sessions, and venue map. Two real app screens.">
    ${defs()}${backdrop(3840, 2560, 'search')}
    ${badge(900, 810, 155)}
    ${body(1095, 901, 'PLAY ON CON', 56, palette.cream, 'font-weight="700" letter-spacing="3"')}
    <g id="search-benefit-copy">
      ${text(893, 1167, 'Your con,', 122, palette.cream, 'letter-spacing="-3"')}
      ${text(893, 1314, 'in your pocket.', 122, palette.moss, 'letter-spacing="-3"')}
      ${body(900, 1481, 'Schedule. Save. Explore.', 54, palette.cream)}
      <path d="M903 1557 H976" stroke="${palette.rust}" stroke-width="8" stroke-linecap="round"/>
      ${body(900, 1636, 'Your Play On Con companion.', 41, palette.cream, 'opacity=".77"')}
    </g>
    ${phone('map', 2507, 846, 389, 'map')}
    ${phone('schedule', 2055, 824, 412, 'schedule')}
  </svg>`;
}

const specifications = 'https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications';
const jobs = [
  { name: 'header', placement: 'product_page_header', size: [3840, 1646], safeArea: { x: 1097, y: 493, width: 1646, height: 661 }, focalBounds: { x: 1126, y: 540, width: 1564, height: 570 }, svg: header(), sources: ['logo'], template: 'https://devimages-cdn.apple.com/design/resources/download/app-store/creative_assets-product_page_header_template-static.psd' },
  { name: 'search-result', placement: 'search_results', size: [3840, 2560], safeArea: { x: 836, y: 765, width: 2168, height: 1030 }, focalBounds: { x: 893, y: 810, width: 2015, height: 922 }, svg: search(), sources: ['logo', 'schedule', 'map'], template: 'https://devimages-cdn.apple.com/design/resources/download/app-store/creative_assets-search_results_template-static.psd' },
];

await mkdir(resolve(output, locale), { recursive: true });
await mkdir(resolve(output, 'sources'), { recursive: true });
await mkdir(resolve(output, 'previews'), { recursive: true });
const assets = [];
for (const job of jobs) {
  const path = resolve(output, locale, `${job.name}.png`);
  await writeFile(resolve(output, 'sources', `${job.name}.svg`), job.svg);
  await sharp(Buffer.from(job.svg)).flatten({ background: palette.night }).removeAlpha().toColourspace('srgb').png({ compressionLevel: 9 }).toFile(path);
  const info = await sharp(path).metadata();
  if (info.width !== job.size[0] || info.height !== job.size[1] || info.hasAlpha || info.channels !== 3 || info.format !== 'png') throw new Error(`Invalid export: ${job.name}`);
  const safe = job.safeArea, focal = job.focalBounds;
  if (focal.x < safe.x || focal.y < safe.y || focal.x + focal.width > safe.x + safe.width || focal.y + focal.height > safe.y + safe.height) throw new Error(`Focal artwork outside template safe area: ${job.name}`);
  await sharp(path).resize({ width: 1400 }).toFile(resolve(output, 'previews', `${job.name}.png`));
  await sharp(path).extract({ left: safe.x, top: safe.y, width: safe.width, height: safe.height }).resize({ width: 1200 }).toFile(resolve(output, 'previews', `${job.name}-safe-area.png`));
  const exported = await readFile(path);
  assets.push({
    path: `${locale}/${job.name}.png`, placement: job.placement, locale, width: info.width, height: info.height,
    format: info.format, color_space: info.space, channels: info.channels, has_alpha: info.hasAlpha,
    bytes: exported.length, sha256: hash(exported), source_svg: `sources/${job.name}.svg`,
    source_assets: job.sources.map(name => ({ path: sourcePaths[name], sha256: hash(buffers[name]) })),
    source_app_build: job.name === 'search-result' ? '2026.10.6+28 (existing capture manifest)' : null,
    specification_url: specifications, specification_verified_on: '2026-10-07',
    template_url: job.template, template_safe_area: job.safeArea, focal_artwork_bounds: job.focalBounds,
    validation: { exact_dimensions: 'passed', opaque_rgb_png: 'passed', focal_bounds_inside_template_safe_area: 'passed', visual_review: 'pending' },
  });
}
await writeFile(resolve(output, 'manifest.json'), JSON.stringify({
  schema_version: 1, app: 'Play On Con', locale, assets,
  source_app_version_note: 'Project is 2026.10.7+29; the existing iPhone captures are documented as 2026.10.6+28. No app UI or capture content was altered.',
  delivery_status: 'local_files_only',
}, null, 2) + '\n');
console.log(JSON.stringify(assets.map(({ path, width, height, channels, has_alpha }) => ({ path, width, height, channels, has_alpha })), null, 2));
