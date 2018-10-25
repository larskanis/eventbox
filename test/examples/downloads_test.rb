require "net/https"
require "open-uri"
require_relative "../test_helper"

class ExamplesDownloadsTest < Minitest::Test
  class ParallelDownloads < Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(2))
    yield_call def init(urls, result)
      @urls =urls
      @urls.each do |url|
        start_download(url)
      end
      @downloads = {}
      @finished = result
    end

    private action def start_download(url)
      data = OpenURI.open_uri(url).read(100).each_line.first
    rescue => err
      download_finished(url, err)
    else
      download_finished(url, data)
    end

    private sync_call def download_finished(url, res)
      @downloads[url] = res
      @finished.yield if @downloads.size == @urls.size
    end

    attr_reader :downloads
  end

  def test_queue
    urls = %w[
      http://ruby-lang.org
      http://aruby-lang.ooorg
      http://wikipedia.org
      http://torproject.org
      http://github.com
      http://google.com
      http://leo.org
    ]

    d = ParallelDownloads.new(urls)
#     require "pp"
#     pp d.downloads

    dls = d.downloads.sort_by{|k,v| k }
    assert_equal urls.sort, dls.map(&:first)
    assert_kind_of Exception, dls[0][1]
    assert_kind_of String, dls[1][1]
    assert_kind_of String, dls[2][1]
  end
end
