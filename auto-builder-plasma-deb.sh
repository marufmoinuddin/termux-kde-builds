#!/data/data/com.termux/files/usr/bin/bash

# KDE Plasma 6.4.2 Debian Package Builder for Termux
# Builds KDE packages and produces .deb artifacts instead of installing them

set -e
set -o pipefail
umask 022  # ensure dpkg-compatible permissions for generated artifacts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PLASMA_VERSION="6.4.2"
KF_VERSION="6.16.0"
QT_VERSION="6.9.1"
BUILD_ROOT="$HOME/Plasma-Build"
LOG_DIR="$BUILD_ROOT/logs"
DOWNLOAD_CACHE="$BUILD_ROOT/downloads"
STAGE_ROOT="$BUILD_ROOT/staging"
DEB_OUTPUT="$BUILD_ROOT/debs"
BUILD_JOBS=$(nproc)
ARCH=$(dpkg --print-architecture 2>/dev/null || echo "aarch64")

# Snapdragon 860 optimizations
export CFLAGS="-march=armv8.2-a+crypto+dotprod -mtune=cortex-a76 -O3 -pipe -ffast-math"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O3 -Wl,--as-needed"
export MAKEFLAGS="-j${BUILD_JOBS}"

# Helper functions
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

is_built() {
    [[ -f "$BUILD_ROOT/.built_$1" ]]
}

mark_built() {
    touch "$BUILD_ROOT/.built_$1"
    log "✓ $1 marked as complete"
}

pkg_install() {
    local packages=("$@")
    local failed=()

    mkdir -p "$LOG_DIR/pkg_install"

    for pkg in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            info "$pkg already installed"
        else
            local log_file="$LOG_DIR/pkg_install/${pkg}.log"
            if pkg install -y "$pkg" &> "$log_file"; then
                info "✓ Installed $pkg"
            else
                warn "Could not install $pkg (may not exist)"
                failed+=("$pkg")
            fi
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "These packages were not installed: ${failed[*]}"
        warn "Continuing anyway - they may not be needed"
    fi
}

# Download with retry and return directory path
download_extract() {
    local url="$1"
    local pkg_name="$2"
    local version="$3"
    local base_filename=$(basename "$url")
    local cache_file="$DOWNLOAD_CACHE/${pkg_name}-${version}-${base_filename}"
    local archive_name=$(basename "$cache_file")
    local max_retries=3
    local retry=0

    if [[ ! -f "$cache_file" ]]; then
        log "Downloading $pkg_name..." >&2
        while [[ $retry -lt $max_retries ]]; do
            if wget -q --show-progress --timeout=60 -O "$cache_file" "$url" &> "$LOG_DIR/${pkg_name}_download.log"; then
                break
            else
                retry=$((retry + 1))
                if [[ $retry -lt $max_retries ]]; then
                    warn "Download failed, retry $retry/$max_retries..." >&2
                    sleep 2
                else
                    error "Failed to download $url after $max_retries attempts"
                    rm -f "$cache_file"
                    return 1
                fi
            fi
        done
    else
    info "Using cached $archive_name" >&2
    fi

    if [[ ! -s "$cache_file" ]]; then
        error "Downloaded file is empty or missing: $cache_file"
        rm -f "$cache_file"
        return 1
    fi

    cd "$BUILD_ROOT"

    local extract_dir=""

    if [[ "$archive_name" == *.tar.xz ]]; then
        extract_dir=$(tar -tf "$cache_file" 2>/dev/null | head -1 | cut -d'/' -f1)
        if [[ -z "$extract_dir" ]]; then
            error "Could not determine directory name from $archive_name"
            return 1
        fi
        rm -rf "$BUILD_ROOT/$extract_dir"
        if ! tar -xf "$cache_file" &> "$LOG_DIR/${pkg_name}_extract.log"; then
            error "Failed to extract $archive_name"
            cat "$LOG_DIR/${pkg_name}_extract.log" >&2
            return 1
        fi
    elif [[ "$archive_name" == *.tar.gz ]]; then
        extract_dir=$(tar -tzf "$cache_file" 2>/dev/null | head -1 | cut -d'/' -f1)
        if [[ -z "$extract_dir" ]]; then
            error "Could not determine directory name from $archive_name"
            return 1
        fi
        rm -rf "$BUILD_ROOT/$extract_dir"
        if ! tar -xzf "$cache_file" &> "$LOG_DIR/${pkg_name}_extract.log"; then
            error "Failed to extract $archive_name"
            cat "$LOG_DIR/${pkg_name}_extract.log" >&2
            return 1
        fi
    else
        error "Unsupported archive format: $archive_name"
        return 1
    fi

    local full_path="$BUILD_ROOT/$extract_dir"
    if [[ ! -d "$full_path" ]]; then
        error "Extracted directory not found: $full_path"
        error "Archive contained: $(tar -tf "$cache_file" 2>/dev/null | head -5)"
        return 1
    fi

    local base_dir_name=$(basename "$full_path")
    if [[ "$base_dir_name" != *"$pkg_name"* ]]; then
        error "Archive directory '$base_dir_name' does not match expected package '$pkg_name'"
        return 1
    fi

    echo "$full_path"
}

