const { test, expect } = require('@playwright/test');
const { waitForBootstrap } = require('./helpers');

const CONTRIBUTE_LIST = '/search_contribute/';

const rows = (page) => page.locator('#contribute-table .tabulator-row');
const typeCells = (page) => page.locator('#contribute-table .tabulator-cell[tabulator-field="type"]');
const filteredCount = (page) => page.locator('#table-filtered-count');
const unfilteredCount = (page) => page.locator('#table-unfiltered-count');
const ALL_TYPES = '?types=pull_requests,help_wanted,good_first_issue';

async function openList(page, query = '') {
  await page.goto(CONTRIBUTE_LIST + query);
  await waitForBootstrap(page);
  await expect(rows(page).first()).toBeVisible();
}

async function count(locator) {
  return parseInt(await locator.textContent(), 10);
}

test('contribute list shows issues but not pull requests by default', async ({ page }) => {
  await openList(page);
  const total = await count(unfilteredCount(page));
  expect(total).toBeGreaterThan(0);
  await expect(page.getByRole('checkbox', { name: 'Pull requests' })).not.toBeChecked();
  await expect(page.getByRole('checkbox', { name: 'Help wanted' })).toBeChecked();
  await expect(page.getByRole('checkbox', { name: 'Good first issue' })).toBeChecked();
  await expect(typeCells(page).filter({ hasText: /PR/ })).toHaveCount(0);
  expect(await count(filteredCount(page))).toBeLessThan(total);

  await openList(page, ALL_TYPES);
  await expect(filteredCount(page)).toHaveText(String(total));
});

test('title and org link to GitHub, repo links to the repo page', async ({ page }) => {
  await openList(page);
  const row = rows(page).first();
  await expect(row.locator('[tabulator-field="title"] a')).toHaveAttribute('href', /^https:\/\/github\.com\//);
  await expect(row.locator('[tabulator-field="repo"] a')).toHaveAttribute('href', /\/r\/[^/]+\/$/);
  const org = row.locator('[tabulator-field="org"] a');
  await expect(org).toHaveAttribute('href', `https://github.com/${(await org.textContent()).trim()}`);
});

test('author links to the author GitHub page', async ({ page }) => {
  await openList(page);
  const author = page.locator('#contribute-table .tabulator-cell[tabulator-field="author"] a').first();
  const login = await author.textContent();
  expect(login).toBeTruthy();
  await expect(author).toHaveAttribute('href', `https://github.com/${login}`);
});

test('pull requests opened by bots are not listed', async ({ page }) => {
  // Searching by author covers all rows, not only those rendered on screen.
  await openList(page, ALL_TYPES);
  const login = (await rows(page).first().locator('[tabulator-field="author"]').textContent()).trim();
  await openList(page, `${ALL_TYPES}&contribute=author:${login}`);
  await expect.poll(() => count(filteredCount(page))).toBeGreaterThan(0);
  for (const bot of ['mergify', 'dependabot', 'renovate']) {
    await page.goto(`${CONTRIBUTE_LIST}${ALL_TYPES}&contribute=author:${bot}`);
    await waitForBootstrap(page);
    await expect(filteredCount(page)).toHaveText('0');
  }
});

test('turning on pull requests shows them and is kept in the URL', async ({ page }) => {
  await openList(page);
  const issues = await count(filteredCount(page));
  await page.getByText('Pull requests', { exact: true }).click();
  await expect(page.getByRole('checkbox', { name: 'Pull requests' })).toBeChecked();
  await expect(page).toHaveURL(/types=pull_requests(%2C|,)help_wanted(%2C|,)good_first_issue/);
  await expect.poll(() => count(filteredCount(page))).toBeGreaterThan(issues);

  await page.reload();
  await waitForBootstrap(page);
  await expect(page.getByRole('checkbox', { name: 'Pull requests' })).toBeChecked();
  await expect.poll(() => count(filteredCount(page))).toBeGreaterThan(issues);

  await page.getByText('Pull requests', { exact: true }).click();
  await expect(page).not.toHaveURL(/types=/);
  await expect(typeCells(page).filter({ hasText: /PR/ })).toHaveCount(0);
});

test('Hide draft PRs hides draft pull requests', async ({ page }) => {
  await openList(page, ALL_TYPES);
  const total = await count(unfilteredCount(page));
  await page.getByRole('checkbox', { name: 'Hide draft PRs' }).check();
  await expect(page).toHaveURL(/drafts=hide/);
  await expect(typeCells(page).filter({ hasText: 'Draft PR' })).toHaveCount(0);
  expect(await count(filteredCount(page))).toBeLessThanOrEqual(total);
});

test('search narrows the list and sets the query parameter', async ({ page }) => {
  await openList(page, ALL_TYPES);
  const total = await count(filteredCount(page));
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
