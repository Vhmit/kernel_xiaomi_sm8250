#!/bin/bash
#
# Compile script for Mimir Kernel (sm8250 / Kona)
# Copyright (C) 2026 Vhmit <viktor.9630@protonmail.com>

# Colors
NC='\033[0m'
RED='\033[0;31m'
LRD='\033[1;31m'
LGR='\033[1;32m'
YLW='\033[0;33m'

# Trap Ctrl+C
handle_interrupt() {
    echo -e "\n${YLW}Build interrupted by user. Exiting...${NC}"
    DIFF=$SECONDS
    TIME_INT="$((DIFF / 60)) minute(s) and $((DIFF % 60)) second(s)"
    [ ! -z "$GITHUB_ENV" ] && echo "BUILD_DURATION=$TIME_INT" >> "$GITHUB_ENV"
    exit 130
}
trap handle_interrupt SIGINT

# Device + flags
DEVICE="$1"
shift

ZIP_FLAG=false
KSU_FLAG=false

for arg in "$@"; do
    case "$arg" in
        -z)   ZIP_FLAG=true ;;
        -ksu) KSU_FLAG=true ;;
    esac
done

if [ -z "$DEVICE" ]; then
    echo -e "${RED}Error: No device specified!${NC}"
    echo -e "Usage: ./build.sh <device_name> [-z] [-ksu]"
    echo -e "Example: ./build.sh alioth"
    echo -e "Example: ./build.sh alioth -z"
    echo -e "Example: ./build.sh alioth -z -ksu"
    exit 1
fi

# Dependencies
check_deps() {
    echo -e "${YLW}########### Checking Dependencies ############${NC}"
    local deps=("bc" "zip" "curl" "git" "make" "python3" "sha256sum" "jq" "perl")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo -e "${RED}Error: $dep is not installed.${NC}"
            exit 1
        fi
    done
    echo -e "${LGR}Dependencies: OK!${NC}"
}

# Variables
TM=$(date '+%Y%m%d-%H%M')
kernel_dir="${PWD}"
objdir="${kernel_dir}/out"
anykernel="$HOME/anykernel"
TC_DIR="${kernel_dir}/tc"
kernel_name="Mimir"
LOG_FILE="${PWD}/build_log.txt"

if [ "$ZIP_FLAG" = true ] && [ "$KSU_FLAG" = true ]; then
    zip_name="${kernel_name}-KSU-${DEVICE}-${TM}.zip"
else
    zip_name="${kernel_name}-${DEVICE}-${TM}.zip"
fi

# Clang
export PATH="$TC_DIR/bin:$PATH"
if [ ! -d "$TC_DIR" ]; then
    echo "AOSP clang not found! Cloning..."
    if ! git clone --depth=1 https://gitlab.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-r596125 "$TC_DIR"; then
        echo "Cloning failed! Aborting..."
        exit 1
    fi
fi

