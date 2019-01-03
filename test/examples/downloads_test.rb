require "net/https"
require "open-uri"
require_relative "../test_helper"

class ExamplesDownloadsTest < Minitest::Test
  class ParallelDownloads < Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(2))
    # Called at ParallelDownloads.new just like Object#initialize in ordinary ruby classes
    # Yield calls get one additional argument and suspend the caller until result.yield is invoked
    yield_call def init(urls, result, &progress)
      @urls = urls
      @urls.each do |url|             # Start a download thread for each URL
        start_download(url)           # Start the download - the call returns immediately
      end
      # It's safe to set instance variables after start_download
      @downloads = {}                 # The result hash with all downloads
      @finished = result              # Don't return to the caller, but store result yielder for later
      @progress = progress
    end

    # Each call to an action method starts a new thread
    # Actions don't have access to instance variables.
    private action def start_download(url)
      data = OpenURI.open_uri(url)    # HTTP GET url
        .read(100).each_line.first    # Retrieve the first line but max 100 bytes
    rescue => err         # Catch any network errors
      download_finished(url, err)     # and store it in the result hash
    else
      download_finished(url, data)    # ... or store the retrieved data when successful
    end

    # Called for each finished download
    private async_call def download_finished(url, res)
      @downloads[url] = res             # Store the download result in the result hash
      @progress&.yield_async(@downloads.size) # Notify the caller about our progress
      if @downloads.size == @urls.size  # All downloads finished?
        @finished.yield                 # Finish ParallelDownloads.new
      end
    end

    attr_reader :downloads            # Threadsafe access to @download
  end

  def test_queue
    urls = %w[
      https://aruby-lang.ooorg
      https://github.com
      https://google.com
      https://leo.org
      https://ruby-lang.org
      https://torproject.org
      https://wikipedia.org
    ]

    a = []
    d = ParallelDownloads.new(urls) { |v| a << v }
    assert_equal urls.map.with_index(1).map{|_,i| i }, a

#     require "pp"
#     pp d.downloads

    dls = d.downloads.sort_by{|k,v| k }
    assert_equal urls.sort, dls.map(&:first)
    assert_kind_of Exception, dls[0][1]
    assert_equal String, dls[1][1].class
    assert_equal String, dls[2][1].class

    ParallelDownloads.eventbox_options[:threadpool].shutdown!
  end
end
