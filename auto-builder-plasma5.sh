#!/data/data/com.termux/files/usr/bin/bash

# Automated script to build KDE Plasma 5.27.11 .deb packages in Termux (ARM64, no root)
# Plasma 5.27.x has mature X11 support, making it ideal for Termux:X11
# Outputs .deb files in ~/termux-packages/debs/

set -e

# Setup environment
echo "Setting up Termux packaging environment for Plasma 5.27.11 (X11)..."

# Optimize for Snapdragon 860 (Cortex-A76/A55 - ARMv8.2-A)
export CFLAGS="-march=armv8.2-a+crypto+dotprod -mtune=cortex-a76 -O3 -pipe -ffast-math"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O3 -Wl,--as-needed"
export MAKEFLAGS="-j$(nproc)"

echo "Compiler optimization flags set for Snapdragon 860"
echo "CFLAGS: ${CFLAGS}"
echo "Using $(nproc) CPU cores for parallel compilation"

# Ensure temporary workspace exists
TMP_ROOT="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
SCRIPT_TMP_DIR="$TMP_ROOT/kde-builder"
mkdir -p "$SCRIPT_TMP_DIR"
export TMPDIR="$TMP_ROOT"

# Update and install dependencies
pkg update && pkg upgrade -y
pkg install git cmake make clang lld binutils libllvm ninja pkg-config python ruby perl wget curl -y
pkg install libiconv zlib libxml2 libxslt libexpat libpng libjpeg-turbo libwebp freetype fontconfig dbus libandroid-glob libandroid-shmem libandroid-spawn libpixman -y
pkg install xorgproto libx11 libxext libxrender libxtst libxdamage libxfixes libxrandr libxcomposite libxcursor libxft libxi libxt libxv libxkbfile libxaw libxmu libxpm libxss libxkbcommon libice libsm libxcb libxau libxdmcp libxshmfence libglvnd libglvnd-dev -y || true
pkg install x11-repo tur-repo -y

# Install Qt5 and KDE Frameworks 5 (KF5) instead of Qt6/KF6
pkg install qt5-qtbase qt5-qtdeclarative qt5-qtsvg qt5-qtx11extras qt5-qtmultimedia qt5-qttools -y || true
pkg install extra-cmake-modules ninja libwayland-protocols vulkan-headers jq libcap boost boost-headers -y
pkg install libxss sdl2 sassc docbook-xml docbook-xsl itstool libqrencode libdmtx liblmdb openexr -y
pkg install xwayland libxcvt gsettings-desktop-schemas duktape libduktape gobject-introspection g-ir-scanner fontconfig-utils pulseaudio-glib -y || true

pip install meson
cpan install URI::Escape

# Clone Termux packages repo
REPO_DIR="$HOME/termux-packages"
if [ ! -d "$REPO_DIR" ]; then
    echo "Cloning termux-packages repo..."
    git clone https://github.com/termux/termux-packages.git "$REPO_DIR"
fi
cd "$REPO_DIR"
if [ -x "./scripts/setup-multilib.sh" ]; then
    ./scripts/setup-multilib.sh || true
else
    echo "setup-multilib.sh not present, skipping multilib setup"
fi

# Create package directories
PACKAGES_DIR="$REPO_DIR/packages"
DEBS_DIR="$REPO_DIR/debs"
mkdir -p "$PACKAGES_DIR" "$DEBS_DIR"

