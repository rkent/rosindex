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

require 'json'
require 'net/http'
require 'uri'

DEBIAN_URL = 'https://packages.debian.org/stable/allpackages?format=txt.gz'
PIP_URL = 'https://raw.githubusercontent.com/rkent/ros_webdata/refs/heads/build/pip_packages.json'

def get_debian_descriptions(packages={})
    content_unicode = nil
    retry_delay = [0, 10, 60]
    retry_delay.each_with_index do |delay, idx|
        if delay != 0 then sleep(delay) end
        begin
            content_unicode = Net::HTTP.get(URI(DEBIAN_URL))
            break
        rescue StandardError => error
            puts 'WARNING: Debian packages description download error: #{error}'
            if idx < retry_delay.length - 1
                puts 'Retrying debian description download'
                next
            else
                puts 'Failing debian description download'
            end
        end
    end

    # Test for failed download
    if !content_unicode then return packages end

    # The package file seems to have unicode that confuses ruby. Just force to ascii.
    content = content_unicode.encode('US-ASCII', invalid: :replace, undef: :replace)
    content.lines.each do |line|
        # Typical package line:
        # 3270-common (4.1ga10-1.1+b1) Common files for IBM 3270 emulators and pr3287
        left_paren = line.index('(')
        right_paren = line.index(')')
        # The file starts with some beginning material that is not packages.
        if not left_paren or not right_paren then next end
        package_name = line[0..left_paren - 2]
        package_desc = line[right_paren + 2..line.length - 1]
        packages[package_name] = package_desc
    end
    packages
end

def get_pip_descriptions(packages)
    content = Net::HTTP.get(URI(PIP_URL))

    # Test for failed download
    if not content then return packages end

    pip_descriptions = JSON(content)
    pip_descriptions.each do |key, value|
        if not packages.key?(key)
            packages[key] = value
            # puts "Updating #{key} with #{value}"
        end
    end
    packages
end
