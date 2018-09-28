require 'simplecov'
SimpleCov.start


BEGIN {
  @start_threads = Thread.list
}

END {
  # Trigger ObjectRegistry#untag and thread stopping
  GC.start
  sleep 0.1 if (Thread.list - @start_threads).any?

  lingering = Thread.list - @start_threads
  if lingering.any?
    warn "Warning: #{lingering.length} lingering threads"
    lingering.each do |th|
      line = th.backtrace&.find{|t| t=~/test\// } or
          th.backtrace&.find{|t| !(t=~/lib\/eventbox(\/|\.rb:)/) } or
          th.backtrace&.first
      warn "    #{ line }"
    end
  end
}

$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "eventbox"
require "minitest/autorun"
require "minitest/hooks/test"

Thread.abort_on_exception = true