# Function to create build.sh for a package
create_build_sh() {
    local pkg_name=$1
    local version=$2
    local src_url=$3
    local git_url=$4
    local git_tag=$5
    local depends=$6
    local cmake_flags=$7
    local patches=$8
    local use_ninja=$9
    local build_dir="${10:-true}"
    local extra_steps="${11:-}"

    local dir="$PACKAGES_DIR/plasma5-$pkg_name"
    mkdir -p "$dir"
    local build_sh="$dir/build.sh"
    local sha256="SKIP"

    # Try to get SHA256 if source URL is provided
    if [ -n "$src_url" ]; then
        local filename="$(basename "$src_url")"
        local sha_file_url="$src_url.sha256"
        local sha_file_path="$SCRIPT_TMP_DIR/$filename.sha256"
        
        if curl -fsSL "$sha_file_url" -o "$sha_file_path" 2>/dev/null; then
            sha256=$(grep -m1 -o '[0-9a-fA-F]\{64\}' "$sha_file_path" || echo "SKIP")
        fi
        rm -f "$sha_file_path"
    fi

    cat > "$build_sh" << EOF
#!/data/data/com.termux/files/usr/bin/bash
TERMUX_PKG_MAINTAINER="Termux User <user@example.com>"
TERMUX_PKG_NAME="plasma5-$pkg_name"
TERMUX_PKG_VERSION="$version"
TERMUX_PKG_SRCURL="$src_url"
TERMUX_PKG_GIT_CLONE="$git_url"
TERMUX_PKG_GIT_CHECKOUT_TAG="$git_tag"
TERMUX_PKG_SHA256="$sha256"
TERMUX_PKG_DEPENDS="$depends"
TERMUX_PKG_BUILD_IN_SRC=$build_dir
TERMUX_PKG_NO_STATICSPLIT=true

termux_step_preconfigure() {
    ${patches:+$patches}
    ${extra_steps:+$extra_steps}
    true
}

termux_step_configure() {
    $(if [ "$use_ninja" == "true" ]; then
        echo "cmake . -G Ninja \\"
    else
        echo "cmake . \\"
    fi)
        -DCMAKE_INSTALL_PREFIX=\$TERMUX_PREFIX \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
        -DBUILD_TESTING=OFF \
        -DCMAKE_DISABLE_FIND_PACKAGE_Systemd=TRUE \
        -DCMAKE_DISABLE_FIND_PACKAGE_UDev=TRUE \
        $cmake_flags
}

termux_step_make_install() {
    $(if [ "$use_ninja" == "true" ]; then
        echo "ninja -j\$(nproc)"
        echo "ninja install DESTDIR=\$TERMUX_PKG_STAGEDIR"
    else
        echo "make -j\$(nproc)"
        echo "make install DESTDIR=\$TERMUX_PKG_STAGEDIR"
    fi)
}
EOF
    chmod +x "$build_sh"
    echo "Created build.sh for plasma5-$pkg_name"
}

# Function to build a package
build_package() {
    local pkg_name=$1
    if ls "$DEBS_DIR"/plasma5-"$pkg_name"_*.deb 1> /dev/null 2>&1; then
        echo "Package plasma5-$pkg_name already built, skipping."
        return 0
    fi
    echo "Building plasma5-$pkg_name..."
    ./build-package.sh -I "plasma5-$pkg_name" > "build-plasma5-$pkg_name.log" 2>&1 || {
        echo "Build failed for plasma5-$pkg_name. Check build-plasma5-$pkg_name.log."
    }
    echo "Built plasma5-$pkg_name successfully."
}

