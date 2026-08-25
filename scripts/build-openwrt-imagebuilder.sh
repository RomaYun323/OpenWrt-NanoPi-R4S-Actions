#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# WSL inherits Windows PATH entries containing spaces. GNU find rejects those
# during ImageBuilder's secure -execdir phase, so use Linux tool paths only.
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
settings_file="$project_root/configs/build-settings.conf"
image_settings_file="$project_root/configs/image-settings.conf"
extra_packages_file="$project_root/configs/extra-packages.conf"
third_party_packages_file="$project_root/configs/third-party-packages.conf"
target='rockchip'
subtarget='armv8'
profile='friendlyarm_nanopi-r4s'
jobs="${OPENWRT_JOBS:-$(nproc)}"
selection_mode="${OPENWRT_SELECTION_MODE:-config}"
prepare_only="${OPENWRT_PREPARE_ONLY:-false}"
validate_only="${OPENWRT_VALIDATE_ONLY:-false}"
cache_root="${OPENWRT_IMAGEBUILDER_CACHE:-$project_root/.cache/imagebuilder}"
work_root="${OPENWRT_IMAGEBUILDER_WORK:-$project_root/.imagebuilder-work}"
output_root="${OPENWRT_IMAGEBUILDER_OUTPUT:-$project_root/.imagebuilder-output}"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

run_logged() {
    local label="$1"
    local logfile="$2"
    shift 2
    printf '%s...\n' "$label"
    if ! "$@" >> "$logfile" 2>&1; then
        tail -n 120 "$logfile" >&2 || true
        die "$label failed; full log: $logfile"
    fi
}

validate_boolean() {
    local name="$1"
    local value="$2"
    [[ "$value" == 'true' || "$value" == 'false' ]] || die "$name must be true or false"
}

read_setting() {
    local file="$1"
    local key="$2"
    local value count
    [[ -f "$file" ]] || die "Missing settings file: $file"
    count="$(sed 's/\r$//' "$file" | grep -Ec "^${key}=\"[^\"]*\"$" || true)"
    [[ "$count" == '1' ]] || die "$file must contain exactly one valid $key setting"
    value="$(sed -e 's/\r$//' -n -e "s/^${key}=\"\([^\"]*\)\"$/\1/p" "$file")"
    printf '%s' "$value"
}

enabled_in_file() {
    local file="$1"
    local package="$2"
    grep -Fqx "$package" "$file"
}

append_enabled_packages() {
    local file="$1"
    local raw line
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line="${raw%$'\r'}"
        [[ "$line" =~ ^[a-z0-9][a-z0-9+_.-]*$ ]] || continue
        image_packages+=("$line")
    done < "$file"
}

deduplicate_image_packages() {
    local package
    local -A seen=()
    local -a unique=()
    for package in "${image_packages[@]}"; do
        if [[ -z "${seen[$package]+x}" ]]; then
            seen["$package"]=1
            unique+=("$package")
        fi
    done
    image_packages=("${unique[@]}")
}

manifest_package_names() {
    local manifest="$1"
    if grep -qF ' - ' "$manifest"; then
        sed -n 's/ - .*//p' "$manifest"
    else
        awk 'NF { print $1 }' "$manifest"
    fi | LC_ALL=C sort -u
}

download_file() {
    local url="$1"
    local destination="$2"
    local temporary="$destination.part"
    if [[ ! -f "$destination" ]]; then
        printf 'Downloading %s\n' "$(basename "$destination")"
        curl --fail --location --retry 3 --output "$temporary" "$url"
        mv -- "$temporary" "$destination"
    fi
}

verify_download() {
    local sums_file="$1"
    local filename="$2"
    local directory="$3"
    local expected
    expected="$(awk -v file="$filename" '$2 == file || $2 == "*" file { print $1 }' "$sums_file")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "Missing checksum for $filename"
    printf '%s  %s\n' "$expected" "$directory/$filename" | sha256sum --check --status \
        || die "Checksum mismatch: $filename"
}

