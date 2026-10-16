#!/usr/bin/env python3

# Copyright 2026 R. Kent James <kent@caspia.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

'''
Get github repo info (stars, description, topics, and contribution suggestions)
from the github graphql api into a json file, for the repos found by discovery.

The graphql api requires a token. Set GITHUB_TOKEN, in a .env file at the root
of this repo or else in the environment.

The results file is a dictionary keyed by repo uri, like:

{
  "https://github.com/ros-industrial/abb_driver.git": {
    "stars": 41,
    "description": "(old) ROS driver for ABB IRC5 / RW5 or RW6 controllers (Simple Message & RAPID)",
    "tags": ["abb", "driver", "irc5", "rapid", "ros", "ros-industrial"],
    "open_issues": 6,
    "help_wanted": {"total": 0, "items": []},
    "good_first_issue": {"total": 0, "items": []},
    "pull_requests": {"total": 1, "items": [{"number": 12, "title": "...", "html_url": "..."}]}
  },
  ...
}
'''

import argparse
import json
from pathlib import Path
import os
import re
import sys
import time

import requests
import yaml

DISCOVERY_RESULTS = '_artifacts/discovery.json'
SCRAPE_ERRORS = '_artifacts/github_scrape_errors.json'
DEFAULT_CONFIG = '_config.yml,index.yml'

GITHUB_GRAPHQL_URL = 'https://api.github.com/graphql'
GITHUB_ENV_FILE = Path(__file__).resolve().parent.parent / '.env'
# Matches https, git, and ssh style github repo uris, capturing owner and repo name
GITHUB_REPO_REGEX = re.compile(
    r'^(?:https?://|git://|ssh://git@|git@)(?:www\.)?github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$')
# Number of repos to get in each graphql query. Larger queries can exceed
# github resource limits, but they are retried as smaller ones
DEFAULT_BATCH_SIZE = 20
# Maximum items in each contribution suggestion list (the most github allows in one page)
LIST_SIZE = 100
REQUEST_TIMEOUT = 60

# Fields to get for each repo. The contribution suggestion lists match those
# shown by js/contribution_suggestions.js
LIST_FIELDS = 'totalCount nodes { number title url }'
LIST_ORDER = 'orderBy: {field: CREATED_AT, direction: DESC}'
REPO_FIELDS = f'''
  stargazerCount
  description
  repositoryTopics(first: 20) {{ nodes {{ topic {{ name }} }} }}
  openIssues: issues(states: OPEN) {{ totalCount }}
  helpWanted: issues(states: OPEN, labels: ["help wanted"], first: {LIST_SIZE}, {LIST_ORDER}) {{ {LIST_FIELDS} }}
  goodFirstIssue: issues(states: OPEN, labels: ["good first issue"], first: {LIST_SIZE}, {LIST_ORDER}) {{ {LIST_FIELDS} }}
  pullRequests(states: OPEN, first: {LIST_SIZE}, {LIST_ORDER}) {{ {LIST_FIELDS} }}
'''


def red(text):
    return f'\033[31m{text}\033[0m'


def green(text):
    return f'\033[32m{text}\033[0m'


def yellow(text):
    return f'\033[33m{text}\033[0m'


class GithubRateLimitError(Exception):
    pass


class ScrapeError:
    # A repo that could not be scraped, saved like the IndexException of the ruby scripts.
    def __init__(self, msg, repo_id='UNKNOWN'):
        self.msg = msg
        self.repo_id = repo_id
        print(red(f'ERROR ({repo_id}): {msg}'))

    def to_dict(self):
        return {'msg': self.msg, 'repo_id': self.repo_id}


def github_token():
    # Get the github api token from the .env file, or else from the environment.
    # The .env file is preferred since it is specific to this repo.
    token = None
    if GITHUB_ENV_FILE.exists():
        for line in GITHUB_ENV_FILE.read_text().splitlines():
            match = re.match(r'^\s*(?:export\s+)?GITHUB_TOKEN\s*=\s*(.*?)\s*$', line)
            if match:
                token = match.group(1).strip('"\'')
    if not token:
        token = os.environ.get('GITHUB_TOKEN')
    return token or None


