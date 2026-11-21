#!/usr/bin/env bash
# Give a CI job its own unlocked keychain holding the code signing identity, so
# codesign never needs the runner user's login keychain.
#
# The self-hosted Mac runner is a launchd service. Its user's login keychain is
# locked whenever nobody is logged in at the console, and codesign then fails
# with errSecInternalComponent. A keychain created by the job is unlocked by the
# job, so signing works without a GUI session.
#
#   bash .github/scripts/signing-keychain.sh create
#     needs SIGNING_CERTIFICATE_P12 (base64 of a .p12 holding an
#     "Apple Development" certificate of the paid team and its private key) and
#     SIGNING_CERTIFICATE_PASSWORD (the .p12 password, may be empty).
#     Writes LEDGER_SIGNING_KEYCHAIN to $GITHUB_ENV.
#   bash .github/scripts/signing-keychain.sh delete
#     removes that keychain and takes it off the user's keychain search list. Run
#     it with `if: always()`.
set -euo pipefail

action="${1:-}"
state_dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/ledger-signing"
keychain="${state_dir}/ledger-signing.keychain-db"
saved_list="${state_dir}/search-list"

case "$action" in
  create)
    if [[ -z "${SIGNING_CERTIFICATE_P12:-}" ]]; then
      echo "::error::The secret SIGNING_CERTIFICATE_P12 is empty. Export the team's Apple Development certificate with its private key as .p12 and store it base64-encoded (see AGENTS.md)." >&2
      exit 1
    fi
    rm -rf "$state_dir"
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"
    umask 077

    password="$(uuidgen)"
    p12="${state_dir}/signing.p12"
    printf '%s' "$SIGNING_CERTIFICATE_P12" | base64 --decode > "$p12"

    security list-keychains -d user | sed -e 's/^ *"//' -e 's/" *$//' > "$saved_list"

    security create-keychain -p "$password" "$keychain"
    # No auto-lock during the job (6 h), and no lock on sleep.
    security set-keychain-settings -t 21600 "$keychain"
    security unlock-keychain -p "$password" "$keychain"
    security import "$p12" -k "$keychain" -f pkcs12 \
      -P "${SIGNING_CERTIFICATE_PASSWORD:-}" \
      -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcrun
    rm -f "$p12"
    # Lets codesign use the key without the "allow access" dialog nobody can click.
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
      -s -k "$password" "$keychain" > /dev/null

    # Ours first, so Xcode finds the identity there; the rest stay reachable.
    old=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && old+=("$line")
    done < "$saved_list"
    security list-keychains -d user -s "$keychain" ${old[@]+"${old[@]}"}

    identities="$(security find-identity -v -p codesigning "$keychain")"
    echo "$identities" | sed -n 's/^ *[0-9]*) [0-9A-F]* /  /p'
    if ! grep -q '"Apple Development' <<< "$identities"; then
      echo "::error::SIGNING_CERTIFICATE_P12 holds no valid Apple Development identity (certificate plus private key)." >&2
      exit 1
    fi
    echo "LEDGER_SIGNING_KEYCHAIN=${keychain}" >> "${GITHUB_ENV:?GITHUB_ENV is not set}"
    ;;
  delete)
    # Drop only our entry: other runners of the same user may share the list.
    rest=()
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != "$keychain" ]] && rest+=("$line")
    done < <(security list-keychains -d user | sed -e 's/^ *"//' -e 's/" *$//')
    if [[ ${#rest[@]} -gt 0 ]]; then
      security list-keychains -d user -s "${rest[@]}"
    fi
    if [[ -e "$keychain" ]]; then
      security delete-keychain "$keychain" || rm -f "$keychain"
    fi
    rm -rf "$state_dir"
    ;;
  *)
    echo "Usage: bash .github/scripts/signing-keychain.sh create|delete" >&2
    exit 1
    ;;
esac
