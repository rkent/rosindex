---
layout: page
title: Help for using the rosindex contribute list
permalink: /help/contribute_list/
breadcrumbs: ['help']
---

# Contribute List Help

**rosindex** provides a [**Contribute**](/search_contribute/) page that lists places where you can help with ROS packages: open pull requests that could use review, and open issues that the maintainers have marked as looking for help. This help page describes the usage of that page.

The list is collected from GitHub when **rosindex** is built, so it may be out of date by a few days. Repositories not hosted on GitHub are not included. At most 100 items of each type are listed for a repository.

## Types of items

- **Pull requests (PR)**: Open pull requests. Reviewing and testing pull requests is a valuable way to help maintainers. A pull request still being worked on by its author is shown as a **Draft PR**.
- **Help wanted**: Open issues with the label `help wanted`, which maintainers use to ask for outside help.
- **Good first issue**: Open issues with the label `good first issue`, which maintainers think are suitable for new contributors.

An issue with both labels is shown once, with both types.

The buttons above the search field show or hide each type of item, and **Hide draft PRs** hides pull requests that are drafts.

## Fields in the contribute list

- Type: The type(s) of the item, as described above.
- \#: The GitHub issue or pull request number. Click it to open the item on GitHub.
- Title: The title of the issue or pull request. Click it to open the item on GitHub.
- Repo: The **rosindex** repository. Click it to see the repository page.
- Org: The GitHub organization or user that owns the repository.
- Stars (★): The number of GitHub stars of the repository.
- Author: The GitHub user who opened the issue or pull request.
- Created, Updated: The dates the item was created and last updated.

By default the list is sorted with the most recently updated items first. Click a column header to sort by that column.

## Searching

**rosindex** uses [lunr search](https://lunrjs.com/) to perform full-text search, as described in the [package list help](/help/package_list/). The contribute list searches these fields:

- title: The title of the issue or pull request.
- repo: The repository name.
- tags: The parts of the repository name, and the repository's GitHub topics.
- org: The GitHub organization.
- author: The GitHub user who opened the item.
- repo_description: The GitHub description of the repository.
- type: `pull_requests`, `help_wanted` or `good_first_issue`.

When a search is performed, the results are sorted by the quality of the search hit.

### Example searches

- `navigation`: Items whose title, repository, or topics mention navigation.
- `+lidar +driver`: Items matching both lidar and driver.