def repo_selected(config, repo_name, selected_names):
    # Should a discovered repo be used, given the configured limits on repos?
    # Matches repo_selected? in _ruby_libs/common.rb
    whitelist = config.get('repo_name_whitelist') or []
    if whitelist and repo_name not in whitelist:
        return False
    max_repos = config.get('max_repos') or 0
    if repo_name not in (config.get('repo_name_always') or []) and \
            repo_name not in selected_names and max_repos > 0 and len(selected_names) > max_repos:
        return False
    return True


def name_key(match):
    # cache key for a github repo, so each repo is only fetched once however its uri is spelled
    return f'{match.group(1)}/{match.group(2)}'.lower()


def contribution_list(connection):
    # Convert a graphql issue or pull request connection into a list for the scrape file
    return {
        'total': connection['totalCount'],
        'items': [
            {'number': node['number'], 'title': node['title'], 'html_url': node['url']}
            for node in connection['nodes']
        ],
    }


class GithubScraper:
    def __init__(self, token):
        # a persistent session is much faster when making many requests
        self.session = requests.Session()
        self.session.headers.update({
            'Authorization': f'Bearer {token}',
            'User-Agent': 'rosindex',
        })
        # scrape results (or the ScrapeError on failure) keyed by lowercase owner/name
        self.repo_scrape_by_name = {}
        # github api usage, for reporting
        self.api_calls = 0
        self.rate_limit = None
        self.rate_remaining = None
        self.points_used = 0
        # cost of the last api call, if github reported it
        self.last_cost = None
        # progress of scrape_repos, for reporting
        self.scrape_done = 0
        self.scrape_total = 0

    def fetch_graphql(self, query, variables):
        # Get a parsed github graphql response, with 'data' and possibly 'errors'
        self.api_calls += 1
        self.last_cost = None
        response = self.session.post(
            GITHUB_GRAPHQL_URL, json={'query': query, 'variables': variables}, timeout=REQUEST_TIMEOUT)
        if 'x-ratelimit-remaining' in response.headers:
            self.rate_remaining = int(response.headers['x-ratelimit-remaining'])
            self.rate_limit = int(response.headers['x-ratelimit-limit'])

        if not response.ok:
            if response.headers.get('x-ratelimit-remaining') == '0':
                reset_time = time.ctime(int(response.headers['x-ratelimit-reset']))
                raise GithubRateLimitError(f'github api rate limit exceeded, resets at {reset_time}')
            raise RuntimeError(f'github api returned {response.status_code} {response.reason}')
        result = response.json()
        # every query includes rateLimit { cost }, which github reports even for partial failures
        rate_info = (result.get('data') or {}).get('rateLimit') or {}
        if rate_info.get('cost') is not None:
            self.last_cost = rate_info['cost']
            self.points_used += self.last_cost
        errors = result.get('errors') or []
        if any(error.get('type') == 'RATE_LIMITED' for error in errors):
            raise GithubRateLimitError('github api rate limit exceeded')
        if any(error.get('type') == 'RESOURCE_LIMITS_EXCEEDED' for error in errors):
            raise RuntimeError('github api resource limits exceeded')
        if result.get('data') is None:
            raise RuntimeError('github api query failed: ' + '; '.join(error.get('message', '') for error in errors))
        return result

    def cost_text(self):
        # the cost of the last api call, for reporting
        if self.last_cost is None:
            return ''
        return f', cost {self.last_cost} point' + ('' if self.last_cost == 1 else 's')

    def scrape_batch(self, repo_names):
        # Get the info for a batch of github repos, given as (owner, name) pairs,
        # into self.repo_scrape_by_name
        variables = {}
        query_repos = []
        for i, (owner, name) in enumerate(repo_names):
            variables[f'o{i}'] = owner
            variables[f'n{i}'] = name
            query_repos.append(f'r{i}: repository(owner: $o{i}, name: $n{i}) {{ {REPO_FIELDS} }}')
        query_variables = ', '.join(f'${key}: String!' for key in variables)
        # rateLimit gives the points cost of this query, and does not add to it
        query_repos.append('rateLimit { cost }')
        query = f'query({query_variables}) {{\n' + '\n'.join(query_repos) + '\n}'

        start_time = time.time()
        try:
            result = self.fetch_graphql(query, variables)
        except GithubRateLimitError:
            raise
        except Exception as e:
            print(yellow(f'github api call {self.api_calls}: failed for {len(repo_names)} repos'
                         f' in {time.time() - start_time:.1f}s{self.cost_text()}: {e}'))
            if len(repo_names) > 1:
                # large queries can time out, so retry as smaller ones
                print(yellow('retrying as smaller queries'))
                half = len(repo_names) // 2
                self.scrape_batch(repo_names[:half])
                self.scrape_batch(repo_names[half:])
            else:
                owner, name = repo_names[0]
                self.repo_scrape_by_name[f'{owner}/{name}'.lower()] = \
                    ScrapeError(f'Github scrape error. repo: {owner}/{name} error: {e}')
                self.scrape_done += 1
            return

        self.scrape_done += len(repo_names)
        print(green(f'github api call {self.api_calls}: got {len(repo_names)} repos'
                    f' ({self.scrape_done} of {self.scrape_total} done) in {time.time() - start_time:.1f}s'
                    f'{self.cost_text()}, {self.rate_remaining} points remaining'))

        for i, (owner, name) in enumerate(repo_names):
            key = f'{owner}/{name}'.lower()
            repo = result['data'].get(f'r{i}')
            if repo is None or any(value is None for field, value in repo.items() if field != 'description'):
                # a missing repo, or a field that failed
                repo_errors = [error for error in result.get('errors') or []
                               if (error.get('path') or [None])[0] == f'r{i}']
                messages = list(dict.fromkeys(error.get('message', '') for error in repo_errors))
                message = '; '.join(messages) if messages else 'no data returned'
                self.repo_scrape_by_name[key] = \
                    ScrapeError(f'Github scrape error. repo: {owner}/{name} error: {message}')
            else:
                self.repo_scrape_by_name[key] = {
                    'stars': repo['stargazerCount'],
                    'description': (repo['description'] or '').strip(),
                    'tags': [node['topic']['name'] for node in repo['repositoryTopics']['nodes']],
                    'open_issues': repo['openIssues']['totalCount'],
                    'help_wanted': contribution_list(repo['helpWanted']),
                    'good_first_issue': contribution_list(repo['goodFirstIssue']),
                    'pull_requests': contribution_list(repo['pullRequests']),
                }

    def scrape_repos(self, uris, batch_size=DEFAULT_BATCH_SIZE):
        # Uses the github graphql api to get various items for repositories, given by
        # their uris. Returns (results, errors): the repo info keyed by uri, and the
        # ScrapeError keyed by uri for each uri that failed. Raises GithubRateLimitError
        # if the rate limit is reached, after saving partial results in self.repo_scrape_by_name.
        repo_names = {}
        for uri in uris:
            match = GITHUB_REPO_REGEX.match(uri.strip())
            if match and name_key(match) not in self.repo_scrape_by_name:
                repo_names.setdefault(name_key(match), (match.group(1), match.group(2)))

        self.scrape_done = 0
        self.scrape_total = len(repo_names)
        print(green(f'Scraping {self.scrape_total} github repos, {batch_size} per api call'))
        names = list(repo_names.values())
        for start in range(0, len(names), batch_size):
            self.scrape_batch(names[start:start + batch_size])

        return self.results(uris)

    def results(self, uris):
        # Get the (results, errors) for uris from the repos scraped so far
        results = {}
        errors = {}
        for uri in uris:
            match = GITHUB_REPO_REGEX.match(uri.strip())
            repo_parms = self.repo_scrape_by_name.get(name_key(match)) if match else {}
            if isinstance(repo_parms, ScrapeError):
                errors[uri] = repo_parms
            elif repo_parms is not None:
                results[uri] = repo_parms
        return results, errors


