#!/data/data/com.termux/files/usr/bin/bash

# Automated script to build KDE Plasma 6.4.2 .deb packages in Termux (ARM64, no root)
# Based on provided guide, creating Termux package recipes and building sequentially
# Outputs .deb files in ~/termux-packages/debs/

set -e

# Setup environment
echo "Setting up Termux packaging environment..."

# Optimize for Snapdragon 860 (Cortex-A76/A55 - ARMv8.2-A)
export CFLAGS="-march=armv8.2-a+crypto+dotprod -mtune=cortex-a76 -O3 -pipe -ffast-math -flto"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O3 -Wl,--as-needed -flto"
export MAKEFLAGS="-j$(nproc)"

echo "Compiler optimization flags set for Snapdragon 860"
echo "CFLAGS: ${CFLAGS}"
echo "Using $(nproc) CPU cores for parallel compilation"

# Ensure temporary workspace exists (Termux defaults TMPDIR to $PREFIX/tmp)
TMP_ROOT="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
SCRIPT_TMP_DIR="$TMP_ROOT/kde-builder"
mkdir -p "$SCRIPT_TMP_DIR"
export TMPDIR="$TMP_ROOT"

pkg update && pkg upgrade -y
pkg install git cmake make clang lld binutils libllvm ninja pkg-config python ruby perl wget curl -y
pkg install libiconv zlib libxml2 libxslt libexpat libpng libjpeg-turbo libwebp freetype fontconfig dbus libandroid-glob libandroid-shmem libandroid-spawn libpixman -y
pkg install xorgproto libx11 libxext libxrender libxtst libxdamage libxfixes libxrandr libxcomposite libxcursor libxft libxi libxt libxv libxkbfile libxaw libxmu libxpm libxss libxkbcommon libice libsm libxcb libxau libxdmcp libxshmfence libglvnd libglvnd-dev -y || true
pkg install x11-repo tur-repo -y
pkg install kf6* qt6* build-essential extra-cmake-modules ninja libwayland-protocols vulkan-headers plasma-wayland-protocols jq libcap boost boost-headers libxss sdl2 sassc pycairo docbook-xml docbook-xsl itstool libqrencode libzxing-cpp libdmtx liblmdb openexr xwayland libxcvt libdisplay-info gsettings-desktop-schemas duktape libduktape gobject-introspection g-ir-scanner fontconfig-utils -y || true
pip install meson
cpan install URI::Escape
#termux-setup-storage

# Clone Termux packages repo
REPO_DIR="$HOME/termux-packages"
if [ ! -d "$REPO_DIR" ]; then
    echo "Cloning termux-packages repo..."
    git clone https://github.com/termux/termux-packages.git "$REPO_DIR"
fi
cd "$REPO_DIR"
if [ -x "./scripts/setup-multilib.sh" ]; then
    ./scripts/setup-multilib.sh || true  # Optional, continue if fails
else
    echo "setup-multilib.sh not present, skipping multilib setup"
fi

# Create package directories and build.sh scripts
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
    local build_dir="${10:-true}"  # Default to build in source dir
    local extra_steps="${11:-}"

    local dir="$PACKAGES_DIR/kde-$pkg_name"
    mkdir -p "$dir"
    local build_sh="$dir/build.sh"
    local sha256=""

    # Determine SHA256 without downloading full tarball when possible
    if [ -n "$src_url" ]; then
        local sha_candidate=""
        local filename="$(basename "$src_url")"
        local sha_file_url="$src_url.sha256"
        local sha_file_path="$SCRIPT_TMP_DIR/$filename.sha256"
        local sha_list_path="$SCRIPT_TMP_DIR/$pkg_name-SHA256SUMS"
        local tarball_path="$SCRIPT_TMP_DIR/$pkg_name-$version.tar.xz"

        if curl -fsSL "$sha_file_url" -o "$sha_file_path"; then
            sha_candidate=$(grep -m1 -o '[0-9a-fA-F]\{64\}' "$sha_file_path")
        else
            local base_url="${src_url%/*}"
            if curl -fsSL "$base_url/SHA256SUMS" -o "$sha_list_path"; then
                sha_candidate=$(grep -m1 " $filename" "$sha_list_path" | awk '{print $1}')
            fi
        fi

        if [ -n "$sha_candidate" ]; then
            sha256="$sha_candidate"
        else
            echo "Warning: Unable to determine SHA256 for $pkg_name from $src_url, falling back to download"
            if curl -fSL "$src_url" -o "$tarball_path"; then
                sha256=$(sha256sum "$tarball_path" | cut -d' ' -f1)
                rm -f "$tarball_path"
            else
                echo "Error: Failed to download source for $pkg_name. Build may fail." >&2
                sha256="SKIP_CHECKSUM"
            fi
        fi

        rm -f "$sha_file_path" "$sha_list_path"
    fi

    cat > "$build_sh" << EOF
