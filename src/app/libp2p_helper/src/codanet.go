package codanet

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"path"
	"time"

	dsb "github.com/ipfs/go-ds-badger"
	logging "github.com/ipfs/go-log"
	p2p "github.com/libp2p/go-libp2p"
	p2pconnmgr "github.com/libp2p/go-libp2p-connmgr"
	"github.com/libp2p/go-libp2p-core/connmgr"
	"github.com/libp2p/go-libp2p-core/control"
	"github.com/libp2p/go-libp2p-core/crypto"
	"github.com/libp2p/go-libp2p-core/host"
	"github.com/libp2p/go-libp2p-core/network"
	"github.com/libp2p/go-libp2p-core/peer"
	"github.com/libp2p/go-libp2p-core/routing"
	discovery "github.com/libp2p/go-libp2p-discovery"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p-kad-dht/dual"
	"github.com/libp2p/go-libp2p-peerstore/pstoreds"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	record "github.com/libp2p/go-libp2p-record"
	p2pconfig "github.com/libp2p/go-libp2p/config"
	mdns "github.com/libp2p/go-libp2p/p2p/discovery"
	ma "github.com/multiformats/go-multiaddr"
	"golang.org/x/crypto/blake2b"
)

type CodaConnectionManager struct {
	p2pManager   *p2pconnmgr.BasicConnMgr
	OnConnect    func(network.Network, network.Conn)
	OnDisconnect func(network.Network, network.Conn)
}

func newCodaConnectionManager() *CodaConnectionManager {
	noop := func(net network.Network, c network.Conn) {}

	return &CodaConnectionManager{
		p2pManager:   p2pconnmgr.NewConnManager(25, 250, time.Duration(30*time.Second)),
		OnConnect:    noop,
		OnDisconnect: noop,
	}
}

// proxy p2pconnmgr.ConnManager interface to p2pconnmgr.BasicConnMgr
func (cm *CodaConnectionManager) TagPeer(p peer.ID, tag string, weight int) {
	cm.p2pManager.TagPeer(p, tag, weight)
}
func (cm *CodaConnectionManager) UntagPeer(p peer.ID, tag string) { cm.p2pManager.UntagPeer(p, tag) }
func (cm *CodaConnectionManager) UpsertTag(p peer.ID, tag string, upsert func(int) int) {
	cm.p2pManager.UpsertTag(p, tag, upsert)
}
func (cm *CodaConnectionManager) GetTagInfo(p peer.ID) *connmgr.TagInfo {
	return cm.p2pManager.GetTagInfo(p)
}
func (cm *CodaConnectionManager) TrimOpenConns(ctx context.Context) { cm.p2pManager.TrimOpenConns(ctx) }
func (cm *CodaConnectionManager) Protect(p peer.ID, tag string)     { cm.p2pManager.Protect(p, tag) }
func (cm *CodaConnectionManager) Unprotect(p peer.ID, tag string) bool {
	return cm.p2pManager.Unprotect(p, tag)
}
func (cm *CodaConnectionManager) IsProtected(p peer.ID, tag string) bool {
	return cm.p2pManager.IsProtected(p, tag)
}
func (cm *CodaConnectionManager) Close() error { return cm.p2pManager.Close() }

// redirect Notifee() to self for notification interception
func (cm *CodaConnectionManager) Notifee() network.Notifiee { return cm }

// proxy Notifee notifications to p2pconnmgr.BasicConnMgr, intercepting Connected and Disconnected
func (cm *CodaConnectionManager) Listen(net network.Network, addr ma.Multiaddr) {
	cm.p2pManager.Notifee().Listen(net, addr)
}
func (cm *CodaConnectionManager) ListenClose(net network.Network, addr ma.Multiaddr) {
	cm.p2pManager.Notifee().ListenClose(net, addr)
}
func (cm *CodaConnectionManager) OpenedStream(net network.Network, stream network.Stream) {
	cm.p2pManager.Notifee().OpenedStream(net, stream)
}
func (cm *CodaConnectionManager) ClosedStream(net network.Network, stream network.Stream) {
	cm.p2pManager.Notifee().ClosedStream(net, stream)
}
func (cm *CodaConnectionManager) Connected(net network.Network, c network.Conn) {
	cm.OnConnect(net, c)
	cm.p2pManager.Notifee().Connected(net, c)
}
func (cm *CodaConnectionManager) Disconnected(net network.Network, c network.Conn) {
	cm.OnDisconnect(net, c)
	cm.p2pManager.Notifee().Disconnected(net, c)
}

