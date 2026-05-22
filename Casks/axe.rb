cask "axe" do
  version "2.5.0"
  sha256 "40a290edafc8ddb46117bbc64236386e5399bad7314a917548125d7ff3c09dad"

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
