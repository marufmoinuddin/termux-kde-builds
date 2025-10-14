#!/data/data/com.termux/files/usr/bin/bash

# Optimized KDE Plasma 6.4.2 Builder for Termux
# Builds packages incrementally with proper error handling and logging

set -e
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

# Check if package is already built
is_built() {
    local pkg_name="$1"
    local marker="$BUILD_ROOT/.built_${pkg_name}"
    [[ -f "$marker" ]]
}

# Mark package as built
mark_built() {
    local pkg_name="$1"
    touch "$BUILD_ROOT/.built_${pkg_name}"
}

# Download and extract package
download_extract() {
    local url="$1"
    local pkg_name="$2"
    local filename=$(basename "$url")
    local cache_file="$DOWNLOAD_CACHE/$filename"
    
    if [[ ! -f "$cache_file" ]]; then
        log "Downloading $pkg_name..."
        wget -q --show-progress -O "$cache_file" "$url" || {
            error "Failed to download $url"
            return 1
        }
    else
        info "Using cached $filename"
    fi
    
    if [[ "$filename" == *.tar.xz ]]; then
        tar -xf "$cache_file" -C "$BUILD_ROOT" || return 1
    elif [[ "$filename" == *.tar.gz ]]; then
        tar -xzf "$cache_file" -C "$BUILD_ROOT" || return 1
    fi
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
    
    log "Building $pkg_name..."
    cd "$src_dir"
    
    local build_dir="build"
    [[ -d "$build_dir" ]] && rm -rf "$build_dir"
    mkdir -p "$build_dir" && cd "$build_dir"
    
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DBUILD_TESTING=OFF \
        -DBUILD_WITH_QT6=ON \
        "${extra_flags[@]}" \
        2>&1 | tee "$LOG_DIR/${pkg_name}_cmake.log" || {
        error "CMake failed for $pkg_name"
        return 1
    }
    
    make -j"$BUILD_JOBS" 2>&1 | tee "$LOG_DIR/${pkg_name}_make.log" || {
        error "Make failed for $pkg_name"
        return 1
    }
    
    make install 2>&1 | tee "$LOG_DIR/${pkg_name}_install.log" || {
        error "Install failed for $pkg_name"
        return 1
    }
    
    mark_built "$pkg_name"
    log "✓ $pkg_name built successfully"
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
    
    log "Building $pkg_name with Meson..."
    cd "$src_dir"
    
    meson setup builddir \
        --prefix="$PREFIX" \
        --buildtype=release \
        "${extra_flags[@]}" \
        2>&1 | tee "$LOG_DIR/${pkg_name}_meson.log" || {
        error "Meson setup failed for $pkg_name"
        return 1
    }
    
    meson compile -C builddir -j"$BUILD_JOBS" 2>&1 | tee "$LOG_DIR/${pkg_name}_compile.log" || {
        error "Meson compile failed for $pkg_name"
        return 1
    }
    
    meson install -C builddir 2>&1 | tee "$LOG_DIR/${pkg_name}_install.log" || {
        error "Meson install failed for $pkg_name"
        return 1
    }
    
    mark_built "$pkg_name"
    log "✓ $pkg_name built successfully"
}

# Apply patch to CMakeLists
patch_cmake() {
    local file="$1"
    local search="$2"
    local replace="$3"
    
    if grep -q "$search" "$file" 2>/dev/null; then
        sed -i "s|$search|$replace|g" "$file"
        info "Patched: $file"
    fi
}

# Initialize environment
init_environment() {
    log "Initializing build environment..."
    
    mkdir -p "$BUILD_ROOT" "$LOG_DIR" "$DOWNLOAD_CACHE"
    cd "$BUILD_ROOT"
    
    # Update packages
    log "Updating Termux packages..."
    pkg update -y
    
    # Install base dependencies
    log "Installing base dependencies..."
    pkg install -y \
        git cmake ninja make clang lld binutils \
        python python-pip perl cpan wget curl jq \
        extra-cmake-modules pkg-config
    
    # Install libraries
    log "Installing libraries..."
    pkg install -y \
        qt6* kf6* \
        build-essential mesa libglvnd-dev \
        libwayland-protocols vulkan-headers plasma-wayland-protocols \
        libcap boost boost-headers xorgproto libxss sdl2 \
        sassc docbook-xml docbook-xsl \
        libqrencode libzxing-cpp libdmtx liblmdb \
        openexr pulseaudio-glib \
        xwayland libxcvt libdisplay-info \
        gsettings-desktop-schemas duktape libduktape \
        gobject-introspection editorconfig-core-c \
        fontconfig-utils itstool spirv-tools
    
    # Python dependencies
    pip install --upgrade meson pycairo
    
    # Perl dependencies
    cpan install URI::Escape 2>&1 | grep -v "^Reading" || true
    
    log "Environment ready!"
}

