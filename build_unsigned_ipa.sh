#!/bin/bash
set -e

# 配置
PROJECT_NAME="ReadApp"
SCHEME="ReadApp"
CONFIGURATION="Release"
BUILD_DIR="./build"
IPA_NAME="${PROJECT_NAME}_unsigned.ipa"

echo "清理旧文件..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "构建 App..."
xcodebuild clean build \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -sdk iphoneos \
    -derivedDataPath "${BUILD_DIR}" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

echo "查找 .app 文件..."
APP_PATH=$(find "${BUILD_DIR}" -name "${PROJECT_NAME}.app" -type d | head -n 1)

if [ -z "${APP_PATH}" ]; then
    echo "找不到 .app 文件！"
    exit 1
fi

echo "打包 IPA..."
mkdir -p "${BUILD_DIR}/Payload"
cp -r "${APP_PATH}" "${BUILD_DIR}/Payload/"
cd "${BUILD_DIR}"
zip -qr "${IPA_NAME}" Payload/
cd - > /dev/null

echo "构建成功！"
