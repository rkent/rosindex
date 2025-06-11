#!/usr/bin/env ruby

# Scrape githb repos into a json file. Can be run as a standalone program, or called from ruby

require 'colorator'
require 'json'
require 'net/http'
require 'nokogiri'
require 'optparse'
require 'uri'

require_relative '../_ruby_libs/common'

DISCOVERY_RESULTS = "_artifacts/discovery.json"
SCRAPE_RESULTS = "_artifacts/github_scrape.json"
SCRAPE_ERRORS = "_artifacts/github_scrape_errors.json"

$repo_scrape = {}

def fetch_uri(uri_str, limit = 10)
  # get an http response, accounting for redirects.
  if limit <= 0 then
    raise IndexException.new("Redirect limit exceeded for #{uri_str}")
  end
  response = Net::HTTP.get_response(URI(uri_str))
  case response
  when Net::HTTPSuccess
    response
  when Net::HTTPRedirection
    fetch_uri(response['location'], limit - 1)
  else
    raise IndexException.new("Github scrape error for uri #{uri_str} : #{response.error!}")
  end
end

def scrape_repo_page(uri_s)
  # Scrapes a github repository home page to get various items
  begin
    # cache the results since this only depends on the repo uri
    if $repo_scrape.key?(uri_s) then
      return $repo_scrape[uri_s]
    end

    repo_uri = URI(uri_s)
    if repo_uri.host == 'github.com' then
      response = fetch_uri(uri_s)
      document = Nokogiri::HTML(response.body)
      # Github repo stars
      element = document.at(".Layout-sidebar .octicon-star + strong")
      if element then
        star_count_f = element.text.to_f
        if element.text.include? 'k' then
            star_count_f = 1000 * star_count_f
        end
        star_count = star_count_f.to_i
      else
          star_count = nil
      end

      # Repo description
      element = document.at('.Layout-sidebar p')
      description = if element then element.text.strip else '' end

      # Tags
      tag_elements = document.css('h3:contains("Topics") + div a')
      tags = []
      tag_elements.each do |element|
        tags.push(element.text.strip)
      end
      repo_parms = {
        stars: star_count,
        description: description,
        tags: tags,
      }
    else
      repo_parms = {}
    end

  rescue Exception => e
    raise IndexException.new("Github scrape error. repo_uri: #{uri_s} error: #{e.message}")
  end

  $repo_scrape[uri_s] = repo_parms
  return repo_parms
end

if __FILE__ == $0
  params = { input_path: DISCOVERY_RESULTS,
             output_path: SCRAPE_RESULTS,
             error_path: SCRAPE_ERRORS,
             max_repos: 0
           }
  OptionParser.new do |opts|
    opts.banner = 'Scrape github repos'
    opts.on("--input_path Path to read discovered repos (#{DISCOVERY_RESULTS})")
    opts.on("--output_path Path to save scrape results (#{SCRAPE_RESULTS})")
    opts.on("--error_path Path to save scrape errors (#{SCRAPE_ERRORS})")
    opts.on("--max_repos Maximum repos to scrape (for debug), 0 for no limit")
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

  # Scrape repos
  repos.each do |distro, repo_list|
    repo_list.each do |repo_item|
      uri = repo_item['uri']
      repo_name = repo_item['name']
      if not $repo_scrape.key?(uri)
        puts ("scraping repo  " + uri).green
        begin
          scrape_repo_page(uri)
        rescue IndexException => e
          errors[repo_name] << e.to_hash()
        end
      end
    end
  end
  

  # Save the results
  File.open(params[:output_path], 'w') { |file| file.write(JSON.pretty_generate($repo_scrape)) }
  File.open(params[:error_path], 'w') { |file| file.write(JSON.pretty_generate(errors)) }
end
