import Foundation
import Testing
@testable import CleanerCore

@Suite struct HomebrewTests {
    let info = """
    {"formulae": [
      {"name": "gh", "desc": "GitHub CLI", "installed": [{"version": "2.80.0", "installed_on_request": true}]},
      {"name": "cairo", "desc": "Graphics", "installed": [{"version": "1.18.4", "installed_on_request": false}]}
     ],
     "casks": [
      {"token": "google-chrome", "name": ["Google Chrome"], "desc": "Web browser", "installed": "153.0", "auto_updates": true,
       "artifacts": [{"app": ["Google Chrome.app"], "target": "/Applications/Google Chrome.app"}, {"zap": []}]},
      {"token": "maccy", "name": ["Maccy"], "installed": "2.7.1", "artifacts": [{"app": ["Maccy.app"]}]}
     ]}
    """
    let outdated = """
    {"formulae": [{"name": "cairo", "installed_versions": ["1.18.4"], "current_version": "1.18.6"}],
     "casks": [{"name": "maccy", "installed_versions": ["2.7.1"], "current_version": "2.8.0"}]}
    """

    @Test func readsPackagesUpdatesAndMissingApps() {
        let packages = Homebrew.parse(info: info, outdated: outdated, fileExists: { $0 == "/Applications/Maccy.app" })
        let byToken = Dictionary(uniqueKeysWithValues: packages.map { ($0.token, $0) })

        #expect(byToken["google-chrome"]?.isAppMissing == true)
        #expect(byToken["google-chrome"]?.autoUpdates == true)
        #expect(byToken["maccy"]?.isAppMissing == false)
        #expect(byToken["maccy"]?.latestVersion == "2.8.0")
        #expect(byToken["cairo"]?.isRequested == false)
        #expect(byToken["cairo"]?.latestVersion == "1.18.6")
        #expect(byToken["gh"]?.isOutdated == false)
    }

    @Test func readsCleanupEstimate() {
        let output = """
        Would remove: /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.6_2 (1,707 files, 34.6MB)
        ==> This operation would free approximately 74.9MB of disk space.
        """
        #expect(Homebrew.parseCleanupEstimate(output) == 74_900_000)
        #expect(Homebrew.parseCleanupEstimate("nothing") == nil)
    }

    @Test func buildsCommandsWithoutAShell() {
        let cask = BrewPackage(kind: .cask, token: "iina", displayName: "IINA", summary: nil, installedVersion: "1",
                               latestVersion: nil, isRequested: true, autoUpdates: false, appPath: nil, isAppMissing: true)
        #expect(Homebrew.uninstallArguments(cask) == ["uninstall", "--cask", "iina"])
        #expect(Homebrew.upgradeArguments(nil) == ["upgrade"])
        #expect(Homebrew.reinstallArguments(cask) == ["reinstall", "--cask", "iina"])
    }
}