create_control_file() {
    local pkg_name="$1"
    local version="$2"
    local stage_dir="$3"
    local control_dir="$stage_dir/DEBIAN"
    local installed_size=$(du -sk "$stage_dir" 2>/dev/null | cut -f1)

    mkdir -p "$control_dir"
    chmod 755 "$control_dir"

    cat > "$control_dir/control" <<EOF
Package: plasma-${pkg_name}
Version: ${version}
Section: misc
Priority: optional
Architecture: ${ARCH}
Maintainer: Termux Plasma Builder <builder@localhost>
Installed-Size: ${installed_size:-0}
Description: KDE Plasma component ${pkg_name} (Termux build)
 Built automatically by auto-builder-plasma5-deb.sh
EOF

    chmod 644 "$control_dir/control"
}

build_deb_artifact() {
    local pkg_name="$1"
    local version="$2"
    local stage_dir="$STAGE_ROOT/$pkg_name"

    create_control_file "$pkg_name" "$version" "$stage_dir"

    mkdir -p "$DEB_OUTPUT"
    local deb_path="$DEB_OUTPUT/${pkg_name}_${version}_${ARCH}.deb"

    if command -v fakeroot &> /dev/null; then
        fakeroot dpkg-deb --build "$stage_dir" "$deb_path" &> "$LOG_DIR/${pkg_name}_dpkg.log"
    else
        dpkg-deb --build "$stage_dir" "$deb_path" &> "$LOG_DIR/${pkg_name}_dpkg.log"
    fi

    if [[ $? -eq 0 ]]; then
        log "✓ Created package: $deb_path"
        mark_built "$pkg_name"
    else
        error "Failed to create package for $pkg_name"
        tail -20 "$LOG_DIR/${pkg_name}_dpkg.log"
        return 1
    fi
}

install_stage_to_prefix() {
    local pkg_name="$1"
    local stage_prefix="$STAGE_ROOT/$pkg_name/data/data/com.termux/files/usr"

    if [[ -d "$stage_prefix" ]]; then
        log "Temporarily installing $pkg_name into build prefix for dependency resolution..."
        (cd "$stage_prefix" && tar -cf - .) | (cd "$PREFIX" && tar -xf -)
    else
        warn "Stage prefix not found for $pkg_name (expected at $stage_prefix)"
    fi
}

cmake_build_deb() {
    local src_dir="$1"
    local pkg_name="$2"
    local version="$3"
    shift 3
    local extra_flags=("$@")

    if is_built "$pkg_name"; then
        info "$pkg_name already packaged, skipping..."
        return 0
    fi

    if [[ ! -d "$src_dir" ]]; then
        error "Source directory not found: $src_dir"
        return 1
    fi

    log "Building $pkg_name (deb)..."
    cd "$src_dir"

    local build_dir="build"
    [[ -d "$build_dir" ]] && rm -rf "$build_dir"
    mkdir -p "$build_dir" && cd "$build_dir"

    local stage_dir="$STAGE_ROOT/$pkg_name"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    local log_file="$LOG_DIR/${pkg_name}_build.log"

    {
        echo "=== CMake Configuration ==="
        cmake .. \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_SYSTEM_NAME=Linux \
            -DCMAKE_C_FLAGS="${CFLAGS}" \
            -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
            -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
            -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
            -DBUILD_TESTING=OFF \
            -DBUILD_WITH_QT6=ON \
            "${extra_flags[@]}" || exit 1

        if [[ "$pkg_name" == "kdoctools" ]]; then
            mkdir -p "bin"
            cat > "bin/KF6::meinproc6" <<'EOF'
#!/data/data/com.termux/files/usr/bin/env sh
exec "$(dirname "$0")/meinproc6" "$@"
EOF
            chmod +x "bin/KF6::meinproc6"
            export PATH="$PWD/bin:$PATH"
        fi

        echo ""
        echo "=== Build ==="
        make -j"$BUILD_JOBS" || exit 1

        echo ""
        echo "=== Install (DESTDIR) ==="
        make install DESTDIR="$stage_dir" || exit 1
    } &> "$log_file"

    if [[ $? -eq 0 ]]; then
        build_deb_artifact "$pkg_name" "$version"
    else
        error "Build failed for $pkg_name - check $log_file"
        tail -50 "$log_file"
        return 1
    fi
}

