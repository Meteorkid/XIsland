#!/bin/bash
set -euo pipefail

X_ISLAND_REPO="${X_ISLAND_REPO:-Meteorkid/XIsland}"
X_ISLAND_APP_PATH="${X_ISLAND_APP_PATH-/Applications/X Island.app}"
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

xisland_release_metadata() {
    local release_json="$1"
    local tag="$2"

    RELEASE_JSON="$release_json" python3 - "$tag" <<'PY'
import json
import os
import re
import sys

def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(os.environ["RELEASE_JSON"])
    tag = sys.argv[1]
    if not re.fullmatch(r"v?\d+\.\d+\.\d+", tag) or data.get("tagName") != tag:
        fail("release metadata does not match the selected version tag")
    name = f"XIsland-{tag.removeprefix('v')}.dmg"
    assets = [asset for asset in data.get("assets", []) if asset.get("name") == name]
    if len(assets) != 1:
        fail(f"release must contain exactly one {name} asset")
    url = assets[0].get("url", "")
    if not isinstance(url, str) or not url.startswith("https://") or any(c in url for c in "\r\n\t"):
        fail("invalid release asset URL")
    filename = re.escape(name)
    patterns = [
        rf"{filename}\s+SHA256:\s*([a-fA-F0-9]{{64}})",
        rf"([a-fA-F0-9]{{64}})\s+\*?{filename}",
        rf"SHA256\s*\({filename}\)\s*=\s*([a-fA-F0-9]{{64}})",
    ]
    hashes = set()
    for line in (data.get("body") or "").splitlines():
        for pattern in patterns:
            match = re.fullmatch(pattern, line.strip().replace("`", ""))
            if match:
                hashes.add(match.group(1).lower())
    if len(hashes) != 1:
        fail(f"missing or conflicting SHA256 checksum for {name} in this release")
    print(name, hashes.pop(), url, sep="\t")
except (AttributeError, TypeError, ValueError) as error:
    fail(f"invalid release metadata: {error}")
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
        --json tagName,assets,body
}

xisland_download_release_asset() {
    local tag="$1"
    local asset_name="$2"
    local output="$3"
    gh release download "$tag" \
        --repo "$X_ISLAND_REPO" \
        --pattern "$asset_name" \
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
        if ! hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1; then
            echo "warning: unable to detach $mount_dir; temporary files retained at $tmpdir" >&2
            return 1
        fi
    fi

    if [[ -n "$tmpdir" ]]; then
        rm -rf -- "$tmpdir"
    fi
}

xisland_validate_app_path() {
    python3 - "$X_ISLAND_APP_PATH" <<'PY'
import os
import sys

path = sys.argv[1]
if (not os.path.isabs(path) or path.startswith("//") or os.path.normpath(path) != path
        or not os.path.basename(path).endswith(".app") or os.path.basename(path) == ".app"
        or any(ord(character) < 32 for character in path)
        or os.path.islink(path) or (os.path.lexists(path) and not os.path.isdir(path))
        or not os.path.isdir(os.path.dirname(path))):
    print("error: install target must be an absolute, normalized .app directory with an existing parent", file=sys.stderr)
    sys.exit(1)
PY
}

xisland_verify_sha256() {
    python3 - "$1" "$2" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
if digest.hexdigest() != sys.argv[2]:
    print("error: downloaded DMG failed SHA256 verification", file=sys.stderr)
    sys.exit(1)
PY
}

