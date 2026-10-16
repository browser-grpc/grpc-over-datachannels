// Full-peer echo harness with SDP exchanged through files:
//
//	peer_echo offerer  <offer-file> <answer-file>
//	peer_echo answerer <offer-file> <answer-file>
//
// Mirrors webrtc/rust/examples/peer_echo.rs.
package main

import (
	"bufio"
	"fmt"
	"os"
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
	switch mode {
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
		fmt.Fprintln(os.Stderr, "usage: peer_echo <offerer|answerer> <offer-file> <answer-file>")
		os.Exit(2)
	}
}
