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
require 'date'
require 'json'
require 'net/http'
require 'uri'


AVERAGED_COUNTS_URL = "https://raw.githubusercontent.com/rkent/ros_webdata/refs/heads/build/averaged_counts-%s.json"
MAX_SCALED_COUNT = 98.4  # use .4 so highest rounds to 99 even with rounding errors

def get_package_downloads()
    # Downloads and processes counts of package downloads, scaled from 1 - 99.

    # The source of these counts is originally from
    # https://awstats.osuosl.org/reports/packages.ros.org/{year}/{month:02d}/awstats.packages.ros.org.downloads.html

    packages_counts = nil
    active_month = Date.today

    retry_delay = [0, 2, 10]
    retry_delay.each_with_index do |delay, idx|
        if delay != 0 then sleep(delay) end
        yy_mm = active_month.strftime('%Y-%m')
        url = URI(AVERAGED_COUNTS_URL % [yy_mm])
        response = Net::HTTP.get_response(url)

        if response.code == '200'
            packages_counts = JSON(response.body)
            break
        end
        # Only look for another month if the current month is missing
        if response.code == '404'
            active_month = active_month.prev_month
        end
        puts ("WARNING: Failed attempt to get package download counts, " + response.msg).yellow
    end

    if !packages_counts
        raise RuntimeError.new("Failed to get package download counts")
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
