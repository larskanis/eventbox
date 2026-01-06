source "https://rubygems.org"

git_source(:github) {|repo_name| "https://github.com/#{repo_name}" }

# Specify your gem's dependencies in eventbox.gemspec
gemspec

group :development do
  gem "bundler", ">= 1.16"
  gem "rake", "~> 13.0"
  gem "minitest", "~> 6.0"
  gem "minitest-mock", "~> 5.0"
  gem "minitest-hooks"
  gem "yard", "~> 0.9"
end

group :test do
  gem 'simplecov', require: false
end
