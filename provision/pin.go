package provision

import "fmt"

// The node-install.sh scripts this app build runs, each a file at a fixed
// commit and its SHA-256. The script decides which repository's node-v*
// releases the server's core and its updater come from, so choosing a
// script chooses the node's core.
//
// Pinned* is this repository's own deploy/node-install.sh
// (meepo161/OpenFlux releases); TestPinnedScriptHash keeps its hash in step
// with the file: when the script changes, commit it, then point
// PinnedCommit at that commit. Official* is the same script following
// p1neappleXpress/OpenFlux releases.
const (
	PinnedRepo   = "meepo161/OpenFlux"
	PinnedCommit = "b2aa79d6bc699cae07f383cf5c4f121c96c523a4"
	PinnedSHA256 = "90d490bdbdd74c942a1a62a217aca2c26eec1181c165b954a9e4f9683e84329e"

	OfficialRepo   = "p1neappleXpress/OpenFlux"
	OfficialCommit = "122ab88baee0bdce515792b48318484e32d0d24c"
	OfficialSHA256 = "70be5e964bf808c96aa9d32caef6b8e0d7c609f7af60c0acae45d4a6af5e6ec5"
)

// Script sources the node wizard offers.
const (
	SourceFork     = "fork"
	SourceOfficial = "official"
)

// Pinned returns this build's own script (SourceFork).
func Pinned() Script {
	return Script{
		URL:    "https://raw.githubusercontent.com/" + PinnedRepo + "/" + PinnedCommit + "/deploy/node-install.sh",
		SHA256: PinnedSHA256,
	}
}

// PinnedFor returns the script for a source: SourceFork (also "") or
// SourceOfficial.
func PinnedFor(source string) (Script, error) {
	switch source {
	case "", SourceFork:
		return Pinned(), nil
	case SourceOfficial:
		return Script{
			URL:    "https://raw.githubusercontent.com/" + OfficialRepo + "/" + OfficialCommit + "/deploy/node-install.sh",
			SHA256: OfficialSHA256,
		}, nil
	}
	return Script{}, fmt.Errorf("неизвестный источник ядра %q", source)
}
