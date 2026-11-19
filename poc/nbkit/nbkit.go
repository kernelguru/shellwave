// Package nbkit ist ein Machbarkeitstest: NetBird-Client eingebettet in eine iOS-App
// (ohne VPN-Profil), mit einem lokalen TCP-Proxy, über den die App per SSH zu einem
// NetBird-Peer verbinden kann. Exportiert über gomobile.
package nbkit

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/netbirdio/netbird/client/embed"
	_ "golang.org/x/mobile/bind"
)

// Node ist ein eingebetteter NetBird-Peer.
type Node struct {
	client    *embed.Client
	mu        sync.Mutex
	listeners []net.Listener
}

// NewNode legt einen Peer an. Entweder setupKey oder jwt angeben.
func NewNode(managementURL, setupKey, jwt, deviceName, statePath string) (*Node, error) {
	c, err := embed.New(embed.Options{
		DeviceName:    deviceName,
		SetupKey:      setupKey,
		JWTToken:      jwt,
		ManagementURL: managementURL,
		ConfigPath:    statePath + "/netbird.json",
		StatePath:     statePath + "/state.json",
		LogLevel:      "info",
	})
	if err != nil {
		return nil, fmt.Errorf("netbird: %w", err)
	}
	return &Node{client: c}, nil
}

// Start verbindet mit dem Management-Server und baut das Overlay auf.
func (n *Node) Start(timeoutSeconds int) error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSeconds)*time.Second)
	defer cancel()
	return n.client.Start(ctx)
}

// Stop baut das Overlay ab und schließt alle Proxys.
func (n *Node) Stop() error {
	n.mu.Lock()
	for _, l := range n.listeners {
		_ = l.Close()
	}
	n.listeners = nil
	n.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return n.client.Stop(ctx)
}

// StartProxy öffnet 127.0.0.1:<port> und leitet jede Verbindung über das Overlay
// an target (z. B. "100.92.1.5:22022") weiter. Gibt den lokalen Port zurück.
func (n *Node) StartProxy(target string) (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	n.mu.Lock()
	n.listeners = append(n.listeners, l)
	n.mu.Unlock()

	go func() {
		for {
			local, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer local.Close()
				ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
				remote, err := n.client.Dial(ctx, "tcp", target)
				cancel()
				if err != nil {
					return
				}
				defer remote.Close()
				done := make(chan struct{}, 2)
				go func() { _, _ = io.Copy(remote, local); done <- struct{}{} }()
				go func() { _, _ = io.Copy(local, remote); done <- struct{}{} }()
				<-done
			}()
		}
	}()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// StatusJSON liefert den Zustand (eigene IP, Peers) als JSON.
func (n *Node) StatusJSON() (string, error) {
	st, err := n.client.Status()
	if err != nil {
		return "", err
	}
	type peer struct {
		FQDN   string `json:"fqdn"`
		IP     string `json:"ip"`
		Status string `json:"status"`
	}
	out := struct {
		IP    string `json:"ip"`
		FQDN  string `json:"fqdn"`
		Peers []peer `json:"peers"`
	}{IP: st.LocalPeerState.IP, FQDN: st.LocalPeerState.FQDN}
	for _, p := range st.Peers {
		out.Peers = append(out.Peers, peer{FQDN: p.FQDN, IP: p.IP, Status: p.ConnStatus.String()})
	}
	b, err := json.Marshal(out)
	return string(b), err
}

// VerifySSHHostKey prüft den Host-Key eines Peers gegen den von NetBird verteilten Schlüssel.
func (n *Node) VerifySSHHostKey(peerAddress string, key []byte) error {
	return n.client.VerifySSHHostKey(peerAddress, key)
}
