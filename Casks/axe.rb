cask "axe" do
  version "1.8.1"
  sha256 "c3225172d68bffde7cb733778478dad881157c1677d69644ea57c1a90f20d800"

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
