# Copyright 2024 R. Kent James
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'colorator'
require 'json'

PACKAGE_DOWNLOADS_FILE = '_artifacts/package_downloads.json'
MAX_SCALED_COUNT = 98.4  # use .4 so highest rounds to 99 even with rounding errors

def get_package_downloads()
    # Reads counts of package downloads from a file, and scales them from 1 - 99.

    # The file is made by _scripts/package_downloads.py from
    # https://awstats.osuosl.org/reports/packages.ros.org/{year}/{month:02d}/awstats.packages.ros.org.downloads.html

    if File.exist?(PACKAGE_DOWNLOADS_FILE)
        puts 'Reading package download counts from saved file'.green
        packages_counts = JSON.parse(File.read(PACKAGE_DOWNLOADS_FILE))
    else
        puts 'Package downloads file does not exist, continuing with no download counts'.red
        return {}
    end

    ### Scale package counts per distro as a 1 - 99 histogram

    # sort by size per distro
    sorted_distros = {}
    packages_counts.each do |distro, packages|
        sorted_distros[distro] = packages.sort_by{|_, value| value }.to_h
    end

    # get the total download counts per distro
    totals_by_distro = {}
    sorted_distros.each do |distro, packages|
        totals_by_distro[distro] = packages.sum {|key, value| value}
    end

    # scale each package count to 1 - 99, if any downloads. Reserve 0 for no downloads
    scaled_by_distro = {}
    sorted_distros.each do |distro, packages|
        distro_scale = MAX_SCALED_COUNT / totals_by_distro[distro].to_f
        cumulative_count = 0.0
        scaled_by_distro[distro] = {}
        packages.each do |name, count|
            cumulative_count += count.to_f
            scaled_by_distro[distro][name] = (1.0 + cumulative_count * distro_scale).to_i
        end
    end
    return scaled_by_distro
end
