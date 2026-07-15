#!/bin/sh
# install.sh — fetch, VERIFY (sha256), and install the rusty binaries.
# Small on purpose: read it before you run it.
#   RUSTY_VERSION       tag to install (default: latest release)
#   RUSTY_INSTALL_BASE  release download base (default: GitHub releases)
#   RUSTY_INSTALL_DIR   install dir (default: ~/.local/bin)
set -eu

REPO="TheLakeMan/rusty"
BASE="${RUSTY_INSTALL_BASE:-https://github.com/$REPO/releases/download}"
DIR="${RUSTY_INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  TARGET="x86_64-unknown-linux-gnu" ;;
  Linux-aarch64) TARGET="aarch64-unknown-linux-gnu" ;;
  *) echo "No prebuilt binary for $(uname -s)/$(uname -m)." >&2
     echo "Build from source instead: cargo install rusty-lisp" >&2
     exit 1 ;;
esac

VERSION="${RUSTY_VERSION:-$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)}"
[ -n "$VERSION" ] || { echo "Could not determine latest release tag." >&2; exit 1; }

NAME="rusty-$VERSION-$TARGET"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching $NAME.tar.gz ..."
curl -fsSL -o "$TMP/$NAME.tar.gz"        "$BASE/$VERSION/$NAME.tar.gz"
curl -fsSL -o "$TMP/$NAME.tar.gz.sha256" "$BASE/$VERSION/$NAME.tar.gz.sha256"

echo "Verifying checksum ..."
(cd "$TMP" && sha256sum -c "$NAME.tar.gz.sha256" >/dev/null)

tar xzf "$TMP/$NAME.tar.gz" -C "$TMP"
mkdir -p "$DIR"
install -m 755 "$TMP/$NAME/rusty" "$TMP/$NAME/rusty-lsp" "$DIR/"

echo "Installed rusty + rusty-lsp to $DIR"
case ":$PATH:" in
  *":$DIR:"*) ;;
  *) echo "NOTE: $DIR is not on your PATH — add: export PATH=\"$DIR:\$PATH\"" ;;
esac
echo "Note: the interpreter is fully self-contained; defrust/graph-compile (JIT) additionally need rustc on PATH."
"$DIR/rusty" --help >/dev/null 2>&1 || true
