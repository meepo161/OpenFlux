package provision

// Pinned is the node-install.sh this app build runs: the file at a fixed
// commit of the app's own repository and its SHA-256. TestPinnedScriptHash
// keeps the hash in step with deploy/node-install.sh; when the script
// changes, commit it, then point PinnedCommit at that commit.
const (
	PinnedRepo   = "p1neappleXpress/OpenFlux"
	PinnedCommit = "122ab88baee0bdce515792b48318484e32d0d24c"
	PinnedSHA256 = "70be5e964bf808c96aa9d32caef6b8e0d7c609f7af60c0acae45d4a6af5e6ec5"
)

// Pinned returns the script location for this build.
func Pinned() Script {
	return Script{
		URL:    "https://raw.githubusercontent.com/" + PinnedRepo + "/" + PinnedCommit + "/deploy/node-install.sh",
		SHA256: PinnedSHA256,
	}
}
