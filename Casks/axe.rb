cask "axe" do
  version "1.8.0"
  sha256 "d4c0a38bb8552733021fefbd9c5fb8ac50022eaa604ed315323b3986d4d340aa"

  url "https://github.com/emerytech/homebrew-axe/releases/download/v#{version}/Axe.zip"
  name "Axe"
  desc "Spotlight-style overlay to quickly kill running apps"
  homepage "https://github.com/emerytech/homebrew-axe"

  depends_on :macos

  app "Axe.app"

  caveats <<~EOS
    Press ⌘A from anywhere to pop the overlay.
    While the overlay is open, ⌘A selects all apps in the list.
    No Accessibility permission required.
  EOS
end
