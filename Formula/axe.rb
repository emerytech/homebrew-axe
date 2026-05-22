class Axe < Formula
  desc "Spotlight-style overlay to quickly kill running macOS apps (⌥⌘K)"
  homepage "https://github.com/emerytech/homebrew-axe"
  url "https://github.com/emerytech/homebrew-axe/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "171712953da81d26035dcbc6a6a86e1bec47812d5630552a9da8e5369e1ff30c"
  license "MIT"

  depends_on :macos

  def install
    system "bash", "menubar/build.sh"
    prefix.install "menubar/Axe.app"
  end

  def caveats
    <<~EOS
      Axe.app was installed to:
        #{opt_prefix}/Axe.app

      Open it with:
        open #{opt_prefix}/Axe.app

      Then press ⌥⌘K (Option+Command+K) from anywhere to pop the overlay.
      No Accessibility permission is required — the hotkey uses Carbon's
      system-level event registration.
    EOS
  end

  test do
    assert_predicate prefix/"Axe.app/Contents/MacOS/Axe", :executable?
  end
end
