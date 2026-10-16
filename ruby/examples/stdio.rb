# Stdio transport: frames DataChannel messages over a byte stream
# with a 4-byte big-endian length prefix (the prefix exists only to
# frame messages on stdio; each framed unit is exactly one DataChannel
# message). Used by the cross-language interop harnesses.
# Mirrors python/examples/stdio.py.

require "grpcdc"

class StdioTransport < Grpcdc::Transport
  # Set to exit the process when the driver goes away.
  attr_accessor :on_eof

  def initialize(writer, reader)
    super()
    @writer = writer # binary writable (e.g. $stdout)
    @reader = reader # binary readable (e.g. $stdin)
    @writer.binmode if @writer.respond_to?(:binmode)
    @reader.binmode if @reader.respond_to?(:binmode)
    @lock = Mutex.new
    @on_eof = nil
  end

  def send(data)
    @lock.synchronize do
      @writer.write([data.bytesize].pack("N"))
      @writer.write(data)
      @writer.flush
    end
  end

  def recv
    header = read_exact(4)
    if header.bytesize < 4
      eof
      raise EOFError, "stdio closed"
    end
    length = header.unpack1("N")
    payload = read_exact(length)
    if payload.bytesize < length
      eof
      raise EOFError, "stdio closed mid-frame"
    end

    payload
  end

  private

  def read_exact(n)
    out = String.new(encoding: Encoding::BINARY)
    while out.bytesize < n
      chunk = @reader.read(n - out.bytesize)
      break if chunk.nil? || chunk.empty?

      out << chunk.b
    end
    out
  end

  def eof
    @on_eof&.call
  end
end
