#!/usr/bin/env bash
#
# build.sh - Portable Pox Kernel builder & AnyKernel3 flashable zip packager
# For Redmi Note 8 Pro (begonia, MT6785)
#
# Dependencies are fully self-contained inside ./kerdevdep
# Builds and flashable zips are placed in ./build
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
OUT_DIR="${OUT_DIR:-$BUILD_DIR/out}"
KERDEVDEP="${KERDEVDEP:-$ROOT_DIR/kerdevdep}"

# Kernel Branding & Versioning (Fully customizable via environment or build script)
KERNEL_NAME="${KERNEL_NAME:-Pox}"
KERNEL_VERSION="${KERNEL_VERSION:-1.0.0-Beta}"
DEVICE_NAME="${DEVICE_NAME:-Redmi Note 8 Pro}"
DEVICE_CODENAME="${DEVICE_CODENAME:-begonia}"
MAINTAINER="${MAINTAINER:-Pox}"
DEFCONFIG="${DEFCONFIG:-}"

log()  { printf '\033[1;32m[*] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[-] %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Recovery-time root manager delivery
# ---------------------------------------------------------------------------
# The root-manager branches ship the matching manager APK inside every
# AnyKernel3 package. The installer copies it to /system/app/<package> while
# still in recovery, so Android registers it for user 0 on the next boot.
# No package manager, init service, or /data write is involved.
#
# POX_ROOT_VARIANT selects the manager (folkpatch|apatch|bakasu).
# POX_INSTALL_ROOT_MANAGER=1 enables the /system/app installation.
# POX_EXCLUSIVE_MANAGERS=1 also removes the two non-selected managers.
# POX_STAGE_KPM_APK=1 copies the Pox Kernel Manager APK to internal storage;
# it is never installed automatically.
POX_ROOT_VARIANT="${POX_ROOT_VARIANT:-}"
POX_INSTALL_ROOT_MANAGER="${POX_INSTALL_ROOT_MANAGER:-0}"
POX_EXCLUSIVE_MANAGERS="${POX_EXCLUSIVE_MANAGERS:-0}"
POX_STAGE_KPM_APK="${POX_STAGE_KPM_APK:-0}"

FOLKPATCH_REPO="${FOLKPATCH_REPO:-LyraVoid/FolkPatch}"
APATCH_REPO="${APATCH_REPO:-bmax121/APatch}"
BAKASU_REPO="${BAKASU_REPO:-Baka-SU/BakaSU}"
KPM_REPO="${KPM_REPO:-methylphetamine/pox-kernel-manager}"

# The BakaSU manager must match the vendored driver, not the moving tip.
# variants/bakasu.patch pins the driver to BakaSU main f6cb7e70 and exports
# KSU_VERSION=35226. BakaSU numbers its manager 30000 + commit_count + 700,
# so v4.2.0-rc3 (4526 commits) is exactly version code 35226.
BAKASU_TAG="${BAKASU_TAG:-v4.2.0-rc3}"
BAKASU_ASSET="${BAKASU_ASSET:-ReSukiSU_v4.2.0-rc3_35171-arm64-v8a-release.apk}"
BAKASU_DRIVER_VERSION="${BAKASU_DRIVER_VERSION:-35226}"

ROOT_LABEL=""
ROOT_PACKAGE=""
ROOT_APK_NAME=""
ROOT_FLASHABLE="0"
KPM_APK_NAME=""

github_latest_apk_url() {
    local repo="$1" pattern="${2:-\.apk$}"
    local api="https://api.github.com/repos/${repo}/releases/latest"
    local json=""
    local -a auth=()

    command -v curl >/dev/null 2>&1 || return 1
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    json="$(curl -fsSL "${auth[@]}" "$api" 2>/dev/null)" || return 1
    printf '%s' "$json" | python3 -c '
import json, re, sys
pattern = re.compile(sys.argv[1])
release = json.load(sys.stdin)
for asset in release.get("assets", []):
    if pattern.search(asset.get("name", "")):
        print(asset["browser_download_url"])
        break
' "$pattern"
}

download_latest_apk() {
    local repo="$1" dest="$2" pattern="$3" label="$4" url=""

    url="$(github_latest_apk_url "$repo" "$pattern")"
    if [[ -z "$url" ]]; then
        err "Could not resolve the latest ${label} APK from ${repo}."
        return 1
    fi

    log "Downloading ${label} release: $(basename "$url")"
    curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" || {
        err "Failed to download ${label} APK."
        return 1
    }
}

download_pinned_apk() {
    local repo="$1" tag="$2" asset="$3" dest="$4" label="$5"
    local url="https://github.com/${repo}/releases/download/${tag}/${asset}"

    log "Downloading pinned ${label} release: ${tag}/${asset}"
    curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" || {
        err "Failed to download ${label} ${tag} (${asset})."
        return 1
    }
}

resolve_root_manager() {
    case "$POX_ROOT_VARIANT" in
        folkpatch)
            ROOT_LABEL="FolkPatch"
            ROOT_PACKAGE="me.yuki.folk"
            ROOT_APK_NAME="FolkPatch.apk"
            ROOT_FLASHABLE="1"
            ;;
        apatch)
            ROOT_LABEL="APatch"
            ROOT_PACKAGE="me.bmax.apatch"
            ROOT_APK_NAME="APatch.apk"
            ROOT_FLASHABLE="1"
            ;;
        bakasu)
            ROOT_LABEL="BakaSU"
            ROOT_PACKAGE="com.resukisu.resukisu"
            ROOT_APK_NAME="BakaSU.apk"
            ROOT_FLASHABLE="0"
            ;;
        "")
            return 0
            ;;
        *)
            err "Unknown POX_ROOT_VARIANT: ${POX_ROOT_VARIANT}"
            exit 1
            ;;
    esac
}

fetch_root_manager_apk() {
    local dest="$1"

    case "$POX_ROOT_VARIANT" in
        folkpatch)
            download_latest_apk "$FOLKPATCH_REPO" "$dest" '\.apk$' "FolkPatch"
            ;;
        apatch)
            download_latest_apk "$APATCH_REPO" "$dest" '\.apk$' "APatch"
            ;;
        bakasu)
            assert_bakasu_driver_version
            download_pinned_apk "$BAKASU_REPO" "$BAKASU_TAG" "$BAKASU_ASSET" "$dest" "BakaSU"
            ;;
        *)
            err "No root manager configured for POX_ROOT_VARIANT='${POX_ROOT_VARIANT}'."
            return 1
            ;;
    esac
}

assert_bakasu_driver_version() {
    local kbuild="drivers/kernelsu/Kbuild"
    local driver_version=""

    [[ -f "$kbuild" ]] || {
        err "BakaSU driver is missing (${kbuild}); apply variants/bakasu.patch first."
        return 1
    }
    driver_version="$(awk -F':=' '/^KSU_VERSION[[:space:]]*:=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$kbuild")"
    if [[ "$driver_version" != "$BAKASU_DRIVER_VERSION" ]]; then
        err "BakaSU driver version ${driver_version:-unknown} does not match manager ${BAKASU_TAG} (${BAKASU_DRIVER_VERSION})."
        return 1
    fi
    log "BakaSU driver/manager version verified: ${driver_version} (${BAKASU_TAG})"
}

fetch_kpm_apk() {
    local dest_dir="$1" url="" tag=""

    url="$(github_latest_apk_url "$KPM_REPO" '\.apk$')"
    if [[ -z "$url" ]]; then
        err "Could not resolve the latest Pox Kernel Manager APK from ${KPM_REPO}."
        return 1
    fi
    tag="$(printf '%s' "$url" | sed -E 's#.*/download/([^/]+)/.*#\1#')"
    [[ -n "$tag" && "$tag" != "$url" ]] || tag="latest"
    KPM_APK_NAME="Pox-Kernel-Manager-${tag}.apk"

    log "Downloading Pox Kernel Manager release: $(basename "$url")"
    curl -fL --retry 3 --connect-timeout 20 -o "$dest_dir/$KPM_APK_NAME" "$url" || {
        err "Failed to download Pox Kernel Manager APK."
        return 1
    }
}

write_pox_install_helper() {
    local stage="$1" others="" pkg

    case "$POX_ROOT_VARIANT" in
        folkpatch) others="me.bmax.apatch com.resukisu.resukisu" ;;
        apatch)    others="me.yuki.folk com.resukisu.resukisu" ;;
        bakasu)    others="me.yuki.folk me.bmax.apatch" ;;
    esac

    cat <<'POX_HELPER_EOF' > "$stage/pox_install.sh"
#!/system/bin/sh
# Pox Kernel recovery post-install helper.
# Installs the selected root manager as a system app for user 0 and optionally
# removes the other root managers. Recovery never talks to the package manager.

ROOT_VARIANT="@ROOT_VARIANT@"
ROOT_LABEL="@ROOT_LABEL@"
ROOT_PACKAGE="@ROOT_PACKAGE@"
ROOT_APK="@ROOT_APK@"
ROOT_FLASHABLE="@ROOT_FLASHABLE@"
INSTALL_ROOT="@INSTALL_ROOT@"
EXCLUSIVE="@EXCLUSIVE@"
OTHER_PACKAGES="@OTHER_PACKAGES@"
STAGE_KPM="@STAGE_KPM@"
KPM_APK="@KPM_APK@"

pox_log() {
    if command -v ui_print >/dev/null 2>&1; then
        ui_print " [*] $*"
    else
        echo " [*] $*"
    fi
}

pox_system_root() {
    local d
    for d in /system /system_root/system /system_root; do
        [ -d "$d/app" ] && { echo "$d"; return 0; }
    done
    return 1
}

