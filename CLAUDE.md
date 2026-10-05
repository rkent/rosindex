# CLAUDE.md

## Overview

This repository contains a Jekyll documentation generator for packages in the ROS 2 ecosystem (ROS Index). It discovers repositories, scrapes package metadata and docs, and generates a static website.

Key locations:
- `_plugins/` – Jekyll plugins (main logic in `rosindex_generator.rb`)
- `_ruby_libs/` – Ruby helpers, including `discovery.rb`
- `_scripts/` – helper scripts (pip/debian package descriptions)
- `_config.yml`, `_config_devel.yml`, `index.yml`, `_config/` – Jekyll/site configuration
- `_data/remotes.yml` – repositories imported into `_remotes/` via `vcs`
- `_layouts/`, `_includes/`, `_sass/` – site templates and styles

## Building

- **Always build under Docker** using `docker/build.sh` (builds the `rosindex/rosindex` image). Use `docker/run.sh <command>` to run commands inside the container, e.g. `docker/run.sh make test-build`.
- **A full build (`make build`) is impractical during development.** Use the Makefile target `test-build` instead; it uses `_config_devel.yml` to limit the scope.
- After a build, the output is a static website in `_site/`. That folder is sufficient to host or inspect the result; no further server is required.

## UI tests (Bootstrap upgrade preparation)

The site uses Bootstrap v3.3.2 (`bootstrap/`), which is to be upgraded. `tests/` holds Playwright browser tests that pin down current behavior (tabs, dropdowns, distro switch, responsive layout, visual snapshots) so regressions are visible after the upgrade.

- Build first (`docker/run.sh make test-build`), then run `docker/test.sh`. It runs the tests in the official Playwright Docker image (the Jekyll image has no npm or browsers) against `_site/`, served with `python3 -m http.server`. Extra arguments pass through, e.g. `docker/test.sh specs/tabs.spec.js`.
- `docker/test.sh --update-snapshots` regenerates the visual baselines in `tests/specs/__screenshots__/`; only do this deliberately (baselines should be recorded on the current Bootstrap version). Baselines are rendered in the container, so don't generate them on the host.
- Tests assert on behavior, not Bootstrap class names. `@playwright/test` in `tests/package.json` must match the image tag in `docker/test.sh`.
