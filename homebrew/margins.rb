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
  version "1.1.0"
  sha256 "562fb980e2988ca8bf0b8d0dfa0add7ffab639412c7a9fcf7f8d8dd0412c56ab"

  url "https://github.com/Chrismacolor/margins/releases/download/v#{version}/Margins-#{version}.dmg"
  name "Margins"
  desc "Native Markdown reader for macOS"
  homepage "https://github.com/Chrismacolor/margins"

  depends_on macos: :ventura

  app "Margins.app"
  binary "#{appdir}/Margins.app/Contents/Resources/margins-cli", target: "margins"

  zap trash: [
    "~/Library/Preferences/com.disanto.margins.plist",
  ]
end
