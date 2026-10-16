// DataChannel echo harness over direct DTLS (no ICE):
// `dc_echo server|client <port>` — mirrors webrtc/js/examples/dc_echo.mjs.
package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	dcwebrtc "dcwebrtc"
)

type serverIO struct {
	conn  *net.UDPConn
	mu    sync.Mutex
	peer  *net.UDPAddr
	queue chan []byte
}

func newServerIO(conn *net.UDPConn) *serverIO {
	io := &serverIO{conn: conn, queue: make(chan []byte, 64)}
	go func() {
		buf := make([]byte, 65536)
		for {
			n, addr, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			io.mu.Lock()
			io.peer = addr
			io.mu.Unlock()
			cp := make([]byte, n)
			copy(cp, buf[:n])
			io.queue <- cp
		}
	}()
	return io
}

func (s *serverIO) Send(buf []byte) error {
	s.mu.Lock()
	peer := s.peer
	s.mu.Unlock()
	if peer == nil {
		return fmt.Errorf("no peer yet")
	}
	_, err := s.conn.WriteToUDP(buf, peer)
	return err
}

func (s *serverIO) Recv(timeoutMs int) []byte {
	select {
	case msg := <-s.queue:
		return msg
	case <-time.After(time.Duration(timeoutMs) * time.Millisecond):
		return nil
	}
}

func config() dcwebrtc.DtlsConfig {
	cert, err := dcwebrtc.GenerateCertificate()
	if err != nil {
		panic(err)
	}
	return dcwebrtc.DtlsConfig{Certificate: cert}
}

func main() {
	mode := ""
	port := 4444
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	if len(os.Args) > 2 {
		port, _ = strconv.Atoi(os.Args[2])
	}
	switch mode {
	case "server":
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: port})
		if err != nil {
			panic(err)
		}
		fmt.Fprintf(os.Stderr, "LISTENING %d\n", port)
		dtls, err := dcwebrtc.DtlsAccept(newServerIO(conn), config())
		if err != nil {
			panic(err)
		}
		fmt.Fprintln(os.Stderr, "HANDSHAKE_OK")
		endpoint := dcwebrtc.NewDcEndpoint(dtls, "server")
		endpoint.SetOnChannel(func(channel *dcwebrtc.DataChannel) {
			fmt.Fprintf(os.Stderr, "CHANNEL_OPEN stream=%d label=%s\n", channel.ID, channel.Label)
			channel.OnMessage(func(data []byte, isText bool) {
				reply := append([]byte("re:"), data...)
				channel.Send(reply)
			})
		})
		select {}
	case "client":
		serverAddr := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: port}
		conn, err := net.DialUDP("udp4", nil, serverAddr)
		if err != nil {
			panic(err)
		}
		dtls, err := dcwebrtc.DtlsConnect(dcwebrtc.UDPPacketIO(conn), config())
		if err != nil {
			panic(err)
		}
		fmt.Fprintln(os.Stderr, "HANDSHAKE_OK")
		endpoint := dcwebrtc.NewDcEndpoint(dtls, "client")
		channel := endpoint.OpenChannel(dcwebrtc.DefaultChannelParams("echo"))
		replies := make(chan string, 64)
		channel.OnMessage(func(data []byte, isText bool) {
			replies <- string(data)
		})
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				continue
			}
			channel.Send([]byte(line))
			select {
			case reply := <-replies:
				fmt.Println(reply)
			case <-time.After(10 * time.Second):
				fmt.Fprintln(os.Stderr, "no reply")
				os.Exit(1)
			}
		}
	default:
		fmt.Fprintln(os.Stderr, "usage: dc_echo <server|client> <port>")
		os.Exit(2)
	}
}