# Main build sequence
build_plasma() {
    log "Starting Plasma ${PLASMA_VERSION} build sequence..."
    
    # KDE Frameworks
    download_extract "https://github.com/KDE/kidletime/archive/refs/tags/v${KF_VERSION}.tar.gz" "kidletime"
    cmake_build "$BUILD_ROOT/kidletime-${KF_VERSION}" "kidletime"
    
    download_extract "https://github.com/KDE/kcmutils/archive/refs/tags/v${KF_VERSION}.tar.gz" "kcmutils"
    cmake_build "$BUILD_ROOT/kcmutils-${KF_VERSION}" "kcmutils"
    
    download_extract "https://github.com/KDE/ksvg/archive/refs/tags/v${KF_VERSION}.tar.gz" "ksvg"
    cmake_build "$BUILD_ROOT/ksvg-${KF_VERSION}" "ksvg"
    
    download_extract "https://github.com/KDE/frameworkintegration/archive/refs/tags/v${KF_VERSION}.tar.gz" "frameworkintegration"
    cmake_build "$BUILD_ROOT/frameworkintegration-${KF_VERSION}" "frameworkintegration"
    
    download_extract "https://github.com/KDE/kdoctools/archive/refs/tags/v${KF_VERSION}.tar.gz" "kdoctools"
    cmake_build "$BUILD_ROOT/kdoctools-${KF_VERSION}" "kdoctools"
    
    download_extract "https://github.com/KDE/syntax-highlighting/archive/refs/tags/v${KF_VERSION}.tar.gz" "syntax-highlighting"
    cd "$BUILD_ROOT/syntax-highlighting-${KF_VERSION}"
    patch_cmake "src/CMakeLists.txt" "add_subdirectory(quick)" "#add_subdirectory(quick)"
    cmake_build "$BUILD_ROOT/syntax-highlighting-${KF_VERSION}" "syntax-highlighting"
    
    download_extract "https://github.com/KDE/kstatusnotifieritem/archive/refs/tags/v${KF_VERSION}.tar.gz" "kstatusnotifieritem"
    cmake_build "$BUILD_ROOT/kstatusnotifieritem-${KF_VERSION}" "kstatusnotifieritem" -DBUILD_PYTHON_BINDINGS=OFF
    
    download_extract "https://github.com/KDE/kdnssd/archive/refs/tags/v${KF_VERSION}.tar.gz" "kdnssd"
    cmake_build "$BUILD_ROOT/kdnssd-${KF_VERSION}" "kdnssd"
    
    download_extract "https://github.com/KDE/kparts/archive/refs/tags/v${KF_VERSION}.tar.gz" "kparts"
    cmake_build "$BUILD_ROOT/kparts-${KF_VERSION}" "kparts"
    
    download_extract "https://github.com/KDE/krunner/archive/refs/tags/v${KF_VERSION}.tar.gz" "krunner"
    cmake_build "$BUILD_ROOT/krunner-${KF_VERSION}" "krunner"
    
    download_extract "https://github.com/KDE/prison/archive/refs/tags/v${KF_VERSION}.tar.gz" "prison"
    cmake_build "$BUILD_ROOT/prison-${KF_VERSION}" "prison"
    
    download_extract "https://github.com/KDE/ktexteditor/archive/refs/tags/v${KF_VERSION}.tar.gz" "ktexteditor"
    cmake_build "$BUILD_ROOT/ktexteditor-${KF_VERSION}" "ktexteditor"
    
    download_extract "https://github.com/KDE/kunitconversion/archive/refs/tags/v${KF_VERSION}.tar.gz" "kunitconversion"
    cmake_build "$BUILD_ROOT/kunitconversion-${KF_VERSION}" "kunitconversion" -DBUILD_PYTHON_BINDINGS=OFF
    
    download_extract "https://github.com/KDE/kdeclarative/archive/refs/tags/v${KF_VERSION}.tar.gz" "kdeclarative"
    cmake_build "$BUILD_ROOT/kdeclarative-${KF_VERSION}" "kdeclarative"
    
    download_extract "https://github.com/KDE/baloo/archive/refs/tags/v${KF_VERSION}.tar.gz" "baloo"
    cmake_build "$BUILD_ROOT/baloo-${KF_VERSION}" "baloo"
    
    download_extract "https://github.com/KDE/kuserfeedback/archive/refs/tags/v${KF_VERSION}.tar.gz" "kuserfeedback"
    cmake_build "$BUILD_ROOT/kuserfeedback-${KF_VERSION}" "kuserfeedback"
    
    download_extract "https://github.com/KDE/kholidays/archive/refs/tags/v${KF_VERSION}.tar.gz" "kholidays"
    cmake_build "$BUILD_ROOT/kholidays-${KF_VERSION}" "kholidays"
    
    download_extract "https://github.com/KDE/kded/archive/refs/tags/v${KF_VERSION}.tar.gz" "kded"
    cmake_build "$BUILD_ROOT/kded-${KF_VERSION}" "kded"
    
    # Qt additional modules
    download_extract "https://github.com/qt/qtpositioning/archive/refs/tags/v${QT_VERSION}.tar.gz" "qtpositioning"
    cd "$BUILD_ROOT/qtpositioning-${QT_VERSION}"
    mkdir -p build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX" -G Ninja
    ninja -j"$BUILD_JOBS" && ninja install
    mark_built "qtpositioning"
    
    download_extract "https://github.com/qt/qtlocation/archive/refs/tags/v${QT_VERSION}.tar.gz" "qtlocation"
    cd "$BUILD_ROOT/qtlocation-${QT_VERSION}"
    mkdir -p build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX" -G Ninja
    ninja -j"$BUILD_JOBS" && ninja install
    mark_built "qtlocation"
    
    download_extract "https://github.com/qt/qtspeech/archive/refs/tags/v${QT_VERSION}.tar.gz" "qtspeech"
    cd "$BUILD_ROOT/qtspeech-${QT_VERSION}"
    mkdir -p build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX" -G Ninja
    ninja -j"$BUILD_JOBS" && ninja install
    mark_built "qtspeech"
    
    download_extract "https://github.com/qt/qtsensors/archive/refs/tags/v${QT_VERSION}.tar.gz" "qtsensors"
    cd "$BUILD_ROOT/qtsensors-${QT_VERSION}"
    mkdir -p build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX" -G Ninja
    ninja -j"$BUILD_JOBS" && ninja install
    mark_built "qtsensors"
    
    # Third-party libraries
    download_extract "https://github.com/qcoro/qcoro/archive/refs/tags/v0.12.0.tar.gz" "qcoro"
    cd "$BUILD_ROOT/qcoro-0.12.0"
    mkdir -p build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX" -G Ninja
    ninja -j"$BUILD_JOBS" && ninja install
    mark_built "qcoro"
    
    download_extract "https://github.com/KDE/phonon/archive/refs/tags/v4.12.0.tar.gz" "phonon"
    cmake_build "$BUILD_ROOT/phonon-4.12.0" "phonon" \
        -DPHONON_BUILD_QT5=OFF \
        -DPHONON_BUILD_QT6=ON
    
    # Plasma packages
    download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/kwayland-${PLASMA_VERSION}.tar.xz" "kwayland"
    cmake_build "$BUILD_ROOT/kwayland-${PLASMA_VERSION}" "kwayland"
    
    download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/kdecoration-${PLASMA_VERSION}.tar.xz" "kdecoration"
    cmake_build "$BUILD_ROOT/kdecoration-${PLASMA_VERSION}" "kdecoration"
    
    download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/libkscreen-${PLASMA_VERSION}.tar.xz" "libkscreen"
    cmake_build "$BUILD_ROOT/libkscreen-${PLASMA_VERSION}" "libkscreen"
    
    download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/plasma-activities-${PLASMA_VERSION}.tar.xz" "plasma-activities"
    cmake_build "$BUILD_ROOT/plasma-activities-${PLASMA_VERSION}" "plasma-activities"
    
    download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/plasma-activities-stats-${PLASMA_VERSION}.tar.xz" "plasma-activities-stats"
    cmake_build "$BUILD_ROOT/plasma-activities-stats-${PLASMA_VERSION}" "plasma-activities-stats"
    
    download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/plasma5support-${PLASMA_VERSION}.tar.xz" "plasma5support"
    cmake_build "$BUILD_ROOT/plasma5support-${PLASMA_VERSION}" "plasma5support"
    
    download_extract "https://github.com/KDE/libplasma/archive/refs/tags/v${PLASMA_VERSION}.tar.gz" "libplasma"
    cmake_build "$BUILD_ROOT/libplasma-${PLASMA_VERSION}" "libplasma"
    
    download_extract "https://download.kde.org/stable/plasma/${PLASMA_VERSION}/breeze-${PLASMA_VERSION}.tar.xz" "breeze"
    cmake_build "$BUILD_ROOT/breeze-${PLASMA_VERSION}" "breeze" \
        -DBUILD_QT6=ON \
        -DBUILD_QT5=OFF
    
    log "Build sequence completed!"
}