find_tool_archive() {
    local sums_file="$1"
    local kind="$2"
    local matches
    matches="$(awk -v kind="$kind" -v target="$target" -v subtarget="$subtarget" \
        '$2 ~ ("openwrt-" kind ".*" target "-" subtarget ".*Linux-x86_64\\.tar\\.zst$") {
            sub(/^\*/, "", $2); print $2
        }' \
        "$sums_file")"
    [[ "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l)" == '1' ]] \
        || die "Unable to identify one $kind archive"
    printf '%s' "$matches"
}

extract_archive() {
    local archive="$1"
    local destination="$2"
    mkdir -p "$destination"
    tar --zstd --extract --file "$archive" --directory "$destination" --strip-components=1
}

configured_channel="$(read_setting "$settings_file" build_channel)"
configured_release="$(read_setting "$settings_file" release_version)"
configured_language="$(read_setting "$settings_file" luci_language)"
configured_extra="$(read_setting "$settings_file" include_extra_packages)"
configured_third_party="$(read_setting "$settings_file" include_third_party_packages)"
configured_rootfs_size="$(read_setting "$image_settings_file" rootfs_partsize_mib)"
configured_squashfs="$(read_setting "$image_settings_file" build_squashfs)"
configured_ext4="$(read_setting "$image_settings_file" build_ext4)"

build_channel="${OPENWRT_BUILD_CHANNEL:-$configured_channel}"
release_version="${OPENWRT_RELEASE_VERSION:-$configured_release}"
luci_language="${OPENWRT_LUCI_LANGUAGE:-$configured_language}"
rootfs_size="${OPENWRT_ROOTFS_PARTSIZE_MIB:-$configured_rootfs_size}"
build_squashfs="${OPENWRT_BUILD_SQUASHFS:-$configured_squashfs}"
build_ext4="${OPENWRT_BUILD_EXT4:-$configured_ext4}"
enable_extra="${OPENWRT_ENABLE_EXTRA_PACKAGES:-$configured_extra}"
enable_third_party="${OPENWRT_ENABLE_THIRD_PARTY_PACKAGES:-$configured_third_party}"

[[ "$build_channel" == 'release' || "$build_channel" == 'snapshot' ]] || die 'Invalid build channel'
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid release version'
[[ "$luci_language" == 'zh_Hant' || "$luci_language" == 'en' ]] || die 'Invalid LuCI language'
[[ "$rootfs_size" =~ ^[1-9][0-9]{0,6}$ ]] || die 'Invalid rootfs size'
[[ "$selection_mode" == 'config' || "$selection_mode" == 'inputs' ]] || die 'Invalid selection mode'
validate_boolean OPENWRT_BUILD_SQUASHFS "$build_squashfs"
validate_boolean OPENWRT_BUILD_EXT4 "$build_ext4"
validate_boolean OPENWRT_ENABLE_EXTRA_PACKAGES "$enable_extra"
validate_boolean OPENWRT_ENABLE_THIRD_PARTY_PACKAGES "$enable_third_party"
validate_boolean OPENWRT_PREPARE_ONLY "$prepare_only"
validate_boolean OPENWRT_VALIDATE_ONLY "$validate_only"
[[ "$build_squashfs" == 'true' || "$build_ext4" == 'true' ]] || die 'Select at least one filesystem'

if [[ "$selection_mode" == 'inputs' ]]; then
    enable_aurora="${OPENWRT_ENABLE_AURORA:-true}"
    enable_arwi="${OPENWRT_ENABLE_ARWI:-true}"
    enable_bandix="${OPENWRT_ENABLE_BANDIX:-true}"
    enable_adguardhome="${OPENWRT_ENABLE_ADGUARDHOME:-true}"
else
    if [[ "$enable_third_party" == 'true' ]]; then
        enabled_in_file "$third_party_packages_file" luci-theme-aurora && enable_aurora=true || enable_aurora=false
        enabled_in_file "$third_party_packages_file" luci-app-arwi-dashboard && enable_arwi=true || enable_arwi=false
        enabled_in_file "$third_party_packages_file" bandix && enable_bandix=true || enable_bandix=false
        enabled_in_file "$third_party_packages_file" luci-app-adguardhome && enable_adguardhome=true || enable_adguardhome=false
    else
        enable_aurora=false
        enable_arwi=false
        enable_bandix=false
        enable_adguardhome=false
    fi