// Helper contains all the daemon state
type Helper struct {
	Host              host.Host
	Mdns              *mdns.Service
	Dht               *dual.DHT
	Ctx               context.Context
	Pubsub            *pubsub.PubSub
	Logger            logging.EventLogger
	DiscoveredPeers   chan peer.AddrInfo
	Rendezvous        string
	Discovery         *discovery.RoutingDiscovery
	Me                peer.ID
	GatingState       *CodaGatingState
	ConnectionManager *CodaConnectionManager
}

type customValidator struct {
	Base record.Validator
}

// this type implements the ConnectionGating interface
// https://godoc.org/github.com/libp2p/go-libp2p-core/connmgr#ConnectionGating
// the comments of the functions below are taken from those docs.
type CodaGatingState struct {
	AddrFilters  *ma.Filters
	DeniedPeers  *peer.Set
	AllowedPeers *peer.Set
}

// InterceptPeerDial tests whether we're permitted to Dial the specified peer.
//
// This is called by the network.Network implementation when dialling a peer.
func (gs *CodaGatingState) InterceptPeerDial(p peer.ID) (allow bool) {
	allow = !gs.DeniedPeers.Contains(p) || gs.AllowedPeers.Contains(p)

	return
}

// InterceptAddrDial tests whether we're permitted to dial the specified
// multiaddr for the given peer.
//
// This is called by the network.Network implementation after it has
// resolved the peer's addrs, and prior to dialling each.
func (gs *CodaGatingState) InterceptAddrDial(id peer.ID, addr ma.Multiaddr) (allow bool) {
	allow = (!gs.DeniedPeers.Contains(id) || gs.AllowedPeers.Contains(id)) && !gs.AddrFilters.AddrBlocked(addr)
	return
}

// InterceptAccept tests whether an incipient inbound connection is allowed.
//
// This is called by the upgrader, or by the transport directly (e.g. QUIC,
// Bluetooth), straight after it has accepted a connection from its socket.
func (gs *CodaGatingState) InterceptAccept(addrs network.ConnMultiaddrs) (allow bool) {
	remoteAddr := addrs.RemoteMultiaddr()
	allow = !gs.AddrFilters.AddrBlocked(remoteAddr)
	return
}

// InterceptSecured tests whether a given connection, now authenticated,
// is allowed.
//
// This is called by the upgrader, after it has performed the security
// handshake, and before it negotiates the muxer, or by the directly by the
// transport, at the exact same checkpoint.
func (gs *CodaGatingState) InterceptSecured(_ network.Direction, id peer.ID, addrs network.ConnMultiaddrs) (allow bool) {
	// note: we don't care about the direction (inbound/outbound). all
	// connections in coda are symmetric: if i am allowed to connect to
	// you, you are allowed to connect to me.
	remoteAddr := addrs.RemoteMultiaddr()
	allow = (!gs.DeniedPeers.Contains(id) || gs.AllowedPeers.Contains(id)) && !gs.AddrFilters.AddrBlocked(remoteAddr)
	return
}

// InterceptUpgraded tests whether a fully capable connection is allowed.
//
// At this point, the connection a multiplexer has been selected.
// When rejecting a connection, the gater can return a DisconnectReason.
// Refer to the godoc on the ConnectionGating type for more information.
//
// NOTE: the go-libp2p implementation currently IGNORES the disconnect reason.
func (gs *CodaGatingState) InterceptUpgraded(network.Conn) (allow bool, reason control.DisconnectReason) {
	allow = true
	reason = control.DisconnectReason(0)
	return
}

