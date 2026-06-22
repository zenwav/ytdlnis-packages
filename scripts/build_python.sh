#!/bin/bash
set -e

# PHASE 1 - BUILD
# All four Android ABIs are built here. Termux uses these arch names:
#   aarch64 -> arm64-v8a
#   arm     -> armeabi-v7a
#   i686    -> x86
#   x86_64  -> x86_64
ARCHITECTURES=("aarch64" "arm" "i686" "x86_64")
OUTPUT_BASE_DIR="${PWD}/output"
packages=(
    "python"
    "quickjs-ng"
    "libandroid-support"
    "libffi"
    "libsqlite"
    "openssl"
    "zlib"
    "brotli"
    "readline"
    "gdbm"
    "libbz2"
    "liblzma"
)

# NDK compiler prefix per Termux arch (used by cross-compile step below).
# The API level (24) is appended to the prefix to form the full clang
# binary name, e.g. armv7a-linux-androideabi24-clang.
declare -A NDK_COMPILER_PREFIX=(
    [aarch64]="aarch64-linux-android"
    [arm]="armv7a-linux-androideabi"
    [i686]="i686-linux-android"
    [x86_64]="x86_64-linux-android"
)

for ARCH in "${ARCHITECTURES[@]}"; do
    echo "--- Building for $ARCH ---"
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    # Build python and packages
    for package in "${packages[@]}"; do
        ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "$package"
    done

    # Move generated .deb files
    find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \( -name "*$ARCH*" -o -name "*all*" \) -exec mv {} "$OUTPUT_DIR/" \;
done

