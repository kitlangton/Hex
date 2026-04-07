#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
package_dir="$script_dir"
install_dir="${INSTALL_DIR:-$HOME/.local/bin}"

mkdir -p "$install_dir"

version="$(plutil -extract CFBundleShortVersionString raw "$repo_root/Hex/Info.plist" 2>/dev/null || true)"
if [[ -z "$version" && -f "$repo_root/package.json" ]]; then
  version="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$repo_root/package.json" | head -n 1)"
fi

if [[ -z "$version" ]]; then
  echo "Error: could not determine Hex version" >&2
  exit 1
fi

swift build --package-path "$package_dir" -c release --product hex-cli
bin_path="$(swift build --package-path "$package_dir" -c release --show-bin-path)"
source_binary="$bin_path/hex-cli"
target_binary="$install_dir/hex-cli-$version"
current_symlink="$install_dir/hex-cli"

install -m 0755 "$source_binary" "$target_binary"
ln -sfn "$(basename "$target_binary")" "$current_symlink"

echo "Installed hex-cli $version to $target_binary"
echo "Updated $current_symlink -> $(basename "$target_binary")"

hash -r 2>/dev/null || true
if ! command -v hex-cli >/dev/null 2>&1; then
  echo "Warning: hex-cli is not on PATH in this shell"
else
  echo "hex-cli is available at $(command -v hex-cli)"
fi
