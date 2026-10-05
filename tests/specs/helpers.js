// Pages used by the tests. Packages/repos are chosen because they exist in the
// test-build output; adjust if the devel config changes the package set.
exports.PACKAGE_PAGE = '/p/abb_common/';
exports.REPO_PAGE = '/r/abb/';
exports.HOME_PAGE = '/';

// Wait until jQuery and the Bootstrap components are loaded.
exports.waitForBootstrap = async (page) => {
  await page.waitForFunction(() => window.jQuery && window.bootstrap && window.bootstrap.Tab && window.bootstrap.Dropdown);
};

// Bootstrap hides inactive panes with display:none; "visible" is the
// behavioral check, independent of class names.