# ---------------------------------------------------------------------------
# Cross-compile a Python C-extension package from source using the NDK
# toolchain that ships inside the Termux builder Docker image.
#
# WHY THIS EXISTS:
#   cibuildwheel's Android platform only supports arm64_v8a and x86_64
#   (see ANDROID_TRIPLET in cibuildwheel/platforms/android.py). There is
#   no way to produce 32-bit Android wheels via cibuildwheel. For the
#   two 32-bit ABIs (armeabi-v7a, x86) we instead run pip on the *host*
#   Python (x86_64 Linux, already installed inside the builder image)
#   but override CC/CXX to point at the NDK cross-compiler and patch
#   sysconfig so the compiled .so files get the correct EXT_SUFFIX for
#   the target arch.
#
# LIMITATION:
#   curl_cffi cannot be built this way because it requires a pre-built
#   libcurl-impersonate binary, and the curl-impersonate release only
#   ships aarch64-linux-android and x86_64-linux-android tarballs.
#   So 32-bit ABIs get cffi + pycryptodome but NOT curl_cffi.
# ---------------------------------------------------------------------------
build_packages_from_source() {
    local ARCH="$1"
    local USR_ROOT="$2"
    local SITE_PACKAGES="$3"
    local PYVER_DIR="$4"

    echo "=== Cross-compiling Python packages for $ARCH ==="

    # Locate the NDK inside the Termux builder image.
    local NDK_DIR
    NDK_DIR=$(ls -d "${ANDROID_HOME:-/opt/android-sdk}/ndk/"*/ 2>/dev/null | sort -V | tail -1)
    if [ -z "$NDK_DIR" ]; then
        echo "ERROR: NDK not found under ${ANDROID_HOME:-/opt/android-sdk}/ndk/"
        return 1
    fi
    echo "NDK: $NDK_DIR"

    local TOOLCHAIN="${NDK_DIR}toolchains/llvm/prebuilt/linux-x86_64/bin"
    local PREFIX="${NDK_COMPILER_PREFIX[$ARCH]}"
    local API=24

    # Resolve the Python include directory (e.g. python3.13).
    local PY_INC_DIR
    PY_INC_DIR=$(ls -d "$USR_ROOT/include/python3."* 2>/dev/null | head -1)
    if [ -z "$PY_INC_DIR" ]; then
        echo "ERROR: Python include dir not found under $USR_ROOT/include/"
        return 1
    fi

    # ---- Set up cross-compiler environment ------------------------------
    export CC="${TOOLCHAIN}/${PREFIX}${API}-clang"
    export CXX="${TOOLCHAIN}/${PREFIX}${API}-clang++"
    export AR="${TOOLCHAIN}/llvm-ar"
    export RANLIB="${TOOLCHAIN}/llvm-ranlib"
    export STRIP="${TOOLCHAIN}/llvm-strip"
    # -D__BIONIC_NO_PAGE_SIZE_MACRO is needed because some NDK versions
    # don't define PAGE_SIZE as a macro, and older code expects it.
    export CFLAGS="-I${USR_ROOT}/include -I${PY_INC_DIR} -D__BIONIC_NO_PAGE_SIZE_MACRO -DNDEBUG -O2"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-L${USR_ROOT}/lib -lm"
    export PKG_CONFIG_PATH="${USR_ROOT}/lib/pkgconfig"
    # Tell setuptools/distutils not to add host-specific include/lib dirs.
    export LDSHARED="${CC} -shared"

    echo "CC=$CC"
    echo "CFLAGS=$CFLAGS"

    # ---- Read EXT_SUFFIX / SOABI from the target Python's sysconfig ----
    # The Termux-built Python stores its build configuration in
    # _sysconfigdata__*.py inside the stdlib tree. We parse that file
    # to discover the exact EXT_SUFFIX the target Python expects, then
    # inject it into the host Python via a sitecustomize.py shim so
    # that pip/setuptools produce .so files with the right name.
    local SYSCONFIG_FILE
    SYSCONFIG_FILE=$(find "${USR_ROOT}/lib/${PYVER_DIR}/" -name '_sysconfigdata__*.py' 2>/dev/null | head -1)
    if [ -z "$SYSCONFIG_FILE" ]; then
        echo "ERROR: _sysconfigdata file not found for $ARCH"
        return 1
    fi
    echo "sysconfig: $SYSCONFIG_FILE"

    local EXT_SUFFIX SOABI
    EXT_SUFFIX=$(python3 -c "
import re, sys
content = open('${SYSCONFIG_FILE}').read()
for pat in (r\"'EXT_SUFFIX':\s*'([^']+)'\", r'\"EXT_SUFFIX\":\s*\"([^\"]+)\"'):
    m = re.search(pat, content)
    if m:
        print(m.group(1)); sys.exit(0)
print('.so')
")
    SOABI=$(python3 -c "
import re, sys
content = open('${SYSCONFIG_FILE}').read()
for pat in (r\"'SOABI':\s*'([^']+)'\", r'\"SOABI\":\s*\"([^\"]+)\"'):
    m = re.search(pat, content)
    if m:
        print(m.group(1)); sys.exit(0)
print('')
")
    echo "Target EXT_SUFFIX: $EXT_SUFFIX"
    echo "Target SOABI: $SOABI"

    # ---- Create sitecustomize.py to override sysconfig -----------------
    local PATCH_DIR
    PATCH_DIR=$(mktemp -d)
    cat > "${PATCH_DIR}/sitecustomize.py" << PYEOF
import sysconfig as _sc
_orig_gcv = _sc.get_config_var
_ext_suffix = ${EXT_SUFFIX@Q}
_soabi = ${SOABI@Q}
def _patched_gcv(name, *a, **kw):
    if name == 'EXT_SUFFIX':
        return _ext_suffix
    if name == 'SOABI':
        return _soabi
    return _orig_gcv(name, *a, **kw)
_sc.get_config_var = _patched_gcv

# Also patch sysconfig.get_path so that 'platinclude' and 'include'
# point at the target Python's headers, not the host's.
_orig_get_path = _sc.get_path
_target_inc = ${PY_INC_DIR@Q}
def _patched_get_path(name, *a, **kw):
    if name in ('platinclude', 'include', 'platstdlib', 'stdlib'):
        return _target_inc.rsplit('/', 1)[0] if '/' in _target_inc else _target_inc
    return _orig_get_path(name, *a, **kw)
_sc.get_path = _patched_get_path
PYEOF

    export PYTHONPATH="${PATCH_DIR}:${PYTHONPATH:-}"

    # ---- Ensure pip is available on the host Python --------------------
    if ! python3 -m pip --version >/dev/null 2>&1; then
        echo "pip not found, bootstrapping with ensurepip..."
        python3 -m ensurepip --upgrade
    fi

    # ---- Build and install C-extension packages from source ------------
    # cffi needs libffi headers + lib. The Termux libffi package installs
    # ffi.h into $USR_ROOT/include/ and libffi.so into $USR_ROOT/lib/.
    # Our CFLAGS/LDFLAGS above already point there, but cffi's setup.py
    # also hard-codes include_dirs / library_dirs. We patch setup.py
    # after download to use the Termux paths directly.
    echo "--- Building cffi ---"
    pip download --no-binary :all: --no-deps cffi -d /tmp/cffi_src
    tar -xf /tmp/cffi_src/cffi-*.tar.gz -C /tmp/cffi_src
    local cffi_dir
    cffi_dir=$(ls -d /tmp/cffi_src/cffi-*/)

    # Patch cffi setup.py to find libffi in the Termux sysroot.
    python3 -c "
import os, re
setup_path = os.path.join('${cffi_dir}', 'setup.py')
content = open(setup_path).read()
# Replace include_dirs that reference /usr/include/ffi etc.
content = re.sub(
    r\"include_dirs\s*=\s*\[[^\]]*\]\",
    \"include_dirs = [repr('${USR_ROOT}/include')]\",
    content,
    count=1,
)
content = re.sub(
    r\"library_dirs\s*=\s*\[\]\",
    \"library_dirs = [repr('${USR_ROOT}/lib')]\",
    content,
)
# Disable pkg-config usage so it uses our paths directly.
content = content.replace('def use_pkg_config():', 'def use_pkg_config():\n    return')
open(setup_path, 'w').write(content)
print('Patched cffi setup.py')
"

    python3 -m pip install --no-deps --target="$SITE_PACKAGES" "$cffi_dir"

    echo "--- Building pycryptodome ---"
    python3 -m pip install --no-binary :all: --no-deps --target="$SITE_PACKAGES" pycryptodome

    # ---- Install pure-Python packages (arch-independent) ---------------
    echo "--- Installing pure-python packages ---"
    python3 -m pip install --only-binary=:all: --no-deps --target="$SITE_PACKAGES" mutagen certifi

    # ---- Clean up -------------------------------------------------------
    unset CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_PATH LDSHARED PYTHONPATH
    rm -rf "$PATCH_DIR" /tmp/cffi_src
    echo "=== Cross-compile done for $ARCH ==="
}

# PHASE 2 - EXTRACTION
# NOTE: Output must live under output/ (not the repo root). Termux's
# restricted AppArmor profile (scripts/profile-restricted.apparmor,
# added 2026-02-25) denies writes to anything under the bind-mounted
# repo root except output/**:
#   deny /home/builder/termux-packages/[^o]** wlk,
#   allow /home/builder/termux-packages/output/** rw,
# Creating jniLibs/ at the root therefore fails with "Permission denied".
JNI_OUT_DIR="${OUTPUT_BASE_DIR}/jniLibs"
mkdir -p "$JNI_OUT_DIR"

for ARCH in "${ARCHITECTURES[@]}"; do
    echo "Processing $ARCH..."

    case $ARCH in
        "aarch64") JNI_ARCH="arm64-v8a" ;;
        "arm")     JNI_ARCH="armeabi-v7a" ;;
        "i686")    JNI_ARCH="x86" ;;
        "x86_64")  JNI_ARCH="x86_64" ;;
    esac

    # Create a fresh extraction directory for this arch
    EXTRACT_DIR="${OUTPUT_BASE_DIR}/extract_$ARCH"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"

    # Extract ALL packages into the SAME folder
    for package in "${packages[@]}"; do
        # Find the deb in the arch folder
        deb_file=$(find "${OUTPUT_BASE_DIR}/$ARCH" -name "${package}_*.deb" | head -n 1)

        if [[ -f "$deb_file" ]]; then
            echo "Extracting $deb_file..."
            # Extracting into $EXTRACT_DIR
            dpkg-deb -x "$deb_file" "$EXTRACT_DIR"
        else
            echo "Warning: Could not find deb for $package"
        fi
    done

    # Navigate to the ACTUAL Termux usr folder
    USR_ROOT="$EXTRACT_DIR/data/data/com.termux/files/usr"

    if [ -d "$USR_ROOT" ]; then
        echo "Creating Zip and Binary for $JNI_ARCH"
        mkdir -p "$JNI_OUT_DIR/$JNI_ARCH"

        # Determine python version directory dynamically
        PYTHON_VERSION_DIR=$(ls -d "$USR_ROOT/lib"/python3.* | head -n 1 | xargs basename)
        echo "Detected Python version directory: $PYTHON_VERSION_DIR"
        SITE_PACKAGES="$USR_ROOT/lib/$PYTHON_VERSION_DIR/site-packages"

        # Inject pre-built wheels if they exist (64-bit ABIs from cibuildwheel).
        # For 32-bit ABIs (armeabi-v7a, x86) no pre-built wheels are available
        # because cibuildwheel does not support them; we fall back to
        # cross-compiling cffi + pycryptodome from source instead.
        WHEEL_DIR="${PWD}/curl_cffi_wheels/$JNI_ARCH"
        if [ -d "$WHEEL_DIR" ] && ls "$WHEEL_DIR"/*.whl >/dev/null 2>&1; then
            for wheel in "$WHEEL_DIR"/*.whl; do
                if [[ -f "$wheel" ]]; then
                    echo "Injecting wheel: $wheel into $SITE_PACKAGES"
                    # Unzip wheel directly into site-packages
                    unzip -o "$wheel" -d "$SITE_PACKAGES"
                fi
            done
        else
            echo "No pre-built wheels for $JNI_ARCH — building from source..."
            build_packages_from_source "$ARCH" "$USR_ROOT" "$SITE_PACKAGES" "$PYTHON_VERSION_DIR"
        fi

        # 1. Handle the Binary
        if [ -f "$USR_ROOT/bin/python3" ]; then
            cp "$USR_ROOT/bin/python3" "$JNI_OUT_DIR/$JNI_ARCH/libpython.so"
        fi

        # 2. Handle QuickJS (libqjs.so) if it exists
        if [ -f "$USR_ROOT/lib/libqjs.so" ]; then
            cp "$USR_ROOT/lib/libqjs.so" "$JNI_OUT_DIR/$JNI_ARCH/libqjs.so"
        fi

        # 3. Handle the Zip (Bootstrap)
        # We 'cd' into the files folder so the zip contains usr/ at its root
        cd "$EXTRACT_DIR/data/data/com.termux/files"
        zip --symlinks -r "$JNI_OUT_DIR/$JNI_ARCH/libpython.zip.so" usr/

        echo "Successfully packaged $JNI_ARCH"
    else
        echo "Error: USR_ROOT not found at $USR_ROOT"
    fi

    # Return to project root
    cd "$PWD"
done

echo "Done! Check: $JNI_OUT_DIR"