fi
validate_boolean OPENWRT_ENABLE_AURORA "$enable_aurora"
validate_boolean OPENWRT_ENABLE_ARWI "$enable_arwi"
validate_boolean OPENWRT_ENABLE_BANDIX "$enable_bandix"
validate_boolean OPENWRT_ENABLE_ADGUARDHOME "$enable_adguardhome"

if [[ "$validate_only" == 'true' ]]; then
    printf 'ImageBuilder configuration validation passed.\n'
    exit 0
fi

if [[ "$build_channel" == 'release' ]]; then
    base_url="https://downloads.openwrt.org/releases/$release_version/targets/$target/$subtarget"
    release_label="$release_version"
else
    base_url="https://downloads.openwrt.org/snapshots/targets/$target/$subtarget"
    release_label='snapshot'
fi

mkdir -p "$cache_root/metadata" "$cache_root/downloads"
metadata_dir="$cache_root/metadata/$release_label"
mkdir -p "$metadata_dir"
curl --fail --location --retry 3 --output "$metadata_dir/sha256sums" "$base_url/sha256sums"
curl --fail --location --retry 3 --output "$metadata_dir/version.buildinfo" "$base_url/version.buildinfo"
official_revision="$(tr -d '\r\n' < "$metadata_dir/version.buildinfo")"
[[ "$official_revision" =~ ^r[0-9]+-[0-9a-f]+$ ]] || die 'Invalid official version.buildinfo'
build_id="${release_label}-${official_revision}"
download_dir="$cache_root/downloads/$build_id"
mkdir -p "$download_dir"
imagebuilder_archive="$(find_tool_archive "$metadata_dir/sha256sums" imagebuilder)"
sdk_archive="$(find_tool_archive "$metadata_dir/sha256sums" sdk)"
download_file "$base_url/$imagebuilder_archive" "$download_dir/$imagebuilder_archive"
download_file "$base_url/$sdk_archive" "$download_dir/$sdk_archive"
verify_download "$metadata_dir/sha256sums" "$imagebuilder_archive" "$download_dir"
verify_download "$metadata_dir/sha256sums" "$sdk_archive" "$download_dir"

[[ "$work_root" != '/' && "$output_root" != '/' && "$cache_root" != '/' ]] || die 'Unsafe working path'
work_marker="$work_root/.official-build-id"
reuse_sdk=false
if [[ -f "$work_marker" && -f "$work_root/sdk/rules.mk" ]]; then
    [[ "$(tr -d '\r\n' < "$work_marker")" == "$build_id" ]] && reuse_sdk=true
fi
if [[ "$reuse_sdk" != 'true' ]]; then
    rm -rf -- "$work_root"
    mkdir -p "$work_root/sdk"
    extract_archive "$download_dir/$sdk_archive" "$work_root/sdk"
    printf '%s\n' "$build_id" > "$work_marker"
else
    printf 'Reusing prepared SDK: %s\n' "$build_id"
fi
rm -rf -- "$work_root/imagebuilder" "$work_root/sources" \
    "$work_root/custom-repository" "$work_root/overlay"
mkdir -p "$work_root/imagebuilder" "$work_root/sources" "$work_root/custom-repository" "$work_root/overlay"
extract_archive "$download_dir/$imagebuilder_archive" "$work_root/imagebuilder"
sdk_dir="$work_root/sdk"
imagebuilder_dir="$work_root/imagebuilder"

export UPDATE_AURORA="$enable_aurora"
export UPDATE_ARWI="$enable_arwi"
export UPDATE_BANDIX="$enable_bandix"
export UPDATE_ADGUARDHOME="$enable_adguardhome"
resolved_sources="$work_root/third-party-sources.buildinfo"
if [[ "$enable_aurora" == 'true' || "$enable_arwi" == 'true' || "$enable_bandix" == 'true' || "$enable_adguardhome" == 'true' ]]; then
    python3 "$project_root/scripts/update-third-party-locks.py" --resolve-output "$resolved_sources"
else
    : > "$resolved_sources"
fi

