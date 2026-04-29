#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq nix-prefetch-github uv
set -euo pipefail

owner=roodjong
repo=symfexit
branch=${1:-main}

cd "$(dirname "$(readlink -f "$0")")"
root=$PWD

echo "==> Fetching latest commit of $owner/$repo@$branch"
new_rev=$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$branch" | jq -r .sha)
echo "    rev = $new_rev"

current_rev=$(grep -oE 'rev = "[0-9a-f]{40}";' flake.nix | head -1 | grep -oE '[0-9a-f]{40}')
if [ "$new_rev" = "$current_rev" ]; then
  echo "==> Already at $current_rev, nothing to do"
  exit 0
fi

echo "==> Prefetching source hash"
new_hash=$(nix-prefetch-github "$owner" "$repo" --rev "$new_rev" | jq -r .hash)
echo "    hash = $new_hash"

echo "==> Updating flake.nix"
sed -i \
  -e "s|rev = \"[0-9a-f]\{40\}\";|rev = \"$new_rev\";|" \
  -e "s|hash = \"sha256-[^\"]*\";|hash = \"$new_hash\";|" \
  flake.nix

echo "==> Regenerating requirements.txt from upstream pyproject.toml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/$owner/$repo/archive/$new_rev.tar.gz" | tar -xz -C "$tmp"
src="$tmp/$repo-$new_rev"
( cd "$src" && uv pip compile pyproject.toml \
    --universal --generate-hashes --strip-extras \
    -o "$root/requirements.txt" )

echo "==> Refreshing dream2nix lock"
nix run "$root#symfexit-package.config.lock.refresh"

echo "==> Done"
