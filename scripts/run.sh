#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$repository_root/build"
app_path="$derived_data_path/Build/Products/Debug/Ambient.app"

# A development certificate and fixed bundle ID/path preserve the signing
# requirement macOS uses for privacy grants; never fall back to ad-hoc signing.
xcodebuild \
    -project "$repository_root/Ambient.xcodeproj" \
    -scheme Ambient \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    DEVELOPMENT_TEAM=Z63L6KDQ9K \
    CODE_SIGN_IDENTITY='Apple Development' \
    build

signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
if ! grep -q '^TeamIdentifier=Z63L6KDQ9K$' <<< "$signature_details" \
    || ! grep -q '^Authority=Apple Development:' <<< "$signature_details"; then
    echo 'Ambient must be signed with an Apple Development identity for Z63L6KDQ9K.' >&2
    exit 1
fi
codesign --verify --strict "$app_path"

# Send the app its normal termination signal and wait for that exact process.
while read -r running_process_id; do
    kill -TERM "$running_process_id"
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! kill -0 "$running_process_id" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    if kill -0 "$running_process_id" 2>/dev/null; then
        echo "Ambient (PID $running_process_id) did not quit; leaving it running." >&2
        exit 1
    fi
done < <(pgrep -x Ambient || true)

open -n "$app_path"
echo "Launched $app_path"
