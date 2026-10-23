<?php
// Stdio transport: frames DataChannel messages over a byte stream
// with a 4-byte big-endian length prefix (the prefix exists only to
// frame messages on stdio; each framed unit is exactly one DataChannel
// message). Used by the cross-language interop harnesses.
// Mirrors ruby/examples/stdio.rb.

require_once __DIR__ . "/../grpcdc.php";

class StdioTransport extends \Grpcdc\Transport
{
    /** @var null|\Closure():void called when the driver goes away */
    public $onEof = null;
    private $writer;
    private $reader;

    public function __construct($writer, $reader)
    {
        $this->writer = $writer;
        $this->reader = $reader;
    }

    public function send(string $data): void
    {
        fwrite($this->writer, pack("N", strlen($data)));
        fwrite($this->writer, $data);
        fflush($this->writer);
    }

    public function recvMessage(): ?string
    {
        $header = $this->readExact(4);
        if (strlen($header) < 4) {
            $this->eof();
            return null;
        }
        $length = unpack("N", $header)[1];
        $payload = $this->readExact($length);
        if (strlen($payload) < $length) {
            $this->eof();
            return null;
        }
        return $payload;
    }

    private function readExact(int $n): string
    {
        $out = "";
        while (strlen($out) < $n) {
            $chunk = fread($this->reader, $n - strlen($out));
            if ($chunk === false || $chunk === "") {
                break;
            }
            $out .= $chunk;
        }
        return $out;
    }

    private function eof(): void
    {
        $this->gone = true;
        if ($this->onEof !== null) {
            ($this->onEof)();
        }
    }
}
