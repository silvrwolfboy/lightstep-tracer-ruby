require 'json'
require 'zlib'
require 'net/http'
require 'thread'
require_relative './util'

class TransportHTTPJSON
  def initialize
    # Configuration
    @host = ''
    @port = 0
    @verbose = 0
    @secure = true

    @thread = nil
    @thread_pid = 0 # process ID that created the thread
    @queue = nil
  end

  def ensure_connection(options)
    @verbose = options[:verbose]
    @host = options[:collector_host]
    @port = options[:collector_port]
    @secure = (options[:collector_encryption] != 'none')
  end

  def flush_report(auth, report)
    if auth.nil? || report.nil?
      puts 'Auth or report not set.' if @verbose > 0
      return nil
    end
    puts report.inspect if @verbose >= 3

    _check_process_id

    # Lazily re-create the queue and thread. Closing the transport as well as
    # a process fork may have reset it to nil.
    if @thread.nil? || !@thread.alive?
      @thread_pid = Process.pid
      @thread = _start_network_thread
    end
    @queue = SizedQueue.new(16) if @queue.nil?

    content = _thrift_struct_to_object(report)
    # content = Zlib::deflate(content)
    @queue << {
      host: @host,
      port: @port,
      secure: @secure,
      access_token: auth.access_token,
      content: content,
      verbose: @verbose
    }
    nil
  end

  # Process.fork can leave SizedQueue and thread in a untrustworthy state. If the
  # process ID has changed, reset the the thread and queue.
  def _check_process_id
    if Process.pid != @thread_pid
      Thread.kill(@thread) unless @thread.nil?
      @thread = nil
      @queue = nil
    end
  end

  def close(discardPending)
    return if @queue.nil?
    return if @thread.nil?

    _check_process_id

    # Since close can be called at shutdown and there are multiple Ruby
    # interpreters out there, don't assume the shutdown process will leave the
    # thread alive or have definitely killed it
    if !@thread.nil? && @thread.alive?
      @queue << { signal_exit: true } unless @queue.nil?
      @thread.join
    elsif !@queue.empty? && !discardPending
      begin
        _post_report(@queue.pop(true))
      rescue
        # Ignore the error. Make sure this final flush does not percollate an
        # exception back into the calling code.
      end
    end

    # Clear the member variables so the transport is in a known state and can be
    # restarted safely
    @queue = nil
    @thread = nil
  end

  def _start_network_thread
    Thread.new do
      done = false
      until done
        params = @queue.pop
        if params[:signal_exit]
          done = true
        else
          _post_report(params)
        end
      end
    end
  end

  def _post_report(params)
    https = Net::HTTP.new(params[:host], params[:port])
    https.use_ssl = params[:secure]
    req = Net::HTTP::Post.new('/api/v0/reports')
    req['LightStep-Access-Token'] = params[:access_token]
    req['Content-Type'] = 'application/json'
    req['Connection'] = 'keep-alive'
    req.body = params[:content].to_json
    res = https.request(req)

    puts res.to_s if params[:verbose] >= 3
  end
end
