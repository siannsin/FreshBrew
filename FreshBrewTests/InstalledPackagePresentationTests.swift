import XCTest
@testable import FreshBrew

final class InstalledPackagePresentationTests: XCTestCase {
    func testPackagesFiltersByKindAndSortsNamesAlphabetically() {
        let packages = [
            makePackage("Zulu", kind: .formula),
            makePackage("chatgpt", kind: .cask),
            makePackage("alpha", kind: .formula),
            makePackage("Beta", kind: .formula)
        ]

        let formulae = InstalledPackagePresentation.packages(
            from: packages,
            kind: .formula,
            query: ""
        )

        XCTAssertEqual(formulae.map(\.name), ["alpha", "Beta", "Zulu"])
    }

    func testPackagesSearchesNamesCaseInsensitivelyWithinKind() {
        let packages = [
            makePackage("openssl@3", kind: .formula),
            makePackage("openjdk", kind: .formula),
            makePackage("OpenVPN Connect", kind: .cask)
        ]

        let formulae = InstalledPackagePresentation.packages(
            from: packages,
            kind: .formula,
            query: "  OPEN  "
        )
        let casks = InstalledPackagePresentation.packages(
            from: packages,
            kind: .cask,
            query: "openvpn"
        )

        XCTAssertEqual(formulae.map(\.name), ["openjdk", "openssl@3"])
        XCTAssertEqual(casks.map(\.name), ["OpenVPN Connect"])
    }

    private func makePackage(
        _ name: String,
        kind: HomebrewPackageKind
    ) -> InstalledPackage {
        InstalledPackage(
            name: name,
            installedVersion: "1.0",
            kind: kind
        )
    }
}
