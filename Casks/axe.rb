cask "axe" do
  version "1.0.0"
  sha256 "89b36e1b41437032651a7e6f71cdfe3c46adca3e2aca68a1b130ffbc6f5790da"

  url "https://github.com/emerytech/homebrew-axe/releases/download/v#{version}/Axe.zip"
  name "Axe"
  desc "Spotlight-style overlay to quickly kill running apps"
  homepage "https://github.com/emerytech/homebrew-axe"

  depends_on :macos

  app "Axe.app"

  caveats <<~EOS
    Press ⌥⌘K (Option+Command+K) from anywhere to pop the overlay.
    No Accessibility permission required.
  EOS
end
