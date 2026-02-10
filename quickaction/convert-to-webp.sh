#!/bin/bash
# Convert to WebP — Finder Quick Action wrapper
# This script is called by an Automator Quick Action that receives
# files or folders as arguments from Finder.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

for f in "$@"; do
  towebp "$f"
done
