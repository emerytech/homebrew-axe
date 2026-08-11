cask "axe" do
  version "3.0.0"
  sha256 "f42b06d2b1730c48986641bdf7add8280652ce2dbbb5f72463f47869327de5b9"

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
