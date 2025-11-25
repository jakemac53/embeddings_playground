#!/bin/bash

# This script is only intended for use via the Gemini CLI extension, it does
# not do any invalidation of the compiled artifacts. If you want to use it
# for local development you will have to manually delete the `out` dir to
# get an updated executable.
set -e

if [ -f "out/mcp_server.exe" ]; then
  out/mcp_server.exe
else
  mkdir out/
  dart compile exe bin/github_mcp.dart -o out/mcp_server.exe >&2
  dart compile exe bin/github.dart -o out/github.exe >&2
  out/mcp_server.exe
fi
