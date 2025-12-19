#!/usr/bin/env bash
set -euo pipefail

echo "FieldExec: macOS command-line codesign fix"
echo

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is macOS-only."
  exit 1
fi

KEYCHAIN_RAW="$(security default-keychain -d user | head -n 1 || true)"
KEYCHAIN="$(printf "%s" "$KEYCHAIN_RAW" | tr -d '\"' | xargs || true)"
if [[ -z "${KEYCHAIN:-}" ]]; then
  KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
fi

IDENTITY_HASH="$(
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ {print $2; exit 0}'
)"

if [[ -z "${IDENTITY_HASH:-}" ]]; then
  echo "No Apple Development signing identity found in the keychain."
  echo "Open Xcode → Settings → Accounts and ensure you have a valid 'Apple Development' certificate."
  exit 1
fi

echo "Keychain:  $KEYCHAIN"
echo "Identity:  $IDENTITY_HASH"
echo

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/sign_test.c" <<'C'
int main() { return 0; }
C

clang "$TMP_DIR/sign_test.c" -o "$TMP_DIR/sign_test_bin" >/dev/null 2>&1 || {
  echo "Failed to compile a tiny test binary (clang missing?)."
  exit 1
}

try_sign() {
  /usr/bin/codesign --force --verbose --sign "$IDENTITY_HASH" -- "$TMP_DIR/sign_test_bin" >/dev/null 2>&1
}

if try_sign; then
  echo "✅ codesign works for Apple Development identity."
  echo "You should be able to run: flutter run -d macos"
  exit 0
fi

echo "codesign FAILED for your Apple Development identity."
echo "This usually breaks Flutter macOS CLI builds with:"
echo "  errSecInternalComponent"
echo
echo "Fix: unlock the login keychain and allow Apple tools (codesign/xcodebuild) to access the key non-interactively."
echo

read -r -s -p "Enter your macOS login keychain password: " KEYCHAIN_PASSWORD
echo

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || {
  echo "Failed to unlock keychain '$KEYCHAIN'."
  echo "Double-check the password, or unlock it manually in Keychain Access and try again."
  exit 1
}

# This is the standard fix used for CI/non-interactive codesigning:
# allow Apple tools to use the private key without prompting.
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN" >/dev/null 2>&1 || {
  echo "Failed to update key partition list."
  echo "Try running again, or open Keychain Access → your private key → Access Control → allow codesign."
  exit 1
}

if try_sign; then
  echo "✅ Fixed: codesign now works non-interactively."
  echo
  echo "Next:"
  echo "  flutter clean"
  echo "  flutter run -d macos"
  exit 0
fi

echo "Still failing to codesign after updating key partition list."
echo
echo "Next steps:"
echo "  - Open Keychain Access → login → Keys → find the private key for your Apple Development cert"
echo "  - In Access Control, allow 'codesign' / 'Xcode' to access it"
echo "  - Or regenerate the Apple Development certificate in Xcode → Settings → Accounts"
exit 1

