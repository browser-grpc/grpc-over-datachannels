// Full-peer echo harness with SDP exchanged through files:
//
//	peer_echo offerer  <offer-file> <answer-file>
//	peer_echo answerer <offer-file> <answer-file>
//	peer_echo mux-offerer  <dir> [turn-addr]  (two pairs over one PeerMux)
//	peer_echo mux-answerer <dir> [turn-addr]
//
// Mirrors webrtc/rust/examples/peer_echo.rs.
package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	dcwebrtc "dcwebrtc"
)

func waitForFile(path string) string {
	for {
		if content, err := os.ReadFile(path); err == nil && len(content) > 0 {
			text := string(content)
			trimmed := true
			for _, r := range text {
				if r != ' ' && r != '\n' && r != '\r' && r != '\t' {
					trimmed = false
				}
			}
			if !trimmed {
				return text
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func loopbackPeer() *dcwebrtc.Peer {
	peer, err := dcwebrtc.NewPeer(dcwebrtc.PeerOptions{
		LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true,
	})
	if err != nil {
		panic(err)
	}
	return peer
}

func main() {
	mode, offerPath, answerPath := "", "", ""
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	if len(os.Args) > 2 {
		offerPath = os.Args[2]
	}
	if len(os.Args) > 3 {
		answerPath = os.Args[3]
	}
	turnAddr := ""
	if len(os.Args) > 3 {
		turnAddr = os.Args[3]
	}
	switch mode {
	case "mux-answerer":
		muxAnswerer(offerPath, turnAddr)
	case "mux-offerer":
		muxOfferer(offerPath, turnAddr)
	case "answerer":
		offer := waitForFile(offerPath)
		peer := loopbackPeer()
		answer, err := peer.HandleOffer(offer)
		if err != nil {
			panic(err)
		}
		if err := os.WriteFile(answerPath, []byte(answer), 0o644); err != nil {
			panic(err)
		}
		fmt.Fprintln(os.Stderr, "ANSWER_WRITTEN")
		endpoint, err := peer.ConnectWithOptions(true)
		if err != nil {
			panic(err)
		}
		fmt.Fprintln(os.Stderr, "CONNECTED")
		endpoint.SetOnChannel(func(channel *dcwebrtc.DataChannel) {
			fmt.Fprintf(os.Stderr, "CHANNEL_OPEN stream=%d\n", channel.ID)
			channel.OnClose(func() {
				fmt.Fprintf(os.Stderr, "CHANNEL_CLOSED stream=%d\n", channel.ID)
			})
			channel.OnMessage(func(data []byte, isText bool) {
				reply := append([]byte("re:"), data...)
				channel.Send(reply)
			})
		})
		select {}
	case "offerer":
		peer := loopbackPeer()
		offer := peer.CreateOffer()
		if err := os.WriteFile(offerPath, []byte(offer), 0o644); err != nil {
			panic(err)
		}
		answer := waitForFile(answerPath)
		if err := peer.HandleAnswer(answer); err != nil {
			panic(err)
		}
		endpoint, err := peer.ConnectWithOptions(true)
		if err != nil {
			panic(err)
		}
		fmt.Fprintln(os.Stderr, "CONNECTED")
		channel := endpoint.OpenChannel(dcwebrtc.DefaultChannelParams("echo"))
		replies := make(chan string, 64)
		channel.OnMessage(func(data []byte, isText bool) {
			replies <- string(data)
		})
		closedLocal := make(chan struct{}, 1)
		channel.OnClose(func() { closedLocal <- struct{}{} })
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				continue
			}
			if line == "__close__" {
				// Cross-stack close check: reset the stream and
				// report once both directions complete locally.
				channel.Close()
				select {
				case <-closedLocal:
					fmt.Fprintln(os.Stderr, "CHANNEL_CLOSED_LOCAL")
				case <-time.After(15 * time.Second):
					fmt.Fprintln(os.Stderr, "close timed out")
					os.Exit(1)
				}
				fmt.Println("closed")
				continue
			}
			channel.Send([]byte(line))
			select {
			case reply := <-replies:
				fmt.Println(reply)
			case <-time.After(15 * time.Second):
				fmt.Fprintln(os.Stderr, "no reply")
				os.Exit(1)
			}
		}
	default:
		fmt.Fprintln(os.Stderr, "usage: peer_echo <offerer|answerer|mux-offerer|mux-answerer> <offer-file|dir> <answer-file>")
		os.Exit(2)
	}
}

// --- mux modes: two pairs over one PeerMux socket per side ---
// SDP goes through <dir>/offer<i> and <dir>/answer<i>. The
// offerer sends a distinct message per pair and prints each
// reply as "pair<i>: <reply>", then MUX_OK. Used by the
// cross-stack webrtc matrix to prove DTLS connection-id
// (RFC 9146) demux agrees across stacks.

// With a TURN server address, the advertised host address is
// deliberately unreachable, so a successful pair proves the
// relay carried it (relay-only, like the in-stack TURN tests).
func muxPeerOptions(turnAddr string) dcwebrtc.PeerOptions {
	options := dcwebrtc.PeerOptions{LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true}
	if turnAddr != "" {
		options.LocalIPs = []string{"10.11.12.13"}
		options.TurnServers = []dcwebrtc.TurnServerConfig{
			{Address: turnAddr, Username: "dcuser", Password: "dcpass"},
		}
	}
	return options
}

func muxAnswerer(dir string, turnAddr string) {
	mux, err := dcwebrtc.NewPeerMux(&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		panic(err)
	}
	defer mux.Close()
	var peers []*dcwebrtc.Peer
	for pair := 0; pair < 2; pair++ {
		offer := waitForFile(filepath.Join(dir, fmt.Sprintf("offer%d", pair)))
		peer, err := mux.NewPeer(muxPeerOptions(turnAddr))
		if err != nil {
			panic(err)
		}
		answer, err := peer.HandleOffer(offer)
		if err != nil {
			panic(err)
		}
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("answer%d", pair)), []byte(answer), 0o644); err != nil {
			panic(err)
		}
		peers = append(peers, peer)
	}
	for _, peer := range peers {
		peer := peer
		go func() {
			endpoint, err := peer.ConnectWithOptions(true)
			if err != nil {
				fmt.Fprintln(os.Stderr, "mux answerer connect:", err)
				os.Exit(1)
			}
			endpoint.SetOnChannel(func(channel *dcwebrtc.DataChannel) {
				channel.OnMessage(func(data []byte, isText bool) {
					reply := append([]byte("re:"), data...)
					channel.Send(reply)
				})
			})
		}()
	}
	fmt.Fprintln(os.Stderr, "MUX_ANSWERER_READY")
	select {}
}

