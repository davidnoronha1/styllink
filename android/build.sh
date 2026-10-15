#!/bin/sh
# Build the StylLink Android app without Gradle: aapt2 -> javac -> d8 -> zip,
# align, sign with a local debug key. Needs the Android SDK (platform 36,
# build-tools 36.0.0) in $ANDROID_HOME or ~/Android/Sdk, plus a JDK.
# ./build.sh install   also installs it on the USB-connected tablet.
set -eu
cd "$(dirname "$0")"
SDK=${ANDROID_HOME:-$HOME/Android/Sdk}
BT=$SDK/build-tools/36.0.0
AJ=$SDK/platforms/android-36/android.jar
rm -rf build && mkdir -p build/classes build/gen

"$BT/aapt2" compile --dir res -o build/res.zip
"$BT/aapt2" link -o build/unsigned.apk -I "$AJ" --manifest AndroidManifest.xml \
  --min-sdk-version 30 --target-sdk-version 36 --version-code 1 --version-name 1.0 \
  --java build/gen build/res.zip
javac -nowarn -Xlint:-options -source 11 -target 11 -classpath "$AJ" -d build/classes \
  $(find src build/gen -name '*.java')
"$BT/d8" --min-api 30 --lib "$AJ" --output build $(find build/classes -name '*.class')
(cd build && zip -qj unsigned.apk classes.dex)
"$BT/zipalign" -f -p 4 build/unsigned.apk build/aligned.apk

[ -f debug.keystore ] || keytool -genkeypair -keystore debug.keystore -storepass android -keypass android \
  -alias styllink -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=StylLink debug" >/dev/null 2>&1
"$BT/apksigner" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android \
  --out styllink.apk build/aligned.apk
echo "built android/styllink.apk ($(du -h styllink.apk | cut -f1))"

if [ "${1:-}" = install ]; then adb install -r styllink.apk; fi
