#!/bin/bash
set -euo pipefail

X_ISLAND_REPO="${X_ISLAND_REPO:-user/xisland}"
X_ISLAND_APP_PATH="${X_ISLAND_APP_PATH:-/Applications/X Island.app}"
X_ISLAND_BIN_DIR="${X_ISLAND_BIN_DIR:-$HOME/.xisland/bin}"

xisland_usage() {
    cat <<'EOF'
Usage: xisland <command>

Commands:
  upgrade    Download and install the latest GitHub release
  help       Show this help message
EOF
}

xisland_require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: required command not found: $cmd" >&2
        exit 1
    fi
}

xisland_release_asset_url() {
    local release_json="$1"

    RELEASE_JSON="$release_json" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["RELEASE_JSON"])
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if name.endswith(".dmg"):
        print(asset["url"])
        break
else:
    sys.exit(1)
PY
}

xisland_release_tag() {
    gh release list \
        --repo "$X_ISLAND_REPO" \
        --exclude-drafts \
        --exclude-pre-releases \
        --limit 1 \
        --json tagName \
        --jq '.[0].tagName'
}

xisland_release_json() {
    local tag="$1"
    gh release view "$tag" \
        --repo "$X_ISLAND_REPO" \
        --json tagName,assets,name,publishedAt
}

xisland_download_release_asset() {
    local tag="$1"
    local output="$2"
    gh release download "$tag" \
        --repo "$X_ISLAND_REPO" \
        --pattern '*.dmg' \
        --output "$output" \
        --clobber
}

xisland_mount_dir_from_attach_output() {
    local attach_output="$1"

    printf '%s\n' "$attach_output" \
        | awk -F '\t' '/\/Volumes\// {print $NF}' \
        | tail -n 1
}

xisland_cleanup_upgrade_artifacts() {
    local mount_dir="${1:-}"
    local tmpdir="${2:-}"

    if [[ -n "$mount_dir" ]]; then
        hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
    fi

    if [[ -n "$tmpdir" ]]; then
        rm -rf "$tmpdir"
    fi
}

xisland_cli_bin_in_path() {
    case ":$PATH:" in
        *":$X_ISLAND_BIN_DIR:"*) return 0 ;;
        *) return 1 ;;
    esac
}

xisland_shell_profile_path_hint() {
    local shell_name
    shell_name="$(basename "${SHELL:-}")"

    case "$shell_name" in
        zsh)
            printf '%s\n' '~/.zshrc'
            ;;
        bash)
            printf '%s\n' '~/.bash_profile'
            ;;
        fish)
            printf '%s\n' '~/.config/fish/config.fish'
            ;;
        *)
            printf '%s\n' 'your shell profile'
            ;;
    esac
}

xisland_shell_profile_path() {
    local shell_name
    shell_name="$(basename "${SHELL:-}")"

    case "$shell_name" in
        zsh)
            printf '%s\n' "$HOME/.zshrc"
            ;;
        bash)
            printf '%s\n' "$HOME/.bash_profile"
            ;;
        fish)
            printf '%s\n' "$HOME/.config/fish/config.fish"
            ;;
        *)
            return 1
            ;;
    esac
}

xisland_path_export_line() {
    local shell_name
    shell_name="$(basename "${SHELL:-}")"

    case "$shell_name" in
        fish)
            printf '%s\n' 'set -gx PATH "$HOME/.xisland/bin" $PATH'
            ;;
        *)
            printf '%s\n' 'export PATH="$HOME/.xisland/bin:$PATH"'
            ;;
    esac
}

xisland_ensure_cli_on_path() {
    if xisland_cli_bin_in_path; then
        return 0
    fi

    local profile_path profile_dir export_line
    profile_path="$(xisland_shell_profile_path)" || return 1
    profile_dir="$(dirname "$profile_path")"
    export_line="$(xisland_path_export_line)"

    mkdir -p "$profile_dir"
    touch "$profile_path"

    if grep -F 'xisland/bin' "$profile_path" >/dev/null 2>&1; then
        return 0
    fi

    {
        printf '\n'
        printf '%s\n' '# Added by X Island'
        printf '%s\n' "$export_line"
    } >> "$profile_path"
}

