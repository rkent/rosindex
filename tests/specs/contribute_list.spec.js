const { test, expect } = require('@playwright/test');
const { waitForBootstrap } = require('./helpers');

const CONTRIBUTE_LIST = '/search_contribute/';

const rows = (page) => page.locator('#contribute-table .tabulator-row');
const typeCells = (page) => page.locator('#contribute-table .tabulator-cell[tabulator-field="type"]');
const filteredCount = (page) => page.locator('#table-filtered-count');
const unfilteredCount = (page) => page.locator('#table-unfiltered-count');

async function openList(page, query = '') {
  await page.goto(CONTRIBUTE_LIST + query);
  await waitForBootstrap(page);
  await expect(rows(page).first()).toBeVisible();
}

async function count(locator) {
  return parseInt(await locator.textContent(), 10);
}

test('contribute list shows all items by default', async ({ page }) => {
  await openList(page);
  const total = await count(unfilteredCount(page));
  expect(total).toBeGreaterThan(0);
  await expect(filteredCount(page)).toHaveText(String(total));
  await expect(page.getByRole('checkbox', { name: 'Pull requests' })).toBeChecked();
  await expect(page.getByRole('checkbox', { name: 'Help wanted' })).toBeChecked();
  await expect(page.getByRole('checkbox', { name: 'Good first issue' })).toBeChecked();
});

test('item number and title link to GitHub, repo links to the repo page', async ({ page }) => {
  await openList(page);
  const row = rows(page).first();
  await expect(row.locator('[tabulator-field="title"] a')).toHaveAttribute('href', /^https:\/\/github\.com\//);
  await expect(row.locator('[tabulator-field="number"] a')).toHaveAttribute('href', /^https:\/\/github\.com\//);
  await expect(row.locator('[tabulator-field="repo"] a')).toHaveAttribute('href', /\/r\/[^/]+\/$/);
});

test('turning off pull requests hides them and is kept in the URL', async ({ page }) => {
  await openList(page);
  const total = await count(unfilteredCount(page));
  await page.getByText('Pull requests', { exact: true }).click();
  await expect(page.getByRole('checkbox', { name: 'Pull requests' })).not.toBeChecked();
  await expect(page).toHaveURL(/types=help_wanted%2Cgood_first_issue|types=help_wanted,good_first_issue/);
  await expect.poll(() => count(filteredCount(page))).toBeLessThan(total);
  await expect(typeCells(page).filter({ hasText: /PR/ })).toHaveCount(0);

  await page.reload();
  await waitForBootstrap(page);
  await expect(page.getByRole('checkbox', { name: 'Pull requests' })).not.toBeChecked();
  await expect.poll(() => count(filteredCount(page))).toBeLessThan(total);
});

test('Hide draft PRs hides draft pull requests', async ({ page }) => {
  await openList(page);
  const total = await count(unfilteredCount(page));
  await page.getByRole('checkbox', { name: 'Hide draft PRs' }).check();
  await expect(page).toHaveURL(/drafts=hide/);
  await expect(typeCells(page).filter({ hasText: 'Draft PR' })).toHaveCount(0);
  expect(await count(filteredCount(page))).toBeLessThanOrEqual(total);
});

test('search narrows the list and sets the query parameter', async ({ page }) => {
  await openList(page);
  const total = await count(unfilteredCount(page));
  const repo = await rows(page).first().locator('[tabulator-field="repo"]').textContent();
  await page.locator('#search-query').fill(repo.trim());
  await page.locator('#search-query').press('Enter');
  await expect(page).toHaveURL(new RegExp(`contribute=${repo.trim()}`));
  await expect(page.locator('#search-enable-box')).toBeChecked();
  await expect.poll(() => count(filteredCount(page))).toBeLessThan(total);

  await page.locator('#search-enable-box').uncheck();
  await expect(filteredCount(page)).toHaveText(String(total));
});

test('header Contribute button opens the contribute list', async ({ page }) => {
  await page.setViewportSize({ width: 1200, height: 800 });
  await page.goto('/');
  await waitForBootstrap(page);
  await page.locator('header').getByRole('button', { name: 'Contribute' }).click();
  await expect(page).toHaveURL(/\/search_contribute\/?$/);
  await expect(rows(page).first()).toBeVisible();
});

test('narrow header Lists dropdown has the contribute list', async ({ page }) => {
  await page.setViewportSize({ width: 500, height: 800 });
  await page.goto('/');
  await waitForBootstrap(page);
  await page.locator('#hLabel').click();
  await page.locator('[aria-labelledby="hLabel"]').getByRole('link', { name: 'Contribute' }).click();
  await expect(page).toHaveURL(/\/search_contribute\/?$/);
});