def main():
    # show progress as it happens, even when output is not a terminal
    sys.stdout.reconfigure(line_buffering=True)

    parser = argparse.ArgumentParser(description='Scrape github repos')
    parser.add_argument('--input_path', default=DISCOVERY_RESULTS,
                        help=f'Path to read discovered repos ({DISCOVERY_RESULTS})')
    parser.add_argument('--output_path',
                        help='Path to save scrape results (github_scrape_filename from the config)')
    parser.add_argument('--error_path', default=SCRAPE_ERRORS,
                        help=f'Path to save scrape errors ({SCRAPE_ERRORS})')
    parser.add_argument('--max_repos', type=int, default=0,
                        help='Maximum repos to scrape (for debug), 0 for no limit')
    parser.add_argument('--batch_size', type=int, default=DEFAULT_BATCH_SIZE,
                        help=f'Repos to get in each github api call ({DEFAULT_BATCH_SIZE})')
    parser.add_argument('--config', default=DEFAULT_CONFIG,
                        help='first_config.yml,second_config.yml,... '
                             'Scrape the repos that a build with these config files would use')
    args = parser.parse_args()

    token = github_token()
    if not token:
        print(red('Github scrape failed because GITHUB_TOKEN is not set'))
        sys.exit(1)

    # Get the list of repos
    if Path(args.input_path).exists():
        print(green(f'Loading discovered repos from {args.input_path}'))
        with open(args.input_path, 'r', encoding='utf8') as f:
            repos = json.load(f)
    else:
        print(red('Github scrape failed because discovery file does not exist'))
        sys.exit(1)

    # The config gives the path for results, and any limits on the repos used by a build
    config = {}
    for file_name in args.config.split(','):
        with open(file_name, 'r', encoding='utf8') as f:
            config.update(yaml.safe_load(f) or {})
    output_path = args.output_path or config['github_scrape_filename']

    # Select the repos to scrape, keyed by uri with the repo name as the value
    selected_names = {}
    selected_uris = {}
    for repo_list in repos.values():
        for repo_item in repo_list:
            uri = repo_item['uri']
            repo_name = repo_item['name']
            if not repo_selected(config, repo_name, selected_names):
                continue
            selected_names[repo_name] = True
            if uri not in selected_uris:
                if args.max_repos > 0 and len(selected_uris) >= args.max_repos:
                    break
                selected_uris[uri] = repo_name

    # Scrape repos
    scraper = GithubScraper(token)
    try:
        results, scrape_errors = scraper.scrape_repos(list(selected_uris), args.batch_size)
    except GithubRateLimitError as e:
        print(red(f'Github scrape stopped early: {e}'))
        results, scrape_errors = scraper.results(list(selected_uris))

    errors = {}
    for uri, error in scrape_errors.items():
        repo_errors = errors.setdefault(selected_uris[uri], [])
        # several uris for a repo may give the same error
        if error.to_dict() not in repo_errors:
            repo_errors.append(error.to_dict())

    # Save the results
    with open(output_path, 'w', encoding='utf8') as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    with open(args.error_path, 'w', encoding='utf8') as f:
        json.dump(errors, f, ensure_ascii=False, indent=2)

    print(green(f'Made {scraper.api_calls} github api calls, using {scraper.points_used} points'))
    if scraper.rate_remaining is not None:
        print(green(f'Github api rate limit: {scraper.rate_remaining} of {scraper.rate_limit} points remaining'))


if __name__ == '__main__':
    main()