# Plasma 5.27.11 package list (X11-focused, mature release)
# Format: version|src_url|git_url|git_tag|depends|cmake_flags|patches|use_ninja|build_dir|extra_steps
declare -A PACKAGES=(
    # Core Plasma 5 libraries
    ["kwayland"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/kwayland-5.27.11.tar.xz|||qt5-qtbase||false||"
    ["kdecoration"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/kdecoration-5.27.11.tar.xz|||qt5-qtbase||false||"
    ["libkscreen"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/libkscreen-5.27.11.tar.xz|||qt5-qtbase||false||"
    ["libksysguard"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/libksysguard-5.27.11.tar.xz|||qt5-qtbase||sed -i 's|find_package(Sensors)|#&|' CMakeLists.txt; sed -i 's|add_subdirectory( processcore )|#&|' CMakeLists.txt|false||"
    
    # Desktop and window manager
    ["kwin"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/kwin-5.27.11.tar.xz|||qt5-qtbase,qt5-qtx11extras,xwayland,libxcvt|-DBUILD_WAYLAND=OFF|sed -i 's|find_package(UDev)|#&|' CMakeLists.txt|false||"
    
    # Workspace
    ["plasma-workspace"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/plasma-workspace-5.27.11.tar.xz|||qt5-qtbase,qt5-qtx11extras||sed -i 's|find_package(UDev REQUIRED)|#&|' CMakeLists.txt; sed -i 's|find_package(PolkitQt5-1)|#&|' CMakeLists.txt|false||"
    ["plasma-desktop"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/plasma-desktop-5.27.11.tar.xz|||qt5-qtbase,qt5-qtx11extras||sed -i 's|pkg_check_modules(LIBWACOM libwacom REQUIRED)|#&|' CMakeLists.txt; sed -i 's|find_package(UDev)|#&|' CMakeLists.txt|false||"
    
    # Themes
    ["breeze"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/breeze-5.27.11.tar.xz|||qt5-qtbase,qt5-qtx11extras||false||"
    ["oxygen"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/oxygen-5.27.11.tar.xz|||qt5-qtbase,qt5-qtx11extras||false||"
    
    # System settings
    ["systemsettings"]="5.27.11|https://download.kde.org/stable/plasma/5.27.11/systemsettings-5.27.11.tar.xz|||qt5-qtbase||false||"
)

echo ""
echo "=========================================="
echo "Building KDE Plasma 5.27.11 for Termux X11"
echo "Packages: ${#PACKAGES[@]}"
echo "=========================================="
echo ""

# Create build.sh for each package
for pkg in "${!PACKAGES[@]}"; do
    IFS='|' read -r version src_url git_url git_tag depends cmake_flags patches use_ninja build_dir extra_steps <<< "${PACKAGES[$pkg]}"
    create_build_sh "$pkg" "$version" "$src_url" "$git_url" "$git_tag" "$depends" "$cmake_flags" "$patches" "$use_ninja" "$build_dir" "$extra_steps"
done

# Build all packages in dependency order
echo ""
echo "Starting package builds..."
for pkg in "${!PACKAGES[@]}"; do
    build_package "$pkg"
done

# Install all generated .deb files
echo ""
echo "Installing all .deb packages..."
if ls "$DEBS_DIR"/plasma5-*.deb 1> /dev/null 2>&1; then
    for deb in "$DEBS_DIR"/plasma5-*.deb; do
        pkg install "$deb" -y || {
            echo "Failed to install $deb. Check logs."
        }
    done
else
    echo "No .deb files found in $DEBS_DIR."
    echo "Builds may have failed. Check logs in $REPO_DIR"
    exit 1
fi

# Set up environment
echo ""
echo "Setting up environment..."
cat >> "$HOME/.profile" << 'EOF'
export PATH=$PREFIX/bin:$PATH
export LD_LIBRARY_PATH=$PREFIX/lib:$LD_LIBRARY_PATH
export QT_PLUGIN_PATH=$PREFIX/lib/qt5/plugins
export KDE_FULL_SESSION=true
export KDE_SESSION_VERSION=5
export XDG_DATA_DIRS=$PREFIX/share:$XDG_DATA_DIRS
export XDG_CONFIG_DIRS=$PREFIX/etc/xdg:$XDG_CONFIG_DIRS
EOF
source "$HOME/.profile"

echo ""
echo "=========================================="
echo "Build complete! To run Plasma 5:"
echo "1. Start Termux:X11 app"
echo "2. Run: termux-x11 :0 &"
echo "3. Launch: dbus-launch --exit-with-session startplasma-x11"
echo "All .deb files are in $DEBS_DIR"
echo "=========================================="
