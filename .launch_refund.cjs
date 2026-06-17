const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: false, args: ['--start-maximized'] });
  const context = await browser.newContext({ viewport: null });
  const page = await context.newPage();
  await page.goto('http://localhost:4000/sign-in', { waitUntil: 'domcontentloaded' });
  await new Promise(r => setTimeout(r, 800));
  await page.fill('input[type=email]', 'dev@nspark.test');
  await page.fill('input[type=password]', 'nspark123');
  await page.click('button[type=submit]');
  await new Promise(r => setTimeout(r, 2000));
  await page.goto('http://localhost:4000/studio/97b1becf-805c-47a1-95a0-a88229fc0410', { waitUntil: 'domcontentloaded' });
  console.log('Refund agent studio open. Browser will stay open until this process is killed.');
  // Keep the window open.
  await new Promise(() => {});
})().catch(e => { console.error(e.message); process.exit(1); });
