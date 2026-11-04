import Foundation
import Testing
@testable import Sandshell

// `LegacyKitsError` and the kit names it matches sbx's refusal by
// (`KitStore.derivedName`). Name lookups take `derivedName` in place of
// `KitStore.sbxName`, which reads what `sbx kit inspect` said from
// `UserDefaults.standard` (the test host is the real app).

struct LegacyKitsErrorTests {
    /// sbx 0.51's refusal, as it printed it.
    static let refusal = "error: resolve kits: cannot mix v3 kits with v1/v2 kits in one sandbox; compositions are "
        + "single-format (v3: claude, git-ssh-sign, github-ssh, sandshell-claude; v1/v2: claude-sbx-statusline). "
        + "Use a v3 version of the v1/v2 kit, for example its published docker.io/sbx/<name> form"

    @Test func readsTheOlderKitsFromSbxsRefusal() {
        #expect(LegacyKitsError.legacyNames(inSbxError: Self.refusal) == ["claude-sbx-statusline"])
    }

    @Test func readsSeveralOlderKits() {
        let message = "cannot mix v3 kits with v1/v2 kits in one sandbox; (v3: claude; v1/v2: hatch, beads-kit)"
        #expect(LegacyKitsError.legacyNames(inSbxError: message) == ["hatch", "beads-kit"])
    }

    @Test(arguments: ["error: resolve kits: kit path /tmp/x does not exist", "", "v1/v2: something"])
    func otherErrorsAreNotARefusal(message: String) {
        #expect(LegacyKitsError.legacyNames(inSbxError: message) == nil)
    }

    @Test func matchesTheNamedKitsToTheWorkspacesReferences() {
        let kits = ["docker.io/sbx/claude-sbx-statusline-kit:latest", "docker.io/sbx/git-ssh-sign:latest",
                    "/Users/me/kits/beads-kit", "sandshell-claude"]
        let matched = LegacyKitsError.refs(named: ["claude-sbx-statusline", "beads"], in: kits,
                                           sbxName: KitStore.derivedName)
        #expect(matched == ["docker.io/sbx/claude-sbx-statusline-kit:latest", "/Users/me/kits/beads-kit"])
    }

    @Test func namesEveryKitAndHowToFixIt() throws {
        let error = LegacyKitsError(refs: ["/Users/me/kits/never-registered-\(UUID().uuidString)"])
        let text = try #require(error.errorDescription)
        #expect(text.contains("older kit format"))
        #expect(text.contains(error.refs[0]))
        #expect(text.contains("Turn it off"))
        #expect(LegacyKitsError(refs: ["/a/one", "/b/two"]).errorDescription?.contains("Turn them off") == true)
    }
}

struct KitDerivedNameTests {
    @Test(arguments: [
        ("docker.io/sbx/claude-sbx-statusline-kit:latest", "claude-sbx-statusline"),
        ("docker.io/sbx/git-ssh-sign:latest", "git-ssh-sign"),
        ("docker.io/sbx/github-ssh@sha256:abc", "github-ssh"),
        ("/Users/me/Code/xmas-kits/hatch-kit", "hatch"),
        ("/Users/me/Code/kits/beads/", "beads"),
        ("git+https://github.com/docker/sbx-kits-contrib.git#ref=ee37&dir=droid", "droid"),
        ("git+https://github.com/me/my-kit.git", "my"),
        ("kit", "kit"),
    ])
    func nameFromReference(ref: String, name: String) {
        #expect(KitStore.derivedName(ref) == name)
    }

    @Test func localKitsAreFolders() {
        #expect(KitStore.isLocal("/Users/me/kit"))
        #expect(KitStore.isLocal("~/kit"))
        #expect(!KitStore.isLocal("docker.io/sbx/claude-sbx-statusline:latest"))
    }

    @Test func dockersOlderStatusLineKitMovesToItsV3Name() {
        #expect(KitStore.current("docker.io/sbx/claude-sbx-statusline-kit:latest") == "docker.io/sbx/claude-sbx-statusline:latest")
    }
}
