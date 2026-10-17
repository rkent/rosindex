site_path ?= _site

devel_config_file=_config_devel.yml

data_dir=_data
cache_dir=_cache
remotes_dir=_remotes
plugins_data_dir=_plugins_data
remotes_file=$(data_dir)/remotes.yml

config_file=_config.yml
index_file=index.yml
update_config=_config/update.yml
scrape_config=_config/scrape.yml
search_config=_config/search_index.yml

.DEFAULT_GOAL := build
.PHONY: build rebuild-dep-descriptions prepare-sources discover \
        update scrape github-scrape test-github-scrape serve serve-devel test-build clean-sources clean-cache clean

PIP_FILE := _artifacts/pip_packages.json
PIP_SCRIPT := _scripts/pip_packages.py
DOWNLOADS_FILE := _artifacts/package_downloads.json
DOWNLOADS_SCRIPT := _scripts/package_downloads.py
DEBIAN_FILE := _artifacts/debian_packages.json
DEBIAN_SCRIPT := _scripts/debian_descriptions.rb
DISCOVERY_SCRIPT = _ruby_libs/discovery.rb
DISCOVERY_RESULTS = _artifacts/discovery.json
DISCOVERY_ERRORS = _artifacts/discovery_errors.json
GITHUB_SCRAPE_SCRIPT = _scripts/github_scrape.py
GITHUB_SCRAPE_ERRORS = _artifacts/github_scrape_errors.json
github_scrape_args ?=

$(PIP_FILE):
	@echo "Get pip descriptions file"
	python3 $(PIP_SCRIPT)

$(DOWNLOADS_FILE):
	@echo "Get package downloads file"
	python3 $(DOWNLOADS_SCRIPT)

$(DISCOVERY_RESULTS): prepare-sources
	@echo "Rebuild discovery file that contains discovered repos"
	bundle exec $(DISCOVERY_SCRIPT) --config=$(config_file),$(index_file) --path=$(DISCOVERY_RESULTS) --errors=$(DISCOVERY_ERRORS)
  
rebuild-dep-descriptions:
	@echo "rebuild pip descriptions file"
	python3 $(PIP_SCRIPT)
	@echo "rebuild package downloads file"
	python3 $(DOWNLOADS_SCRIPT)
	@echo "rebuild debian descriptions file"
	ruby $(DEBIAN_SCRIPT)

$(DEBIAN_FILE):
	@echo "Get debian descriptions file"
	ruby $(DEBIAN_SCRIPT)

discover: prepare-sources
	@echo "Rebuild discovery file that contains discovered repos"
	bundle exec $(DISCOVERY_SCRIPT) --config=$(config_file),$(index_file)

github-scrape:
	@echo "Rebuild github scrape file from discovered repos"
	python3 $(GITHUB_SCRAPE_SCRIPT) --config=$(config_file),$(index_file) --input_path=$(DISCOVERY_RESULTS) --error_path=$(GITHUB_SCRAPE_ERRORS) $(github_scrape_args)

test-github-scrape:
	@echo "Rebuild github scrape file for only the repos used by test-build"
	python3 $(GITHUB_SCRAPE_SCRIPT) --config=$(config_file),$(index_file),$(devel_config_file) --input_path=$(DISCOVERY_RESULTS) --error_path=$(GITHUB_SCRAPE_ERRORS) $(github_scrape_args)

build: rebuild-dep-descriptions discover github-scrape prepare-sources
	bundle exec jekyll build --verbose --trace -d $(site_path) --config=$(config_file),$(index_file)

prepare-sources:
	mkdir -p $(remotes_dir)
	vcs import --input $(remotes_file) --force $(remotes_dir)
	vcs pull $(remotes_dir)

update: prepare-sources
	bundle exec jekyll build --verbose --trace -d $(site_path) --config=$(config_file),$(index_file),$(update_config)

scrape: prepare-sources
	bundle exec jekyll build --verbose --trace -d $(site_path) --config=$(config_file),$(index_file),$(scrape_config)

search-index: prepare-sources
	bundle exec jekyll build --verbose --trace -d $(site_path) --config=$(config_file),$(index_file),$(search_config)

serve:
	bundle exec jekyll serve --host 0.0.0.0 --no-watch --trace -d $(site_path) --config=$(config_file),$(index_file) --skip-initial-build

serve-devel:
	bundle exec jekyll serve --host 0.0.0.0 --no-watch --trace -d $(site_path) --config=$(config_file),$(index_file),$(devel_config_file) --skip-initial-build

test-build: $(PIP_FILE) $(DOWNLOADS_FILE) $(DEBIAN_FILE) $(DISCOVERY_RESULTS) test-github-scrape prepare-sources
	bundle exec jekyll build --verbose --trace -d $(site_path) --config=$(config_file),$(index_file),$(devel_config_file)

clean-sources:
	rm -rf $(plugins_data_dir)
	rm -rf $(remotes_dir)

clean-cache:
	rm -rf $(cache_dir)

clean: clean-cache clean-sources

