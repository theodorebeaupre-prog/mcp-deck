# Changelog

All notable changes to MCP Deck are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - TBD

### Added
- Dashboard of all MCP servers found on the machine, grouped by client or by server.
- Config scanning for Claude Desktop, Claude Code (global, per-project and `.mcp.json`), and Cursor.
- On-demand and on-launch health checks for `stdio` and `http`/`sse` transports (JSON-RPC `initialize`), with auth-required detection.
- Server detail view: full command, masked environment variables, exposed tools (`tools/list`), last check time.
- Enable/disable a server per client with automatic `.bak` backup and lossless round-trip via `_disabled_mcpServers`.
- Live log viewer for Claude Desktop MCP logs with per-server filtering.
- Menu bar icon reflecting global status (error / auth-required badge).
