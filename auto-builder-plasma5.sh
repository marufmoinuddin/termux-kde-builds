#!/data/data/com.termux/files/usr/bin/bash

# Optimized KDE Plasma 6.4.2 Builder for Termux
# Builds packages incrementally with proper error handling

set -e
set -o pipefail

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
BUILD_JOBS=$(nproc)

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

# Safe package installation
pkg_install() {
    local packages=("$@")
    local failed=()
    
    for pkg in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            info "$pkg already installed"
        else
            if pkg install -y "$pkg" 2>&1 | grep -v "^Reading\|^Building\|^Get:\|^Hit:"; then
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

# Download with retry and return actual extracted directory
download_extract() {
    local url="$1"
    local pkg_name="$2"
    local version="$3"
    local filename=$(basename "$url")
    local cache_file="$DOWNLOAD_CACHE/$filename"
    local max_retries=3
    local retry=0
    
    if [[ ! -f "$cache_file" ]]; then
        log "Downloading $pkg_name..."
        while [[ $retry -lt $max_retries ]]; do
            if wget -q --show-progress --timeout=60 -O "$cache_file" "$url"; then
                break
            else
                retry=$((retry + 1))
                if [[ $retry -lt $max_retries ]]; then
                    warn "Download failed, retry $retry/$max_retries..."
                    sleep 2
                else
                    error "Failed to download $url after $max_retries attempts"
                    rm -f "$cache_file"
                    return 1
                fi
            fi
        done
    else
        info "Using cached $filename"
    fi
    
    cd "$BUILD_ROOT"
    
    # Extract and find the actual directory name
    local extract_dir=""
    if [[ "$filename" == *.tar.xz ]]; then
        extract_dir=$(tar -tf "$cache_file" | head -1 | cut -d'/' -f1)
        tar -xf "$cache_file" || return 1
    elif [[ "$filename" == *.tar.gz ]]; then
        extract_dir=$(tar -tzf "$cache_file" | head -1 | cut -d'/' -f1)
        tar -xzf "$cache_file" || return 1
    fi
    
    # Return the actual extracted directory path
    echo "$BUILD_ROOT/$extract_dir"
}

# Standard CMake build
cmake_build() {
    local src_dir="$1"
    local pkg_name="$2"
    shift 2
    local extra_flags=("$@")
    
    if is_built "$pkg_name"; then
        info "$pkg_name already built, skipping..."
        return 0
    fi
    
    if [[ ! -d "$src_dir" ]]; then
        error "Source directory not found: $src_dir"
        return 1
    fi
    
    log "Building $pkg_name..."
    cd "$src_dir"
    
    local build_dir="build"
    [[ -d "$build_dir" ]] && rm -rf "$build_dir"
    mkdir -p "$build_dir" && cd "$build_dir"
    
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
        
        echo ""
        echo "=== Build ==="
        make -j"$BUILD_JOBS" || exit 1
        
        echo ""
        echo "=== Install ==="
        make install || exit 1
    } &> "$log_file"
    
    if [[ $? -eq 0 ]]; then
        mark_built "$pkg_name"
        log "✓ $pkg_name built successfully"
        return 0
    else
        error "Build failed for $pkg_name - check $log_file"
        tail -50 "$log_file"
        return 1
    fi
}

# Ninja build
ninja_build() {
    local src_dir="$1"
    local pkg_name="$2"
    shift 2
    local extra_flags=("$@")
    
    if is_built "$pkg_name"; then
        info "$pkg_name already built, skipping..."
        return 0
    fi
    
    if [[ ! -d "$src_dir" ]]; then
        error "Source directory not found: $src_dir"
        return 1
    fi
    
    log "Building $pkg_name with Ninja..."
    cd "$src_dir"
    
    local build_dir="build"
    [[ -d "$build_dir" ]] && rm -rf "$build_dir"
    mkdir -p "$build_dir" && cd "$build_dir"
    
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
        ninja install || exit 1
    } &> "$log_file"
    
    if [[ $? -eq 0 ]]; then
        mark_built "$pkg_name"
        log "✓ $pkg_name built successfully"
        return 0
    else
        error "Build failed for $pkg_name - check $log_file"
        tail -50 "$log_file"
        return 1
    fi
}

