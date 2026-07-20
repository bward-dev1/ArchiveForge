#!/usr/bin/env bash
# ArchiveForge — fetch & pin the same upstream emulator cores WizardiOS
# already uses, scoped to just the two systems this app needs (GBA/NDS).
# Each core stays in its own framework/license island. Run from the repo
# root:  ./Scripts/setup-cores.sh
set -euo pipefail
cd "$(dirname "$0")/.."

add() { # add <path> <url> <ref>
  local path="Cores/$1" url="$2" ref="${3:-}"
  if [ -d "$path/.git" ] || git config -f .gitmodules --get "submodule.$path.url" >/dev/null 2>&1; then
    echo "✓ $path already present"
  else
    echo "→ adding $path from $url"
    git submodule add "$url" "$path" || { echo "  ⚠ could not add $path (repo may be moved/removed)"; return 0; }
  fi
  [ -n "$ref" ] && git -C "$path" checkout "$ref" 2>/dev/null || true
}

echo "== GBA =="
add mGBA    https://github.com/mgba-emu/mgba.git          # MPL-2.0  (cleanest, no JIT needed — see Cores/README.md)

echo "== NDS =="
add melonDS https://github.com/melonDS-emu/melonDS.git    # GPLv3    (needs JIT — sideload-only, same as WizardiOS)

git submodule update --init --recursive || true
echo
echo "Done. Next: build each core for iOS/macOS — see Cores/README.md."
