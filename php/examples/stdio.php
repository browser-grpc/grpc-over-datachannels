<?php
// Stdio transport: frames DataChannel messages over a byte stream
// with a 4-byte big-endian length prefix (the prefix exists only to
// frame messages on stdio; each framed unit is exactly one DataChannel
// message). Used by the cross-language interop harnesses.
// Mirrors ruby/examples/stdio.rb.
//
// Reads are buffered and non-blocking: recvMessage returns null
// when no complete frame has arrived yet, so the endpoint pump
// can interleave concurrent stream fibers (a handler waiting on
// one stream must not starve producers on another).

require_once __DIR__ . "/../grpcdc.php";

class StdioTransport extends \Grpcdc\Transport
{
    /** @var null|\Closure():void called when the driver goes away */
    public $onEof = null;
    private $writer;
    private $reader;
    private string $buffer = "";
    private bool $eofSeen = false;

    public function __construct($writer, $reader)
    {
        $this->writer = $writer;
        $this->reader = $reader;
        if (is_resource($this->reader)) {
            stream_set_blocking($this->reader, false);
        }
    }

    public function send(string $data): void
    {
        fwrite($this->writer, pack("N", strlen($data)));
        fwrite($this->writer, $data);
        fflush($this->writer);
    }

    public function recvMessage(): ?string
    {
        while (true) {
            if (strlen($this->buffer) >= 4) {
                $length = unpack("N", substr($this->buffer, 0, 4))[1];
                if (strlen($this->buffer) >= 4 + $length) {
                    $payload = substr($this->buffer, 4, $length);
                    $this->buffer = substr($this->buffer, 4 + $length);
                    return $payload;
                }
            }
            if ($this->eofSeen) {
                $this->eof();
                return null;
            }
            $chunk = fread($this->reader, 8192);
            if ($chunk === false || $chunk === "") {
                if (is_resource($this->reader) && feof($this->reader)) {
                    $this->eofSeen = true;
                    continue;
                }
                return null; // would block: no complete frame yet
            }
            $this->buffer .= $chunk;
        }
    }

    private function eof(): void
    {
        $this->gone = true;
        if ($this->onEof !== null) {
            ($this->onEof)();
        }
    }
}