#!/data/data/com.termux/files/usr/bin/bash
TERMUX_PKG_MAINTAINER="Termux User <user@example.com>"
TERMUX_PKG_NAME="kde-$pkg_name"
TERMUX_PKG_VERSION="$version"
TERMUX_PKG_SRCURL="$src_url"
TERMUX_PKG_GIT_CLONE="$git_url"
TERMUX_PKG_GIT_CHECKOUT_TAG="$git_tag"
TERMUX_PKG_SHA256="$sha256"
TERMUX_PKG_DEPENDS="$depends"
TERMUX_PKG_BUILD_IN_SRC=$build_dir
TERMUX_PKG_NO_STATICSPLIT=true

termux_step_preconfigure() {
    $patches
    $extra_steps
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
        -DCMAKE_C_FLAGS="-march=armv8.2-a+crypto+dotprod -mtune=cortex-a76 -O3 -pipe -ffast-math -flto" \
        -DCMAKE_CXX_FLAGS="-march=armv8.2-a+crypto+dotprod -mtune=cortex-a76 -O3 -pipe -ffast-math -flto" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,-O3 -Wl,--as-needed -flto" \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-O3 -Wl,--as-needed -flto" \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
        -DBUILD_TESTING=OFF \
        -DBUILD_WITH_QT6=ON \
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
    echo "Created build.sh for kde-$pkg_name"
}

# Function to build a package
build_package() {
    local pkg_name=$1
    echo "Building kde-$pkg_name..."
    ./build-package.sh -I "kde-$pkg_name" > "build-$pkg_name.log" 2>&1 || {
        echo "Build failed for kde-$pkg_name. Check build-$pkg_name.log."
        exit 1
    }
    echo "Built kde-$pkg_name successfully."
}

