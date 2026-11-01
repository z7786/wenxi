package piece

import "testing"

func TestED2KKnownHashesAndExactPartBoundary(t *testing.T) {
	var small FileHasher
	small.Write([]byte("abc"))
	if small.FileHash().String() != "A448017AAF21D8525FC10AE87AA6729D" {
		t.Fatal("MD4 vector mismatch")
	}
	exact := make([]byte, PartSize)
	var full FileHasher
	full.Write(exact)
	hashes := full.PartHashes()
	if len(hashes) != 2 || full.FileHash() != BuildFileHash(hashes) {
		t.Fatal("exact part must retain the empty trailing MD4")
	}
	var empty MD4
	if hashes[1] != empty.Digest() {
		t.Fatal("empty trailing part mismatch")
	}
	exact[0] = 1
	var corrupt FileHasher
	corrupt.Write(exact)
	if corrupt.FileHash() == full.FileHash() {
		t.Fatal("corrupt part accepted")
	}
}