# Meson build
meson_build() {
    local src_dir="$1"
    local pkg_name="$2"
    shift 2
    local extra_flags=("$@")
    
    if is_built "$pkg_name"; then
        info "$pkg_name already built, skipping..."
        return 0
    fi
    
    if [[ ! -d "$src_dir" ]]; then
        error "Source directory not found: $src_dir"
        return 1
    fi
    
    log "Building $pkg_name with Meson..."
    cd "$src_dir"
    
    [[ -d "builddir" ]] && rm -rf builddir
    
    local log_file="$LOG_DIR/${pkg_name}_build.log"
    
    {
        meson setup builddir \
            --prefix="$PREFIX" \
            --buildtype=release \
            "${extra_flags[@]}" || exit 1
        
        meson compile -C builddir -j"$BUILD_JOBS" || exit 1
        meson install -C builddir || exit 1
    } &> "$log_file"
    
    if [[ $? -eq 0 ]]; then
        mark_built "$pkg_name"
        log "✓ $pkg_name built successfully"
        return 0
    else
        error "Build failed for $pkg_name - check $log_file"
        tail -50 "$log_file"
        return 1
    fi
}

# Apply patch
patch_cmake() {
    local file="$1"
    local search="$2"
    local replace="$3"
    
    if [[ -f "$file" ]] && grep -q "$search" "$file" 2>/dev/null; then
        sed -i "s|$search|$replace|g" "$file"
        info "Patched: $file"
    fi
}

