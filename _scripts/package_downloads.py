#!/usr/bin/env python3

# Copyright 2024 R. Kent James <kent@caspia.com>
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

import argparse
from datetime import date, timedelta
import json
from pathlib import Path
import sys

from bs4 import BeautifulSoup
import requests

PACKAGE_AWS_URL = 'https://awstats.osuosl.org/reports/packages.ros.org/{year}/{month:02d}/awstats.packages.ros.org.downloads.html'

'''
This script totals the downloads of ROS packages from packages.ros.org over the
previous complete months, using the monthly awstats reports at osuosl.org.

The totals are stored in a file 'package_downloads.json' (typically in the _artifacts directory)
that is a JSON file containing a dictionary of distros, each a dictionary of package counts, like:

{
 "humble": {"rosidl_default_runtime": 149406, "rosidl_parser": 149262, ...},
 "jazzy": {...},
...
}

Package names use underscores, so the debian package ros-humble-rosidl-parser is
counted as rosidl_parser in distro humble.

A typical table row we need to parse looks like this (with some example rows):

<table class="aws_data" border="1" cellpadding="2" cellspacing="0" width="100%">
    <tbody>
        <tr bgcolor="#ECECEC">
            <th colspan="2">Downloads</th>
            <th bgcolor="#66DDEE" width="80">Hits</th>
            <th bgcolor="#66DDEE" width="80">206 Hits</th>
            <th bgcolor="#2EA495" width="80">Bandwidth</th>
            <th bgcolor="#2EA495" width="80">Average size</th>
        </tr>
        <tr>
            <td width="32"><img src="/icon/mime/archive.png" alt="" title=""></td>
            <td class="aws"><a href="http://packages.ros.org/ros2/ubuntu/dists/jammy/main/binary-amd64/Packages.gz"
                    target="url" rel="nofollow">/ros2/ubuntu/dists/jammy/main/binary-amd64/Packages.gz</a></td>
            <td>387,830</td>
            <td>12,258</td>
            <td>583.33 GB</td>
            <td>1.49 MB</td>
        </tr>
        <tr>
            <td><img src="/icon/mime/package.png" alt="" title=""></td>
            <td class="aws"><a
                    href="http://packages.ros.org/ros2/ubuntu/pool/main/r/ros-humble-rosidl-parser/ros-humble-rosidl-parser_3.1.5-2jammy.20240728.202913_amd64.deb"
                    target="url" rel="nofollow">/ros2/ubuntu/pool/main/r/ros-humble-rosidl-parser/ros-humble-ros...</a>
            </td>
            <td>49,754</td>
            <td>5</td>
            <td>920.63 MB</td>
            <td>18.95 KB</td>
        </tr>

So for the above row, we need to get the ros type (ros2), distro (humble), name (rosidl-parser), downloads(49,754).
We are not interested in some rows (href="http://packages.ros.org/ros2/ubuntu/dists/jammy/main/binary-amd64/Packages.gz")
'''


def get_aws_downloads(url):
    """Get the package download counts for one month, as {distro: {name: count}}."""
    print(url)
    response = requests.get(url)
    if response.status_code != 200:
        raise RuntimeError(f'download failed of {url}: status {response.status_code}')

    soup = BeautifulSoup(response.content, 'html.parser')
    data = soup.find_all('table', class_='aws_data')

    package_rows = data[1].find_all('td', class_='aws')
    packages_counts = {}
    print(f'possible package rows found: {len(package_rows)}')
    for row in package_rows:
        details = row.a['href'].split('/')
        if len(details) < 9:
            continue
        if details[3] not in ['ros', 'ros2']:
            continue
        if not details[8].startswith('ros'):
            continue
        full_name_details = details[8].split('-')
        if len(full_name_details) <= 2:
            continue
        if full_name_details[1] in ['dev', 'build']:
            continue

        name = '_'.join(full_name_details[2:])
        distro = full_name_details[1]
        count = int(row.next_sibling.get_text().replace(',', ''))

        # Accumulate counts for different releases of the package
        distro_counts = packages_counts.setdefault(distro, {})
        distro_counts[name] = distro_counts.get(name, 0) + count

    return packages_counts


def previous_months(months_count):
    """List (month, year) for the complete months before the month of three days ago."""
    # Three days of slack lets the report for the last month finish.
    three_days_ago = date.today() - timedelta(days=3)
    months = []
    for months_back in range(1, 1 + months_count):
        month = three_days_ago.month - months_back
        year = three_days_ago.year
        if month < 1:
            month += 12
            year -= 1
        months.append((month, year))
    return months


def save_package_downloads(outdir='_artifacts', months_count=3):
    """Total package downloads over the previous months into package_downloads.json."""
    summary_data = {}
    for month, year in previous_months(months_count):
        packages_counts = get_aws_downloads(PACKAGE_AWS_URL.format(month=month, year=year))
        for distro, packages in packages_counts.items():
            distro_counts = summary_data.setdefault(distro, {})
            for name, count in packages.items():
                distro_counts[name] = distro_counts.get(name, 0) + count

    outPath = Path(outdir)
    outPath.mkdir(parents=True, exist_ok=True)
    with open(outPath / 'package_downloads.json', 'w', encoding='utf8') as json_file:
        json.dump(summary_data, json_file)


def main(sysargs=None):
    sysargs = sys.argv[1:] if sysargs is None else sysargs
    parser = argparse.ArgumentParser(
        description='Total downloads of ROS packages from packages.ros.org over the previous months'
    )
    parser.add_argument('-o', '--output_dir', default='_artifacts', help='Directory containing output files')
    parser.add_argument('-m', '--months', type=int, default=3, help='Number of months to total, default is 3')
    args = parser.parse_args(sysargs)
    save_package_downloads(args.output_dir, args.months)


if __name__ == '__main__':
    main()
