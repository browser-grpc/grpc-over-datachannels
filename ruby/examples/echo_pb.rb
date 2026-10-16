# Hand-written protobuf messages for proto/echo.proto (package echo).
#
# Deliberately minimal (two messages) so the example needs no protobuf
# codegen dependency — the wire bytes are genuine protobuf:
# EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
# Mirrors python/examples/echo_pb.py.

module EchoPb
  module_function

  def append_varint(out, value)
    v = value & 0xFFFFFFFFFFFFFFFF
    while v > 0x7F
      out << ((v & 0x7F) | 0x80)
      v >>= 7
    end
    out << v
    out
  end

  def append_string_field(out, field, value)
    return out if value.nil? || value.empty?

    data = value.encode(Encoding::UTF_8).b
    append_varint(out, (field << 3) | 2)
    append_varint(out, data.bytesize)
    out << data
    out
  end

  def append_int32_field(out, field, value)
    return out if value == 0

    append_varint(out, (field << 3) | 0)
    append_varint(out, value & 0xFFFFFFFFFFFFFFFF)
  end

  class Reader
    def initialize(buf)
      @buf = buf.b
      @pos = 0
    end

    def varint
      result = 0
      shift = 0
      loop do
        raise ArgumentError, "truncated varint" if @pos >= @buf.bytesize

        b = @buf.getbyte(@pos)
        @pos += 1
        result |= (b & 0x7F) << shift
        return result if (b & 0x80).zero?

        shift += 7
        raise ArgumentError, "varint too long" if shift >= 64
      end
    end

    # [field_number, value] or nil at end; value is Integer or String.
    def field
      return nil if @pos >= @buf.bytesize

      tag = varint
      num = tag >> 3
      wire = tag & 7
      case wire
      when 0
        [num, varint]
      when 2
        n = varint
        raise ArgumentError, "truncated bytes field" if @pos + n > @buf.bytesize

        value = @buf.byteslice(@pos, n)
        @pos += n
        [num, value]
      when 1
        raise ArgumentError, "truncated fixed64" if @pos + 8 > @buf.bytesize

        value = @buf.byteslice(@pos, 8)
        @pos += 8
        [num, value]
      when 5
        raise ArgumentError, "truncated fixed32" if @pos + 4 > @buf.bytesize

        value = @buf.byteslice(@pos, 4)
        @pos += 4
        [num, value]
      else
        raise ArgumentError, "bad wire type"
      end
    end
  end

  def self.as_int32(value)
    return 0 unless value.is_a?(Integer)

    ((value & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000
  end

  def self.as_string(value)
    value.is_a?(String) ? value.dup.force_encoding(Encoding::UTF_8) : ""
  end

  # Mirrors proto/echo.proto EchoRequest.
  class EchoRequest
    attr_accessor :message, :count, :delay_ms

    def initialize(message: "", count: 0, delay_ms: 0)
      @message = message
      @count = count
      @delay_ms = delay_ms
    end

    def marshal_dc
      out = String.new(encoding: Encoding::BINARY)
      EchoPb.append_string_field(out, 1, @message)
      EchoPb.append_int32_field(out, 2, @count)
      EchoPb.append_int32_field(out, 3, @delay_ms)
      out
    end

    def unmarshal_dc(data)
      @message = ""
      @count = 0
      @delay_ms = 0
      reader = Reader.new(data)
      loop do
        item = reader.field
        return self if item.nil?

        num, value = item
        case num
        when 1 then @message = EchoPb.as_string(value)
        when 2 then @count = EchoPb.as_int32(value)
        when 3 then @delay_ms = EchoPb.as_int32(value)
        end
      end
    end

    def ==(other)
      other.is_a?(EchoRequest) &&
        [@message, @count, @delay_ms] == [other.message, other.count, other.delay_ms]
    end

    def inspect
      "EchoRequest(message=#{@message.inspect}, count=#{@count}, delay_ms=#{@delay_ms})"
    end
  end

  # Mirrors proto/echo.proto EchoResponse.
  class EchoResponse
    attr_accessor :message, :index

    def initialize(message: "", index: 0)
      @message = message
      @index = index
    end

    def marshal_dc
      out = String.new(encoding: Encoding::BINARY)
      EchoPb.append_string_field(out, 1, @message)
      EchoPb.append_int32_field(out, 2, @index)
      out
    end

    def unmarshal_dc(data)
      @message = ""
      @index = 0
      reader = Reader.new(data)
      loop do
        item = reader.field
        return self if item.nil?

        num, value = item
        case num
        when 1 then @message = EchoPb.as_string(value)
        when 2 then @index = EchoPb.as_int32(value)
        end
      end
    end

    def ==(other)
      other.is_a?(EchoResponse) && [@message, @index] == [other.message, other.index]
    end

    def inspect
      "EchoResponse(message=#{@message.inspect}, index=#{@index})"
    end
  end
end
