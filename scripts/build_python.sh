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

# NDK compiler prefix per Termux arch. The API level (24) is appended
# to form the full clang binary name, e.g. armv7a-linux-androideabi24-clang.
declare -A NDK_COMPILER_PREFIX=(
    [aarch64]="aarch64-linux-android"
    [arm]="armv7a-linux-androideabi"
    [i686]="i686-linux-android"
    [x86_64]="x86_64-linux-android"
)

# Target machine name returned by platform.uname().machine on the
# target device. Used to create matching entries in curl_cffi's
# libs.json so detect_arch() picks the right one.
declare -A TARGET_MACHINE=(
    [aarch64]="aarch64"
    [arm]="armv7l"
    [i686]="i686"
    [x86_64]="x86_64"
)

# Target pointer size in bytes (struct.calcsize("P")).
declare -A TARGET_PTR_SIZE=(
    [aarch64]=8
    [arm]=4
    [i686]=4
    [x86_64]=8
)

# curl-impersonate arch name used in the libs.json "arch" field
# (determines the download URL, but we skip download since file exists).
declare -A CURL_ARCH_NAME=(
    [aarch64]="aarch64"
    [arm]="arm"
    [i686]="i386"
    [x86_64]="x86_64"
)

for ARCH in "${ARCHITECTURES[@]}"; do
    echo "--- Building for $ARCH ---"
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    for package in "${packages[@]}"; do
        ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "$package"
    done

    find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \( -name "*$ARCH*" -o -name "*all*" \) -exec mv {} "$OUTPUT_DIR/" \;
done

