require 'simplecov'
SimpleCov.start

$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "eventbox"
require "minitest/autorun"
require "minitest/hooks/test"

Thread.abort_on_exception = true
