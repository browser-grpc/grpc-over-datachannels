package dcwebrtc

// TURN on muxed peers: two PeerMuxes whose peers also allocate
// on a fake TURN server. The advertised host addresses are
// deliberately unreachable, so a working echo proves the
// relayed pairs carried ICE + DTLS + data while the mux
// demuxed the non-relay traffic by connection id. The
// allocation's UDP leg rides a dedicated per-peer socket (an
// allocation pins a concrete 5-tuple); TURN traffic never
// touches the shared socket.

import (
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

func TestTurnMuxToMuxTwoPairs(t *testing.T) {
	_, serverAddr := fakeTurn(t)
	options := PeerOptions{
		RequirePeerCertificate: false,
		LocalIPs:               []string{"10.11.12.13"},
		TurnServers:            []TurnServerConfig{{Address: serverAddr, Username: "dcuser", Password: "dcpass"}},
	}
	muxA, err := NewPeerMux(&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer muxA.Close()
	muxB, err := NewPeerMux(&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer muxB.Close()

	type pair struct {
		offerer, answerer *Peer
		offer             string
	}
	var pairs []pair
	for i := 0; i < 2; i++ {
		offerer, err := muxA.NewPeer(options)
		if err != nil {
			t.Fatal(err)
		}
		defer offerer.Close()
		answerer, err := muxB.NewPeer(options)
		if err != nil {
			t.Fatal(err)
		}
		defer answerer.Close()
		offer := offerer.CreateOffer()
		if !strings.Contains(offer, "typ relay") {
			t.Fatalf("muxed offerer has no relay candidate:\n%s", offer)
		}
		pairs = append(pairs, pair{offerer, answerer, offer})
	}

	done := make(chan error, 2)
	for i, p := range pairs {
		go func(i int, p pair) {
			answer, err := p.answerer.HandleOffer(p.offer)
			if err != nil {
				done <- err
				return
			}
			if err := p.offerer.HandleAnswer(answer); err != nil {
				done <- err
				return
			}
			type connResult struct {
				ep  *DcEndpoint
				err error
			}
			connect := func(peer *Peer) chan connResult {
				ch := make(chan connResult, 1)
				go func() {
					ep, err := peer.ConnectWithOptions(true)
					ch <- connResult{ep, err}
				}()
				return ch
			}
			offerCh, answerCh := connect(p.offerer), connect(p.answerer)
			var epOffer, epAnswer *DcEndpoint
			for k := 0; k < 2; k++ {
				select {
				case r := <-offerCh:
					if r.err != nil {
						done <- fmt.Errorf("pair %d offerer connect: %w", i, r.err)
						return
					}
					epOffer = r.ep
				case r := <-answerCh:
					if r.err != nil {
						done <- fmt.Errorf("pair %d answerer connect: %w", i, r.err)
						return
					}
					epAnswer = r.ep
				case <-time.After(30 * time.Second):
					done <- fmt.Errorf("pair %d connect timed out", i)
					return
				}
			}
			heard := make(chan string, 1)
			epAnswer.SetOnChannel(func(channel *DataChannel) {
				channel.OnMessage(func(data []byte, isText bool) {
					heard <- string(data)
					channel.Send([]byte("re:" + string(data)))
				})
			})
			channel := epOffer.OpenChannel(DefaultChannelParams("echo"))
			reply := make(chan string, 1)
			channel.OnMessage(func(data []byte, isText bool) {
				reply <- string(data)
			})
			want := fmt.Sprintf("hello-from-pair-%d", i)
			channel.Send([]byte(want))
			select {
			case got := <-heard:
				if got != want {
					done <- fmt.Errorf("pair %d: answerer heard %q, want %q", i, got, want)
					return
				}
			case <-time.After(15 * time.Second):
				done <- fmt.Errorf("pair %d: answerer heard nothing", i)
				return
			}
			select {
			case got := <-reply:
				if want := "re:" + want; got != want {
					done <- fmt.Errorf("pair %d: offerer reply %q, want %q", i, got, want)
					return
				}
			case <-time.After(15 * time.Second):
				done <- fmt.Errorf("pair %d: offerer got no reply", i)
				return
			}
			done <- nil
		}(i, p)
	}
	for range pairs {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
}
