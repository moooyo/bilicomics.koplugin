// Render the design board on the authorized remote environment.
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE);
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_PATH, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1296, height: 1000 }, deviceScaleFactor: 1 });
await page.goto(process.argv[2] + "/overview.html", { waitUntil: "networkidle" });
await page.waitForFunction(() => window.__overviewReady);
for (const frame of page.frames().filter(frame => frame !== page.mainFrame())) {
  await frame.waitForFunction(() => window.__prototypeReady === true);
  await frame.waitForFunction(() => [...document.images].every(image => image.complete));
}
await page.screenshot({ path: process.argv[3], fullPage: true });
await browser.close();
