#!/usr/bin/env ruby

# Get github repo info (stars, description, topics) from the github api into a
# json file. Can be run as a standalone program, or called from ruby
#
# Set GITHUB_TOKEN, in a .env file at the root of this repo or else in the
# environment, to get a usable rate limit (5000 requests/hour instead of 60).

require 'colorator'
require 'json'
require 'net/http'
require 'optparse'
require 'uri'
require 'yaml'

require_relative '../_ruby_libs/common'

DISCOVERY_RESULTS = "_artifacts/discovery.json"
SCRAPE_ERRORS = "_artifacts/github_scrape_errors.json"
DEFAULT_CONFIG = ["_config.yml", "index.yml"]

GITHUB_API_HOST = 'api.github.com'
GITHUB_ENV_FILE = File.expand_path('../.env', __dir__)
# Matches https, git, and ssh style github repo uris, capturing owner and repo name
GITHUB_REPO_REGEX = %r{\A(?:https?://|git://|ssh://git@|git@)(?:www\.)?github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?\z}

# scrape results keyed by repo uri, as saved to the scrape file
$repo_scrape = {}
# scrape results (or the IndexException on failure) keyed by lowercase
# owner/name, so each github repo is only fetched once however its uri is spelled
$repo_scrape_by_name = {}
$github_http = nil
# github api usage, for reporting
$github_api_calls = 0
$github_rate_limit = nil
$github_rate_remaining = nil

def github_token()
  # get the github api token from the .env file, or else from the environment.
  # The .env file is preferred since it is specific to this repo.
  if not defined?($github_token) then
    $github_token = nil
    if File.exist?(GITHUB_ENV_FILE) then
      File.foreach(GITHUB_ENV_FILE) do |line|
        match = line.match(/\A\s*(?:export\s+)?GITHUB_TOKEN\s*=\s*(.*?)\s*\z/)
        if match then
          $github_token = match[1].gsub(/\A["']|["']\z/, '')
        end
      end
    end
    if $github_token.nil? or $github_token.empty? then
      $github_token = ENV['GITHUB_TOKEN']
    end
    if $github_token.nil? or $github_token.empty? then
      $github_token = nil
      puts ("WARNING: GITHUB_TOKEN not set, github api is limited to 60 requests/hour").yellow
    end
  end
  return $github_token
end

def fetch_github_api(path, limit = 10)
  # get a parsed github api response, accounting for redirects (for example renamed repos).
  if limit <= 0 then
    raise "Redirect limit exceeded for #{path}"
  end
  if $github_http.nil? then
    # a persistent connection is much faster when getting many repos
    $github_http = Net::HTTP.start(GITHUB_API_HOST, 443, use_ssl: true)
  end
  request = Net::HTTP::Get.new(path)
  request['Accept'] = 'application/vnd.github+json'
  request['X-GitHub-Api-Version'] = '2022-11-28'
  request['User-Agent'] = 'rosindex'
  token = github_token()
  if token then
    request['Authorization'] = "Bearer #{token}"
  end

  begin
    response = $github_http.request(request)
  rescue StandardError
    # force a reconnect on the next request
    $github_http = nil
    raise
  end
  $github_api_calls += 1
  if response['x-ratelimit-remaining'] then
    $github_rate_remaining = response['x-ratelimit-remaining'].to_i
    $github_rate_limit = response['x-ratelimit-limit'].to_i
  end

  case response
  when Net::HTTPSuccess
    JSON.parse(response.body)
  when Net::HTTPRedirection
    location = URI(response['location'])
    if location.host != GITHUB_API_HOST then
      raise "Unexpected redirect to #{response['location']}"
    end
    fetch_github_api(location.request_uri, limit - 1)
  else
    if response['x-ratelimit-remaining'] == '0' then
      reset_time = Time.at(response['x-ratelimit-reset'].to_i)
      raise "github api rate limit exceeded, resets at #{reset_time}"
    end
    raise "github api returned #{response.code} #{response.message}"
  end
end

def scrape_repo_page(uri_s)
  # Uses the github api to get various items for a github repository
  # cache the results since this only depends on the repo uri
  if $repo_scrape.key?(uri_s) then
    return $repo_scrape[uri_s]
  end

  match = GITHUB_REPO_REGEX.match(uri_s.to_s.strip)
  if match then
    name_key = "#{match[1]}/#{match[2]}".downcase
    if not $repo_scrape_by_name.key?(name_key) then
      begin
        repo = fetch_github_api("/repos/#{match[1]}/#{match[2]}")
        $repo_scrape_by_name[name_key] = {
          stars: repo['stargazers_count'],
          description: (repo['description'] || '').strip,
          tags: repo['topics'] || [],
        }
      rescue StandardError => e
        # cache failures too, so a failing repo is not retried
        $repo_scrape_by_name[name_key] =
          IndexException.new("Github scrape error. repo_uri: #{uri_s} error: #{e.message}")
      end
    end
    repo_parms = $repo_scrape_by_name[name_key]
    if repo_parms.is_a?(IndexException) then
      raise repo_parms
    end
  else
    repo_parms = {}
  end

  $repo_scrape[uri_s] = repo_parms
  return repo_parms
end

if __FILE__ == $0
  params = { input_path: DISCOVERY_RESULTS,
             output_path: nil,
             error_path: SCRAPE_ERRORS,
             max_repos: 0,
             config: DEFAULT_CONFIG
           }
  OptionParser.new do |opts|
    opts.banner = 'Scrape github repos'
    opts.on("--input_path Path to read discovered repos (#{DISCOVERY_RESULTS})")
    opts.on("--output_path Path to save scrape results (github_scrape_filename from the config)")
    opts.on("--error_path Path to save scrape errors (#{SCRAPE_ERRORS})")
    opts.on("--max_repos N", Integer, "Maximum repos to scrape (for debug), 0 for no limit")
    opts.on('--config first_config.yml,second_config.yml,...', Array,
            "Scrape the repos that a build with these config files would use")
  end.parse!(into: params)

  errors = Hash.new
  errors.default_proc = proc do |h,k|
    h[k]=[]
  end

  # Get the list of repos
  if File.exist?(params[:input_path])
    puts ("Loading discovered repos from #{params[:input_path]}").green
    repos = File.open(params[:input_path], 'r') { |f| JSON.load(f) }
  else
    puts ("Github scrape failed because discovery file does not exist").red
    exit(1)
  end

  # The config gives the path for results, and any limits on the repos used by a build
  config = Hash.new
  params[:config].each do |file_name|
    config.merge!(YAML.load_file(file_name))
  end
  output_path = params[:output_path] || config['github_scrape_filename']

  # Scrape repos
  selected_names = {}
  attempted_uris = {}
  scrape_count = 0
  catch(:max_repos_reached) do
    repos.each do |distro, repo_list|
      repo_list.each do |repo_item|
        uri = repo_item['uri']
        repo_name = repo_item['name']
        unless repo_selected?(config, repo_name, selected_names) then next end
        selected_names[repo_name] = true
        if not attempted_uris.key?(uri)
          attempted_uris[uri] = true
          if params[:max_repos] > 0 and scrape_count >= params[:max_repos]
            throw :max_repos_reached
          end
          scrape_count += 1
          puts ("scraping Github for repo  " + uri).green
          begin
            scrape_repo_page(uri)
          rescue IndexException => e
            errors[repo_name] << e.to_hash()
          end
        end
      end
    end
  end

  # Save the results
  File.open(output_path, 'w') { |file| file.write(JSON.pretty_generate($repo_scrape)) }
  File.open(params[:error_path], 'w') { |file| file.write(JSON.pretty_generate(errors)) }

  puts ("Made #{$github_api_calls} github api calls").green
  if $github_rate_remaining then
    puts ("Github api rate limit: #{$github_rate_remaining} of #{$github_rate_limit} calls remaining").green
  end
end
