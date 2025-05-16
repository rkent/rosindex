#!/usr//bin/env python

# Copyright 2025 R. Kent James <kent@caspia.com>
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

# This script downloads all of the distribution caches into local files.

import os
from pathlib import Path
import rosdistro
import yaml

CACHE_DIRECTORY = "_remotes/distribution_cache"


def main():
  outpath = Path(CACHE_DIRECTORY)
  index = rosdistro.get_index(rosdistro.get_index_url())
  for distro in index.distributions:
      print(f'Writing distribution.yaml for distro {distro}')
      yaml_str = rosdistro.get_distribution_cache_string(index, distro)
      '''
      distro groovy has a line that causes yaml safe_load to fail. That line is:
      \  <run_depend>roslib</run_depend>\n\n</package>\n", map_msgs: !!python/str "<package>\n\

      yaml.safe_load dies when it sees "!!python/str"  So we have to use yaml.full_load
      Also appears in hydro.
      '''
      distribution_cache = yaml.full_load(yaml_str)
      os.makedirs(outpath / distro, exist_ok=True)
      with open(outpath / distro / 'distribution.yaml', 'w') as f:
          yaml.dump(distribution_cache, f)

if __name__ == '__main__':
    main()