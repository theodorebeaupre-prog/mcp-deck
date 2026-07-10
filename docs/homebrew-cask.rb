# Homebrew cask template for MCP Deck.
# Publish it in a tap repository (e.g. github.com/theodorebeaupre-prog/homebrew-tap)
# as Casks/mcp-deck.rb, updating `version` and `sha256` on each release:
#   shasum -a 256 MCP-Deck-vX.Y.Z.zip
cask "mcp-deck" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_RELEASE_ZIP"

  url "https://github.com/theodorebeaupre-prog/mcp-deck/releases/download/v#{version}/MCP-Deck-v#{version}.zip"
  name "MCP Deck"
  desc "Menu bar dashboard for MCP servers across Claude Desktop, Claude Code, and Cursor"
  homepage "https://github.com/theodorebeaupre-prog/mcp-deck"

  depends_on macos: ">= :sonoma"

  app "MCPDeck.app"

  zap trash: [
    "~/Library/Preferences/com.theodorebeaupre.MCPDeck.plist",
  ]
end