if [[ ! -f "$sdk_dir/.custom-feeds-ready" ]]; then
    feeds_log="$work_root/sdk-feeds.log"
    if ! (
        cd "$sdk_dir"
        ./scripts/feeds update -a
        # Install only definitions needed to package the selected custom apps.
        # ImageBuilder obtains all remaining official packages from OpenWrt's
        # signed repositories, so installing every SDK feed is unnecessary.
        ./scripts/feeds install \
            luci luci-compat luci-lib-jsonc curl zoneinfo-all conntrack iw
        touch .custom-feeds-ready
    ) > "$feeds_log" 2>&1; then
        tail -n 120 "$feeds_log" >&2 || true
        die "SDK feeds preparation failed; full log: $feeds_log"
    fi
    printf 'SDK feeds prepared.\n'
fi

# LuCI package recipes invoke these two small host utilities directly.  Build
# them once inside the reusable SDK without compiling target dependencies.
package_log="$work_root/sdk-package-build.log"
: > "$package_log"
run_logged 'Preparing LuCI host tools' "$package_log" \
    make -C "$sdk_dir/feeds/luci/modules/luci-base" TOPDIR="$sdk_dir" host-compile
export PATH="$sdk_dir/staging_dir/host/bin:$PATH"

# The official LuCI feed also contains luci-app-adguardhome.  When the newer
# third-party version is selected, remove only that feed symlink so metadata is
# generated from the source resolved above.
if [[ "$enable_adguardhome" == 'true' ]]; then
    official_adguardhome="$sdk_dir/package/feeds/luci/luci-app-adguardhome"
    if [[ -L "$official_adguardhome" ]]; then
        expected_adguardhome="$sdk_dir/feeds/luci/applications/luci-app-adguardhome"
        actual_adguardhome="$(readlink -f "$official_adguardhome")"
        [[ "$actual_adguardhome" == "$expected_adguardhome" ]] \
            || die "Refusing to remove unexpected AdGuardHome package link: $official_adguardhome"
        unlink "$official_adguardhome"
    fi
fi

custom_packages=()
while read -r name url ref commit extra; do
    [[ -z "${name:-}" ]] && continue
    [[ -z "${extra:-}" && "$commit" =~ ^[0-9a-f]{40}$ ]] || die "Invalid resolved source: $name"
    source_dir="$work_root/sources/$name"
    git init --quiet "$source_dir"
    git -C "$source_dir" remote add origin "$url"
    git -C "$source_dir" fetch --quiet --depth 1 origin "$commit"
    git -C "$source_dir" checkout --quiet --detach "$commit"
    package_dir="$sdk_dir/package/$name"
    rm -rf -- "$package_dir"
    cp -a "$source_dir" "$package_dir"
    rm -rf -- "$package_dir/.git"
    if [[ "$name" == 'luci-app-adguardhome' ]]; then
        git -C "$package_dir" apply "$project_root/patches/luci-app-adguardhome-luci-compat.patch"
        # OpenWrt's official LuCI feed now ships a date-based version of the
        # same package name.  Give this upstream v1.19 package a higher local
        # packaging version so APK selects the freshly resolved custom source.
        sed -i -E 's/^PKG_VERSION:=/PKG_VERSION:=99./' "$package_dir/Makefile"
    fi
    custom_packages+=("$name")
done < "$resolved_sources"

