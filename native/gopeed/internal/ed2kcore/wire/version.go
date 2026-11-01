package wire

import "strings"

// compatibleClient is Kelpie's id in the top byte of CT_EMULE_VERSION. eMule
// and aMule assign 0-6 (SO_EMULE .. SO_HYDRANODE), 0x0A, 0x14, 0x28,
// 0x32-0x36, 0x44, 0x98 and 0xFF; 0x4B ('K') is free.
const compatibleClient = 0x4B

// ToEmuleVersion packs a version such as "v1.2.3-dev" into CT_EMULE_VERSION,
// which both the server login and the peer Hello carry: compatible client
// in the top byte, then major, minor and update in 7, 7 and 3 bits, as
// aMule's make_full_ed2k_version (OtherFunctions.h:334) lays them out.
// Each field counts its leading digits only, so a suffix does not zero it.
func ToEmuleVersion(version string) uint32 {
	var parts [3]uint32
	for i, part := range strings.SplitN(strings.TrimPrefix(version, "v"), ".", 3) {
		for _, r := range part {
			if r < '0' || r > '9' {
				break
			}
			parts[i] = parts[i]*10 + uint32(r-'0')
		}
	}
	return compatibleClient<<24 | (parts[0]&0x7F)<<17 | (parts[1]&0x7F)<<10 | (parts[2]&0x07)<<7
}
