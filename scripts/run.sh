#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$repository_root/build"
app_path="$derived_data_path/Build/Products/Debug/Ambient.app"

# Sign with the same Developer ID identity as the released app. macOS ties privacy grants to the
# signing requirement, so a development-signed build would take the grants away from the installed
# app (the toggles stay on in System Settings but the app is refused). Never fall back to ad-hoc signing.
xcodebuild \
    -project "$repository_root/Ambient.xcodeproj" \
    -scheme Ambient \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    DEVELOPMENT_TEAM=Z63L6KDQ9K \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY='Developer ID Application' \
    build

signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
if ! grep -q '^TeamIdentifier=Z63L6KDQ9K$' <<< "$signature_details" \
    || ! grep -q '^Authority=Developer ID Application:' <<< "$signature_details"; then
    echo 'Ambient must be signed with the Developer ID Application identity for Z63L6KDQ9K.' >&2
    exit 1
fi
codesign --verify --strict "$app_path"

# Build verification must not open windows on the owner’s desktop.
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi

# Send the app its normal termination signal and wait for that exact process.
while read -r running_process_id; do
    # Other worktrees may be running their own build. Only quit this executable.
    [[ "$(ps -p "$running_process_id" -o comm=)" == "$app_path/Contents/MacOS/Ambient" ]] || continue
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

# LaunchServices does not automatically inherit this shell's environment.
# Pass only configured overrides; never persist them in defaults or the app bundle.
launch_options=()
for environment_name in PUBLIK_API_KEY PUBLIK_API_BASE_URL AMBIENT_CONNECTOR_ORIGIN AMBIENT_ANALYTICS_DEV; do
    if [[ -n "${!environment_name:-}" ]]; then
        launch_options+=(--env "$environment_name=${!environment_name}")
    fi
done
# The ${array[@]+...} form keeps macOS's bash 3.2 from treating an empty array as unset.
open -n ${launch_options[@]+"${launch_options[@]}"} --stdout "$derived_data_path/app-stdout.log" --stderr "$derived_data_path/app-stderr.log" "$app_path" --args "$@"
echo "Launched $app_path"