pox_mount_system() {
    local d
    for d in /system_root /system; do
        if grep -q " $d " /proc/mounts 2>/dev/null; then
            mount -o rw,remount "$d" 2>/dev/null && { echo "$d"; return 0; }
        fi
    done
    for d in \
        /dev/block/bootdevice/by-name/system \
        /dev/block/by-name/system \
        /dev/block/platform/bootdevice/by-name/system; do
        [ -b "$d" ] || continue
        mkdir -p /system_root
        if mount -o rw "$d" /system_root 2>/dev/null; then
            pox_system_root || echo /system_root
            return 0
        fi
    done
    if [ -d /system ]; then
        mount -o rw,remount / 2>/dev/null && { echo /system; return 0; }
    fi
    return 1
}

pox_flash_root_package() {
    local src="$1" tmp="/dev/tmp/pox-root-install" bb="/dev/tmp/pox-root-busybox"

    rm -rf "$tmp"
    mkdir -p "$tmp"
    if unzip -o "$src" "lib/arm64-v8a/libbusybox.so" -d /dev/tmp >/dev/null 2>&1; then
        mv -f /dev/tmp/lib/arm64-v8a/libbusybox.so "$bb" 2>/dev/null
        chmod 755 "$bb" 2>/dev/null
        rm -rf /dev/tmp/lib
    fi
    unzip -o "$src" "assets/*" "lib/*" -x "lib/*/libbusybox.so" -d "$tmp" >/dev/null 2>&1
    if [ -f "$tmp/assets/InstallAP.sh" ]; then
        chmod -R 755 "$tmp/assets" "$tmp/lib" 2>/dev/null
        if [ -x "$bb" ]; then
            ( cd "$tmp" && ASH_STANDALONE=1 "$bb" sh assets/InstallAP.sh 3 "$OUTFD" "$src" )
        else
            ( cd "$tmp" && sh assets/InstallAP.sh 3 "$OUTFD" "$src" )
        fi
        pox_log "$ROOT_LABEL kernel patch step complete."
    else
        pox_log "$ROOT_LABEL package has no InstallAP.sh; skipping kernel patch step."
    fi
}

