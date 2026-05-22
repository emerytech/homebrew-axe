cask "axe" do
  version "1.3.0"
  sha256 "d699d24d044ddc4e01167ce52e2e7957b4a7462f8a6113657bc3e4fa777c2d62"

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
