### Use Eventbox to download URLs concurrently

The following example illustrates how to use actions in order to download a list of URLs in parallel.

At first the `init` method starts an action for each URL to be downloaded, initializes some variables and stores the `result` object for later use.
Since the `result` is not yielded in the method body, the external call to `ParallelDownloads.new` doesn't return to that point in time.
Instead it's suspended until `result` is yielded later on, when all URLs have been retrieved.

### Running actions

Each call to the action method `start_download` starts a new thread (or at least borrows one from the thread-pool).
That way we leave the protected event scope of {Eventbox.async_call async_call}, {Eventbox.sync_call sync_call} and {Eventbox.yield_call yield_call} methods and enter the action scope which runs concurrently.
Since actions don't have access to instance variables, all required information must be passed as method arguments.
This is intentionally, because all arguments pass the {Eventbox::Sanitizer} that way, which protects from data races and translates between internal event based and external blocking behavior of `Proc` objects.
Actions should never use shared data directly or share any data with other program parts, but should use event scope methods like {Eventbox.sync_call sync_call} or closures like {Eventbox#yield_proc yield_proc} to access shared data in a thread-safe way.

### Catching errors

Another typical and recommended code sequence is the `rescue` / `else` declaration in an action method.
They inform the Eventbox object about success or failure of a particular action.
This outcome can then be properly handled by event scope methods.
In our case either the received data or the received exception is sent to `download_finished`.
It is a event scope method, so that it can safely access instance variables.
If all downloads completed, the result object received at `init` is yielded, so that the external call to `ParallelDownloads.new` returns.

Let's see how this looks in practice:

```ruby
require "eventbox"
require "net/https"
require "open-uri"
require "pp"

# Build a new Eventbox based class, which makes use of a pool of two threads.
# This way the number of concurrent downloads is limited to 3.
class ParallelDownloads < Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(3))

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

urls = %w[
  http://ruby-lang.org
  http://ruby-lang.ooorg
  http://wikipedia.org
  http://torproject.org
  http://github.com
]

d = ParallelDownloads.new(urls) { |progress| print progress }
pp d.downloads
```

This prints the numbers 1 to 5 as downloads finish and subsequently prints the reveived HTML text, so that the output looks like the following.
The order depends on the particular response time of the URL.

```ruby
12345{"http://ruby-lang.ooorg"=>#<SocketError: Failed to open TCP connection to ruby-lang.ooorg:80 (getaddrinfo: Name or service not known)>,
 "http://wikipedia.org"=>"<!DOCTYPE html>\n",
 "http://torproject.org"=>"<div class=\"eoy-background\">\n",
 "http://ruby-lang.org"=>"<!DOCTYPE html>\n",
 "http://github.com"=>"\n"}
```

Since Eventbox protects from data races, it's insignificant in which order events are emitted by an event scope method and whether objects are changed after being sent.
It's therefore OK to set `@downloads` both before or after starting the action threads per `start_download` in `init`.

### Change to closure style

There is another alternative way to transmit the result of an action to the event scope.
Instead of calling a {Eventbox.sync_call sync_call} method a closure like {Eventbox.sync_proc sync_proc} can be used.
It is simply the anonymous form of {Eventbox.sync_call sync_call}.
It behaves exactly identical, but is passed as argument.
This means in particular, that it's thread-safe to call {Eventbox.sync_proc sync_proc} from an action or external scope.

The above class rewritten to the closure style looks like so:

```ruby
class ParallelDownloads < Eventbox.with_options(threadpool: Eventbox::ThreadPool.new(3))

  yield_call def init(urls, result, &progress)
    urls.each do |url|                   # Start a download thread for each URL

      on_finished = async_proc do |res|   # Create a closure object comparable to sync_call
        @downloads[url] = res            # Store the download result in the result hash
        progress&.yield(@downloads.size) # Notify the caller about our progress
        if @downloads.size == urls.size  # All downloads finished?
          result.yield                   # Let ParallelDownloads.new return
        end
      end

      start_download(url, on_finished)   # Start the download - the call returns immediately
    end
    @downloads = {}                      # The result hash with all downloads
  end

  private action def start_download(url, on_finished)
    data = OpenURI.open_uri(url)         # HTTP GET url
      .read(100).each_line.first         # Retrieve the first line but max 100 bytes
  rescue SocketError => err              # Catch any network errors
    on_finished.yield(err)               # and store it in the result hash
  else
    on_finished.yield(data)              # ... or store the retrieved data when successful
  end

  attr_reader :downloads                 # Threadsafe access to @download
end
```

I guess that friends of object orientated programming probably like the method style more, while fans of functional programming prefer closures.
All in all it's purely a matter of taste whether you prefer the method or the closure style.