# Initialize environment
init_environment() {
    log "Initializing build environment..."
    
    mkdir -p "$BUILD_ROOT" "$LOG_DIR" "$DOWNLOAD_CACHE"
    cd "$BUILD_ROOT"
    
    log "Updating Termux packages..."
    pkg update -y 2>&1 | grep -v "^Reading\|^Building\|^Get:\|^Hit:" || true
    
    log "Installing base dependencies..."
    pkg_install git cmake ninja make clang lld binutils \
        python wget curl jq extra-cmake-modules pkg-config
    
    log "Installing Qt6 base packages..."
    pkg_install qt6-qtbase qt6-qtdeclarative qt6-qtsvg qt6-qtwayland \
        qt6-qtmultimedia qt6-qttools qt6-qt5compat
    
    log "Installing development tools..."
    pkg_install build-essential mesa xorgproto \
        libcap boost boost-headers libxss sdl2 \
        sassc docbook-xml docbook-xsl \
        libqrencode libdmtx liblmdb openexr \
        pulseaudio fontconfig itstool
    
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

# Build sequence
build_plasma() {
    log "Starting Plasma ${PLASMA_VERSION} build sequence..."
    
    # KDE Frameworks (in dependency order)
    local -a frameworks=(
        "kidletime:${KF_VERSION}"
        "kcmutils:${KF_VERSION}"
        "ksvg:${KF_VERSION}"
        "frameworkintegration:${KF_VERSION}"
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
        
        local src_dir=$(download_extract "https://github.com/KDE/${name}/archive/refs/tags/v${ver}.tar.gz" "$name" "$ver")
        
        if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
            error "Failed to extract $name"
            continue
        fi
        
        # Special handling for syntax-highlighting
        if [[ "$name" == "syntax-highlighting" ]]; then
            patch_cmake "$src_dir/src/CMakeLists.txt" \
                "add_subdirectory(quick)" "#add_subdirectory(quick)"
        fi
        
        # Special handling for kunitconversion and kstatusnotifieritem
        if [[ "$name" == "kunitconversion" || "$name" == "kstatusnotifieritem" ]]; then
            cmake_build "$src_dir" "$name" -DBUILD_PYTHON_BINDINGS=OFF
        else
            cmake_build "$src_dir" "$name"
        fi
    done
    
    # Qt modules
    local -a qt_modules=(
        "qtpositioning"
        "qtlocation"
        "qtspeech"
        "qtsensors"
    )
    
    for mod in "${qt_modules[@]}"; do
        local src_dir=$(download_extract "https://github.com/qt/${mod}/archive/refs/tags/v${QT_VERSION}.tar.gz" "$mod" "$QT_VERSION")
        
        if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
            error "Failed to extract $mod"
            continue
        fi
        
        ninja_build "$src_dir" "$mod"
    done
    
    # Third-party libraries
    local qcoro_dir=$(download_extract "https://github.com/qcoro/qcoro/archive/refs/tags/v0.12.0.tar.gz" "qcoro" "0.12.0")
    if [[ -n "$qcoro_dir" && -d "$qcoro_dir" ]]; then
        ninja_build "$qcoro_dir" "qcoro"
    fi
    
    local phonon_dir=$(download_extract "https://github.com/KDE/phonon/archive/refs/tags/v4.12.0.tar.gz" "phonon" "4.12.0")
    if [[ -n "$phonon_dir" && -d "$phonon_dir" ]]; then
        cmake_build "$phonon_dir" "phonon" \
            -DPHONON_BUILD_QT5=OFF -DPHONON_BUILD_QT6=ON
    fi
    
    # Plasma components (from KDE downloads, different URL structure)
    local -a plasma_pkgs=(
        "kwayland"
        "kdecoration"
        "libkscreen"
        "plasma-activities"
        "plasma-activities-stats"
        "plasma5support"
    )
    
    for pkg in "${plasma_pkgs[@]}"; do
        local src_dir=$(download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/${pkg}-${PLASMA_VERSION}.tar.xz" "$pkg" "$PLASMA_VERSION")
        
        if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
            error "Failed to extract $pkg"
            continue
        fi
        
        cmake_build "$src_dir" "$pkg"
    done
    
    # Breeze
    local breeze_dir=$(download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/breeze-${PLASMA_VERSION}.tar.xz" "breeze" "$PLASMA_VERSION")
    if [[ -n "$breeze_dir" && -d "$breeze_dir" ]]; then
        cmake_build "$breeze_dir" "breeze" \
            -DBUILD_QT6=ON -DBUILD_QT5=OFF
    fi
    
    log "Build sequence completed!"
}

# Setup fonts
setup_fonts() {
    if is_built "fonts"; then
        info "Fonts already configured"
        return 0
    fi
    
    log "Setting up fonts..."
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
    log "Fonts configured"
}

# Summary
generate_summary() {
    local built_count=$(ls "$BUILD_ROOT"/.built_* 2>/dev/null | wc -l)
    
    echo ""
    log "Build Summary"
    echo "============================================"
    echo "Total packages built: $built_count"
    echo "Build directory: $BUILD_ROOT"
    echo "Logs directory: $LOG_DIR"
    echo "Downloads cached: $DOWNLOAD_CACHE"
    echo "============================================"
    
    if [[ $built_count -gt 0 ]]; then
        info "To continue building more packages, run this script again."
        info "Already-built packages will be skipped automatically."
    fi
    
    echo ""
    info "Check logs for any warnings or errors: ls -lh $LOG_DIR"
}

# Main
main() {
    log "KDE Plasma ${PLASMA_VERSION} Builder for Termux"
    log "Using ${BUILD_JOBS} CPU cores for compilation"
    echo ""
    
    # Check we're in Termux
    if [[ ! -d "/data/data/com.termux" ]]; then
        error "This script must be run in Termux!"
        exit 1
    fi
    
    init_environment
    build_plasma
    setup_fonts
    generate_summary
    
    log "All done! ✓"
}

# Trap errors
trap 'error "Build failed at line $LINENO. Check logs in $LOG_DIR"' ERR

# Handle script arguments
case "${1:-}" in
    --clean)
        warn "Removing build directory..."
        rm -rf "$BUILD_ROOT"
        log "Clean complete"
        exit 0
        ;;
    --status)
        if [[ -d "$BUILD_ROOT" ]]; then
            echo "Built packages:"
            ls -1 "$BUILD_ROOT"/.built_* 2>/dev/null | sed 's|.*/\.built_||' || echo "None"
        else
            echo "No build directory found"
        fi
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  (no args)   - Run the build"
        echo "  --clean     - Remove build directory"
        echo "  --status    - Show built packages"
        echo "  --help      - Show this help"
        exit 0
        ;;
esac

# Run main
main "$@"