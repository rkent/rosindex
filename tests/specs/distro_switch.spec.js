const { test, expect } = require('@playwright/test');
const { PACKAGE_PAGE, waitForBootstrap } = require('./helpers');

test('distro switch shows only the selected distro content', async ({ page }) => {
  await page.goto(PACKAGE_PAGE);
  await waitForBootstrap(page);
  await page.locator('#jazzy-option').click();
  await expect(page.locator('.distro-jazzy').first()).toBeVisible();
  await expect(page.locator('.distro-humble').first()).toBeHidden();
  await page.locator('#humble-option').click();
  await expect(page.locator('.distro-humble').first()).toBeVisible();
  await expect(page.locator('.distro-jazzy').first()).toBeHidden();
});

test('distro choice is stored in the rosdistro cookie', async ({ page, context }) => {
  await page.goto(PACKAGE_PAGE);
  await waitForBootstrap(page);
  await page.locator('#jazzy-option').click();
  const cookies = await context.cookies();
  expect(cookies.find((c) => c.name === 'rosdistro')?.value).toBe('jazzy');
});

test('"Older" dropdown opens', async ({ page }) => {
  await page.goto(PACKAGE_PAGE);
  await waitForBootstrap(page);
  await page.locator('#older-distro-button').click();
  await expect(page.locator('.older-distro-option').first()).toBeVisible();
});
