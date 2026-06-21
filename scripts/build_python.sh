#!/bin/bash
set -e

# PHASE 1 - BUILD
ARCHITECTURES=("aarch64")
OUTPUT_BASE_DIR="${PWD}/output"
packages=(
    "python"
    "python-cffi"
    "python-pycryptodomex"
    "quickjs"
    "libandroid-support"
    "libffi"
    "libsqlite"
    "openssl"
    "zlib"
    "brotli"
    "readline"
    "libgdbm"
    "libbz2"
    "liblzma"
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

# PHASE 2 - EXTRACTION
JNI_OUT_DIR="${PWD}/jniLibs"
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

        # Inject python wheels if provided (only for arm64-v8a)
        if [[ "$JNI_ARCH" == "arm64-v8a" ]]; then
            WHEEL_DIR="${PWD}/curl_cffi_wheels/$JNI_ARCH"
            if [ -d "$WHEEL_DIR" ]; then
                for wheel in "$WHEEL_DIR"/*.whl; do
                    if [[ -f "$wheel" ]]; then
                        echo "Injecting wheel: $wheel into $SITE_PACKAGES"
                        # Unzip wheel directly into site-packages
                        unzip -o "$wheel" -d "$SITE_PACKAGES"
                    fi
                done
            else
                echo "Warning: Wheel directory $WHEEL_DIR not found"
            fi
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
