cask "axe" do
  version "2.7.0"
  sha256 "5da2fffa0df22741c643fd6abd5528a29fa215561608c4f962a54e9209e584ff"

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