ninja_build_deb() {
    local src_dir="$1"
    local pkg_name="$2"
    local version="$3"
    shift 3
    local extra_flags=("$@")

    if is_built "$pkg_name"; then
        info "$pkg_name already packaged, skipping..."
        return 0
    fi

    if [[ ! -d "$src_dir" ]]; then
        error "Source directory not found: $src_dir"
        return 1
    fi

    log "Building $pkg_name with Ninja (deb)..."
    cd "$src_dir"

    local build_dir="build"
    [[ -d "$build_dir" ]] && rm -rf "$build_dir"
    mkdir -p "$build_dir" && cd "$build_dir"

    local stage_dir="$STAGE_ROOT/$pkg_name"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    local log_file="$LOG_DIR/${pkg_name}_build.log"

    {
        cmake .. \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_SYSTEM_NAME=Linux \
            -DCMAKE_C_FLAGS="${CFLAGS}" \
            -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
            -G Ninja \
            "${extra_flags[@]}" || exit 1

        ninja -j"$BUILD_JOBS" || exit 1
        DESTDIR="$stage_dir" ninja install || exit 1
    } &> "$log_file"

    if [[ $? -eq 0 ]]; then
        build_deb_artifact "$pkg_name" "$version"
    else
        error "Build failed for $pkg_name - check $log_file"
        tail -50 "$log_file"
        return 1
    fi
}

meson_build_deb() {
    local src_dir="$1"
    local pkg_name="$2"
    local version="$3"
    shift 3
    local extra_flags=("$@")

    if is_built "$pkg_name"; then
        info "$pkg_name already packaged, skipping..."
        return 0
    fi

    if [[ ! -d "$src_dir" ]]; then
        error "Source directory not found: $src_dir"
        return 1
    fi

    log "Building $pkg_name with Meson (deb)..."
    cd "$src_dir"

    [[ -d "builddir" ]] && rm -rf builddir

    local stage_dir="$STAGE_ROOT/$pkg_name"
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir"

    local log_file="$LOG_DIR/${pkg_name}_build.log"

    {
        meson setup builddir \
            --prefix="$PREFIX" \
            --buildtype=release \
            "${extra_flags[@]}" || exit 1

        meson compile -C builddir -j"$BUILD_JOBS" || exit 1
        DESTDIR="$stage_dir" meson install -C builddir || exit 1
    } &> "$log_file"

    if [[ $? -eq 0 ]]; then
        build_deb_artifact "$pkg_name" "$version"
    else
        error "Build failed for $pkg_name - check $log_file"
        tail -50 "$log_file"
        return 1
    fi
}

patch_cmake() {
    local file="$1"
    local search="$2"
    local replace="$3"

    if [[ -f "$file" ]] && grep -q "$search" "$file" 2>/dev/null; then
        sed -i "s|$search|$replace|g" "$file"
        info "Patched: $file"
    fi
}