func muxOfferer(dir string, turnAddr string) {
	mux, err := dcwebrtc.NewPeerMux(&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		panic(err)
	}
	defer mux.Close()
	var peers []*dcwebrtc.Peer
	for pair := 0; pair < 2; pair++ {
		peer, err := mux.NewPeer(muxPeerOptions(turnAddr))
		if err != nil {
			panic(err)
		}
		offer := peer.CreateOffer()
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("offer%d", pair)), []byte(offer), 0o644); err != nil {
			panic(err)
		}
		peers = append(peers, peer)
	}
	type result struct {
		pair int
		text string
	}
	results := make(chan result, 2)
	for pair, peer := range peers {
		answer := waitForFile(filepath.Join(dir, fmt.Sprintf("answer%d", pair)))
		if err := peer.HandleAnswer(answer); err != nil {
			panic(err)
		}
		go func(pair int, peer *dcwebrtc.Peer) {
			endpoint, err := peer.ConnectWithOptions(true)
			if err != nil {
				fmt.Fprintln(os.Stderr, "mux offerer connect:", err)
				os.Exit(1)
			}
			channel := endpoint.OpenChannel(dcwebrtc.DefaultChannelParams("echo"))
			replies := make(chan string, 4)
			channel.OnMessage(func(data []byte, isText bool) {
				replies <- string(data)
			})
			msg := fmt.Sprintf("hello-from-pair-%d", pair)
			channel.Send([]byte(msg))
			select {
			case reply := <-replies:
				results <- result{pair, reply}
			case <-time.After(30 * time.Second):
				fmt.Fprintln(os.Stderr, "mux offerer: no reply for pair", pair)
				os.Exit(1)
			}
		}(pair, peer)
	}
	got := make(map[int]string)
	for len(got) < 2 {
		r := <-results
		got[r.pair] = r.text
	}
	for pair := 0; pair < 2; pair++ {
		fmt.Printf("pair%d: %s\n", pair, got[pair])
	}
	fmt.Println("MUX_OK")
	select {}
}