if ((${#custom_packages[@]} > 0)); then
    {
        printf 'CONFIG_LUCI_LANG_%s=y\n' "$luci_language"
        for name in "${custom_packages[@]}"; do
            printf 'CONFIG_PACKAGE_%s=m\n' "$name"
        done
    } >> "$sdk_dir/.config"
    run_logged 'Generating SDK package metadata' "$package_log" make -C "$sdk_dir" defconfig
    if grep -q '^CONFIG_SIGN_EACH_PACKAGE=y$' "$sdk_dir/.config" && [[ ! -s "$sdk_dir/private-key.pem" ]]; then
        run_logged 'Generating SDK package signing key' "$package_log" \
            "$sdk_dir/staging_dir/host/bin/openssl" ecparam -name prime256v1 \
            -genkey -noout -out "$sdk_dir/private-key.pem"
        chmod 0600 "$sdk_dir/private-key.pem"
    fi
    mkdir -p "$sdk_dir/bin/packages"
    for name in "${custom_packages[@]}"; do
        package_dir="$sdk_dir/package/$name"
        makefile="$(find "$package_dir" -maxdepth 2 -type f -name Makefile -print -quit)"
        [[ -n "$makefile" ]] || die "No Makefile found for $name"
        relative_package_dir="${makefile%/Makefile}"
        relative_package_dir="${relative_package_dir#"$sdk_dir/"}"
        find "$sdk_dir/bin/packages" -type f -name "$name-*.apk" -delete
        run_logged "Cleaning $name" "$package_log" \
            make -C "$sdk_dir/$relative_package_dir" TOPDIR="$sdk_dir" clean
        run_logged "Packaging $name" "$package_log" \
            make -C "$sdk_dir/$relative_package_dir" TOPDIR="$sdk_dir" -j"$jobs" compile
    done
fi

image_packages=(luci luci-app-attendedsysupgrade)
if [[ "$luci_language" == 'zh_Hant' ]]; then
    image_packages+=(luci-i18n-base-zh-tw)
fi
if [[ "$enable_extra" == 'true' ]]; then
    append_enabled_packages "$extra_packages_file"
fi

for name in "${custom_packages[@]}"; do
    matches=()
    while IFS= read -r apk; do matches+=("$apk"); done < <(find "$sdk_dir/bin/packages" -type f -name "$name-*.apk" -print)
    ((${#matches[@]} > 0)) || die "SDK did not produce $name APK"
    cp -a "${matches[@]}" "$work_root/custom-repository/"
    image_packages+=("$name")

    if [[ "$luci_language" == 'zh_Hant' && "$name" == luci-app-* ]]; then
        translation="luci-i18n-${name#luci-app-}-zh-tw"
        translation_apk="$(find "$sdk_dir/bin/packages" -type f -name "$translation-*.apk" -print -quit)"
        if [[ -n "$translation_apk" ]]; then
            cp -a "$translation_apk" "$work_root/custom-repository/"
        fi
    fi
done

deduplicate_image_packages

mkdir -p "$imagebuilder_dir/packages"
cp -a "$work_root/custom-repository/." "$imagebuilder_dir/packages/"
cp -a "$project_root/files/." "$work_root/overlay/"
if [[ "$enable_aurora" != 'true' ]]; then
    rm -f -- "$work_root/overlay/etc/apk/keys/eamonxg.pem" "$work_root/overlay/etc/apk/repositories.d/customfeeds.list"
fi

printf 'Official image source: %s (%s)\n' "$base_url" "$official_revision"
printf 'Third-party sources: %s package(s), latest stable refs resolved\n' "${#custom_packages[@]}"
printf 'Image packages: %s\n' "${image_packages[*]}"
if [[ "$prepare_only" == 'true' ]]; then
    printf 'SDK and ImageBuilder preparation completed.\n'
    exit 0
fi

base_manifest_file="$work_root/base-packages.manifest"
manifest_file="$work_root/final-packages.manifest"
make --no-print-directory -C "$imagebuilder_dir" manifest \
    PROFILE="$profile" \
    PACKAGES="${image_packages[*]}" \
    STRIP_ABI=1 \
    > "$base_manifest_file"
[[ -s "$base_manifest_file" ]] || die 'ImageBuilder produced an empty package manifest'

auto_translations=()
skipped_translations=()
if [[ "$luci_language" == 'zh_Hant' ]]; then
    apk_db="$(find "$imagebuilder_dir/build_dir" -type f -path '*/root-*/lib/apk/db/installed' -print -quit)"
    [[ -n "$apk_db" ]] || die 'Unable to locate the ImageBuilder APK database'
    apk_root="${apk_db%/lib/apk/db/installed}"
    apk_arch="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"$/\1/p' "$imagebuilder_dir/.config")"
    [[ -n "$apk_arch" ]] || die 'Unable to identify the ImageBuilder package architecture'

    while IFS= read -r app_package; do
        translation="luci-i18n-${app_package#luci-app-}-zh-tw"
        if "$imagebuilder_dir/staging_dir/host/bin/apk" \
            --root "$apk_root" \
            --keys-dir "$imagebuilder_dir/keys" \
            --no-logfile \
            --repositories-file "$imagebuilder_dir/repositories" \
            --repository "$imagebuilder_dir/packages/packages.adb" \
            --cache-dir "$imagebuilder_dir/dl" \
            --arch "$apk_arch" \
            search --exact "$translation" 2>/dev/null | grep -Fq "$translation-"; then
            auto_translations+=("$translation")
        else
            skipped_translations+=("$translation")
        fi
    done < <(manifest_package_names "$base_manifest_file" | sed -n '/^luci-app-/p')

    if ((${#auto_translations[@]} > 0)); then
        image_packages+=("${auto_translations[@]}")
        deduplicate_image_packages
    fi
fi

make --no-print-directory -C "$imagebuilder_dir" manifest \
    PROFILE="$profile" \
    PACKAGES="${image_packages[*]}" \
    STRIP_ABI=1 \
    > "$manifest_file"
[[ -s "$manifest_file" ]] || die 'ImageBuilder produced an empty final package manifest'
if ((${#auto_translations[@]} > 0)); then
    printf 'Automatic zh_Hant packages: %s\n' "${auto_translations[*]}"
fi
if ((${#skipped_translations[@]} > 0)); then
    printf 'Unavailable zh_Hant packages (skipped): %s\n' "${skipped_translations[*]}"
fi
printf 'Final requested packages: %s\n' "${image_packages[*]}"
manifest_names="$(manifest_package_names "$manifest_file" | paste -sd ' ' -)"
[[ -n "$manifest_names" ]] || die 'Unable to read package names from the ImageBuilder manifest'
packages_hash="$(printf '%s' "$manifest_names" | sha256sum | awk '{ print $1 }')"
packages_hash_short="${packages_hash:0:12}"
printf 'Firmware Selector package ID: %s\n' "$packages_hash_short"

make -C "$imagebuilder_dir" image \
    PROFILE="$profile" \
    PACKAGES="${image_packages[*]}" \
    EXTRA_IMAGE_NAME="$packages_hash_short" \
    FILES="$work_root/overlay" \
    ROOTFS_PARTSIZE="$rootfs_size"

target_output="$imagebuilder_dir/bin/targets/$target/$subtarget"
[[ -d "$target_output" ]] || die 'ImageBuilder did not create the target output directory'
rm -rf -- "$output_root"
mkdir -p "$output_root"
firmware_prefix="openwrt-$release_label-$packages_hash_short"
for source_file in "$target_output"/*nanopi-r4s*.img.gz "$target_output"/*nanopi-r4s*.manifest; do
    [[ -f "$source_file" ]] || continue
    source_name="$(basename "$source_file")"
    if [[ "$source_name" == *squashfs* && "$build_squashfs" != 'true' ]]; then continue; fi
    if [[ "$source_name" == *ext4* && "$build_ext4" != 'true' ]]; then continue; fi
    source_suffix="${source_name#*rockchip-armv8-}"
    cp "$source_file" "$output_root/$firmware_prefix-rockchip-armv8-$source_suffix"
done
test -n "$(find "$output_root" -maxdepth 1 -type f -name '*.img.gz' -print -quit)" \
    || die 'No selected NanoPi R4S image was produced'
cp "$resolved_sources" "$output_root/third-party-sources.buildinfo"
cp "$metadata_dir/version.buildinfo" "$output_root/openwrt-version.buildinfo"
{
    printf 'channel=%s\n' "$build_channel"
    printf 'release_version=%s\n' "$release_version"
    printf 'official_revision=%s\n' "$official_revision"
    printf 'official_source=%s\n' "$base_url"
    printf 'package_set_sha256=%s\n' "$packages_hash"
    printf 'package_set_id=%s\n' "$packages_hash_short"
    printf 'luci_language=%s\n' "$luci_language"
    printf 'automatic_luci_i18n=%s\n' "${auto_translations[*]}"
    printf 'unavailable_luci_i18n=%s\n' "${skipped_translations[*]}"
    printf 'rootfs_partsize_mib=%s\n' "$rootfs_size"
    printf 'build_squashfs=%s\n' "$build_squashfs"
    printf 'build_ext4=%s\n' "$build_ext4"
} > "$output_root/build-selection.txt"
(
    cd "$output_root"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
printf 'Firmware output: %s\n' "$output_root"
