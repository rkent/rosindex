#!/usr/bin/env ruby

# Get github repo info (stars, description, topics, and contribution
# suggestions) from the github graphql api into a json file. Can be run as a
# standalone program, or called from ruby
#
# The graphql api requires a token. Set GITHUB_TOKEN, in a .env file at the
# root of this repo or else in the environment.

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
# Number of repos to get in each graphql query. Larger queries can exceed
# github resource limits, but they are retried as smaller ones
DEFAULT_BATCH_SIZE = 20
# Maximum items in each contribution suggestion list (the most github allows in one page)
LIST_SIZE = 100

# Fields to get for each repo. The contribution suggestion lists match those
# shown by js/contribution_suggestions.js
LIST_FIELDS = "totalCount nodes { number title url }"
LIST_ORDER = "orderBy: {field: CREATED_AT, direction: DESC}"
REPO_FIELDS = <<~GRAPHQL
  stargazerCount
  description
  repositoryTopics(first: 20) { nodes { topic { name } } }
  openIssues: issues(states: OPEN) { totalCount }
  helpWanted: issues(states: OPEN, labels: ["help wanted"], first: #{LIST_SIZE}, #{LIST_ORDER}) { #{LIST_FIELDS} }
  goodFirstIssue: issues(states: OPEN, labels: ["good first issue"], first: #{LIST_SIZE}, #{LIST_ORDER}) { #{LIST_FIELDS} }
  pullRequests(states: OPEN, first: #{LIST_SIZE}, #{LIST_ORDER}) { #{LIST_FIELDS} }
GRAPHQL

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
# progress of scrape_repos, for reporting
$scrape_done = 0
$scrape_total = 0

class GithubRateLimitError < StandardError
end

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
    end
  end
  return $github_token
end

def fetch_github_graphql(query, variables)
  # get a parsed github graphql response, with 'data' and possibly 'errors'
  token = github_token()
  if token.nil? then
    raise "GITHUB_TOKEN is not set, it is required for the github graphql api"
  end
  if $github_http.nil? then
    # a persistent connection is much faster when making many requests
    $github_http = Net::HTTP.start(GITHUB_API_HOST, 443, use_ssl: true)
  end
  request = Net::HTTP::Post.new('/graphql')
  request['Content-Type'] = 'application/json'
  request['User-Agent'] = 'rosindex'
  request['Authorization'] = "Bearer #{token}"
  request.body = JSON.generate({query: query, variables: variables})

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

  if response['x-ratelimit-remaining'] == '0' and not response.is_a?(Net::HTTPSuccess) then
    reset_time = Time.at(response['x-ratelimit-reset'].to_i)
    raise GithubRateLimitError, "github api rate limit exceeded, resets at #{reset_time}"
  end
  if not response.is_a?(Net::HTTPSuccess) then
    raise "github api returned #{response.code} #{response.message}"
  end
  result = JSON.parse(response.body)
  errors = result['errors'] || []
  if errors.any? { |error| error['type'] == 'RATE_LIMITED' } then
    raise GithubRateLimitError, "github api rate limit exceeded"
  end
  if errors.any? { |error| error['type'] == 'RESOURCE_LIMITS_EXCEEDED' } then
    raise "github api resource limits exceeded"
  end
  if result['data'].nil? then
    raise "github api query failed: #{errors.map { |error| error['message'] }.join('; ')}"
  end
  return result
end

def contribution_list(connection)
  # convert a graphql issue or pull request connection into a list for the scrape file
  return {
    total: connection['totalCount'],
    items: connection['nodes'].map do |node|
      {number: node['number'], title: node['title'], html_url: node['url']}
    end,
  }
end

def scrape_batch(repo_names)
  # get the info for a batch of github repos, given as [owner, name] pairs,
  # into $repo_scrape_by_name
  variables = {}
  query_repos = []
  repo_names.each_with_index do |(owner, name), i|
    variables["o#{i}"] = owner
    variables["n#{i}"] = name
    query_repos << "r#{i}: repository(owner: $o#{i}, name: $n#{i}) { #{REPO_FIELDS} }"
  end
  query_variables = variables.keys.map { |key| "$#{key}: String!" }.join(', ')
  query = "query(#{query_variables}) {\n#{query_repos.join("\n")}\n}"

  start_time = Time.now
  begin
    result = fetch_github_graphql(query, variables)
  rescue GithubRateLimitError
    raise
  rescue StandardError => e
    puts ("github api call #{$github_api_calls}: failed for #{repo_names.length} repos" \
          " in #{(Time.now - start_time).round(1)}s: #{e.message}").yellow
    if repo_names.length > 1 then
      puts ("retrying as smaller queries").yellow
      # large queries can time out, so retry as smaller ones
      half = repo_names.length / 2
      scrape_batch(repo_names[0...half])
      scrape_batch(repo_names[half..])
    else
      owner, name = repo_names[0]
      $repo_scrape_by_name["#{owner}/#{name}".downcase] =
        IndexException.new("Github scrape error. repo: #{owner}/#{name} error: #{e.message}")
      $scrape_done += 1
    end
    return
  end

  $scrape_done += repo_names.length
  puts ("github api call #{$github_api_calls}: got #{repo_names.length} repos" \
        " (#{$scrape_done} of #{$scrape_total} done) in #{(Time.now - start_time).round(1)}s," \
        " #{$github_rate_remaining} points remaining").green

  repo_names.each_with_index do |(owner, name), i|
    name_key = "#{owner}/#{name}".downcase
    repo = result['data']["r#{i}"]
    if repo.nil? or repo.except('description').values.any?(&:nil?) then
      # a missing repo, or a field that failed
      repo_errors = (result['errors'] || []).select { |error| error['path']&.first == "r#{i}" }
      message = repo_errors.empty? ? 'no data returned' : repo_errors.map { |error| error['message'] }.uniq.join('; ')
      $repo_scrape_by_name[name_key] =
        IndexException.new("Github scrape error. repo: #{owner}/#{name} error: #{message}")
    else
      $repo_scrape_by_name[name_key] = {
        stars: repo['stargazerCount'],
        description: (repo['description'] || '').strip,
        tags: repo['repositoryTopics']['nodes'].map { |node| node['topic']['name'] },
        open_issues: repo['openIssues']['totalCount'],
        help_wanted: contribution_list(repo['helpWanted']),
        good_first_issue: contribution_list(repo['goodFirstIssue']),
        pull_requests: contribution_list(repo['pullRequests']),
      }
    end
  end
end

def scrape_repos(uris, batch_size = DEFAULT_BATCH_SIZE)
  # Uses the github graphql api to get various items for repositories, given by
  # their uris. Results are added to $repo_scrape. Returns a hash, keyed by uri,
  # of the IndexException for each uri that failed.
  repo_names = {}
  uris.each do |uri|
    match = GITHUB_REPO_REGEX.match(uri.to_s.strip)
    if match then
      name_key = "#{match[1]}/#{match[2]}".downcase
      unless $repo_scrape_by_name.key?(name_key) then
        repo_names[name_key] ||= [match[1], match[2]]
      end
    end
  end

  $scrape_done = 0
  $scrape_total = repo_names.length
  puts ("Scraping #{$scrape_total} github repos, #{batch_size} per api call").green
  repo_names.values.each_slice(batch_size) do |batch|
    scrape_batch(batch)
  end

  errors = {}
  uris.each do |uri|
    match = GITHUB_REPO_REGEX.match(uri.to_s.strip)
    if match then
      repo_parms = $repo_scrape_by_name["#{match[1]}/#{match[2]}".downcase]
    else
      repo_parms = {}
    end
    if repo_parms.is_a?(IndexException) then
      errors[uri] = repo_parms
    elsif repo_parms then
      $repo_scrape[uri] = repo_parms
    end
  end
  return errors
end

if __FILE__ == $0
  # show progress as it happens, even when output is not a terminal
  $stdout.sync = true

  params = { input_path: DISCOVERY_RESULTS,
             output_path: nil,
             error_path: SCRAPE_ERRORS,
             max_repos: 0,
             batch_size: DEFAULT_BATCH_SIZE,
             config: DEFAULT_CONFIG
           }
  OptionParser.new do |opts|
    opts.banner = 'Scrape github repos'
    opts.on("--input_path Path to read discovered repos (#{DISCOVERY_RESULTS})")
    opts.on("--output_path Path to save scrape results (github_scrape_filename from the config)")
    opts.on("--error_path Path to save scrape errors (#{SCRAPE_ERRORS})")
    opts.on("--max_repos N", Integer, "Maximum repos to scrape (for debug), 0 for no limit")
    opts.on("--batch_size N", Integer, "Repos to get in each github api call (#{DEFAULT_BATCH_SIZE})")
    opts.on('--config first_config.yml,second_config.yml,...', Array,
            "Scrape the repos that a build with these config files would use")
  end.parse!(into: params)

  if github_token().nil? then
    puts ("Github scrape failed because GITHUB_TOKEN is not set").red
    exit(1)
  end

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

  # Select the repos to scrape, keyed by uri with the repo name as the value
  selected_names = {}
  selected_uris = {}
  repos.each do |distro, repo_list|
    repo_list.each do |repo_item|
      uri = repo_item['uri']
      repo_name = repo_item['name']
      unless repo_selected?(config, repo_name, selected_names) then next end
      selected_names[repo_name] = true
      if not selected_uris.key?(uri)
        if params[:max_repos] > 0 and selected_uris.length >= params[:max_repos]
          break
        end
        selected_uris[uri] = repo_name
      end
    end
  end

  # Scrape repos
  begin
    scrape_errors = scrape_repos(selected_uris.keys, params[:batch_size])
    scrape_errors.each do |uri, e|
      # several uris for a repo may give the same error
      unless errors[selected_uris[uri]].include?(e.to_hash()) then
        errors[selected_uris[uri]] << e.to_hash()
      end
    end
  rescue GithubRateLimitError => e
    puts ("Github scrape stopped early: #{e.message}").red
  end

  # Save the results
  File.open(output_path, 'w') { |file| file.write(JSON.pretty_generate($repo_scrape)) }
  File.open(params[:error_path], 'w') { |file| file.write(JSON.pretty_generate(errors)) }

  puts ("Made #{$github_api_calls} github api calls").green
  if $github_rate_remaining then
    puts ("Github api rate limit: #{$github_rate_remaining} of #{$github_rate_limit} points remaining").green
  end
end