init_environment() {
    log "Initializing build environment (deb mode)..."

    mkdir -p "$BUILD_ROOT" "$LOG_DIR" "$DOWNLOAD_CACHE" "$STAGE_ROOT" "$DEB_OUTPUT"
    cd "$BUILD_ROOT"

    log "Updating Termux packages..."
    pkg update -y 2>&1 | grep -v "^Reading\|^Building\|^Get:\|^Hit:" || true

    log "Installing base dependencies..."
    pkg_install git cmake ninja make clang lld binutils \
        python wget curl jq extra-cmake-modules pkg-config dpkg fakeroot

    log "Installing Qt6 base packages..."
    pkg_install qt6-qtbase qt6-qtdeclarative qt6-qtsvg qt6-qtwayland \
        qt6-qtmultimedia qt6-qttools qt6-qt5compat qt6-qtspeech

    log "Installing development tools..."
    pkg_install build-essential mesa xorgproto \
        libcap boost boost-headers libxss sdl2 \
        sassc docbook-xml docbook-xsl \
        libqrencode libdmtx liblmdb openexr \
        pulseaudio pulseaudio-glib fontconfig itstool \
        layer-shell-qt

    log "Installing additional repositories..."
    pkg_install x11-repo tur-repo

    log "Installing Wayland/X11 packages..."
    pkg_install libwayland xwayland libxcvt \
        gsettings-desktop-schemas gobject-introspection

    log "Installing Python/Perl tools..."
    pkg_install python-pip perl

    if ! command -v meson &> /dev/null; then
        log "Installing Python packages..."
        pip install --quiet --upgrade pip setuptools wheel
        pip install --quiet meson pycairo
    fi

    if ! perl -MURI::Escape -e 'exit 0' 2>/dev/null; then
        log "Installing Perl modules..."
        yes | cpan -T URI::Escape &> "$LOG_DIR/cpan.log" || warn "CPAN may have had issues"
    fi

    log "Environment ready!"
}

