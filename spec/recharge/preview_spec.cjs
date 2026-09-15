"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const assert = require("node:assert/strict");
const { chromium } = require(process.argv[4]);

async function main() {
  assert.equal(process.platform, "linux", "Run only through ssh test-env.");
  assert.ok(process.env.SSH_CONNECTION, "A remote verification session is required.");
  const root = path.resolve(process.argv[2]);
  const output = path.resolve(process.argv[3]);
  fs.mkdirSync(output, { recursive: false });
  const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
  const errors = [];
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
  page.on("pageerror", error => errors.push(String(error)));
  const url = pathToFileURL(path.join(root, "index.html")).href;
  const report = { host: "test-env", passed: false, imageChecks: 0, networkRequests: 0 };
  await page.route(/^https?:/, route => { report.networkRequests += 1; route.abort(); });
  try {
    await page.goto(url);
    const scenes = await page.locator("#scene-nav button[data-scene-id]").evaluateAll(nodes => nodes.map(node => node.dataset.sceneId));
    assert.ok(scenes.length >= 29);
    for (const size of ["600x800", "480x640"]) {
      await page.locator("#resolution").selectOption(size);
      for (const scene of scenes) {
        await page.locator(`#scene-nav button[data-scene-id="${scene}"]`).click();
        await page.waitForFunction(({ scene, size }) => {
          const image = document.getElementById("main-image");
          return document.getElementById("scene-id").textContent === scene
            && !document.getElementById("image-link").hidden
            && image.complete && image.naturalWidth === Number(size.split("x")[0]);
        }, { scene, size });
        assert.equal(await page.locator("#missing").isVisible(), false);
        report.imageChecks += 1;
      }
    }
    await page.locator("#resolution").selectOption("600x800");
    await page.locator('#scene-nav button[data-scene-id="recharge-pending-no-expiry"]').click();
    await page.locator("#open-zoom").click();
    await page.waitForFunction(() => document.getElementById("viewer").open && !document.getElementById("viewer-image").hidden);
    await page.locator("#native-toggle").click();
    assert.equal(await page.locator("#native-toggle").getAttribute("aria-pressed"), "true");
    await page.keyboard.press("Escape");
    assert.equal(await page.locator("#viewer").isVisible(), false);
    await page.screenshot({ path: path.join(output, "gallery-desktop.png") });
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    await page.screenshot({ path: path.join(output, "gallery-mobile.png") });
    const hiddenPath = path.join(root, "screens/480x640/recharge-pending-no-expiry.png");
    fs.renameSync(hiddenPath, hiddenPath + ".verification-hidden");
    try {
      const missing = await browser.newPage();
      await missing.goto(url + "#scene=recharge-pending-no-expiry&size=480x640");
      await missing.locator("#missing").waitFor({ state: "visible" });
      assert.equal(await missing.locator("#image-link").isVisible(), false);
      assert.equal(await missing.locator("#open-zoom").isDisabled(), true);
      assert.equal(await missing.locator("#original").getAttribute("href"), null);
      await missing.close();
    } finally { fs.renameSync(hiddenPath + ".verification-hidden", hiddenPath); }
    assert.deepEqual(errors, []);
    assert.equal(report.networkRequests, 0);
    report.passed = true;
  } finally {
    await browser.close();
    fs.writeFileSync(path.join(output, "preview-verification.json"), JSON.stringify({ ...report, errors }, null, 2) + "\n");
  }
  console.log(JSON.stringify(report));
}

main().catch(error => { console.error(error); process.exitCode = 1; });