echo -e "${LGR}######### Clang version #########${NC}"
CLANG_FULL=$($TC_DIR/bin/clang --version | head -n 1)
VER=$(echo "$CLANG_FULL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
REV=$(echo "$CLANG_FULL" | grep -oE 'r[0-9]+' | head -n1)
CLANG_VER="${VER}${REV:+ ($REV)}"
echo -e "${YLW}Clang version: ${CLANG_VER}${NC}"
[ ! -z "$GITHUB_ENV" ] && echo "CLANG_VERSION=$CLANG_VER" >> "$GITHUB_ENV"

# Exports
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_HOST=viktor
export KBUILD_BUILD_USER=vhmit

clean_all() {
    echo -e "${YLW}########### Cleaning Output Directory ############${NC}"
    rm -rf "${objdir}" "$LOG_FILE" *.zip
}

make_defconfig() {
    echo -e "${LGR}########### Generating Defconfig ############${NC}"

    if [ ! -f "arch/arm64/configs/${DEVICE}_defconfig" ]; then
        echo -e "${RED}Error: ${DEVICE}_defconfig not found!${NC}"
        exit 1
    fi

    make -s O="${objdir}" ARCH=$ARCH CC=clang ${DEVICE}_defconfig LLVM=1 LLVM_IAS=1

    # DroidSpaces support
    if [ "$ENABLE_DROIDSPACES" = true ]; then
        if [ -f "build.config.droidspaces" ]; then
            echo -e "${LGR}Applying DroidSpaces config fragment...${NC}"
            cat build.config.droidspaces >> "${objdir}/.config"
            make -s O="${objdir}" ARCH=$ARCH olddefconfig
        else
            echo -e "${YLW}Warning: build.config.droidspaces not found. Continuing without it.${NC}"
        fi
    fi

    # KernelSU
    if [ "$KSU_FLAG" = true ]; then
        echo -e "${LGR}KernelSU flag enabled – ensure KernelSU is already integrated in the tree.${NC}"
        # curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
    fi
}

compile_headers() {
    echo -e "${YLW}########### Compiling Headers ############${NC}"
    local HDR_PATH="${objdir}/arch/arm64/boot/usr"
    make -j$(nproc --all) O=${objdir} ARCH=${ARCH} CC=clang LLVM=1 LLVM_IAS=1 \
         INSTALL_HDR_PATH="$HDR_PATH" headers_install
    find "$HDR_PATH" -type f \( -name ".install" -o -name "..install.cmd" \) -delete
    echo -e "${LGR}Headers ready: $HDR_PATH${NC}"
}

compile() {
    echo -e "${LGR}########### Compiling kernel ############${NC}"
    local TEMP_LOG=$(mktemp)
    set -o pipefail

    make -j$(nproc --all) O="${objdir}" ARCH=${ARCH} \
        CC=clang LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm \
        OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
        CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
        LLVM=1 LLVM_IAS=1 2>&1 | tee "$TEMP_LOG"

    local exit_status=$?
    set +o pipefail

    if [ $exit_status -ne 0 ]; then
        [ $exit_status -eq 130 ] && exit 130
        echo -e "${RED}Compilation failed!${NC}"
        mv "$TEMP_LOG" "$LOG_FILE"
        RESPONSE=$(curl -s -F "content=@$LOG_FILE" https://bin.cyberknight777.dev)
        if [[ "$RESPONSE" == *"bin.cyberknight777.dev"* ]]; then
            echo -e "${YLW}Rustbin Log: ${LGR}${RESPONSE}${NC}"
            [ ! -z "$GITHUB_ENV" ] && echo "ERROR_LOG_URL=$RESPONSE" >> "$GITHUB_ENV"
            rm -f "$LOG_FILE"
        else
            echo -e "${RED}Upload failed. Check build_log.txt${NC}"
        fi
        exit $exit_status
    else
        rm -f "$TEMP_LOG"
        echo -e "${LGR}Kernel compiled successfully!${NC}"
    fi
}

completion() {
    LOCAL_BOOT="${objdir}/arch/arm64/boot"

    if [[ -f "${LOCAL_BOOT}/Image" ]]; then
        echo -e "${LGR}######### Packaging AnyKernel3 #########${NC}"

        rm -rf "$anykernel"
        git clone --depth=1 --single-branch -b "${DEVICE}" https://github.com/Vhmit/AnyKernel3.git "$anykernel"

        # DTB handling
        [[ -f "${LOCAL_BOOT}/dtb.img" ]] && mv "${LOCAL_BOOT}/dtb.img" "${LOCAL_BOOT}/dtb"

        cp -f "${LOCAL_BOOT}/Image" "$anykernel/"
        [[ -f "${LOCAL_BOOT}/dtb" ]] && cp -f "${LOCAL_BOOT}/dtb" "$anykernel/"
        [[ -f "${LOCAL_BOOT}/dtbo.img" ]] && cp -f "${LOCAL_BOOT}/dtbo.img" "$anykernel/"

        cd "$anykernel" || exit 1
        find . -name "*.zip" -type f -delete
        zip -r9 AnyKernel.zip * -x .git README.md *placeholder
        cp AnyKernel.zip "$kernel_dir/$zip_name"
        cd "$kernel_dir" || exit 1
        rm -rf "$anykernel"

        echo -e "${LGR}####### Kernel packaged successfully! #######${NC}"

        SHA256=$(sha256sum "$zip_name" | awk '{print $1}')
        echo -e "${YLW}SHA256: ${NC}${SHA256}"
        [ ! -z "$GITHUB_ENV" ] && echo "ZIP_SHA256=$SHA256" >> "$GITHUB_ENV"

        if [ "$DO_UPLOAD" = true ]; then
            echo -e "${YLW}Uploading to Gofile...${NC}"
            SERVER=$(curl -s https://api.gofile.io/servers | jq -r '.data.servers[0].name // "store1"')
            [ ! -z "$GITHUB_ENV" ] && echo "GOFILE_SERVER=$SERVER" >> "$GITHUB_ENV"
            RESPONSE=$(curl -# -L -F "file=@$zip_name" "https://${SERVER}.gofile.io/contents/uploadfile")

            if echo "$RESPONSE" | jq -e '.status == "ok"' >/dev/null 2>&1; then
                DOWNLOAD_LINK=$(echo "$RESPONSE" | jq -r '.data.downloadPage')
                echo -e "${LGR}Download: ${NC}${DOWNLOAD_LINK}"
                [ ! -z "$GITHUB_ENV" ] && echo "ZIP_DOWNLOAD_LINK=$DOWNLOAD_LINK" >> "$GITHUB_ENV"
            else
                echo -e "${RED}Upload failed!${NC}"
                [ ! -z "$GITHUB_ENV" ] && echo "ZIP_DOWNLOAD_LINK=" >> "$GITHUB_ENV"
            fi
        else
            echo -e "${YLW}Gofile upload skipped.${NC}"
        fi
    fi
}

# ========== Execution ==========
check_deps

DO_UPLOAD=false
ENABLE_DROIDSPACES=false
COMPILE_HDR=false

# Modo CI / GitHub Actions
if [ -n "$GITHUB_ACTIONS" ] || [ -n "$CI" ]; then
    DO_UPLOAD=true
    case "${ENABLE_DROIDSPACES,,}" in
        y|yes|true|1) ENABLE_DROIDSPACES=true ;;
        *)            ENABLE_DROIDSPACES=false ;;
    esac
else
    if [ "$ZIP_FLAG" = true ]; then
        echo -ne "${YLW}Enable DroidSpaces support? (y/N): ${NC}"
        read -r DROID_CHOICE
        case "$DROID_CHOICE" in
            [yY]|[yY][eE][sS]) ENABLE_DROIDSPACES=true ;;
        esac

        echo -ne "${YLW}Upload ZIP to Gofile? (y/N): ${NC}"
        read -r UPLOAD_CHOICE
        case "$UPLOAD_CHOICE" in
            [yY]|[yY][eE][sS]) DO_UPLOAD=true ;;
        esac
    else
        echo -ne "${YLW}Compile headers? (y/N): ${NC}"
        read -r HDR_CHOICE
        case "$HDR_CHOICE" in
            [yY]|[yY][eE][sS]) COMPILE_HDR=true ;;
        esac
    fi
fi

# Export branch info for Actions
[ -n "$GITHUB_ENV" ] && {
    echo "BUILD_BRANCH=${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}" >> "$GITHUB_ENV"
}

clean_all
SECONDS=0
make_defconfig
compile

DIFF=$SECONDS
BUILD_TIME="$((DIFF / 60)) minute(s) and $((DIFF % 60)) second(s)"
[ -n "$GITHUB_ENV" ] && echo "BUILD_DURATION=$BUILD_TIME" >> "$GITHUB_ENV"

if [ -f "${objdir}/arch/arm64/boot/Image" ]; then
    if [ "$ZIP_FLAG" = true ]; then
        completion
    else
        echo -e "\n${YLW}Flag -z not set. Skipping ZIP.${NC}"
        [ "$COMPILE_HDR" = true ] && compile_headers
        echo -e "Files in: ${objdir}/arch/arm64/boot/"
    fi
    echo -e "\n${LGR}Completed successfully in: $BUILD_TIME${NC}"
else
    echo -e "\n${RED}Kernel compilation failed!${NC}"
    echo -e "Elapsed: $BUILD_TIME"
    exit 1
fi

cd "${kernel_dir}" || exit 1