# Define package list with metadata (name, version, source, depends, flags, patches)
declare -A PACKAGES=(
    ["kwayland"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/kwayland-6.4.2.tar.xz||qt6-qtbase,kf6-kwindowsystem||false"
    ["kdecoration"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/kdecoration-6.4.2.tar.xz||qt6-qtbase,kf6-kconfig,kde-kwayland|-DBUILD_WITH_QT6=ON|false"
    ["libkscreen"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/libkscreen-6.4.2.tar.xz||qt6-qtbase,kf6-kconfigwidgets|-DBUILD_WITH_QT6=ON|false"
    ["plasma-activities"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-activities-6.4.2.tar.xz||qt6-qtbase,kf6-kconfig,kde-libplasma|-DBUILD_WITH_QT6=ON|false"
    ["plasma-activities-stats"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-activities-stats-6.4.2.tar.xz||kf6-kconfig,kde-plasma-activities|-DBUILD_WITH_QT6=ON|false"
    ["kidletime"]="6.16.0||https://github.com/KDE/kidletime.git|v6.16.0|qt6-qtbase|-DBUILD_WITH_QT6=ON|false"
    ["plasma5support"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma5support-6.4.2.tar.xz||qt6-qtbase,kf6-kconfig,kf6-kcoreaddons|-DBUILD_WITH_QT6=ON|false"
    ["layer-shell-qt"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/layer-shell-qt-6.4.2.tar.xz||qt6-qtbase,kf6-kwayland|-DBUILD_WITH_QT6=ON|false"
    ["kcmutils"]="6.16.0||https://github.com/KDE/kcmutils.git|v6.16.0|kf6-kconfig,kf6-kdeclarative|-DBUILD_WITH_QT6=ON|false"
    ["ksvg"]="6.16.0||https://github.com/KDE/ksvg.git|v6.16.0|qt6-qtbase,kf6-karchive|-DBUILD_WITH_QT6=ON|false"
    ["aurorae"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/aurorae-6.4.2.tar.xz||qt6-qtbase,kf6-kconfigwidgets|-DBUILD_WITH_QT6=ON|false"
    ["frameworkintegration"]="6.16.0||https://github.com/KDE/frameworkintegration.git|v6.16.0|kf6-kconfig,kf6-knotifications|-DBUILD_WITH_QT6=ON|false"
    ["breeze"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/breeze-6.4.2.tar.xz||qt6-qtbase,kf6-kconfig,kf6-kwindowsystem|-DBUILD_QT6=ON -DBUILD_QT5=OFF|false"
    ["breeze-gtk"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/breeze-gtk-6.4.2.tar.xz||qt6-qtbase,sassc,pycairo|-DBUILD_WITH_QT6=ON|false"
    ["kdoctools"]="6.16.0||https://github.com/KDE/kdoctools.git|v6.16.0|kf6-karchive,docbook-xml,docbook-xsl,perl-uri|ln -s \$PWD/bin/meinproc6 \$HOME/bin/KF6::meinproc6; export PATH=\"\$HOME/bin:\$PATH\"|false"
    ["qtpositioning"]="6.9.1||https://github.com/qt/qtpositioning.git|v6.9.1|qt6-qtbase||true"
    ["qtlocation"]="6.9.1||https://github.com/qt/qtlocation.git|v6.9.1|qt6-qtbase,kde-qtpositioning||true"
    ["qcoro"]="0.12.0||https://github.com/qcoro/qcoro.git|v0.12.0|qt6-qtbase,kf6-kcoreaddons||true"
    ["libplasma"]="6.4.2||https://github.com/KDE/libplasma.git|v6.4.2|qt6-qtbase,kf6-kconfig,kf6-kwindowsystem|-DBUILD_WITH_QT6=ON|false"
    ["kstatusnotifieritem"]="6.16.0||https://github.com/KDE/kstatusnotifieritem.git|v6.16.0|kf6-knotifications|-DBUILD_WITH_QT6=ON -DBUILD_PYTHON_BINDINGS=OFF|false"
    ["kdnssd"]="6.16.0||https://github.com/KDE/kdnssd.git|v6.16.0|qt6-qtbase,kf6-kcoreaddons|-DBUILD_WITH_QT6=ON|false"
    ["syntax-highlighting"]="6.16.0||https://github.com/KDE/syntax-highlighting.git|v6.16.0|qt6-qtbase,kf6-kcoreaddons|sed -i 's|add_subdirectory(quick)|#&|' src/CMakeLists.txt|-DBUILD_WITH_QT6=ON|false"
    ["libproxy"]="master||https://github.com/libproxy/libproxy.git|master|gsettings-desktop-schemas,duktape,gobject-introspection|meson setup build --prefix=\$TERMUX_PREFIX -Dvapi=false -Ddocs=false -Dintrospection=false; termux_step_make_install() { meson compile -C build; meson install -C build --destdir \$TERMUX_PKG_STAGEDIR; }|false"
    ["libkexiv2"]="25.07.80||https://github.com/KDE/libkexiv2.git|v25.07.80|qt6-qtbase,kf6-kcoreaddons|-DBUILD_WITH_QT6=ON|false"
    ["phonon"]="4.12.0||https://github.com/KDE/phonon.git|v4.12.0|qt6-qtbase,pulseaudio-glib|-DPHONON_BUILD_QT5=OFF -DPHONON_BUILD_QT6=ON|false"
    ["kio-extras"]="25.07.80|https://github.com/KDE/kio-extras/archive/refs/tags/v25.07.80.tar.gz||qt6-qtbase,kf6-kio,openexr|sed -i '/target_link_libraries(kio_thumbnail/a\        android-shmem' thumbnail/CMakeLists.txt|-DBUILD_WITH_QT6=ON|false"
    ["kparts"]="6.16.0||https://github.com/KDE/kparts.git|v6.16.0|kf6-kio,kf6-kxmlgui|-DBUILD_WITH_QT6=ON|false"
    ["krunner"]="6.16.0||https://github.com/KDE/krunner.git|v6.16.0|kf6-kcoreaddons,kf6-kio|-DBUILD_WITH_QT6=ON|false"
    ["prison"]="6.16.0||https://github.com/KDE/prison.git|v6.16.0|qt6-qtbase,libqrencode,libzxing-cpp,libdmtx|-DBUILD_WITH_QT6=ON|false"
    ["qtspeech"]="6.9.1||https://github.com/qt/qtspeech.git|v6.9.1|qt6-qtbase||true"
    ["ktexteditor"]="6.16.0||https://github.com/KDE/ktexteditor.git|v6.16.0|kf6-kio,kf6-syntax-highlighting|-DBUILD_WITH_QT6=ON|false"
    ["kunitconversion"]="6.16.0||https://github.com/KDE/kunitconversion.git|v6.16.0|kf6-kcoreaddons|-DBUILD_WITH_QT6=ON -DBUILD_PYTHON_BINDINGS=OFF|false"
    ["spirv-tools"]="master||https://github.com/KhronosGroup/SPIRV-Tools.git|master||python3 utils/git-sync-deps|-DCMAKE_EXE_LINKER_FLAGS=\"-llog\"|false"
    ["kdeclarative"]="6.16.0||https://github.com/KDE/kdeclarative.git|v6.16.0|kf6-kio,kf6-kquickcharts,kde-spirv-tools|-DBUILD_WITH_QT6=ON|false"
    ["baloo"]="6.16.0||https://github.com/KDE/baloo.git|v6.16.0|kf6-kio,liblmdb|-DBUILD_WITH_QT6=ON|false"
    ["baloo-widgets"]="25.07.80||https://github.com/KDE/baloo-widgets.git|v25.07.80|kf6-kio,kde-baloo|-DBUILD_WITH_QT6=ON|false"
    ["kuserfeedback"]="6.16.0||https://github.com/KDE/kuserfeedback.git|v6.16.0|qt6-qtbase,kf6-kcoreaddons|-DBUILD_WITH_QT6=ON|false"
    ["qtsensors"]="6.9.1||https://github.com/qt/qtsensors.git|v6.9.1|qt6-qtbase||true"
    ["kglobalacceld"]="6.4.2||https://github.com/KDE/kglobalacceld.git|v6.4.2|kf6-kcoreaddons|-DBUILD_WITH_QT6=ON|false"
    ["kactivitymanagerd"]="6.4.2||https://github.com/KDE/kactivitymanagerd.git|v6.4.2|kf6-kcoreaddons,kde-plasma-activities|-DBUILD_WITH_QT6=ON|false"
    ["kglobalaccel"]="6.16.0||https://github.com/KDE/kglobalaccel.git|v6.16.0|kf6-kcoreaddons|-DBUILD_WITH_QT6=ON|false"
    ["kholidays"]="6.16.0||https://github.com/KDE/kholidays.git|v6.16.0|qt6-qtbase|-DBUILD_WITH_QT6=ON|false"
    ["knighttime"]="master||https://invent.kde.org/plasma/knighttime.git|master|kf6-kcoreaddons|-DBUILD_WITH_QT6=ON|false"
    ["wayland-protocols"]="master||https://gitlab.freedesktop.org/wayland/wayland-protocols.git|master||meson setup build --prefix=\$TERMUX_PREFIX --buildtype=release; termux_step_make_install() { ninja -j\$(nproc); ninja install DESTDIR=\$TERMUX_PKG_STAGEDIR; }|false"
    ["kscreenlocker"]="6.4.2||https://invent.kde.org/plasma/kscreenlocker.git|v6.4.2|kf6-kwindowsystem|sed -i 's|find_package(PAM REQUIRED)|#&|' CMakeLists.txt; sed -i 's|add_subdirectory(greeter)|#&|' CMakeLists.txt; git checkout v6.4.2|-DBUILD_WITH_QT6=ON|false"
    ["libqaccessibilityclient"]="master||https://invent.kde.org/libraries/libqaccessibilityclient.git|master|qt6-qtbase||false"
    ["kwin-x11"]="master||https://invent.kde.org/plasma/kwin-x11.git|stable|qt6-qtbase,kf6-kwindowsystem,xwayland,libxcvt,libdisplay-info|sed -i 's|find_package(UDev)|#&|' CMakeLists.txt; sed -i 's|UDev::UDev|#&|' src/CMakeLists.txt; sed -i '/target_link_libraries(kwin/a\        android-shmem' src/CMakeLists.txt; sed -i '/set(kcm_libs/a\        Qt::DBus\n        android-shmem' src/kcms/rules/CMakeLists.txt; git checkout stable|-DBUILD_WITH_QT6=ON -DBUILD_WAYLAND_COMPOSITOR=OFF -DBUILD_KWIN_WAYLAND=OFF -DBUILD_KWIN_X11=ON -DKF6_HOST_TOOLING=\$TERMUX_PREFIX/lib/cmake|false"
    ["kded"]="6.16.0||https://github.com/KDE/kded.git|v6.16.0|kf6-kcoreaddons|-DBUILD_WITH_QT6=ON|false"
    ["appstream"]="master||https://github.com/ximion/appstream.git|master|qt6-qtbase|meson setup builddir --prefix=\$TERMUX_PREFIX -Dqt=true -Dvapi=false -Ddocs=false -Dapidocs=false -Dgir=true -Dsystemd=false -Dstemming=false; termux_step_make_install() { ninja -j\$(nproc); ninja install DESTDIR=\$TERMUX_PKG_STAGEDIR; }|false"
    ["kquickcharts"]="master||https://github.com/KDE/kquickcharts.git|master|qt6-qtbase,kf6-kcoreaddons|-DBUILD_WITH_QT6=ON|false"
    ["plasma-workspace"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-workspace-6.4.2.tar.xz||qt6-qtbase,kf6-kio,kde-kwin-x11|sed -i 's|find_package(KWinDBusInterface CONFIG REQUIRED)|find_package(KWinX11DBusInterface CONFIG REQUIRED)|' CMakeLists.txt; sed -i 's|find_package(UDev REQUIRED)|#&|' CMakeLists.txt; sed -i 's|find_package(PolkitQt6-1)|#&|' CMakeLists.txt; sed -i 's|find_package(KSysGuard|#&|' CMakeLists.txt; sed -i 's|add_subdirectory(region_language)|#&|' kcms/CMakeLists.txt; sed -i 's|add_subdirectory(users)|#&|' kcms/CMakeLists.txt; sed -i 's|PolkitQt6-1::Core|#&|' kcms/region_language/localegenhelper/CMakeLists.txt; sed -i 's|UDev::UDev|#&|' devicenotifications/CMakeLists.txt; sed -i 's|exampleutility.cpp exampleutility.h|#&|' kcms/region_language/CMakeLists.txt; sed -i 's|add_subdirectory(devicenotifications)|#&|' CMakeLists.txt|-DBUILD_WITH_QT6=ON -DBUILD_CAMERAINDICATOR=OFF|false"
    ["plasma-workspace-wallpapers"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-workspace-wallpapers-6.4.2.tar.xz||qt6-qtbase|-DBUILD_WITH_QT6=ON|false"
    ["noto-fonts"]="master||||mkdir -p \$TERMUX_PKG_STAGEDIR\$TERMUX_PREFIX/share/fonts; wget -P \$TERMUX_PKG_STAGEDIR\$TERMUX_PREFIX/share/fonts https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf; wget -P \$TERMUX_PKG_STAGEDIR\$TERMUX_PREFIX/share/fonts https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSans/NotoSans-Bold.ttf; wget -P \$TERMUX_PKG_STAGEDIR\$TERMUX_PREFIX/share/fonts https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf; fc-cache -fv|true"
    ["plasma-integration"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-integration-6.4.2.tar.xz||qt6-qtbase,kf6-kio|-DBUILD_QT5=OFF -DBUILD_QT6=ON|false"
    ["milou"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/milou-6.4.2.tar.xz||qt6-qtbase,kf6-krunner|-DBUILD_WITH_QT6=ON|false"
    ["ocean-sound-theme"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/ocean-sound-theme-6.4.2.tar.xz||qt6-qtbase|-DBUILD_WITH_QT6=ON|false"
    ["oxygen"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/oxygen-6.4.2.tar.xz||qt6-qtbase,kf6-kconfigwidgets|-DBUILD_QT5=OFF -DBUILD_QT6=ON|false"
    ["oxygen-sounds"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/oxygen-sounds-6.4.2.tar.xz||qt6-qtbase|-DBUILD_WITH_QT6=ON|false"
    ["plasma-nano"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-nano-6.4.2.tar.xz||qt6-qtbase,kf6-kdeclarative||false"
    ["pulseaudio-qt"]="1.7.0||https://github.com/KDE/pulseaudio-qt.git|v1.7.0|qt6-qtbase,pulseaudio-glib||false"
    ["plasma-pa"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-pa-6.4.2.tar.xz||qt6-qtbase,kde-pulseaudio-qt||false"
    ["plasma-welcome"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-welcome-6.4.2.tar.xz||qt6-qtbase,kf6-knewstuff||false"
    ["purpose"]="master||https://github.com/KDE/purpose.git|master|kf6-kio,kf6-knewstuff||false"
    ["plasma-browser-integration"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-browser-integration-6.4.2.tar.xz||qt6-qtbase,kf6-kio|-DCOPY_MESSAGING_HOST_FILE_HOME=ON|false"
    ["plasma-sdk"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-sdk-6.4.2.tar.xz||qt6-qtbase,kf6-kio||false"
    ["qqc2-breeze-style"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/qqc2-breeze-style-6.4.2.tar.xz||qt6-qtbase,kf6-kirigami||false"
    ["qqc2-desktop-style"]="master||https://github.com/KDE/qqc2-desktop-style.git|master|qt6-qtbase,kf6-kirigami||false"
    ["plasma-desktop"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/plasma-desktop-6.4.2.tar.xz||qt6-qtbase,kf6-kio,kde-kwin-x11|sed -i 's|find_package(KSysGuard CONFIG REQUIRED)|find_package(KWinX11DBusInterface CONFIG REQUIRED)|' CMakeLists.txt; sed -i 's|find_package(UDev)|#&|' CMakeLists.txt; sed -i 's|PkgConfig::LIBWACOM|#&|' kcms/tablet/CMakeLists.txt; sed -i 's|PkgConfig::LIBWACOM|#&|' applets/taskmanager/CMakeLists.txt|-DBUILD_WITH_QT6=ON -DCMAKE_DISABLE_FIND_PACKAGE_LibWacom=TRUE|false"
    ["systemsettings"]="6.4.2|https://download.kde.org/stable/plasma/6.4.2/systemsettings-6.4.2.tar.xz||qt6-qtbase,kf6-kcmutils,kde-plasma-desktop|-DBUILD_WITH_QT6=ON|false"
)

# Create build.sh for each package
for pkg in "${!PACKAGES[@]}"; do
    IFS='|' read -r version src_url git_url git_tag depends patches cmake_flags extra_steps use_ninja <<< "${PACKAGES[$pkg]}"
    create_build_sh "$pkg" "$version" "$src_url" "$git_url" "$git_tag" "$depends" "$cmake_flags" "$patches" "$use_ninja" "true" "$extra_steps"
done

# Build all packages in dependency order
for pkg in "${!PACKAGES[@]}"; do
    build_package "$pkg"
done

# Install all generated .deb files
echo "Installing all .deb packages..."
for deb in "$DEBS_DIR"/*.deb; do
    pkg install "$deb" -y || {
        echo "Failed to install $deb. Check logs."
        exit 1
    }
done

# Set up environment
echo "Setting up environment..."
cat >> "$HOME/.profile" << 'EOF'
export PATH=$PREFIX/bin:$PATH
export LD_LIBRARY_PATH=$PREFIX/lib:$LD_LIBRARY_PATH
export QT_PLUGIN_PATH=$PREFIX/lib/qt6/plugins
export KDE_FULL_SESSION=true
export KDE_SESSION_VERSION=6
export XDG_DATA_DIRS=$PREFIX/share:$XDG_DATA_DIRS
export XDG_CONFIG_DIRS=$PREFIX/etc/xdg:$XDG_CONFIG_DIRS
EOF
source "$HOME/.profile"

# Instructions to run
echo "Build complete! To run Plasma:"
echo "1. Start Termux:X11 app."
echo "2. Run: termux-x11 :0 &"
echo "3. Launch: dbus-launch --exit-with-session startplasma-x11"
echo "All .deb files are in $DEBS_DIR"