# Homebrew cask for Margins — a native macOS Markdown reader.
# https://github.com/Chrismacolor/margins
#
# Maintained in the app repo (homebrew/margins.rb) and mirrored verbatim to the
# tap (Chrismacolor/homebrew-tap, under Casks/). On each release, bump `version`
# + `sha256` to the new DMG (release.sh prints the sha256), then copy this file
# into the tap. Install:
#
#   brew install --cask Chrismacolor/tap/margins
#
# Updates flow through `brew upgrade` — no in-app updater (keeps the app
# zero-dependency).

cask "margins" do
  version "1.2.1"
  sha256 "256e69cbc99ed4125bdf470546a4f1e0302a95fd8962602f9d705ca22f0b7084"

  url "https://github.com/Chrismacolor/margins/releases/download/v#{version}/Margins-#{version}.dmg"
  name "Margins"
  desc "Native Markdown reader for macOS"
  homepage "https://github.com/Chrismacolor/margins"

  depends_on macos: :ventura

  app "Margins.app"
  binary "#{appdir}/Margins.app/Contents/Resources/margins-cli", target: "margins"

  caveats <<~EOS
    Margins is signed and notarized, but Homebrew quarantines every download.
    If you only ever launch Margins from an agent or the CLI (e.g. watch mode),
    macOS never runs its first-open approval and may show a misleading
    "Margins.app is damaged" dialog. It is not damaged — clear the quarantine:

      xattr -dr com.apple.quarantine "#{appdir}/Margins.app"

    To skip quarantine on future upgrades, install with:

      brew install --cask --no-quarantine margins
  EOS

  zap trash: [
    "~/Library/Preferences/com.disanto.margins.plist",
  ]
end
