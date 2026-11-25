// Captures every tile of the gallery (`?window=gallery&still=1`) as its own JPEG, plus one contact sheet per section.
// Usage: node scripts/capture-gallery.mjs <output directory> [scale=2] [filter]
// Needs the dev server running (`pnpm dev`, port 1420) and Playwright's Chromium (`npx playwright install chromium`).
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

const outputDirectory = process.argv[2] ?? 'docs/ui-captures';
const deviceScaleFactor = Number(process.argv[3] ?? 2);
const nameFilter = process.argv[4] ?? '';

const browser = await chromium.launch();
const pageErrors = [];
for (const colorScheme of ['light']) {
  const page = await browser.newPage({ viewport: { width: 1900, height: 1200 }, deviceScaleFactor, colorScheme });
  page.on('pageerror', (error) => pageErrors.push(error.message));
  page.on('console', (message) => message.type() === 'error' && pageErrors.push(message.text()));
  await page.goto('http://localhost:1420/?window=gallery&still=1', { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(1500);

  const tiles = await page.locator('[data-capture]').all();
  for (const tile of tiles) {
    const captureName = await tile.getAttribute('data-capture');
    if (nameFilter && !captureName.includes(nameFilter)) continue;
    const group = captureName.split('-')[0];
    const directory = path.join(outputDirectory, group);
    await mkdir(directory, { recursive: true });
    await tile.screenshot({ path: path.join(directory, `${captureName}.jpg`), type: 'jpeg', quality: 72, animations: 'disabled' });
  }

  if (!nameFilter) {
    // Contact sheets are for an overview, so they are taken at 1x whatever the tile scale.
    const sheetPage = await browser.newPage({ viewport: { width: 1900, height: 1200 }, deviceScaleFactor: 1, colorScheme });
    await sheetPage.goto('http://localhost:1420/?window=gallery&still=1', { waitUntil: 'networkidle' });
    await sheetPage.evaluate(() => document.fonts.ready);
    await sheetPage.waitForTimeout(1500);
    const sections = await sheetPage.locator('.gallery-section').all();
    await mkdir(path.join(outputDirectory, 'sheets'), { recursive: true });
    for (const [sectionIndex, section] of sections.entries()) {
      const title = (await section.locator(':scope > h2').textContent()) ?? `section-${sectionIndex}`;
      const fileName = title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
      await section.screenshot({ path: path.join(outputDirectory, 'sheets', `${fileName}.jpg`), type: 'jpeg', quality: 70, animations: 'disabled' });
    }
    await sheetPage.close();
  }
  await page.close();
}
await browser.close();
if (pageErrors.length > 0) {
  console.error('Page errors:\n' + pageErrors.join('\n'));
  process.exitCode = 1;
}
