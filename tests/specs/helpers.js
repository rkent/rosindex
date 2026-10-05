// Pages used by the tests. Packages/repos are chosen because they exist in the
// test-build output; adjust if the devel config changes the package set.
exports.PACKAGE_PAGE = '/p/abb_common/';
exports.REPO_PAGE = '/r/abb/';
exports.HOME_PAGE = '/';

// Wait until the page's jQuery and Bootstrap plugins are loaded.
exports.waitForBootstrap = async (page) => {
  await page.waitForFunction(() => window.jQuery && window.jQuery.fn.tab && window.jQuery.fn.dropdown);
};

// Bootstrap 3 hides inactive panes with display:none; "visible" is the
// behavioral check, independent of class names.
