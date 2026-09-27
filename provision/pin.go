package provision

// Pinned is the node-install.sh this app build runs: the file at a fixed
// commit of the app's own repository and its SHA-256. TestPinnedScriptHash
// keeps the hash in step with deploy/node-install.sh; when the script
// changes, commit it, then point PinnedCommit at that commit.
const (
	PinnedRepo   = "meepo161/openfluxfork"
	PinnedCommit = "4ed30bd948c72d82e5146289295d654d48034f94"
	PinnedSHA256 = "cbd883f8d8d5509f3554c8e1fc8b246cedfab6ef7f36326fd33e14168d63018c"
)

// Pinned returns the script location for this build.
func Pinned() Script {
	return Script{
		URL:    "https://raw.githubusercontent.com/" + PinnedRepo + "/" + PinnedCommit + "/deploy/node-install.sh",
		SHA256: PinnedSHA256,
	}
}
