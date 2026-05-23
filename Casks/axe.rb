cask "axe" do
  version "2.6.1"
  sha256 "46d07cac6c64cd2b00eec0ab6d18e8f739784cc13d207571fac1315ea44fd0e2"

  url "https://github.com/emerytech/homebrew-axe/releases/download/v#{version}/Axe.zip"
  name "Axe"
  desc "Spotlight-style overlay to quickly kill running apps"
  homepage "https://github.com/emerytech/homebrew-axe"

  depends_on :macos

  app "Axe.app"

  uninstall quit: "com.emerytech.axe"

  zap trash: [
    "~/Library/Preferences/com.emerytech.axe.plist",
    "~/Library/Saved Application State/com.emerytech.axe.savedState",
  ]

  caveats <<~EOS
    Press ⌘Z from anywhere to pop the overlay.
    You can change the shortcut anytime in Settings.
    No Accessibility permission required.
  EOS
end
