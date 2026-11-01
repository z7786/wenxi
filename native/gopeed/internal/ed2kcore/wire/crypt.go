package wire

// CryptOptions bits, one byte shared by Source Exchange v4, the servers'
// obfuscated source answers and callbacks, and Kad's TAG_ENCRYPTION (aMule
// kademlia/Prefs.cpp:217 GetMyConnectOptions, PartFile.cpp:1800).
const (
	CryptSupported      byte = 0x01
	CryptRequested      byte = 0x02
	CryptRequired       byte = 0x04
	CryptDirectCallback byte = 0x08
	// CryptHasUserHash: a server answer carries the source's user hash,
	// which keys an obfuscated connection.
	CryptHasUserHash byte = 0x80
)

// CanObfuscate tells whether a connection to a client with these crypt
// options may be obfuscated: it supports obfuscation and we know the user
// hash that keys it. Kelpie requests obfuscation, so a supporting client is
// always obfuscated, as aMule does (CUpDownClient::Connect).
func CanObfuscate(options byte, user Hash) bool {
	return options&CryptSupported != 0 && user != Hash{}
}