# Setup fonts
setup_fonts() {
    log "Setting up fonts..."
    mkdir -p "$HOME/.local/share/fonts"
    cd "$HOME/.local/share/fonts"
    
    [[ -f "NotoSans-Regular.ttf" ]] || \
        wget -q https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf
    [[ -f "NotoSans-Bold.ttf" ]] || \
        wget -q https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSans/NotoSans-Bold.ttf
    [[ -f "NotoColorEmoji.ttf" ]] || \
        wget -q https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf
    
    fc-cache -fv
    log "Fonts configured"
}

# Generate summary
generate_summary() {
    log "Build Summary"
    echo "============================================"
    echo "Total packages built: $(ls "$BUILD_ROOT"/.built_* 2>/dev/null | wc -l)"
    echo "Build directory: $BUILD_ROOT"
    echo "Logs directory: $LOG_DIR"
    echo "============================================"
    info "To continue building more packages, run this script again."
    info "Progress is saved, already-built packages will be skipped."
}

# Main execution
main() {
    log "KDE Plasma ${PLASMA_VERSION} Builder for Termux"
    log "Using ${BUILD_JOBS} CPU cores"
    echo ""
    
    init_environment
    build_plasma
    setup_fonts
    generate_summary
    
    log "All done! ✓"
}

# Trap errors
trap 'error "Build failed at line $LINENO. Check logs in $LOG_DIR"' ERR

# Run main
main "$@"