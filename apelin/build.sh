#!/bin/sh
# Builds LockScreenRestore here, without Theos: the Logos sources are translated to plain
# Objective-C by apelin/logos2objc.js (run through icli, which has JavaScriptCore), then
# compiled, signed, staged and packaged with the toolchain, ldid and dpkg-deb.
set -eu

: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}" # set, and empty on roothide

root="$APELIN_PROJECT_ROOT"
inc="$root/apelin/vendor/theos-headers"
stage="$(mktemp -d "${TMPDIR:?}/stage.XXXXXX")"
gen="$(mktemp -d "${TMPDIR:?}/gen.XXXXXX")"
trap 'rm -rf -- "${stage:?}" "${gen:?}"' EXIT

if [ ! -f "$inc/Preferences/PSListController.h" ]; then
    echo "missing Preferences headers in apelin/vendor/theos-headers" >&2
    exit 1
fi

echo "==> Translating Logos sources"
for f in Tweak LSRWallpaperPane; do
    sed "s|@@SRC@@|$root/$f.xm|; s|@@DST@@|$gen/$f.m|" "$root/apelin/logos2objc.js" > "$gen/$f.js"
    icli probe "$gen/$f.js" >/dev/null
done

case "$APELIN_BOOTSTRAP" in
    roothide) archs="arm64e" ;;
    *) archs="arm64 arm64e" ;;
esac
echo "==> Building for $APELIN_BOOTSTRAP ($archs)"

cflags="-fobjc-arc -miphoneos-version-min=15.0 -O2 -I$root -I$inc"
frameworks="-framework UIKit -framework Foundation -framework CoreText -framework AVFoundation -framework CoreMedia -framework ImageIO -framework CoreMotion -framework CoreGraphics -framework QuartzCore"

tweak_objs=""
prefs_objs=""
for a in $archs; do
    clang $cflags -arch "$a" -c -o "$gen/Tweak-$a.o" "$gen/Tweak.m"
    clang $cflags -arch "$a" -c -o "$gen/Pane-$a.o" "$gen/LSRWallpaperPane.m"
    clang $cflags -arch "$a" -c -o "$gen/Debug-$a.o" "$root/DebugTools.m"
    clang $cflags -arch "$a" -c -o "$gen/Prefs-$a.o" "$root/lockscreenrestoreprefs/LSRRootListController.m"
    clang -dynamiclib -arch "$a" -miphoneos-version-min=15.0 \
        -install_name /Library/MobileSubstrate/DynamicLibraries/LockScreenRestore.dylib \
        -o "$gen/LockScreenRestore-$a.dylib" \
        "$gen/Tweak-$a.o" "$gen/Pane-$a.o" "$gen/Debug-$a.o" \
        $frameworks -undefined dynamic_lookup 2>/dev/null
    clang -bundle -arch "$a" -miphoneos-version-min=15.0 \
        -o "$gen/LockScreenRestorePrefs-$a" "$gen/Prefs-$a.o" \
        -framework UIKit -framework Foundation -undefined dynamic_lookup 2>/dev/null
    tweak_objs="$tweak_objs $gen/LockScreenRestore-$a.dylib"
    prefs_objs="$prefs_objs $gen/LockScreenRestorePrefs-$a"
done

# shellcheck disable=SC2086
lipo -create $tweak_objs -output "$gen/LockScreenRestore.dylib"
# shellcheck disable=SC2086
lipo -create $prefs_objs -output "$gen/LockScreenRestorePrefs"

echo "==> Signing"
ldid -S "$gen/LockScreenRestore.dylib"
ldid -S "$gen/LockScreenRestorePrefs"

echo "==> Staging"
bundle="$stage$APELIN_PREFIX/Library/PreferenceBundles/LockScreenRestorePrefs.bundle"
mkdir -p "$stage$APELIN_PREFIX/Library/MobileSubstrate/DynamicLibraries" \
         "$bundle" \
         "$stage$APELIN_PREFIX/Library/PreferenceLoader/Preferences" \
         "$stage/DEBIAN"
cp "$gen/LockScreenRestore.dylib" "$stage$APELIN_PREFIX/Library/MobileSubstrate/DynamicLibraries/"
cp "$root/LockScreenRestore.plist" "$stage$APELIN_PREFIX/Library/MobileSubstrate/DynamicLibraries/"
cp "$gen/LockScreenRestorePrefs" "$bundle/"
cp "$root/lockscreenrestoreprefs/Resources/Info.plist" "$bundle/"
cp "$root/lockscreenrestoreprefs/Resources/Root.plist" "$bundle/"
cp "$root/lockscreenrestoreprefs/Resources"/icon*.png "$bundle/"
cp -R "$root/lockscreenrestoreprefs/Resources/en.lproj" "$bundle/"
cp -R "$root/lockscreenrestoreprefs/Resources/zh-Hans.lproj" "$bundle/"
cp "$root/lockscreenrestoreprefs/entry.plist" \
   "$stage$APELIN_PREFIX/Library/PreferenceLoader/Preferences/LockScreenRestorePrefs.plist"

sed "s/^Architecture:.*/Architecture: $APELIN_ARCHITECTURE/" "$root/control" > "$stage/DEBIAN/control"

echo "==> Packaging"
dpkg-deb -b --root-owner-group "$stage" "$APELIN_PACKAGE_DIR/" >/dev/null
ls -l "$APELIN_PACKAGE_DIR"