func (cv customValidator) Validate(key string, value []byte) error {
	log.Printf("DHT Validating: %s = %s", key, value)
	return cv.Base.Validate(key, value)
}

func (cv customValidator) Select(key string, values [][]byte) (int, error) {
	log.Printf("DHT Selecting Among: %s = %s", key, bytes.Join(values, []byte("; ")))
	return cv.Base.Select(key, values)
}

// TODO: just put this into main.go?

// MakeHelper does all the initialization to run one host
func MakeHelper(ctx context.Context, listenOn []ma.Multiaddr, externalAddr ma.Multiaddr, statedir string, pk crypto.PrivKey, networkID string, seeds []peer.AddrInfo, gatingState CodaGatingState) (*Helper, error) {
	logger := logging.Logger("codanet.Helper")

	me, err := peer.IDFromPrivateKey(pk)
	if err != nil {
		return nil, err
	}

	dso := dsb.DefaultOptions

	ds, err := dsb.NewDatastore(path.Join(statedir, "libp2p-peerstore-v0"), &dso)
	if err != nil {
		return nil, err
	}

	dsoDht := dsb.DefaultOptions
	dsDht, err := dsb.NewDatastore(path.Join(statedir, "libp2p-dht-v0"), &dsoDht)
	if err != nil {
		return nil, err
	}

	ps, err := pstoreds.NewPeerstore(ctx, ds, pstoreds.DefaultOpts())
	if err != nil {
		return nil, err
	}

	rendezvousString := fmt.Sprintf("/coda/0.0.1/%s", networkID)

	pnetKey := blake2b.Sum256([]byte(rendezvousString))

	// custom validator to omit the ipns validation.

	rv := customValidator{Base: record.NamespacedValidator{"pk": record.PublicKeyValidator{}}}

	// TODO: we may be able to take this gross hack out now
	// gross hack to exfiltrate the DHT from the side effect of option evaluation
	kadch := make(chan *dual.DHT)

	connManager := newCodaConnectionManager()

	host, err := p2p.New(ctx,
		p2p.Muxer("/coda/mplex/1.0.0", DefaultMplexTransport),
		p2p.Identity(pk),
		p2p.Peerstore(ps),
		p2p.DisableRelay(),
		p2p.ConnectionGater(&gatingState),
		p2p.ConnectionManager(connManager),
		p2p.ListenAddrs(listenOn...),
		p2p.AddrsFactory(func(as []ma.Multiaddr) []ma.Multiaddr {
			as = append(as, externalAddr)
			return as
		}),
		p2p.NATPortMap(),
		p2p.Routing(
			p2pconfig.RoutingC(func(host host.Host) (routing.PeerRouting, error) {
				kad, err := dual.New(ctx, host, dual.WanDHTOption(dht.Datastore(dsDht)), dual.DHTOption(dht.Validator(rv)), dual.WanDHTOption(dht.BootstrapPeers(seeds...)), dual.DHTOption(dht.ProtocolPrefix("/coda")))
				go func() { kadch <- kad }()
				return kad, err
			})),
		p2p.UserAgent("github.com/codaprotocol/coda/tree/master/src/app/libp2p_helper"),
		p2p.PrivateNetwork(pnetKey[:]))

	if err != nil {
		return nil, err
	}

	kad := <-kadch
	kad.Bootstrap(ctx)

	// nil fields are initialized by beginAdvertising
	return &Helper{
		Host:              host,
		Ctx:               ctx,
		Mdns:              nil,
		Dht:               kad,
		Pubsub:            nil,
		Logger:            logger,
		DiscoveredPeers:   nil,
		Rendezvous:        rendezvousString,
		Discovery:         nil,
		Me:                me,
		GatingState:       &gatingState,
		ConnectionManager: connManager,
	}, nil
}