xisland_finish_upgrade() {
    local status="$1"
    local rollback_ok=1
    trap - EXIT HUP INT TERM

    if [[ "$upgrade_succeeded" != 1 && -n "$upgrade_transaction_dir" ]]; then
        if [[ -d "$upgrade_transaction_dir/previous.app" ]]; then
            if [[ -e "$X_ISLAND_APP_PATH" ]]; then
                mv "$X_ISLAND_APP_PATH" "$upgrade_transaction_dir/failed.app" || rollback_ok=0
            fi
            if [[ "$rollback_ok" == 1 ]]; then
                mv "$upgrade_transaction_dir/previous.app" "$X_ISLAND_APP_PATH" || rollback_ok=0
            fi
            if [[ "$rollback_ok" == 1 ]]; then
                echo "Restored the previous X Island app." >&2
                open "$X_ISLAND_APP_PATH" >/dev/null 2>&1 || true
            else
                echo "error: automatic rollback failed; previous app retained at $upgrade_transaction_dir/previous.app" >&2
            fi
        elif [[ "$upgrade_replacement_started" == 1 && -e "$X_ISLAND_APP_PATH" ]]; then
            mv "$X_ISLAND_APP_PATH" "$upgrade_transaction_dir/failed.app" || rollback_ok=0
        fi
    fi

    if [[ "$rollback_ok" == 1 && -n "$upgrade_transaction_dir" ]]; then
        rm -rf -- "$upgrade_transaction_dir" || true
    fi
    xisland_cleanup_upgrade_artifacts "$upgrade_mount_dir" "$upgrade_tmpdir" || true
    return "$status"
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

xisland_upgrade() (
    if [[ "${X_ISLAND_TEST_MODE:-0}" == "1" ]]; then
        echo "upgrade:test-mode"
        return 0
    fi

    xisland_require_command gh
    xisland_require_command python3
    xisland_require_command hdiutil
    xisland_require_command codesign
    xisland_require_command xattr
    xisland_require_command open
    xisland_validate_app_path || return 1

    # 子 shell 持有事务状态，EXIT trap 不依赖已返回函数的 local 变量。
    upgrade_tmpdir=""
    upgrade_mount_dir=""
    upgrade_transaction_dir=""
    upgrade_replacement_started=0
    upgrade_succeeded=0
    trap 'xisland_finish_upgrade "$?"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    local tag
    tag="$(xisland_release_tag)" || return 1
    if [[ ! "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: unable to determine a valid latest release tag" >&2
        exit 1
    fi

    local release_json
    release_json="$(xisland_release_json "$tag")" || return 1

    local metadata asset_name expected_sha256 asset_url
    metadata="$(xisland_release_metadata "$release_json" "$tag")" || return 1
    IFS=$'\t' read -r asset_name expected_sha256 asset_url <<< "$metadata"

    local dmg_path volume_app staged_app app_parent
    upgrade_tmpdir="$(mktemp -d)" || return 1

    dmg_path="$upgrade_tmpdir/$asset_name"
    echo "==> Downloading $tag from GitHub Releases..."
    xisland_download_release_asset "$tag" "$asset_name" "$dmg_path" || return 1
    xisland_verify_sha256 "$dmg_path" "$expected_sha256" || return 1

    echo "==> Mounting DMG..."
    upgrade_mount_dir="$upgrade_tmpdir/mount"
    mkdir "$upgrade_mount_dir" || return 1
    hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$upgrade_mount_dir" >/dev/null || return 1

    volume_app="$upgrade_mount_dir/X Island.app"
    if [[ ! -d "$volume_app" || -L "$volume_app" ]]; then
        echo "error: mounted DMG does not contain X Island.app" >&2
        exit 1
    fi

    # ad-hoc 签名校验只检查 bundle 完整性，不代表 Developer ID 发布者认证。
    codesign --verify --deep --strict "$volume_app" || return 1
    app_parent="$(dirname "$X_ISLAND_APP_PATH")"
    upgrade_transaction_dir="$(mktemp -d "$app_parent/.xisland-upgrade.XXXXXX")" || return 1
    staged_app="$upgrade_transaction_dir/X Island.app"
    cp -R "$volume_app" "$staged_app" || return 1
    xattr -cr "$staged_app" || true
    codesign --verify --deep --strict "$staged_app" || return 1

    echo "==> Unmounting DMG..."
    hdiutil detach "$upgrade_mount_dir" -quiet >/dev/null || return 1
    upgrade_mount_dir=""

    echo "==> Stopping running app..."
    pkill -x "XIsland" >/dev/null 2>&1 || true

    echo "==> Installing to $X_ISLAND_APP_PATH..."
    if [[ -e "$X_ISLAND_APP_PATH" ]]; then
        mv "$X_ISLAND_APP_PATH" "$upgrade_transaction_dir/previous.app" || return 1
    fi
    upgrade_replacement_started=1
    mv "$staged_app" "$X_ISLAND_APP_PATH" || return 1

    echo "==> Launching app..."
    open "$X_ISLAND_APP_PATH" || return 1
    upgrade_succeeded=1

    echo "Upgraded X Island to $tag"
    echo "Release asset: $asset_url"
    xisland_configure_cli_path
)

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