xisland_print_path_guidance() {
    if xisland_cli_bin_in_path; then
        return 0
    fi

    local profile_hint
    profile_hint="$(xisland_shell_profile_path_hint)"

    echo ""
    echo "To run 'xisland upgrade' from any directory, add this to $profile_hint:"
    echo "  export PATH=\"$X_ISLAND_BIN_DIR:\$PATH\""
}

xisland_configure_cli_path() {
    if xisland_cli_bin_in_path; then
        return 0
    fi

    if xisland_ensure_cli_on_path; then
        local profile_hint
        profile_hint="$(xisland_shell_profile_path_hint)"
        echo ""
        echo "Configured your shell PATH in $profile_hint."
        echo "Open a new shell window, or run:"
        echo "  export PATH=\"$X_ISLAND_BIN_DIR:\$PATH\""
        return 0
    fi

    xisland_print_path_guidance
}

xisland_upgrade() {
    if [[ "${X_ISLAND_TEST_MODE:-0}" == "1" ]]; then
        echo "upgrade:test-mode"
        return 0
    fi

    xisland_require_command gh
    xisland_require_command hdiutil
    xisland_require_command xattr
    xisland_require_command open

    local tag
    tag="$(xisland_release_tag)"
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        echo "error: unable to determine latest release tag" >&2
        exit 1
    fi

    local release_json
    release_json="$(xisland_release_json "$tag")"

    local asset_api_url
    asset_api_url="$(xisland_release_asset_url "$release_json")" || {
        echo "error: latest release does not contain a DMG asset" >&2
        exit 1
    }

    local tmpdir dmg_path mount_dir volume_app
    tmpdir="$(mktemp -d)"
    trap 'xisland_cleanup_upgrade_artifacts "" "$tmpdir"' EXIT

    dmg_path="$tmpdir/XIsland.dmg"
    echo "==> Downloading $tag from GitHub Releases..."
    xisland_download_release_asset "$tag" "$dmg_path"

    echo "==> Mounting DMG..."
    local attach_output
    attach_output="$(hdiutil attach "$dmg_path" -nobrowse)"
    mount_dir="$(xisland_mount_dir_from_attach_output "$attach_output")"
    if [[ -z "$mount_dir" ]]; then
        echo "error: failed to mount DMG" >&2
        exit 1
    fi

    trap 'xisland_cleanup_upgrade_artifacts "${mount_dir:-}" "${tmpdir:-}"' EXIT

    volume_app="$mount_dir/X Island.app"
    if [[ ! -d "$volume_app" ]]; then
        echo "error: mounted DMG does not contain X Island.app" >&2
        exit 1
    fi

    echo "==> Stopping running app..."
    pkill -x "XIsland" >/dev/null 2>&1 || true

    echo "==> Installing to $X_ISLAND_APP_PATH..."
    rm -rf "$X_ISLAND_APP_PATH"
    cp -R "$volume_app" "$X_ISLAND_APP_PATH"

    echo "==> Clearing Gatekeeper quarantine..."
    xattr -cr "$X_ISLAND_APP_PATH" || true

    echo "==> Unmounting DMG..."
    hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
    mount_dir=""

    echo "==> Launching app..."
    open "$X_ISLAND_APP_PATH"

    echo "Upgraded X Island to $tag"
    echo "Release asset: $asset_api_url"
    xisland_configure_cli_path
}

xisland_dispatch() {
    local command="${1:-}"
    shift || true

    case "$command" in
        "" | help | --help | -h)
            xisland_usage
            ;;
        upgrade)
            xisland_upgrade "$@"
            ;;
        *)
            echo "error: unknown command: $command" >&2
            xisland_usage >&2
            return 1
            ;;
    esac
}