build_plasma_debs() {
    log "Starting Plasma ${PLASMA_VERSION} packaging sequence..."

    local -a qt_modules=(
        "qtpositioning:${QT_VERSION}"
        "qtlocation:${QT_VERSION}"
        "qtspeech:${QT_VERSION}"
        "qtsensors:${QT_VERSION}"
    )

    for mod in "${qt_modules[@]}"; do
        local name="${mod%%:*}"
        local ver="${mod##*:}"

        local src_dir=$(download_extract "https://github.com/qt/${name}/archive/refs/tags/v${ver}.tar.gz" "$name" "$ver")

        if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
            error "Failed to extract $name"
            continue
        fi

        ninja_build_deb "$src_dir" "$name" "$ver"
        install_stage_to_prefix "$name"
    done

    local -a frameworks=(
        "kidletime:${KF_VERSION}"
        "kcmutils:${KF_VERSION}"
        "ksvg:${KF_VERSION}"
        "frameworkintegration:${KF_VERSION}"
        "syntax-highlighting:${KF_VERSION}"
        "kdoctools:${KF_VERSION}"
        "kstatusnotifieritem:${KF_VERSION}"
        "kdnssd:${KF_VERSION}"
        "kparts:${KF_VERSION}"
        "krunner:${KF_VERSION}"
        "prison:${KF_VERSION}"
        "ktexteditor:${KF_VERSION}"
        "kunitconversion:${KF_VERSION}"
        "kdeclarative:${KF_VERSION}"
        "baloo:${KF_VERSION}"
        "kuserfeedback:${KF_VERSION}"
        "kholidays:${KF_VERSION}"
        "kded:${KF_VERSION}"
    )

    for fw in "${frameworks[@]}"; do
        local name="${fw%%:*}"
        local ver="${fw##*:}"

        log "Processing $name v$ver..."

        local src_dir=$(download_extract "https://github.com/KDE/${name}/archive/refs/tags/v${ver}.tar.gz" "$name" "$ver")
        local extract_status=$?

        if [[ $extract_status -ne 0 || -z "$src_dir" || ! -d "$src_dir" ]]; then
            error "Failed to extract or locate $name (exit: $extract_status, dir: '$src_dir')"
            info "Download cache contents:"
            ls -lh "$DOWNLOAD_CACHE"/*${name}* 2>/dev/null || echo "No files found for $name"
            continue
        fi

        info "Source directory: $src_dir"

        if [[ "$name" == "kunitconversion" || "$name" == "kstatusnotifieritem" ]]; then
            cmake_build_deb "$src_dir" "$name" "$ver" -DBUILD_PYTHON_BINDINGS=OFF
        elif [[ "$name" == "syntax-highlighting" ]]; then
            patch_cmake "$src_dir/src/CMakeLists.txt" \
                "add_subdirectory(quick)" "#add_subdirectory(quick)"
            cmake_build_deb "$src_dir" "$name" "$ver" -DBUILD_QML_PLUGIN=OFF
            install_stage_to_prefix "$name"
        elif [[ "$name" == "kdeclarative" || "$name" == "krunner" ]]; then
            cmake_build_deb "$src_dir" "$name" "$ver" -DBUILD_KTP_PLUGIN=OFF
        else
            cmake_build_deb "$src_dir" "$name" "$ver"
        fi
    done

    local qcoro_dir=$(download_extract "https://github.com/qcoro/qcoro/archive/refs/tags/v0.12.0.tar.gz" "qcoro" "0.12.0")
    if [[ -n "$qcoro_dir" && -d "$qcoro_dir" ]]; then
        ninja_build_deb "$qcoro_dir" "qcoro" "0.12.0"
    fi

    local phonon_dir=$(download_extract "https://github.com/KDE/phonon/archive/refs/tags/v4.12.0.tar.gz" "phonon" "4.12.0")
    if [[ -n "$phonon_dir" && -d "$phonon_dir" ]]; then
        cmake_build_deb "$phonon_dir" "phonon" "4.12.0" \
            -DPHONON_BUILD_QT5=OFF -DPHONON_BUILD_QT6=ON
    fi

    # kwin-x11 provides KWinDBusInterface needed by plasma-workspace
    if ! is_built "kwin-x11"; then
        log "Cloning kwin-x11..."
        cd "$BUILD_ROOT"
        if [[ -d "kwin-x11" ]]; then
            rm -rf kwin-x11
        fi
        if git clone --depth 1 https://invent.kde.org/plasma/kwin-x11.git &> "$LOG_DIR/kwin-x11_clone.log"; then
            # Patches for Termux compatibility
            patch_cmake "$BUILD_ROOT/kwin-x11/CMakeLists.txt" "find_package(UDev)" "#find_package(UDev)"

            if [[ -f "$BUILD_ROOT/kwin-x11/src/CMakeLists.txt" ]]; then
                sed -i '/UDev::UDev/d' "$BUILD_ROOT/kwin-x11/src/CMakeLists.txt"
                # Add android-shmem to linker for shared memory APIs
                sed -i '/epoxy::epoxy/a\\        android-shmem' "$BUILD_ROOT/kwin-x11/src/CMakeLists.txt"
            fi

            if [[ -f "$BUILD_ROOT/kwin-x11/src/kcms/rules/CMakeLists.txt" ]]; then
                sed -i '/KF6::XmlGui/a\\    android-shmem' "$BUILD_ROOT/kwin-x11/src/kcms/rules/CMakeLists.txt"
            fi

            if cmake_build_deb "$BUILD_ROOT/kwin-x11" "kwin-x11" "$PLASMA_VERSION" \
                -DBUILD_WAYLAND_COMPOSITOR=OFF \
                -DBUILD_KWIN_WAYLAND=OFF \
                -DBUILD_KWIN_X11=ON \
                -DKF6_HOST_TOOLING=$PREFIX/lib/cmake; then
                install_stage_to_prefix "kwin-x11"
            fi
        else
            warn "Failed to clone kwin-x11"
        fi
    fi

    local -a plasma_pkgs=(
        "kwayland:${PLASMA_VERSION}"
        "kdecoration:${PLASMA_VERSION}"
        "libkscreen:${PLASMA_VERSION}"
        "plasma-activities:${PLASMA_VERSION}"
        "plasma-activities-stats:${PLASMA_VERSION}"
        "plasma5support:${PLASMA_VERSION}"
        "libplasma:${PLASMA_VERSION}"
        "ocean-sound-theme:${PLASMA_VERSION}"
        "plasma-workspace:${PLASMA_VERSION}"
        "plasma-integration:${PLASMA_VERSION}"
        "milou:${PLASMA_VERSION}"
        "plasma-desktop:${PLASMA_VERSION}"
        "systemsettings:${PLASMA_VERSION}"
        "plasma-pa:${PLASMA_VERSION}"
    )

    for pkg in "${plasma_pkgs[@]}"; do
        local name="${pkg%%:*}"
        local ver="${pkg##*:}"

        local src_dir=$(download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/${name}-${PLASMA_VERSION}.tar.xz" "$name" "$ver")

        if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
            error "Failed to extract $name"
            continue
        fi

        cmake_build_deb "$src_dir" "$name" "$ver"
    done
    
    # Git-only plasma components (need special handling)
    log "Packaging git-sourced components..."
    
    # kglobalaccel (git)
    if ! is_built "kglobalaccel"; then
        log "Cloning kglobalaccel..."
        cd "$BUILD_ROOT"
        if [[ -d "kglobalaccel" ]]; then
            rm -rf kglobalaccel
        fi
        if git clone --depth 1 --branch v${KF_VERSION} https://github.com/KDE/kglobalaccel.git &> "$LOG_DIR/kglobalaccel_clone.log"; then
            cmake_build_deb "$BUILD_ROOT/kglobalaccel" "kglobalaccel" "$KF_VERSION"
        else
            warn "Failed to clone kglobalaccel"
        fi
    fi
    
    # kscreenlocker (git with patches)
    if ! is_built "kscreenlocker"; then
        log "Cloning kscreenlocker..."
        cd "$BUILD_ROOT"
        if [[ -d "kscreenlocker" ]]; then
            rm -rf kscreenlocker
        fi
        if git clone --depth 1 --branch v${PLASMA_VERSION} https://invent.kde.org/plasma/kscreenlocker.git &> "$LOG_DIR/kscreenlocker_clone.log"; then
            # Patch: disable PAM and greeter
            patch_cmake "$BUILD_ROOT/kscreenlocker/CMakeLists.txt" "find_package(PAM REQUIRED)" "#find_package(PAM REQUIRED)"
            patch_cmake "$BUILD_ROOT/kscreenlocker/CMakeLists.txt" "add_subdirectory(greeter)" "#add_subdirectory(greeter)"
            cmake_build_deb "$BUILD_ROOT/kscreenlocker" "kscreenlocker" "$PLASMA_VERSION"
        else
            warn "Failed to clone kscreenlocker"
        fi
    fi
    
    local breeze_dir=$(download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/breeze-${PLASMA_VERSION}.tar.xz" "breeze" "$PLASMA_VERSION")
    if [[ -n "$breeze_dir" && -d "$breeze_dir" ]]; then
        cmake_build_deb "$breeze_dir" "breeze" "$PLASMA_VERSION" \
            -DBUILD_QT6=ON -DBUILD_QT5=OFF
    fi

    log "Packaging sequence completed!"
}

setup_fonts() {
    if is_built "fonts"; then
        info "Fonts already staged"
        return 0
    fi

    log "Collecting fonts for package..."
    mkdir -p "$HOME/.local/share/fonts"
    cd "$HOME/.local/share/fonts"

    local fonts=(
        "https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf"
        "https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSans/NotoSans-Bold.ttf"
        "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf"
    )

    for font_url in "${fonts[@]}"; do
        local font_file=$(basename "$font_url")
        [[ -f "$font_file" ]] || wget -q "$font_url"
    done

    fc-cache -fv &> "$LOG_DIR/fontconfig.log"
    mark_built "fonts"
    log "Fonts cached"
}

generate_summary() {
    local built_count=$(ls "$BUILD_ROOT"/.built_* 2>/dev/null | wc -l)

    echo ""
    log "Packaging Summary"
    echo "============================================"
    echo "Total packages built: $built_count"
    echo "Build directory: $BUILD_ROOT"
    echo "Debian packages: $DEB_OUTPUT"
    echo "Logs directory: $LOG_DIR"
    echo "Downloads cached: $DOWNLOAD_CACHE"
    echo "============================================"

    if [[ $built_count -gt 0 ]]; then
        info "Resulting .deb files are in $DEB_OUTPUT"
        info "Already-packaged modules will be skipped when rerunning."
    fi

    echo ""
    info "Inspect logs with: ls -lh $LOG_DIR"
}

main() {
    log "KDE Plasma ${PLASMA_VERSION} Debian Packager for Termux"
    log "Using ${BUILD_JOBS} CPU cores for compilation"
    echo ""

    if [[ ! -d "/data/data/com.termux" ]]; then
        error "This script must be run in Termux!"
        exit 1
    fi

    init_environment
    build_plasma_debs
    setup_fonts
    generate_summary

    log "All done! ✓"
}

trap 'error "Build failed at line $LINENO. Check logs in $LOG_DIR"' ERR

case "${1:-}" in
    --clean)
        warn "Removing build directory..."
        rm -rf "$BUILD_ROOT"
        log "Clean complete"
        exit 0
        ;;
    --status)
        if [[ -d "$BUILD_ROOT" ]]; then
            echo "Packaged modules:"
            ls -1 "$BUILD_ROOT"/.built_* 2>/dev/null | sed 's|.*/\\.built_||' || echo "None"
        else
            echo "No build directory found"
        fi
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  (no args)   - Run the packaging build"
        echo "  --clean     - Remove build directory"
        echo "  --status    - Show packaged modules"
        echo "  --help      - Show this help"
        exit 0
        ;;
esac

main "$@"