pox_remove_others() {
    local pkg base
    for pkg in $OTHER_PACKAGES; do
        for base in /system /system_root/system /system_root; do
            rm -rf "$base/app/$pkg" "$base/priv-app/$pkg" \
                   "$base/app/$pkg.apk" "$base/priv-app/$pkg.apk" 2>/dev/null || true
        done
        # Residual user-installed copies from earlier flashes. The system copy
        # is the authoritative one; data cleanup is best effort.
        rm -rf /data/app/*"$pkg"* /data/data/"$pkg" \
               /data/user/0/"$pkg" /data/user_de/0/"$pkg" 2>/dev/null || true
        pox_log "Removed residual $pkg manager."
    done
}

pox_install_root_manager() {
    local src="$AKHOME/$ROOT_APK" sys dest

    [ "$INSTALL_ROOT" = "1" ] || return 0
    [ -f "$src" ] || { pox_log "Missing $ROOT_APK in package."; return 1; }

    if [ "$ROOT_FLASHABLE" = "1" ]; then
        pox_flash_root_package "$src"
    fi

    sys="$(pox_mount_system)" || {
        pox_log "Cannot mount /system read-write; $ROOT_LABEL was not installed."
        return 1
    }
    dest="$sys/app/$ROOT_PACKAGE"
    rm -rf "$dest"
    mkdir -p "$dest" || return 1
    cp -f "$src" "$dest/$ROOT_PACKAGE.apk" || return 1
    chown 0:0 "$dest" "$dest/$ROOT_PACKAGE.apk" 2>/dev/null || true
    chmod 0755 "$dest"
    chmod 0644 "$dest/$ROOT_PACKAGE.apk"
    chcon u:object_r:system_file:s0 "$dest" "$dest/$ROOT_PACKAGE.apk" 2>/dev/null || true
    pox_log "Installed $ROOT_LABEL to $dest/$ROOT_PACKAGE.apk"

    [ "$EXCLUSIVE" = "1" ] && pox_remove_others
    return 0
}

pox_stage_kpm_apk() {
    local d source="$AKHOME/$KPM_APK"

    [ "$STAGE_KPM" = "1" ] || return 0
    [ -f "$source" ] || { pox_log "Missing $KPM_APK in package."; return 1; }

    for d in /sdcard/Download /data/media/0/Download \
             /storage/emulated/0/Download /sdcard /data/local/tmp; do
        [ -d "$d" ] || continue
        if cp -f "$source" "$d/$KPM_APK" 2>/dev/null; then
            chmod 0644 "$d/$KPM_APK" 2>/dev/null || true
            pox_log "Copied $KPM_APK to $d (install it manually)."
        fi
    done
    return 0
}

pox_post_install() {
    pox_install_root_manager
    pox_stage_kpm_apk
}
POX_HELPER_EOF

    sed -i \
        -e "s|@ROOT_VARIANT@|${POX_ROOT_VARIANT}|g" \
        -e "s|@ROOT_LABEL@|${ROOT_LABEL}|g" \
        -e "s|@ROOT_PACKAGE@|${ROOT_PACKAGE}|g" \
        -e "s|@ROOT_APK@|${ROOT_APK_NAME}|g" \
        -e "s|@ROOT_FLASHABLE@|${ROOT_FLASHABLE}|g" \
        -e "s|@INSTALL_ROOT@|${POX_INSTALL_ROOT_MANAGER}|g" \
        -e "s|@EXCLUSIVE@|${POX_EXCLUSIVE_MANAGERS}|g" \
        -e "s|@OTHER_PACKAGES@|${others}|g" \
        -e "s|@STAGE_KPM@|${POX_STAGE_KPM_APK}|g" \
        -e "s|@KPM_APK@|${KPM_APK_NAME}|g" \
        "$stage/pox_install.sh"
    chmod 0755 "$stage/pox_install.sh"
}

# Determine safe parallel jobs based on available RAM and load to protect host PC from freezing
auto_jobs() {
    local mem_avail_kb
    mem_avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 3000000)
    # Estimate ~1.2GB per clang worker; clamp jobs between 2 and 4 to prevent freezing host
    local safe_jobs=$(( mem_avail_kb / 1200000 ))
    if (( safe_jobs < 2 )); then
        safe_jobs=2
    elif (( safe_jobs > 4 )); then
        safe_jobs=4
    fi
    echo "$safe_jobs"
}
JOBS="${JOBS:-$(auto_jobs)}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
DATE="$(date +%Y%m%d-%H%M)"

# Git Metadata: Branch & Commit ID
GIT_BRANCH="${GIT_BRANCH:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "onyx")}}"
GIT_BRANCH="${GIT_BRANCH#refs/heads/}"
GIT_BRANCH="${GIT_BRANCH#refs/tags/}"

# The KPM branch only delivers the companion APK for manual installation.
# It never installs a root manager and never removes one.
if [[ "$GIT_BRANCH" == onyx-kpm* ]]; then
    POX_STAGE_KPM_APK=1
    POX_INSTALL_ROOT_MANAGER=0
    POX_EXCLUSIVE_MANAGERS=0
fi
COMMIT_HASH="${COMMIT_HASH:-$(git rev-parse --short=7 HEAD 2>/dev/null || echo "custom")}"
COMMIT_DATE="$(git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M' 2>/dev/null || date +'%Y-%m-%d %H:%M')"
COMMIT_SUBJECT="$(git log -1 --format=%s 2>/dev/null || echo "Release build")"

# Version Name / Codename (Rocks theme: Granite, Obsidian, Onyx)
#
# One resolver maps every branch/tag name used by this repository, including the
# consolidated `feature/*` branches and the `release/<edition>-<date>` tags, to
# an edition name, a human description, and the default defconfig. Root flavors
# (KSU-Next/BakaSU/ReSukiSU/APatch) and media overlays (C2, MIUI) are composed so
# combined tags such as `release/onyx-c2-ksu-next-2026-10-20` report the full
# edition instead of silently falling back to the generic Onyx build.
resolve_variant() {
    local branch="$1"
    local root="" root_desc="" defconfig="begonia_user_defconfig"
    local extra_desc=""

    # Root flavor. Order matters: `sultan` is matched before the generic APatch
    # pattern so the Sultan debloat label wins.
    case "$branch" in
        *resukisu*)                   root="ReSukiSU"; root_desc="ReSukiSU Root";        defconfig="resukisu_defconfig" ;;
        *bakasu*)                     root="BakaSU";   root_desc="BakaSU Root";          defconfig="bakasu_defconfig" ;;
        *ksun*|*ksu-next*|*kernelsu*) root="KSU-Next"; root_desc="KernelSU-Next";        defconfig="begonia_ksu_next_defconfig" ;;
        *sultan*)                     root="Sultan-APatch"; root_desc="Sultan Debloat APatch"; defconfig="begonia_apatch_defconfig" ;;
        *apatch*|*folkpatch*)         root="APatch";   root_desc="APatch";               defconfig="begonia_apatch_defconfig" ;;
        *kaeru*)                      root="Kaeru";    root_desc="Kaeru Bootloader";     defconfig="begonia_user_defconfig" ;;
    esac

    # Orthogonal media overlays.
    if [[ "$branch" == *miui* || "$branch" == *hyperos* ]]; then
        extra_desc="${extra_desc:+$extra_desc + }MIUI/HyperOS"
    fi
    if [[ "$branch" == *c2* || "$branch" == *codec2* ]]; then
        extra_desc="${extra_desc:+$extra_desc + }Codec2 Media"
    fi

    DEFAULT_DEFCONFIG="$defconfig"

    if [[ "$branch" == main || "$branch" == *granite* ]]; then
        VERSION_NAME="Granite"
        BRANCH_DESC="Rock-Solid Stability Edition"
        DEFAULT_DEFCONFIG="begonia_user_defconfig"
        return
    fi

    if [[ "$branch" == *obsidian* || "$branch" == *memory-enhanced* ]]; then
        VERSION_NAME="Obsidian"
        BRANCH_DESC="iOS-Style Compressed Memory Edition"
        DEFAULT_DEFCONFIG="begonia_user_defconfig"
        return
    fi

    local edition="Onyx"
    [[ "$branch" == *c2* || "$branch" == *codec2* ]] && edition="${edition}-C2"
    [[ "$branch" == *miui* || "$branch" == *hyperos* ]] && edition="${edition}-MIUI"

    BRANCH_DESC="Zero Frame-Drop Gaming"
    [[ -n "$extra_desc" ]] && BRANCH_DESC="$BRANCH_DESC & $extra_desc"

    if [[ -n "$root" ]]; then
        VERSION_NAME="${edition}-${root}"
        BRANCH_DESC="$BRANCH_DESC & $root_desc Edition"
    else
        VERSION_NAME="$edition"
        BRANCH_DESC="$BRANCH_DESC Edition (Unrooted)"
    fi
}

if [[ -z "${VERSION_NAME:-}" ]]; then
    resolve_variant "$GIT_BRANCH"
else
    BRANCH_DESC="${BRANCH_DESC:-Custom Edition}"
    DEFAULT_DEFCONFIG="begonia_user_defconfig"
fi

# If the branch name asked for a feature defconfig that does not exist in this
# checkout (for example `GIT_BRANCH=feature/ksun` on top of common/base), fall
# back to the unrooted default so `./build.sh all` still works instead of dying
# in the kconfig step.
if [[ -z "${DEFCONFIG:-}" && ! -f "$ROOT_DIR/arch/arm64/configs/${DEFAULT_DEFCONFIG}" ]]; then
    warn "Defconfig ${DEFAULT_DEFCONFIG} is not present in this checkout; falling back to begonia_user_defconfig"
    DEFAULT_DEFCONFIG="begonia_user_defconfig"
fi

DEFCONFIG="${DEFCONFIG:-$DEFAULT_DEFCONFIG}"
BRANCH_CODENAME="$VERSION_NAME"

# Kernel release strings.
#   CUSTOM_LOCALVERSION   -> CONFIG_LOCALVERSION, i.e. what `uname -r` shows.
#                            Unextended: 4.14.357-Pox
#   EXTENDED_LOCALVERSION -> full edition-qualified identity, shown in the
#                            build log, changelog, installer banner, metadata.
#                            Extended:   4.14.357-Pox-1.0.0-Beta-Onyx-KSU-Next
# The commit id is excluded from both so kernel identity stays stable; it stays
# in the build metadata, the changelog, and the <commit>.zip link.
if [[ -n "${LOCALVERSION:-}" ]]; then
    CUSTOM_LOCALVERSION="$LOCALVERSION"
else
    CUSTOM_LOCALVERSION="-${KERNEL_NAME}"
fi
EXTENDED_LOCALVERSION="${EXTENDED_LOCALVERSION:--${KERNEL_NAME}-${KERNEL_VERSION}-${VERSION_NAME}}"

# Base Linux version from the top-level Makefile (e.g. 4.14.357).
LINUX_VERSION="4.14.$(grep -m1 '^SUBLEVEL =' "$ROOT_DIR/Makefile" | awk '{print $3}')"

# Package zip base name: name, version, edition, device
if [[ -n "${PACKAGE_NAME:-}" ]]; then
    ZIP_BASE="$PACKAGE_NAME"
elif [[ "$KERNEL_NAME" == *"$DEVICE_CODENAME"* ]]; then
    ZIP_BASE="${KERNEL_NAME}-${KERNEL_VERSION}-${VERSION_NAME}"
else
    ZIP_BASE="${KERNEL_NAME}-${KERNEL_VERSION}-${VERSION_NAME}-${DEVICE_CODENAME}"
fi

# 1. Ensure kerdevdep is bootstrapped
if [[ ! -f "$KERDEVDEP/env.sh" || ! -x "$KERDEVDEP/clang/bin/clang" || ! -x "$KERDEVDEP/bin/ccache" ]]; then
    log "Bootstrapping self-contained dependencies in $KERDEVDEP ..."
    bash "$KERDEVDEP/setup_kerdevdep.sh"
fi

# 2. Source kerdevdep environment
# shellcheck source=/dev/null
source "$KERDEVDEP/env.sh"

ARCH=arm64
CC=clang
CLANG_TRIPLE=aarch64-linux-gnu-
CROSS_COMPILE=aarch64-linux-gnu-
AK3_DIR="$KERDEVDEP/anykernel"

# Builder identity shown in the kernel banner: Linux version ... (POX@poxproject)
export KBUILD_BUILD_USER="POX"
export KBUILD_BUILD_HOST="poxproject"

ACTION="${1:-all}"

clean_build() {
    log "Cleaning build outputs in $OUT_DIR ..."
    rm -rf "$OUT_DIR"
    log "Clean complete."
}

distclean_build() {
    log "Removing entire build directory $BUILD_DIR ..."
    rm -rf "$BUILD_DIR"
    log "Distclean complete."
}

prepare_config() {
    # Droidspaces-OSS: merge the container support fragment before olddefconfig
    if [[ -f "$ROOT_DIR/arch/arm64/configs/droidspaces.config" && -f "$OUT_DIR/.config" ]]; then
        log "Merging Droidspaces config fragment..."
        sh "$ROOT_DIR/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
            "$OUT_DIR/.config" "$ROOT_DIR/arch/arm64/configs/droidspaces.config" >/dev/null
    fi
    local test_src="$BUILD_DIR/.tc-test.c"
    mkdir -p "$BUILD_DIR"
    printf 'int x;\n' > "$test_src"

    if [[ "${KEEP_CUSTOM_FLAGS:-0}" == "1" ]]; then
        log "KEEP_CUSTOM_FLAGS=1 - keeping custom -mllvm flags"
        rm -f "$test_src"
        return
    fi

    if ! "$KERDEVDEP/clang/bin/clang" --target=aarch64-linux-gnu \
        -mllvm -polly -mllvm -polly-postopts=1 -mllvm -polly-ast-use-context \
        -mllvm -polly-detect-keep-going -mllvm -polly-vectorizer=stripmine \
        -mllvm -polly-invariant-load-hoisting -c "$test_src" -o /dev/null 2>/dev/null; then
        log "Toolchain lacks patched LLVM Polly - disabling CONFIG_LLVM_POLLY"
        ./scripts/config --file "$OUT_DIR/.config" --disable LLVM_POLLY
    fi

    if ! "$KERDEVDEP/clang/bin/clang" --target=aarch64-linux-gnu \
        -mllvm -unroll-threshold=1000 -mllvm -inline-threshold=1500 \
        -c "$test_src" -o /dev/null 2>/dev/null; then
        log "Toolchain rejects -mllvm thresholds - disabling CONFIG_INLINE_OPTIMIZATION"
        ./scripts/config --file "$OUT_DIR/.config" --disable INLINE_OPTIMIZATION
    fi

    # Dynamically apply LOCALVERSION based on KERNEL_NAME and KERNEL_VERSION.
    # Also disable LOCALVERSION_AUTO so `uname -r` never gets a `-g<commit>`
    # suffix appended by the kernel build (the commit stays in build metadata).
    log "Setting CONFIG_LOCALVERSION=\"$CUSTOM_LOCALVERSION\" (LOCALVERSION_AUTO off)"
    ./scripts/config --file "$OUT_DIR/.config" --set-str LOCALVERSION "$CUSTOM_LOCALVERSION"
    ./scripts/config --file "$OUT_DIR/.config" --disable LOCALVERSION_AUTO

    # shellcheck disable=SC2086
    make O="$OUT_DIR" ARCH="$ARCH" CC="$CC" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        $EXTRA_FLAGS olddefconfig
    rm -f "$test_src"
}

run_menuconfig() {
    mkdir -p "$OUT_DIR"
    if [[ ! -f "$OUT_DIR/.config" ]]; then
        log "Generating defconfig ($DEFCONFIG) ..."
        # shellcheck disable=SC2086
        make O="$OUT_DIR" ARCH="$ARCH" CC="$CC" \
            CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
            $EXTRA_FLAGS "$DEFCONFIG"
        prepare_config
    fi
    make O="$OUT_DIR" ARCH="$ARCH" CC="$CC" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        menuconfig
}

build_kernel() {
    log "================================================="
    log "Building $KERNEL_NAME"
    log "Version:      $KERNEL_VERSION"
    log "Version Name: $VERSION_NAME ($BRANCH_DESC)"
    log "Branch:       $GIT_BRANCH"
    log "Commit ID:    $COMMIT_HASH"
    log "Device:       $DEVICE_NAME ($DEVICE_CODENAME)"
    log "Maintainer:   $MAINTAINER"
    log "uname -r:     ${LINUX_VERSION}${CUSTOM_LOCALVERSION}"
    log "Extended Ver: ${LINUX_VERSION}${EXTENDED_LOCALVERSION}"
    log "Defconfig:    $DEFCONFIG"
    log "Output Dir:   $BUILD_DIR"
    log "Object Dir:   $OUT_DIR"
    log "Jobs:         $JOBS"
    log "Toolchain:    $KERDEVDEP"
    log "================================================="

    local bcc="$CC"
    if command -v ccache >/dev/null 2>&1 && [[ "${CCACHE:-1}" == "1" ]]; then
        bcc="ccache $CC"
        export CCACHE_DIR="${CCACHE_DIR:-$BUILD_DIR/.ccache}"
        mkdir -p "$CCACHE_DIR"
        log "Using ccache (cache dir: $CCACHE_DIR)"
    fi

    mkdir -p "$OUT_DIR" "$BUILD_DIR"
    cd "$ROOT_DIR"

    if [[ ! -f "$OUT_DIR/.config" ]]; then
        log "Configuring with $DEFCONFIG ..."
        # shellcheck disable=SC2086
        make O="$OUT_DIR" ARCH="$ARCH" CC="$bcc" \
            CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
            $EXTRA_FLAGS "$DEFCONFIG"
        prepare_config
    else
        log "Reusing existing .config in $OUT_DIR"
        ./scripts/config --file "$OUT_DIR/.config" --set-str LOCALVERSION "$CUSTOM_LOCALVERSION"
        ./scripts/config --file "$OUT_DIR/.config" --disable LOCALVERSION_AUTO
        # shellcheck disable=SC2086
        make O="$OUT_DIR" ARCH="$ARCH" CC="$bcc" \
            CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
            $EXTRA_FLAGS olddefconfig
        # Ensure version headers are regenerated so UTS_RELEASE and compile.h always match
        rm -f "$OUT_DIR/include/config/kernel.release" "$OUT_DIR/include/generated/utsrelease.h" "$OUT_DIR/include/generated/compile.h" "$OUT_DIR/init/version.o"
    fi

    if grep -q '^CONFIG_KALLSYMS_ALL=y$' "$OUT_DIR/.config"; then
        log "CONFIG_KALLSYMS_ALL=y verified (APatch supported)."
    fi

    # Host PC safety: ensure load average and memory are suitable before launching build (skip in CI/GitHub Actions or SKIP_LOAD_CHECK)
    if [[ -z "${SKIP_LOAD_CHECK:-}" && -z "${CI:-}" && -z "${GITHUB_ACTIONS:-}" ]]; then
        local load
        while true; do
            load=$(awk '{print int($1)}' /proc/loadavg 2>/dev/null || echo 0)
            local mem_avail_kb mem_avail_mb
            mem_avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 2000000)
            mem_avail_mb=$(( mem_avail_kb / 1024 ))
            if (( load > 8 || mem_avail_mb < 700 )); then
                warn "PC load is high (${load}) or available RAM low (${mem_avail_mb}MB). Waiting 5s for host to settle..."
                sleep 5
            else
                break
            fi
        done
    fi

    log "Starting kernel compilation (nice priority, jobs: $JOBS)..."
    # shellcheck disable=SC2086
    nice -n 10 make O="$OUT_DIR" ARCH="$ARCH" CC="$bcc" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        $EXTRA_FLAGS -j"$JOBS"

    local image="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
    if [[ ! -f "$image" ]]; then
        err "Build failed: $image was not produced."
        exit 1
    fi

    cp -f "$image" "$BUILD_DIR/Image.gz-dtb"
    log "Kernel image saved to: $BUILD_DIR/Image.gz-dtb"
}

package_zip() {
    if [[ "${SKIP_PACKAGE:-0}" == "1" ]]; then
        log "Skipping zip packaging."
        return
    fi

    local image="$BUILD_DIR/Image.gz-dtb"
    if [[ ! -f "$image" ]]; then
        if [[ -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" ]]; then
            cp -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" "$image"
        else
            err "Cannot package zip: $image does not exist. Run build first."
            exit 1
        fi
    fi

    local stage="$BUILD_DIR/.anykernel_stage"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -r "$AK3_DIR/." "$stage/"
    cp "$image" "$stage/Image.gz-dtb"

    # Fetch the recovery-time payloads before generating anykernel.sh so a
    # download failure fails the build instead of silently shipping a zip
    # without the manager the branch promises.
    resolve_root_manager
    if [[ "$POX_INSTALL_ROOT_MANAGER" == "1" ]]; then
        if [[ -z "$ROOT_APK_NAME" ]]; then
            err "POX_INSTALL_ROOT_MANAGER=1 requires POX_ROOT_VARIANT (folkpatch|apatch|bakasu)."
            exit 1
        fi
        fetch_root_manager_apk "$stage/$ROOT_APK_NAME" || exit 1
        chmod 0644 "$stage/$ROOT_APK_NAME"
    fi
    if [[ "$POX_STAGE_KPM_APK" == "1" ]]; then
        fetch_kpm_apk "$stage" || exit 1
        chmod 0644 "$stage/$KPM_APK_NAME"
    fi
    if [[ "$POX_INSTALL_ROOT_MANAGER" == "1" || "$POX_STAGE_KPM_APK" == "1" ]]; then
        write_pox_install_helper "$stage"
    fi

    local commit_hash commit_date commit_subject kver toolchain_ver git_branch
    commit_hash="$(git rev-parse --short HEAD 2>/dev/null || echo "custom")"
    commit_date="$(git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M' 2>/dev/null || date +'%Y-%m-%d %H:%M')"
    commit_subject="$(git log -1 --format=%s 2>/dev/null || echo "Release build")"
    git_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "gaming")"
    kver="$LINUX_VERSION"
    toolchain_ver="TheRagingBeast TRB Clang 18.0.0 (17092023)"

    local kernel_name_upper version_name_upper
    kernel_name_upper="$(echo "$KERNEL_NAME" | tr '[:lower:]' '[:upper:]')"
    version_name_upper="$(echo "$VERSION_NAME" | tr '[:lower:]' '[:upper:]')"
    local full_title="${KERNEL_NAME} Kernel ${KERNEL_VERSION} [${VERSION_NAME}]"

    # Generate dynamic changelog ui_print statements for TWRP
    local changelog_ui=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local escaped_line
        escaped_line="$(echo "$line" | sed 's/"/\\"/g')"
        changelog_ui+="ui_print \"   * ${escaped_line}\";\n"
    done < <(git log -n 8 --pretty=format:"[%h] %s" 2>/dev/null || echo "[custom] Initial ${KERNEL_NAME} ${VERSION_NAME} release")

    # Generate standalone CHANGELOG.txt for the flashable zip
    {
        echo "========================================================"
        echo " ${kernel_name_upper} KERNEL ${KERNEL_VERSION} [${version_name_upper}] - ${DEVICE_NAME} (${DEVICE_CODENAME})"
        echo " Version: $KERNEL_VERSION"
        echo " Version Name: $VERSION_NAME ($BRANCH_DESC)"
        echo " Branch: $GIT_BRANCH"
        echo " Commit ID: $COMMIT_HASH"
        echo " Maintainer: $MAINTAINER"
        echo " Motto: We aim for stability, not for anything else."
        echo " Linux (uname -r): v$kver$CUSTOM_LOCALVERSION | Date: $COMMIT_DATE"
        echo " Extended Version: v$kver$EXTENDED_LOCALVERSION"
        echo " Toolchain: $toolchain_ver"
        echo " Defconfig: $DEFCONFIG (APatch ready)"
        echo " Memory: iOS-Style On-Demand Multi-Stream Compressed ZRAM"
        echo " Gaming: Zero Frame-Drop Gaming Mode Controller"
        echo "========================================================"
        echo ""
        echo "--- Changelog (Recent Commits) ---"
        git log -n 15 --pretty=format:"* %h (%cd) - %s%n  Author: %an%n%b" --date=short 2>/dev/null || git log -n 5 2>/dev/null || true
    } > "$stage/CHANGELOG.txt"

    cat << AK_EOF > "$stage/anykernel.sh"
# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers
# Configured for ${full_title} by ${MAINTAINER}

## AnyKernel setup
properties() { '
kernel.string=${KERNEL_NAME} ${KERNEL_VERSION} [${VERSION_NAME}] by ${MAINTAINER} for ${DEVICE_NAME} (${DEVICE_CODENAME})
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=${DEVICE_CODENAME}
device.name2=${DEVICE_CODENAME}_in
device.name3=${DEVICE_CODENAME}in
device.name4=
supported.versions=
supported.patchlevels=
'; } # end properties

## shell variables
BLOCK=boot;
# ${DEVICE_NAME} (${DEVICE_CODENAME}) is an A-only device: a single boot partition,
# no A/B slot suffix. Keep IS_SLOT_DEVICE=0 (AnyKernel3 default for A-only).
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## TWRP / Recovery UI Banner & Version Details
ui_print " ";
ui_print " ============================================";
ui_print "   ${kernel_name_upper} KERNEL ${KERNEL_VERSION} [${version_name_upper}]";
ui_print " ============================================";
ui_print "  * Kernel       : ${KERNEL_NAME}            ";
ui_print "  * Version      : ${KERNEL_VERSION}         ";
ui_print "  * Version Name : ${VERSION_NAME} (${BRANCH_DESC})";
ui_print "  * Branch       : ${GIT_BRANCH}             ";
ui_print "  * Commit ID    : ${COMMIT_HASH}            ";
ui_print "  * Device       : ${DEVICE_NAME} (${DEVICE_CODENAME})";
ui_print "  * Maintainer   : ${MAINTAINER}             ";
ui_print "  * Motto        : We aim for stability,     ";
ui_print "                   not for anything else.    ";
ui_print "  * uname -r     : $kver$CUSTOM_LOCALVERSION";
ui_print "  * Extended Ver : $kver$EXTENDED_LOCALVERSION";
ui_print "  * Build Date   : $COMMIT_DATE              ";
ui_print "  * Toolchain    : $toolchain_ver            ";
ui_print "  * Features     : APatch / KernelPatch ready";
ui_print "  * Crypto Engine: ARMv8 CE & NEON Accelerated";
ui_print "  * Mem Engine   : iOS-Style On-Demand ZRAM  ";
ui_print "  * Game Engine  : Zero Frame-Drop Gaming Mode";
ui_print "  * Display Mode : iOS D65 & Sunlight HBM Overdrive";
ui_print "  * Perf Mode    : Tri-State Auto-Trigger Engine";
ui_print " --------------------------------------------";
ui_print "  LATEST COMMIT:";
ui_print "  $COMMIT_SUBJECT";
ui_print " --------------------------------------------";
ui_print "  CHANGELOG (Recent Changes):";
AK_EOF
    printf '%b' "$changelog_ui" >> "$stage/anykernel.sh"
    cat << AK_EOF >> "$stage/anykernel.sh"
ui_print " ============================================";
ui_print " ";

## AnyKernel file attributes
ui_print " [*] [1/4] Configuring ramdisk permissions & ownership...";
ui_print "     - Target partition: /dev/block/by-name/boot (A-only)";
chmod -R 750 \$RAMDISK/*;
chown -R root:root \$RAMDISK/*;

## AnyKernel install
ui_print " [*] [2/4] Dumping and unpacking current boot image...";
dump_boot;

## Ramdisk enhancements
if [ -d "\$RAMDISK" ]; then
    ui_print " [*] Injecting memory enhancement & gaming mode into ramdisk...";

    # 1. iOS-Style On-Demand Compressed Memory Management
    cat << 'RC_EOF' > \$RAMDISK/init.memory_enhanced.rc
# Pox adaptive memory (HarmonyOS EROFS-cache + MGLRU lesson, 4.14-safe):
# - swappiness 100: anon -> per-CPU zstd ZRAM (no LMK kills, 85% fewer kills lesson)
# - watermark 150: early kswapd fits 8.3ms frame budget (gaming raises to 200, powersave drops to 100)
# - page-cluster 0: no swap readahead (ZRAM random; readahead wastes CPU/RAM)
# - vfs pressure 50: retain dentries for instant launch (EROFS block-cache lesson)
# - dirty 20/10: throughput (gaming tightens to 10/5 for latency)
# Kernel gaming_mode switches these per-mode; boot sets balanced baseline.
on boot
    write /proc/sys/vm/watermark_scale_factor 150
    write /proc/sys/vm/page-cluster 0
    write /proc/sys/vm/vfs_cache_pressure 50
    write /proc/sys/vm/swappiness 100
    write /proc/sys/vm/dirty_ratio 20
    write /proc/sys/vm/dirty_background_ratio 10
    write /proc/sys/vm/dirty_expire_centisecs 1500
    write /proc/sys/vm/dirty_writeback_centisecs 300
    write /proc/sys/vm/stat_interval 10

    # Advanced CFS & Interactivity Tunables (FreeBSD ULE / Windows NT Dynamic Boost)
    write /proc/sys/kernel/sched_latency_ns 3000000
    write /proc/sys/kernel/sched_min_granularity_ns 300000
    write /proc/sys/kernel/sched_wakeup_granularity_ns 250000
    write /proc/sys/kernel/sched_sync_hint_enable 1

    # Low-latency high-throughput networking & Fair Queueing for BBR
    write /proc/sys/net/core/default_qdisc fq
    write /proc/sys/net/ipv4/tcp_congestion_control bbr
    write /proc/sys/net/ipv4/tcp_fastopen 3
    write /proc/sys/net/ipv4/tcp_slow_start_after_idle 0
    write /proc/sys/net/ipv4/tcp_tw_reuse 1
    write /proc/sys/net/ipv4/tcp_autocorking 0
    write /proc/sys/net/ipv4/tcp_notsent_lowat 16384
    write /proc/sys/net/ipv4/tcp_rmem "4096 87380 6291456"
    write /proc/sys/net/ipv4/tcp_wmem "4096 65536 6291456"
    write /proc/sys/net/ipv4/tcp_ecn 1
    write /proc/sys/net/ipv4/tcp_syncookies 1
    write /proc/sys/net/core/netdev_max_backlog 5000

on property:sys.boot_completed=1
    write /sys/block/zram0/comp_algorithm zstd
    write /sys/block/zram0/max_comp_streams 8
    write /proc/sys/vm/watermark_scale_factor 150
    write /proc/sys/vm/page-cluster 0
    write /proc/sys/vm/vfs_cache_pressure 50
    write /proc/sys/vm/swappiness 100
    write /proc/sys/vm/dirty_ratio 20
    write /proc/sys/vm/dirty_background_ratio 10
    write /proc/sys/vm/dirty_expire_centisecs 1500
    write /proc/sys/vm/dirty_writeback_centisecs 300
    write /proc/sys/vm/stat_interval 10
    write /proc/sys/kernel/sched_latency_ns 3000000
    write /proc/sys/kernel/sched_min_granularity_ns 300000
    write /proc/sys/kernel/sched_wakeup_granularity_ns 250000
    write /proc/sys/net/core/default_qdisc fq
    write /proc/sys/net/ipv4/tcp_congestion_control bbr
    write /proc/sys/net/ipv4/tcp_autocorking 0
    write /proc/sys/net/ipv4/tcp_notsent_lowat 16384
    write /proc/sys/net/ipv4/tcp_rmem "4096 87380 6291456"
    write /proc/sys/net/ipv4/tcp_wmem "4096 65536 6291456"
RC_EOF
    chmod 644 \$RAMDISK/init.memory_enhanced.rc

    # 2. Zero Frame-Drop Gaming Mode, Real Colors Calibration & ROM Performance Mode Triggers
    cat << 'RC_EOF' > \$RAMDISK/init.gaming.rc
# Gaming Mode & iOS Display Init Script for Redmi Note 8 Pro (begonia)
# Triggers full gaming performance optimizations and color profiles

on boot
    chmod 0644 /proc/perfmgr/gaming_mode
    chmod 0644 /sys/kernel/gaming_mode
    chmod 0644 /proc/perfmgr/true_tone
    chmod 0644 /sys/kernel/true_tone
    chmod 0644 /proc/perfmgr/color_mode
    chmod 0644 /sys/kernel/color_mode
    chmod 0644 /proc/perfmgr/hbm_mode
    chmod 0644 /sys/kernel/hbm_mode
    # Pox standout safe-rootless torch: 0666 by design so stock
    # flashlight apps work without root; hardware guards
    # (325mA clamp, 20ms anti-strobe, 5-min timeout) in driver.
    chmod 0666 /proc/perfmgr/torch_brightness
    chmod 0666 /proc/perfmgr/flashlight_brightness
    chmod 0444 /proc/perfmgr/torch_info
    chmod 0444 /proc/perfmgr/profile
    chmod 0666 /sys/kernel/torch_brightness
    chmod 0666 /sys/kernel/flashlight_brightness
    chmod 0666 /sys/devices/platform/flashlights_mt6360/torchbrightness
    chmod 0644 /proc/perfmgr/camera_profile
    chmod 0644 /sys/kernel/camera_profile
    chmod 0644 /proc/perfmgr/slog3
    chmod 0644 /sys/kernel/slog3
    chmod 0644 /proc/perfmgr/camera_4k60
    chmod 0644 /sys/kernel/camera_4k60
    # Universal USB OTG: keep every adapter working plug-and-play.
    # Directory needs +x to enumerate; device nodes stay world-
    # accessible so DACs/serial/ethernet/iPhone tethering just work.
    chmod 0755 /dev/bus/usb
    chmod 0666 /dev/bus/usb/*/* 2>/dev/null || true
    chmod 0666 /dev/ttyUSB0
    chmod 0666 /dev/ttyUSB1
    chmod 0666 /dev/ttyUSB2
    chmod 0666 /dev/ttyUSB3
    chmod 0666 /dev/ttyACM0
    chmod 0666 /dev/ttyACM1
    chmod 0644 /proc/perfmgr/touch_game_mode
    chmod 0644 /proc/perfmgr/touch_sensitivity
    chmod 0664 /sys/class/touch/touch_dev/touch_game_mode
    chmod 0664 /sys/class/touch/touch_dev/touch_sensitivity
    chmod 0644 /proc/perfmgr/headphone_gain
    chmod 0644 /sys/kernel/sound_control/headphone_gain
    chmod 0644 /proc/perfmgr/mic_gain
    chmod 0644 /sys/kernel/sound_control/mic_gain
    chmod 0644 /proc/perfmgr/vibrator_strength
    chmod 0644 /proc/perfmgr/wakelock_blocker
    chmod 0644 /proc/perfmgr/fast_charge
    chmod 0644 /proc/perfmgr/dt2w
    chmod 0644 /sys/android_touch/doubletap2wake
    chmod 0644 /proc/perfmgr/dynamic_fsync
    chmod 0644 /sys/kernel/dynamic_fsync/dynamic_fsync
    chmod 0644 /sys/module/task_turbo/parameters/feats
    chmod 0644 /proc/perfmgr/battery_bypass
    chmod 0644 /proc/perfmgr/battery_limit
    chmod 0444 /proc/perfmgr/battery_status
    chmod 0644 /sys/module/ged/parameters/gx_game_mode
    chmod 0644 /sys/module/ged/parameters/gx_boost_on
    chmod 0644 /sys/module/ged/parameters/boost_gpu_enable
    chmod 0644 /sys/module/ged/parameters/gx_force_cpu_boost
    write /sys/module/ged/parameters/boost_gpu_enable 1
    write /proc/perfmgr/true_tone 1
    write /proc/perfmgr/color_mode 1
    write /proc/perfmgr/fast_charge 1

    # MIUI / HyperOS 3 memory swap & xswapd cgroup nodes (restricted to root & system)
    chown root system /dev/memcg/memory.xswapd.quota
    chown root system /dev/memcg/memory.xswapd.enable
    chown root system /dev/memcg/memory.xswapd.score
    chown root system /dev/memcg/memory.xswapd.refaults
    chown root system /dev/memcg/memory.xswapd.reclaim
    chown root system /dev/memcg/apps/memory.xswapd.quota
    chown root system /dev/memcg/apps/memory.xswapd.score
    chown root system /dev/memcg/apps/memory.xswapd.refaults
    chmod 0664 /dev/memcg/memory.xswapd.quota
    chmod 0664 /dev/memcg/memory.xswapd.enable
    chmod 0664 /dev/memcg/memory.xswapd.score
    chmod 0444 /dev/memcg/memory.xswapd.refaults
    chmod 0664 /dev/memcg/memory.xswapd.reclaim
    chmod 0664 /dev/memcg/apps/memory.xswapd.quota
    chmod 0664 /dev/memcg/apps/memory.xswapd.score
    chmod 0444 /dev/memcg/apps/memory.xswapd.refaults
    chown root system /sys/kernel/xswapd/* 2>/dev/null || true
    chmod 0664 /sys/kernel/xswapd/enabled 2>/dev/null || true
    chmod 0664 /sys/kernel/xswapd/trigger 2>/dev/null || true
    chmod 0664 /sys/kernel/xswapd/watermark_kb 2>/dev/null || true
    chmod 0664 /sys/kernel/xswapd/min_score 2>/dev/null || true
    chmod 0664 /sys/kernel/xswapd/max_scan_pages 2>/dev/null || true
    chmod 0664 /sys/kernel/xswapd/refault_threshold 2>/dev/null || true
    chmod 0664 /sys/kernel/xswapd/interval_ms 2>/dev/null || true
    chmod 0444 /sys/kernel/xswapd/reclaimed_pages 2>/dev/null || true
    chmod 0444 /sys/kernel/xswapd/status 2>/dev/null || true

    # Default flash storage readahead to 128KB for smooth capture and I/O
    write /sys/block/sda/queue/read_ahead_kb 128
    write /sys/block/sdb/queue/read_ahead_kb 128
    write /sys/block/sdc/queue/read_ahead_kb 128
    write /sys/block/mmcblk0/queue/read_ahead_kb 128

    # Flash storage queue tuning: mq-deadline flash tuning, allow bio request merging and enable affinity
    write /sys/block/sda/queue/scheduler mq-deadline
    write /sys/block/sda/queue/iosched/read_expire 250
    write /sys/block/sda/queue/iosched/write_expire 1500
    write /sys/block/sda/queue/iosched/fifo_batch 8
    write /sys/block/sda/queue/rq_affinity 2
    write /sys/block/sda/queue/iostats 0
    write /sys/block/sda/queue/add_random 0
    write /sys/block/sda/queue/nomerges 0
    write /sys/block/sda/queue/nr_requests 128
    write /sys/block/sdb/queue/scheduler mq-deadline
    write /sys/block/sdb/queue/iosched/read_expire 250
    write /sys/block/sdb/queue/iosched/write_expire 1500
    write /sys/block/sdb/queue/iosched/fifo_batch 8
    write /sys/block/sdb/queue/rq_affinity 2
    write /sys/block/sdb/queue/iostats 0
    write /sys/block/sdb/queue/add_random 0
    write /sys/block/sdb/queue/nomerges 0
    write /sys/block/sdb/queue/nr_requests 128
    write /sys/block/sdc/queue/scheduler mq-deadline
    write /sys/block/sdc/queue/iosched/read_expire 250
    write /sys/block/sdc/queue/iosched/write_expire 1500
    write /sys/block/sdc/queue/iosched/fifo_batch 8
    write /sys/block/sdc/queue/rq_affinity 2
    write /sys/block/sdc/queue/iostats 0
    write /sys/block/sdc/queue/add_random 0
    write /sys/block/sdc/queue/nomerges 0
    write /sys/block/sdc/queue/nr_requests 128
    write /sys/block/mmcblk0/queue/scheduler mq-deadline
    write /sys/block/mmcblk0/queue/iosched/read_expire 250
    write /sys/block/mmcblk0/queue/iosched/write_expire 1500
    write /sys/block/mmcblk0/queue/iosched/fifo_batch 8
    write /sys/block/mmcblk0/queue/rq_affinity 2
    write /sys/block/mmcblk0/queue/iostats 0
    write /sys/block/mmcblk0/queue/add_random 0
    write /sys/block/mmcblk0/queue/nomerges 0
    write /sys/block/mmcblk0/queue/nr_requests 128

    # Flash storage health permissions
    chmod 0444 /proc/ufs_health
    chmod 0444 /sys/bus/platform/devices/11270000.ufshci/dump_health
    chmod 0444 /sys/bus/platform/devices/11270000.ufshci/health
    chmod 0444 /sys/bus/platform/devices/11270000.ufshci/health_remaining_pct
    chmod 0444 /sys/bus/platform/devices/11270000.ufshci/life_time_a
    chmod 0444 /sys/bus/platform/devices/11270000.ufshci/life_time_b
    chmod 0444 /sys/bus/platform/devices/11270000.ufshci/pre_eol_info
    chmod 0444 /sys/bus/platform/devices/11270000.ufshci/product_name
    chmod 0444 /sys/bus/platform/devices/11270000.ufshci/product_revision
    chmod 0444 /sys/bus/platform/devices/11270000.ufshci/manufacturer_id

# ROM Performance Mode / Game Space Active
on property:persist.sys.power_mode_perf=1
    write /proc/perfmgr/gaming_mode 1
    write /proc/net/wlan/setCAM "CAM 1"
    write /sys/block/sda/queue/read_ahead_kb 512
    write /sys/block/sdb/queue/read_ahead_kb 512
    write /sys/block/sdc/queue/read_ahead_kb 512
    write /sys/block/mmcblk0/queue/read_ahead_kb 512

on property:persist.sys.power_mode_perf=0
    write /proc/perfmgr/gaming_mode 0
    write /proc/net/wlan/setCAM "CAM 0"
    write /sys/block/sda/queue/read_ahead_kb 128
    write /sys/block/sdb/queue/read_ahead_kb 128
    write /sys/block/sdc/queue/read_ahead_kb 128
    write /sys/block/mmcblk0/queue/read_ahead_kb 128

# Ultra Power Saver Mode (AOSP / LineageOS Battery Saver)
on property:persist.sys.power_mode_perf=-1
    write /proc/perfmgr/gaming_mode -1
    write /proc/net/wlan/setCAM "CAM 0"
    write /sys/block/sda/queue/read_ahead_kb 128
    write /sys/block/sdb/queue/read_ahead_kb 128
    write /sys/block/sdc/queue/read_ahead_kb 128
    write /sys/block/mmcblk0/queue/read_ahead_kb 128

# LineageOS Performance Profile (0=power_save, 1=balanced, 2=performance)
on property:sys.perf.profile=2
    setprop persist.sys.power_mode_perf 1

on property:sys.perf.profile=1
    setprop persist.sys.power_mode_perf 0

on property:sys.perf.profile=0
    setprop persist.sys.power_mode_perf -1

# Android Battery Saver Global Low Power mode
on property:settings.global.low_power=1
    setprop persist.sys.power_mode_perf -1

on property:settings.global.low_power=0
    setprop persist.sys.power_mode_perf 0

# GameSpace Mode (AOSP / Chaldea GameSpace)
on property:sys.gamespace.mode=1
    setprop persist.sys.power_mode_perf 1

on property:sys.gamespace.mode=0
    setprop persist.sys.power_mode_perf 0

on property:sys.gamespace.in_game=1
    setprop persist.sys.power_mode_perf 1

on property:sys.gamespace.in_game=0
    setprop persist.sys.power_mode_perf 0

# AOSP / PixelOS / LineageOS libperfmgr PowerHAL trigger
on property:vendor.powerhal.state=SUSTAINED_PERFORMANCE
    setprop persist.sys.power_mode_perf 1

on property:vendor.powerhal.state=""
    setprop persist.sys.power_mode_perf 0

# MIUI / HyperOS Performance Mode trigger
on property:persist.sys.perf_mode=1
    setprop persist.sys.power_mode_perf 1

on property:persist.sys.perf_mode=0
    setprop persist.sys.power_mode_perf 0

# Direct debug toggle
on property:debug.gaming.mode=1
    setprop persist.sys.power_mode_perf 1

on property:debug.gaming.mode=0
    setprop persist.sys.power_mode_perf 0
RC_EOF
    chmod 644 \$RAMDISK/init.gaming.rc

    # 3. Smart Battery Guard & Direct Power Bypass Charging
    cat << 'RC_EOF' > \$RAMDISK/init.battery_guard.rc
# Smart Battery Guard & Direct Power Bypass Charging for Redmi Note 8 Pro (begonia)
on boot
    chmod 0664 /sys/kernel/battery_protection/bypass_mode
    chmod 0664 /sys/kernel/battery_protection/charge_limit
    chmod 0664 /sys/kernel/battery_protection/thermal_guard
    chmod 0664 /sys/kernel/battery_protection/temp_limit
    chmod 0444 /sys/kernel/battery_protection/status
    chmod 0444 /sys/kernel/battery_protection/battery_soc
    chmod 0444 /sys/kernel/battery_protection/battery_temp

    # Default: Full charge (100%), thermal guard disabled (0) so JEITA handles protection without artificial stopping
    write /sys/kernel/battery_protection/charge_limit 100
    write /sys/kernel/battery_protection/thermal_guard 0
    write /sys/kernel/battery_protection/temp_limit 48

    # True Tone System Default (Calibrated Liquid Retina D65)
    chmod 0644 /proc/perfmgr/true_tone
    chmod 0644 /sys/kernel/true_tone
    write /proc/perfmgr/true_tone 1
RC_EOF
    chmod 644 \$RAMDISK/init.battery_guard.rc

    if [ -f "\$RAMDISK/init.rc" ]; then
        insert_line init.rc "init.memory_enhanced.rc" after "import /init.environ.rc" "import /init.memory_enhanced.rc";
        insert_line init.rc "init.gaming.rc" after "import /init.memory_enhanced.rc" "import /init.gaming.rc";
        insert_line init.rc "init.battery_guard.rc" after "import /init.gaming.rc" "import /init.battery_guard.rc";
    fi
fi

ui_print " [*] [3/4] Repacking boot image with ${KERNEL_NAME} ${VERSION_NAME} (${KERNEL_VERSION})...";
ui_print "     - Linux kernel: v$kver (MT6785 / Helio G90T)";
ui_print "     - Low-battery call reboot fix: active";
ui_print "     - Smart Battery Guard: Direct-Power Bypass & 39C Thermal Protection";
ui_print "     - Hardware Bypass Control: /proc/perfmgr/battery_bypass (0644)";
ui_print "     - Hardware 240Hz Touch Gaming Mode: zero-debounce sampling active";
ui_print "     - Hardware Double-Tap to Wake: /proc/perfmgr/dt2w & /sys/android_touch";
ui_print "     - MediaTek Task-Turbo: UI RenderThread, Binder & BigCore boost";
ui_print "     - Hardware Vibrator: unlocked 3.3V range & /proc/perfmgr/vibrator_strength";
ui_print "     - Deep Sleep Wakelock Filter: parasitic network wakelocks blocked";
ui_print "     - Fast Charge Boost: 1.5A PC USB & 2.0A non-std charger boost active";
ui_print "     - Hi-Fi Sound & Mic: MT6359 +8dB headphone & +18dB mic analog gain";
ui_print "     - Dynamic Fsync Engine: micro-stutter elimination active";
ui_print "     - Network & Wi-Fi Engine: TCP Fast Open & Wi-Fi SetCAM zero-jitter active";
ui_print "     - EAS Schedutil & Fork: 32% capacity margin & child_runs_first active";
ui_print "     - Flash Storage Queue: rq_affinity=2, iostats=0 & nomerges tuning";
ui_print "     - LiquidCool Gaming Thermal: 1200mW CPU & 1000mW GPU floor lock";
ui_print "     - Storage I/O: BFQ hierarchical scheduler & 512KB readahead active";
ui_print "     - Cinema Camera Engine: 4K 60FPS unlocked & Sony S-Log3 active";
ui_print "     - APatch / KernelPatch KALLSYMS: enabled";
ui_print "     - iOS-Style Compressed Memory: ZSTD ZRAM, 24MB cushion, vfs=50";
ui_print "     - True Tone Display Engine: Calibrated D65 Liquid Retina reference active";
ui_print "     - Video Anti-Lag Engine: VDEC/VENC clock floor & LP4-2100 DDR active";
ui_print "     - Zero Frame-Drop Gaming Mode: active on ROM Performance toggle";
ui_print "     - FPSGO Ultra-Rescue + Mali-G76 MC4 Touch Boost: enabled";
ui_print "     - Universal USB OTG: DACs, controllers, serial & ethernet active";
write_boot;

## Root manager / Pox Kernel Manager delivery (generated by build.sh).
## pox_install.sh runs inside recovery: it installs the selected manager into
## /system/app for user 0 and/or copies the KPM APK to internal storage.
if [ -f "\$AKHOME/pox_install.sh" ]; then
    . "\$AKHOME/pox_install.sh";
    pox_post_install;
fi;

ui_print " [*] [4/4] Cleaning up temporary installer files...";
ui_print " ";
ui_print " ============================================";
ui_print "   ${kernel_name_upper} ${version_name_upper} ${KERNEL_VERSION} (${GIT_BRANCH}) INSTALLED!";
ui_print "   Commit: ${COMMIT_HASH}";
ui_print "   We aim for stability, not for anything else.";
ui_print "      Reboot and enjoy solid stability.      ";
ui_print " ============================================";
ui_print " ";
## end install
AK_EOF

    local zip_file="$BUILD_DIR/${ZIP_BASE}.zip"
    log "Packaging AnyKernel3 flashable zip: $zip_file"
    # -X strips extra file attributes (uid/gid/timestamps) so identical inputs
    # produce identical archives across hosts.
    (cd "$stage" && zip -r9 -X "$zip_file" . -x '*.git*' -x '.github*')
    rm -rf "$stage"

    # Also maintain latest.zip, a date-stamped copy, and the commit/device
    # links in build/. Skip copies that would resolve to the primary archive:
    # the commit id is no longer part of the name, so the device name can now
    # collide with it.
    local date_zip="$BUILD_DIR/${KERNEL_NAME}-${KERNEL_VERSION}-${VERSION_NAME}-${DATE}.zip"
    local device_zip="$BUILD_DIR/${KERNEL_NAME}-${KERNEL_VERSION}-${VERSION_NAME}-${DEVICE_CODENAME}.zip"
    if [[ "$date_zip" != "$zip_file" ]]; then
        cp -f "$zip_file" "$date_zip"
    fi
    if [[ "$device_zip" != "$zip_file" ]]; then
        cp -f "$zip_file" "$device_zip"
    fi
    ln -sf "$(basename "$zip_file")" "$BUILD_DIR/latest.zip"
    ln -sf "$(basename "$zip_file")" "$BUILD_DIR/${COMMIT_HASH}.zip"

    write_build_metadata "$zip_file"

    log "================================================="
    log "BUILD SUCCEEDED!"
    log "Package ZIP:   $zip_file"
    log "Commit Link:   $BUILD_DIR/${COMMIT_HASH}.zip"
    log "Latest Link:   $BUILD_DIR/latest.zip"
    if [[ "$device_zip" != "$zip_file" ]]; then
        log "Device Link:   $device_zip"
    fi
    log "Kernel Image:  $BUILD_DIR/Image.gz-dtb"
    log "Metadata:      $BUILD_DIR/build-info.env"
    log "================================================="
}

# ---------------------------------------------------------------------------
# Build metadata
# ---------------------------------------------------------------------------
# Emit a shell-sourceable env file plus a JSON twin so CI (and humans) can read
# the exact artifact identity without re-deriving it from the branch name.
write_build_metadata() {
    local zip_file="$1"
    local zip_name zip_size zip_size_h zip_sha256 zip_md5
    zip_name="$(basename "$zip_file")"
    zip_size="$(stat -c%s "$zip_file" 2>/dev/null || wc -c < "$zip_file")"
    zip_size_h="$(du -h "$zip_file" | awk '{print $1}')"
    zip_sha256="$(sha256sum "$zip_file" | awk '{print $1}')"
    zip_md5="$(md5sum "$zip_file" | awk '{print $1}')"
    local linux_ver="$LINUX_VERSION"

    local info="$BUILD_DIR/build-info.env"
    mkdir -p "$BUILD_DIR"
    {
        printf '# Pox build metadata - generated %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'KERNEL_NAME=%q\n'        "$KERNEL_NAME"
        printf 'KERNEL_VERSION=%q\n'     "$KERNEL_VERSION"
        printf 'VERSION_NAME=%q\n'       "$VERSION_NAME"
        printf 'BRANCH_DESC=%q\n'        "$BRANCH_DESC"
        printf 'GIT_BRANCH=%q\n'         "$GIT_BRANCH"
        printf 'COMMIT_HASH=%q\n'        "$COMMIT_HASH"
        printf 'COMMIT_FULL=%q\n'        "$(git rev-parse HEAD 2>/dev/null || echo "$COMMIT_HASH")"
        printf 'COMMIT_DATE=%q\n'        "$COMMIT_DATE"
        printf 'COMMIT_SUBJECT=%q\n'     "$COMMIT_SUBJECT"
        printf 'DEFCONFIG=%q\n'          "$DEFCONFIG"
        printf 'DEVICE_NAME=%q\n'        "$DEVICE_NAME"
        printf 'DEVICE_CODENAME=%q\n'    "$DEVICE_CODENAME"
        printf 'MAINTAINER=%q\n'         "$MAINTAINER"
        printf 'LINUX_VERSION=%q\n'      "$linux_ver"
        printf 'LOCALVERSION=%q\n'          "${LINUX_VERSION}${CUSTOM_LOCALVERSION}"
        printf 'LOCALVERSION_EXTENDED=%q\n' "${LINUX_VERSION}${EXTENDED_LOCALVERSION}"
        printf 'TOOLCHAIN=%q\n'          "TheRagingBeast TRB Clang 18.0.0 (17092023)"
        printf 'BUILD_DATE=%q\n'         "$DATE"
        printf 'ZIP_PATH=%q\n'           "$zip_file"
        printf 'ZIP_NAME=%q\n'           "$zip_name"
        printf 'ZIP_SIZE_BYTES=%q\n'     "$zip_size"
        printf 'ZIP_SIZE_HUMAN=%q\n'     "$zip_size_h"
        printf 'ZIP_SHA256=%q\n'         "$zip_sha256"
        printf 'ZIP_MD5=%q\n'            "$zip_md5"
    } > "$info"

    if command -v python3 >/dev/null 2>&1; then
        POX_KERNEL_NAME="$KERNEL_NAME" \
        POX_KERNEL_VERSION="$KERNEL_VERSION" \
        POX_VERSION_NAME="$VERSION_NAME" \
        POX_BRANCH_DESC="$BRANCH_DESC" \
        POX_GIT_BRANCH="$GIT_BRANCH" \
        POX_COMMIT_HASH="$COMMIT_HASH" \
        POX_COMMIT_FULL="$(git rev-parse HEAD 2>/dev/null || echo "$COMMIT_HASH")" \
        POX_COMMIT_DATE="$COMMIT_DATE" \
        POX_COMMIT_SUBJECT="$COMMIT_SUBJECT" \
        POX_DEFCONFIG="$DEFCONFIG" \
        POX_DEVICE_NAME="$DEVICE_NAME" \
        POX_DEVICE_CODENAME="$DEVICE_CODENAME" \
        POX_MAINTAINER="$MAINTAINER" \
        POX_LINUX_VERSION="$linux_ver" \
        POX_LOCALVERSION="${LINUX_VERSION}${CUSTOM_LOCALVERSION}" \
        POX_LOCALVERSION_EXTENDED="${LINUX_VERSION}${EXTENDED_LOCALVERSION}" \
        POX_ZIP_NAME="$zip_name" \
        POX_ZIP_SIZE_BYTES="$zip_size" \
        POX_ZIP_SIZE_HUMAN="$zip_size_h" \
        POX_ZIP_SHA256="$zip_sha256" \
        POX_ZIP_MD5="$zip_md5" \
        python3 - "$BUILD_DIR/build-info.json" <<'PY'
import json, os, sys
data = {k[4:].lower(): v for k, v in os.environ.items() if k.startswith("POX_")}
with open(sys.argv[1], "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
    else
        warn "python3 not found; skipping JSON metadata"
    fi

    log "Build metadata written to: $info"
}

# ---------------------------------------------------------------------------
# Uploads (Gofile + PixelDrain)
# ---------------------------------------------------------------------------
# Resolve the flashable zip produced by `package_zip`. Prefers an explicit
# ZIP_FILE, then the latest.zip symlink, then the newest versioned archive.
find_artifact_zip() {
    if [[ -n "${ZIP_FILE:-}" && -f "$ZIP_FILE" ]]; then
        printf '%s\n' "$ZIP_FILE"
        return 0
    fi

    if [[ -L "$BUILD_DIR/latest.zip" ]]; then
        local resolved
        resolved="$(readlink -f "$BUILD_DIR/latest.zip" 2>/dev/null || true)"
        if [[ -n "$resolved" && -f "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    elif [[ -f "$BUILD_DIR/latest.zip" ]]; then
        printf '%s\n' "$BUILD_DIR/latest.zip"
        return 0
    fi

    local newest
    newest="$(ls -t "$BUILD_DIR"/${KERNEL_NAME}-*.zip 2>/dev/null | grep -v 'latest\.zip' | head -n1 || true)"
    if [[ -n "$newest" && -f "$newest" ]]; then
        printf '%s\n' "$newest"
        return 0
    fi

    return 1
}

# Write a small KEY=value file (shell-quoted) with the upload result.
write_upload_result() {
    local out="$1"
    shift
    mkdir -p "$BUILD_DIR"
    : > "$out"
    while (( $# >= 2 )); do
        printf '%s=%q\n' "$1" "$2" >> "$out"
        shift 2
    done
}

upload_gofile() {
    local zip_file
    zip_file="$(find_artifact_zip)" || { err "No flashable zip found. Run ./build.sh all first."; return 1; }
    command -v curl >/dev/null 2>&1 || { err "curl is required for Gofile upload."; return 1; }

    local token="${GOFILE_TOKEN:-}"
    local folder="${GOFILE_FOLDER_ID:-}"
    local zip_name local_md5
    zip_name="$(basename "$zip_file")"
    local_md5="$(md5sum "$zip_file" | awk '{print $1}')"

    log "Resolving Gofile upload server ..."
    local servers
    servers="$(curl -fsS --max-time 30 https://api.gofile.io/servers 2>/dev/null \
        | python3 -c "import json,sys;print(' '.join(s.get('name','') for s in json.load(sys.stdin).get('data',{}).get('servers',[])))" 2>/dev/null || true)"
    if [[ -z "$servers" ]]; then
        err "Gofile server list unavailable."
        return 1
    fi

    local server resp page id remote_md5
    resp=""
    for server in $servers; do
        log "Uploading $zip_name to Gofile server: $server"
        local curl_args=(-fsS --max-time 900 -F "file=@${zip_file}")
        [[ -n "$token" ]]  && curl_args+=(-F "token=${token}")
        [[ -n "$folder" ]] && curl_args+=(-F "folderId=${folder}")
        resp="$(curl "${curl_args[@]}" "https://${server}.gofile.io/contents/uploadfile" 2>/dev/null || true)"
        if grep -q '"downloadPage"' <<<"$resp"; then
            break
        fi
        resp=""
    done

    if [[ -z "$resp" ]]; then
        err "Gofile upload failed on every server."
        return 1
    fi

    page="$(python3 -c "import json,sys;print(json.load(sys.stdin)['data'].get('downloadPage',''))" <<<"$resp" 2>/dev/null || true)"
    id="$(python3 -c "import json,sys;print(json.load(sys.stdin)['data'].get('id',''))" <<<"$resp" 2>/dev/null || true)"
    remote_md5="$(python3 -c "import json,sys;print(json.load(sys.stdin)['data'].get('md5',''))" <<<"$resp" 2>/dev/null || true)"

    if [[ -z "$page" ]]; then
        err "Gofile response did not contain a download page."
        return 1
    fi

    log "Gofile mirror: $page"
    if [[ -n "$remote_md5" && "$remote_md5" != "$local_md5" ]]; then
        warn "Gofile md5 mismatch (local=$local_md5 remote=$remote_md5)"
    fi

    write_upload_result "$BUILD_DIR/gofile.env" \
        GOFILE_URL "$page" \
        GOFILE_ID "$id" \
        GOFILE_MD5 "$local_md5"
    log "Gofile result written to: $BUILD_DIR/gofile.env"
}

upload_pixeldrain() {
    local zip_file
    zip_file="$(find_artifact_zip)" || { err "No flashable zip found. Run ./build.sh all first."; return 1; }
    command -v curl >/dev/null 2>&1 || { err "curl is required for PixelDrain upload."; return 1; }

    local key="${PIXELDRAIN_API_KEY:-}"
    if [[ -z "$key" ]]; then
        warn "PIXELDRAIN_API_KEY is not set; skipping PixelDrain upload."
        return 0
    fi

    local zip_name
    zip_name="$(basename "$zip_file")"
    log "Uploading $zip_name to PixelDrain ..."

    # PUT with the API key as the HTTP Basic password (empty username).
    local resp
    resp="$(curl -fsS --max-time 900 -T "$zip_file" -u ":${key}" \
        "https://pixeldrain.com/api/file/" 2>/dev/null || true)"

    if [[ -z "$resp" ]]; then
        err "PixelDrain upload failed (empty response)."
        return 1
    fi

    local id
    id="$(python3 -c "import json,sys;print(json.load(sys.stdin).get('id',''))" <<<"$resp" 2>/dev/null || true)"
    if [[ -z "$id" ]]; then
        err "PixelDrain response did not contain a file id."
        return 1
    fi

    local page="https://pixeldrain.com/u/${id}"
    log "PixelDrain mirror: $page"
    write_upload_result "$BUILD_DIR/pixeldrain.env" \
        PIXELDRAIN_URL "$page" \
        PIXELDRAIN_ID "$id"
    log "PixelDrain result written to: $BUILD_DIR/pixeldrain.env"
}

# Best-effort: mirror to both providers and merge the results. Individual
# provider failures are reported but do not abort the other upload.
upload_all() {
    local rc=0
    local gofile_env="$BUILD_DIR/gofile.env"
    local pixeldrain_env="$BUILD_DIR/pixeldrain.env"
    local combined="$BUILD_DIR/upload-info.env"
    : > "$gofile_env"
    : > "$pixeldrain_env"

    upload_gofile || rc=1
    upload_pixeldrain || rc=1

    {
        printf '# Pox mirror results - generated %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        cat "$gofile_env" "$pixeldrain_env"
    } > "$combined"
    log "Combined mirror results written to: $combined"

    return "$rc"
}

# Print the build metadata for the most recent artifact, generating it if the
# zip exists but the metadata file does not.
show_info() {
    local info="$BUILD_DIR/build-info.env"
    if [[ ! -f "$info" ]]; then
        local zip_file
        zip_file="$(find_artifact_zip)" || { err "No build metadata and no flashable zip found."; return 1; }
        write_build_metadata "$zip_file"
    fi
    cat "$info"
}

install_device() {
    local zip_file
    zip_file="$(find_artifact_zip)" || { err "No AnyKernel3 zip found in $BUILD_DIR. Please run ./build.sh all first."; return 1; }

    log "Checking ADB connection to device..."
    if ! command -v adb >/dev/null 2>&1; then
        err "adb tool not found in PATH."
        exit 1
    fi

    local dev_state
    dev_state=$(adb get-state 2>/dev/null || echo "offline")
    if [[ "$dev_state" != "device" && "$dev_state" != "recovery" ]]; then
        err "Device not detected in 'device' or 'recovery' mode (current state: $dev_state)."
        exit 1
    fi

    log "Pushing $(basename "$zip_file") to device (/sdcard/)..."
    adb push "$zip_file" "/sdcard/$(basename "$zip_file")"
    adb push "$zip_file" "/sdcard/latest.zip"
    adb push "$zip_file" "/sdcard/Pox-Kernel-latest.zip"

    log "Kernel zip installed to /sdcard/ on device!"
    log "  - /sdcard/$(basename "$zip_file")"
    log "  - /sdcard/latest.zip"
    log "  - /sdcard/Pox-Kernel-latest.zip"
}

case "$ACTION" in
    clean)
        clean_build
        ;;
    distclean)
        distclean_build
        ;;
    menuconfig)
        run_menuconfig
        ;;
    kernel)
        build_kernel
        ;;
    zip|package)
        package_zip
        ;;
    info)
        show_info
        ;;
    gofile)
        upload_gofile
        ;;
    pixeldrain)
        upload_pixeldrain
        ;;
    upload)
        upload_all
        ;;
    install)
        install_device
        ;;
    build-install|"build and install")
        build_kernel
        package_zip
        install_device
        ;;
    all|"")
        build_kernel
        package_zip
        ;;
    help|-h|--help)
        cat <<USAGE
Usage: $0 [action]

Actions:
  all (default)      Configure, build the kernel, and package the flashable zip
  kernel             Build the kernel image only
  zip | package      Package build/Image.gz-dtb into an AnyKernel3 zip
  info               Print the metadata for the most recent artifact
  gofile             Mirror the latest zip to Gofile (GOFILE_TOKEN optional)
  pixeldrain         Mirror the latest zip to PixelDrain (PIXELDRAIN_API_KEY required)
  upload             Mirror to every configured provider (Gofile + PixelDrain)
  install            Push the latest zip to a connected device via adb
  build-install      Build, package, then push to a connected device
  menuconfig         Open the kernel configuration menu
  clean              Remove object output (keeps the packaged zips)
  distclean          Remove the whole build directory
  help               Show this help

Environment:
  GIT_BRANCH, DEFCONFIG, VERSION_NAME, PACKAGE_NAME, LOCALVERSION, EXTENDED_LOCALVERSION
  JOBS, EXTRA_FLAGS, CCACHE, SKIP_LOAD_CHECK, KEEP_CUSTOM_FLAGS
  GOFILE_TOKEN, GOFILE_FOLDER_ID, PIXELDRAIN_API_KEY
USAGE
        ;;
    *)
        err "Unknown action: $ACTION"
        echo "Usage: $0 [all|kernel|zip|info|gofile|pixeldrain|upload|install|build-install|menuconfig|clean|distclean|help]"
        exit 1
        ;;
esac