# ---------------------------------------------------------------------------
# Cross-compile Python C-extension packages from source using the NDK
# toolchain that ships inside the Termux builder Docker image.
#
# This function handles 32-bit ABIs (armeabi-v7a, x86) where cibuildwheel
# cannot produce wheels. It builds cffi, pycryptodome, and curl_cffi
# from source by:
#
#   1. Setting up the NDK cross-compiler (CC, CXX, CFLAGS, LDFLAGS, ...)
#   2. Creating a sitecustomize.py that patches:
#      - sysconfig.get_config_var("EXT_SUFFIX") -> target EXT_SUFFIX
#      - sysconfig.get_config_var("SOABI") -> target SOABI
#      - platform.uname().machine -> target machine (for curl_cffi)
#      - struct.calcsize("P") -> target pointer size (for curl_cffi)
#   3. Installing host cffi (for curl_cffi's build-time code generation)
#   4. Cross-compiling cffi, pycryptodome, curl_cffi -> target site-packages
#
# For curl_cffi specifically:
#   - A pre-built libcurl-impersonate.a (from the
#     build_libcurl_impersonate_32bit CI job) is extracted to a temp dir
#   - curl_cffi's libs.json is patched with a 32-bit Android entry whose
#     "libdir" points to the extracted library
#   - CIBW_PLATFORM=android is set so is_android_env() returns True
#   - download_libcurl() finds the pre-built .a and skips downloading
#   - The NDK cross-compiler compiles and links the _wrapper extension
# ---------------------------------------------------------------------------
build_packages_from_source() {
    local ARCH="$1"
    local USR_ROOT="$2"
    local SITE_PACKAGES="$3"
    local PYVER_DIR="$4"
    local JNI_ARCH="$5"

    echo "=== Cross-compiling Python packages for $ARCH ($JNI_ARCH) ==="

    # --- Locate the NDK inside the Termux builder image ---
    local NDK_DIR
    NDK_DIR=$(ls -d "${ANDROID_HOME:-/opt/android-sdk}/ndk/"*/ 2>/dev/null | sort -V | tail -1)
    if [ -z "$NDK_DIR" ]; then
        NDK_DIR=$(ls -d "${HOME}/Android/Sdk/ndk/"*/ 2>/dev/null | sort -V | tail -1)
    fi
    if [ -z "$NDK_DIR" ]; then
        echo "ERROR: NDK not found. Tried ${ANDROID_HOME:-/opt/android-sdk}/ndk/ and ~/Android/Sdk/ndk/"
        return 1
    fi
    echo "NDK: $NDK_DIR"

    local TOOLCHAIN="${NDK_DIR}toolchains/llvm/prebuilt/linux-x86_64/bin"
    local PREFIX="${NDK_COMPILER_PREFIX[$ARCH]}"
    local API=24

    # --- Resolve Python include directory ---
    local PY_INC_DIR
    PY_INC_DIR=$(ls -d "$USR_ROOT/include/python3."* 2>/dev/null | head -1)
    if [ -z "$PY_INC_DIR" ]; then
        echo "ERROR: Python include dir not found under $USR_ROOT/include/"
        return 1
    fi
    echo "Python include: $PY_INC_DIR"

    # --- Set up cross-compiler environment ---
    export CC="${TOOLCHAIN}/${PREFIX}${API}-clang"
    export CXX="${TOOLCHAIN}/${PREFIX}${API}-clang++"
    export AR="${TOOLCHAIN}/llvm-ar"
    export RANLIB="${TOOLCHAIN}/llvm-ranlib"
    export STRIP="${TOOLCHAIN}/llvm-strip"
    export CFLAGS="-I${USR_ROOT}/include -I${PY_INC_DIR} -D__BIONIC_NO_PAGE_SIZE_MACRO -DNDEBUG -O2 -fPIC"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-L${USR_ROOT}/lib -lm"
    export LDSHARED="${CC} -shared"
    export PKG_CONFIG_PATH="${USR_ROOT}/lib/pkgconfig"
    # CPATH and LIBRARY_PATH help the C preprocessor and linker find
    # target headers and libs outside of setuptools' explicit flags.
    export CPATH="${USR_ROOT}/include:${PY_INC_DIR}"
    export LIBRARY_PATH="${USR_ROOT}/lib"

    echo "CC=$CC"
    echo "CFLAGS=$CFLAGS"
    echo "LDFLAGS=$LDFLAGS"

    # --- Read EXT_SUFFIX / SOABI from the target Python's sysconfig ---
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

    local T_MACHINE="${TARGET_MACHINE[$ARCH]}"
    local T_PTR_SIZE="${TARGET_PTR_SIZE[$ARCH]}"
    local T_CURL_ARCH="${CURL_ARCH_NAME[$ARCH]}"
    echo "Target machine: $T_MACHINE"
    echo "Target pointer size: $T_PTR_SIZE bytes"
    echo "curl-impersonate arch: $T_CURL_ARCH"

    # --- Create sitecustomize.py with comprehensive patches ---
    # This file is loaded automatically at Python startup (via PYTHONPATH)
    # and patches sysconfig, platform, and struct so that:
    #   1. setuptools/distutils produces .so files with the target EXT_SUFFIX
    #   2. curl_cffi's detect_arch() picks the correct 32-bit libs.json entry
    local PATCH_DIR
    PATCH_DIR=$(mktemp -d)
    cat > "${PATCH_DIR}/sitecustomize.py" << PYEOF
# Auto-generated by build_python.sh for cross-compilation
# Target: ${ARCH} (${JNI_ARCH})
import sysconfig as _sc
import platform as _platform
import struct as _struct
from collections import namedtuple as _nt

# --- Target configuration (injected from build_python.sh) ---
_target_ext_suffix = ${EXT_SUFFIX@Q}
_target_soabi = ${SOABI@Q}
_target_machine = ${T_MACHINE@Q}
_target_ptr_size = ${T_PTR_SIZE}

# --- Patch sysconfig.get_config_var for EXT_SUFFIX and SOABI ---
# This makes setuptools/distutils name the compiled .so files with the
# target arch's suffix (e.g. .cpython-313-arm-linux-androideabi.so)
# instead of the host's (.cpython-312-x86_64-linux-gnu.so).
_orig_gcv = _sc.get_config_var
def _patched_gcv(name, *a, **kw):
    if name == 'EXT_SUFFIX':
        return _target_ext_suffix
    if name == 'SOABI':
        return _target_soabi
    return _orig_gcv(name, *a, **kw)
_sc.get_config_var = _patched_gcv

# --- Patch platform.uname().machine for curl_cffi's detect_arch() ---
# detect_arch() matches libs.json entries against platform.uname().machine.
# On the host (x86_64) this returns 'x86_64', but we need it to return
# the target arch so the correct libs.json entry is selected.
_orig_uname = _platform.uname
_uname_nt = _nt('uname_result', ['system', 'node', 'release', 'version', 'machine'])
def _patched_uname(*a, **kw):
    u = _orig_uname(*a, **kw)
    return _uname_nt(system=u.system, node=u.node, release=u.release,
                     version=u.version, machine=_target_machine)
_platform.uname = _patched_uname

# --- Patch struct.calcsize("P") for curl_cffi's detect_arch() ---
# detect_arch() computes pointer_size = struct.calcsize("P") * 8.
# On a 64-bit host this is always 64, but we need 32 for 32-bit targets
# so the matching libs.json entry (pointer_size: 32) is selected.
# We ONLY override the "P" format; all other formats pass through.
_orig_calcsize = _struct.calcsize
def _patched_calcsize(fmt, *a, **kw):
    if fmt == 'P':
        return _target_ptr_size
    return _orig_calcsize(fmt, *a, **kw)
_struct.calcsize = _patched_calcsize

print(f'[sitecustomize] Cross-compile patches loaded: machine={_target_machine}, '
      f'ptr_size={_target_ptr_size}, ext_suffix={_target_ext_suffix}')
PYEOF

    # PYTHONPATH includes: patch dir (for sitecustomize.py) + nothing else.
    # We deliberately do NOT add $SITE_PACKAGES here because the target
    # cffi's _cffi_backend.so can't be imported on the host. Instead,
    # we install a host cffi separately for build-time use.
    export PYTHONPATH="${PATCH_DIR}:${PYTHONPATH:-}"

    # --- Ensure pip is available on the host Python ---
    if ! python3 -m pip --version >/dev/null 2>&1; then
        echo "pip not found, bootstrapping with ensurepip..."
        python3 -m ensurepip --upgrade
    fi

    # --- Install host build dependencies ---
    # curl_cffi's build requires cffi>=2.0.0 for code generation (cdef,
    # set_source, emit_c_code). We install a HOST (x86_64) cffi binary
    # wheel so it's importable during the build. The target cffi (for
    # the 32-bit arch) is installed separately to $SITE_PACKAGES.
    echo "--- Installing host build dependencies ---"
    python3 -m pip install --upgrade 'cffi>=2.0.0' setuptools wheel pycparser

    # --- Cross-compile cffi ---
    echo "--- Building cffi for ${ARCH} ---"
    local CFFI_SRC_DIR="/tmp/cffi_src_${ARCH}"
    rm -rf "$CFFI_SRC_DIR"
    mkdir -p "$CFFI_SRC_DIR"
    python3 -m pip download --no-binary :all: --no-deps cffi -d "$CFFI_SRC_DIR"
    tar -xf "$CFFI_SRC_DIR"/cffi-*.tar.gz -C "$CFFI_SRC_DIR"
    local cffi_dir
    cffi_dir=$(ls -d "${CFFI_SRC_DIR}/cffi-"*/)

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

    # --- Cross-compile pycryptodome ---
    echo "--- Building pycryptodome for ${ARCH} ---"
    python3 -m pip install --no-binary :all: --no-deps --target="$SITE_PACKAGES" pycryptodome

    # --- Cross-compile curl_cffi ---
    # This is the most complex part. curl_cffi's build process:
    #   1. scripts/build.py calls detect_arch() which reads libs.json
    #      and matches against platform.uname().machine + pointer_size
    #   2. download_libcurl() checks if libdir/obj_name exists; if so,
    #      it skips the download (our pre-built .a is already there)
    #   3. cffi's FFI class generates C code and compiles _wrapper.so
    #      using the cross-compiler (CC env var) and links against
    #      the pre-built libcurl-impersonate.a via extra_link_args
    local LIBCURL_TARBALL="${PWD}/libcurl_impersonate/${JNI_ARCH}/libcurl-impersonate-${JNI_ARCH}.tar.gz"
    if [ -f "$LIBCURL_TARBALL" ]; then
        echo "--- Building curl_cffi for ${ARCH} ---"
        echo "Using pre-built libcurl-impersonate: $LIBCURL_TARBALL"

        # Extract libcurl-impersonate to a temp dir
        local LIBCURL_EXTRACT_DIR="/tmp/libcurl_${ARCH}"
        rm -rf "$LIBCURL_EXTRACT_DIR"
        mkdir -p "$LIBCURL_EXTRACT_DIR"
        tar xzf "$LIBCURL_TARBALL" -C "$LIBCURL_EXTRACT_DIR"

        # Verify the .a file exists
        if [ ! -f "$LIBCURL_EXTRACT_DIR/lib/libcurl-impersonate.a" ]; then
            echo "ERROR: libcurl-impersonate.a not found in extracted tarball"
            find "$LIBCURL_EXTRACT_DIR" -type f
            return 1
        fi
        echo "libcurl-impersonate.a: $(ls -lh "$LIBCURL_EXTRACT_DIR/lib/libcurl-impersonate.a" | awk '{print $5}')"

        # Download curl_cffi source
        local CURL_CFFI_SRC_DIR="/tmp/curl_cffi_src_${ARCH}"
        rm -rf "$CURL_CFFI_SRC_DIR"
        mkdir -p "$CURL_CFFI_SRC_DIR"
        python3 -m pip download --no-binary :all: --no-deps curl_cffi -d "$CURL_CFFI_SRC_DIR"
        tar -xf "$CURL_CFFI_SRC_DIR"/curl_cffi-*.tar.gz -C "$CURL_CFFI_SRC_DIR"
        local curl_cffi_dir
        curl_cffi_dir=$(ls -d "${CURL_CFFI_SRC_DIR}/curl_cffi-"*/)

        # Patch libs.json to add a 32-bit Android entry whose "libdir"
        # points to where we extracted the pre-built library.
        # detect_arch() will match this entry because:
        #   - system="Android" (CIBW_PLATFORM=android is set below)
        #   - machine matches patched platform.uname().machine
        #   - pointer_size matches patched struct.calcsize("P")*8
        #   - libc="android" (is_android_env() returns True)
        python3 -c "
import json

path = '${curl_cffi_dir}/libs.json'
with open(path) as f:
    archs = json.load(f)

new_entry = {
    'system': 'Android',
    'machine': '${T_MACHINE}',
    'pointer_size': $((T_PTR_SIZE * 8)),
    'sysname': 'linux-android',
    'link_type': 'static',
    'libc': 'android',
    'obj_name': 'libcurl-impersonate.a',
    'arch': '${T_CURL_ARCH}',
    'libdir': '${LIBCURL_EXTRACT_DIR}/lib',
}

# Remove any existing entry with the same system+machine to avoid
# duplicates if the script is re-run.
archs = [a for a in archs
         if not (a.get('system') == new_entry['system']
                 and a.get('machine') == new_entry['machine'])]
archs.append(new_entry)

with open(path, 'w') as f:
    json.dump(archs, f, indent=2)

print(f'Patched curl_cffi libs.json: added Android/{new_entry[\"machine\"]} entry')
print(f'  libdir = {new_entry[\"libdir\"]}')
print(f'  pointer_size = {new_entry[\"pointer_size\"]}')
"

        # Verify the libs.json patch
        echo "=== libs.json Android entries ==="
        python3 -c "
import json
with open('${curl_cffi_dir}/libs.json') as f:
    for a in json.load(f):
        if a.get('system') == 'Android':
            print(json.dumps(a, indent=2))
"

        # Set CIBW_PLATFORM=android so curl_cffi's is_android_env() returns True.
        # This makes detect_arch() set uname_system="Android" and libc="android".
        export CIBW_PLATFORM=android

        # Install curl_cffi with --no-build-isolation so it uses the host
        # cffi (installed above) for code generation instead of creating
        # an isolated build env that would install a different cffi.
        # The cross-compiler (CC) and patched EXT_SUFFIX ensure the
        # compiled _wrapper.so targets the 32-bit arch.
        python3 -m pip install --no-build-isolation --no-deps \
            --target="$SITE_PACKAGES" "$curl_cffi_dir"

        unset CIBW_PLATFORM
        rm -rf "$LIBCURL_EXTRACT_DIR" "$CURL_CFFI_SRC_DIR"
    else
        echo "WARNING: libcurl-impersonate not found at $LIBCURL_TARBALL"
        echo "  Skipping curl_cffi for $JNI_ARCH. The package will not"
        echo "  be available on this architecture."
    fi

    # --- Install pure-Python packages (arch-independent) ---
    echo "--- Installing pure-python packages ---"
    python3 -m pip install --only-binary=:all: --no-deps --target="$SITE_PACKAGES" mutagen certifi

    # --- Verify compiled extensions have the correct EXT_SUFFIX ---
    echo "=== Verifying compiled .so files ==="
    find "$SITE_PACKAGES" -name '*.so' -type f | while read -r sofile; do
        echo "  $(basename "$sofile")"
    done

    # --- Clean up ---
    unset CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS LDSHARED
    unset PKG_CONFIG_PATH CPATH LIBRARY_PATH PYTHONPATH CIBW_PLATFORM
    rm -rf "$PATCH_DIR" "$CFFI_SRC_DIR"
    echo "=== Cross-compile done for $ARCH ($JNI_ARCH) ==="
}

