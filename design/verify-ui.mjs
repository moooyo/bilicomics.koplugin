// Run only on the authorized remote verification environment.
import { createRequire } from "node:module";
import fs from "node:fs/promises";
import path from "node:path";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "/opt/goby-admin-ui/node_modules/playwright-core");
const base = process.argv[2];
const output = process.argv[3];
await fs.mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_PATH || undefined, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1440, height: 1060 }, deviceScaleFactor: 1 });
const errors = [];
page.on("pageerror", error => errors.push(error.message));
const checks = [];
function check(name, passed, detail = null) {
  checks.push({ name, passed, detail });
  if (!passed) throw new Error(name + ": " + JSON.stringify(detail));
}
async function open(view, extra = "") {
  await page.goto(`${base}/?view=${view}${extra}`, { waitUntil: "networkidle" });
  await page.waitForFunction(() => window.__prototypeReady === true);
}
const routes = ["continue", "following", "detail", "search", "downloads", "settings", "reader", "purchase"];
const measurements = [];
for (const view of routes) {
  await open(view);
  await page.locator(".device-screen").screenshot({ path: path.join(output, `${view}.png`) });
  measurements.push(await page.evaluate(() => {
    const screen = document.querySelector(".device-screen");
    const content = document.querySelector(".bc-content");
    return { view: screen.dataset.screen, screenWidth: screen.clientWidth, screenOverflowX: screen.scrollWidth - screen.clientWidth,
      contentOverflowY: content ? content.scrollHeight - content.clientHeight : 0,
      contentOverflowX: content ? content.scrollWidth - content.clientWidth : 0 };
  }));
  if (["continue", "following", "detail", "downloads"].includes(view)) {
    check(`base_${view}_fits_page`, measurements.at(-1).contentOverflowY <= 2, measurements.at(-1));
  }
}
await open("continue");
await page.screenshot({ path: path.join(output, "desktop.png"), fullPage: true });
await page.locator('.device-screen [data-action="open-reader"]').click();
check("resume_opens_reader", await page.locator('[data-screen="reader"]').count() === 1);
await page.locator('[data-action="reader-menu"]').first().click();
check("reader_has_plugin_menu", await page.getByRole("dialog").count() === 1);
await page.locator('[data-action="reader-catalog"]').click();
await page.locator('[data-action="select-downloads"]').click();
check("locked_download_checkboxes_disabled", await page.locator('.episode-check:disabled').count() > 0);
await page.locator('[data-action="select-readable"]').click();
check("download_selection_enables_action", await page.locator('[data-action="confirm-download"]').isEnabled());
await page.locator('[data-action="confirm-download"]').click();
check("download_selection_opens_queue", await page.locator('[data-screen="downloads"]').count() === 1);

await open("purchase");
await page.locator('[data-action="submit-purchase"]').click();
check("purchase_pending_disables_resubmission", await page.locator('[data-action="submit-purchase"]').isDisabled());
check("purchase_pending_freezes_scope", await page.locator('[data-action="purchase-mode"]').first().isDisabled());
await page.waitForSelector('[data-action="purchase-read"]');
await page.locator('[data-action="purchase-read"]').click();
check("purchase_success_resumes_reader", await page.locator('[data-screen="reader"]').count() === 1);
await open("purchase");
await page.locator('[data-action="purchase-mode"][data-mode="batch"]').click();
await page.locator(".device-screen").screenshot({ path: path.join(output, "purchase-batch.png") });
await page.locator('[data-action="submit-purchase"]').click();
await page.waitForSelector('[data-action="purchase-read"]');
check("batch_confirmation_preserves_chapter_count", (await page.locator(".purchase-state h3").innerText()).includes("5"));
await open("purchase", "&scenario=low");
check("insufficient_balance_disables_payment", await page.locator('[data-action="submit-purchase"]').isDisabled());
check("no_recharge_entry", (await page.locator('[role="dialog"]').innerText()).includes("\u5145\u503c") === false);
await page.locator(".device-screen").screenshot({ path: path.join(output, "purchase-low.png") });
await open("purchase", "&scenario=unknown");
check("unknown_has_no_pay_action", await page.locator('[data-action="submit-purchase"]').count() === 0);
await page.locator('[data-action="close-modal"]').first().click();
await page.locator('[data-action="open-purchase"]').click();
check("unknown_survives_dialog_reopen", await page.locator('[data-action="refresh-purchase"]').count() === 1);
await page.locator(".device-screen").screenshot({ path: path.join(output, "purchase-unknown.png") });
await page.locator('[data-action="refresh-purchase"]').click();
check("unknown_resolves_to_access", await page.locator('[data-action="purchase-read"]').count() === 1);
await open("purchase", "&scenario=loadfail");
check("paid_load_failure_offers_retry_without_payment", await page.locator('[data-action="purchase-read"]').count() === 1 && await page.locator('[data-action="submit-purchase"]').count() === 0);

await open("downloads", "&offline=1");
await page.locator('[data-action="read-downloaded"]').first().click();
check("downloaded_chapter_opens_offline", await page.locator('[data-screen="reader"]').count() === 1);
await open("search");
await page.locator("#search-input").fill("\u5c71\u6d77");
await page.locator('#comic-search button[type="submit"]').click();
check("search_filters_results", await page.locator(".follow-row").count() === 1);
for (const view of ["continue", "detail", "following"]) {
  await open(view, "&size=large");
  const overflow = await page.locator(".bc-content").evaluate(element => element.scrollHeight - element.clientHeight);
  check(`large_${view}_fits_page`, overflow <= 2, overflow);
}

await page.setViewportSize({ width: 390, height: 1000 });
for (const view of ["continue", "detail", "purchase", "downloads", "settings"]) {
  await open(view);
  const overflow = await page.evaluate(() => ({ body: document.documentElement.scrollWidth - innerWidth,
    screen: document.querySelector(".device-screen").scrollWidth - document.querySelector(".device-screen").clientWidth }));
  check(`mobile_${view}_no_horizontal_overflow`, overflow.body <= 1 && overflow.screen <= 1, overflow);
}
await open("continue");
await page.screenshot({ path: path.join(output, "mobile.png"), fullPage: true });
check("no_browser_runtime_errors", errors.length === 0, errors);
await fs.writeFile(path.join(output, "verification.json"), JSON.stringify({ checks, measurements, errors }, null, 2));
console.log(JSON.stringify({ checks: checks.length, passed: checks.filter(item => item.passed).length, measurements, errors }, null, 2));
await browser.close();
