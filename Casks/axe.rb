cask "axe" do
  version "3.2.1"
  sha256 "e0346b251c9875d1bc88b80052c564c62d02cac86d6178d80333cf33ebfd34ef"

  url "https://github.com/emerytech/homebrew-axe/releases/download/v#{version}/Axe.zip"
  name "Axe"
  desc "Spotlight-style overlay to quickly kill running apps"
  homepage "https://github.com/emerytech/homebrew-axe"

  depends_on macos: ">= :ventura"

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