# PHASE 2 - EXTRACTION
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

    EXTRACT_DIR="${OUTPUT_BASE_DIR}/extract_$ARCH"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"

    for package in "${packages[@]}"; do
        deb_file=$(find "${OUTPUT_BASE_DIR}/$ARCH" -name "${package}_*.deb" | head -n 1)
        if [[ -f "$deb_file" ]]; then
            echo "Extracting $deb_file..."
            dpkg-deb -x "$deb_file" "$EXTRACT_DIR"
        else
            echo "Warning: Could not find deb for $package"
        fi
    done

    USR_ROOT="$EXTRACT_DIR/data/data/com.termux/files/usr"

    if [ -d "$USR_ROOT" ]; then
        echo "Creating Zip and Binary for $JNI_ARCH"
        mkdir -p "$JNI_OUT_DIR/$JNI_ARCH"

        PYTHON_VERSION_DIR=$(ls -d "$USR_ROOT/lib"/python3.* | head -n 1 | xargs basename)
        echo "Detected Python version directory: $PYTHON_VERSION_DIR"
        SITE_PACKAGES="$USR_ROOT/lib/$PYTHON_VERSION_DIR/site-packages"

        # Inject pre-built wheels if they exist (64-bit ABIs from cibuildwheel).
        # For 32-bit ABIs, fall back to cross-compiling from source.
        WHEEL_DIR="${PWD}/curl_cffi_wheels/$JNI_ARCH"
        if [ -d "$WHEEL_DIR" ] && ls "$WHEEL_DIR"/*.whl >/dev/null 2>&1; then
            for wheel in "$WHEEL_DIR"/*.whl; do
                if [[ -f "$wheel" ]]; then
                    echo "Injecting wheel: $wheel into $SITE_PACKAGES"
                    unzip -o "$wheel" -d "$SITE_PACKAGES"
                fi
            done
        else
            echo "No pre-built wheels for $JNI_ARCH — building from source..."
            build_packages_from_source "$ARCH" "$USR_ROOT" "$SITE_PACKAGES" "$PYTHON_VERSION_DIR" "$JNI_ARCH"
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
        cd "$EXTRACT_DIR/data/data/com.termux/files"
        zip --symlinks -r "$JNI_OUT_DIR/$JNI_ARCH/libpython.zip.so" usr/

        echo "Successfully packaged $JNI_ARCH"
    else
        echo "Error: USR_ROOT not found at $USR_ROOT"
    fi

    cd "$PWD"
done

echo "Done! Check: $JNI_OUT_DIR"
