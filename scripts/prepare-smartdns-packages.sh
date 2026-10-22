#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 5 ]] || {
    printf 'Usage: %s PACKAGE SOURCE DESTINATION COMMIT LUCI_LANGUAGE\n' "$0" >&2
    exit 2
}

package_name="$1"
source_dir="$2"
package_dir="$3"
commit="$4"
luci_language="$5"
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'Invalid SmartDNS commit: %s\n' "$commit" >&2
    exit 2
}

rm -rf -- "$package_dir"
mkdir -p "$package_dir"
commit_short="${commit:0:12}"

case "$package_name" in
    smartdns)
        cp "$project_root/patches/smartdns/core.Makefile" "$package_dir/Makefile"
        sed -i "s/@SMARTDNS_COMMIT_SHORT@/$commit_short/g" "$package_dir/Makefile"
        sdk_dir="$(cd -- "$package_dir/../.." && pwd)"
        sdk_source_dir="$sdk_dir/custom-sources/smartdns"
        rm -rf -- "$sdk_source_dir"
        mkdir -p "$sdk_source_dir"
        cp -a "$source_dir/." "$sdk_source_dir/"
        rm -rf -- "$sdk_source_dir/.git"
        ;;
    luci-app-smartdns)
        upstream_luci="$source_dir/package/luci"
        simplified_po="$upstream_luci/files/luci/i18n/smartdns.zh-cn.po"
        [[ -f "$simplified_po" && -d "$upstream_luci/files/root" ]] || {
            printf 'Unsupported SmartDNS LuCI source layout at %s\n' "$source_dir" >&2
            exit 1
        }
        cp "$project_root/patches/smartdns/luci.Makefile" "$package_dir/Makefile"
        sed -i "s/@SMARTDNS_COMMIT_SHORT@/$commit_short/g" "$package_dir/Makefile"
        cp -a "$upstream_luci/files/root" "$package_dir/root"
        if [[ -d "$upstream_luci/control" ]]; then
            mkdir -p "$package_dir/ipkg"
            [[ -f "$upstream_luci/control/postinst" ]] \
                && cp "$upstream_luci/control/postinst" "$package_dir/ipkg/postinst"
            [[ -f "$upstream_luci/control/prerm" ]] \
                && cp "$upstream_luci/control/prerm" "$package_dir/ipkg/prerm"
        fi
        mkdir -p "$package_dir/po/zh_Hans"
        cp "$simplified_po" "$package_dir/po/zh_Hans/smartdns.po"
        # Repair the one unterminated upstream msgstr before standard gettext
        # validation and LuCI's po2lmo processing.
        sed -i 's/^msgstr "Smartdns DOH服务器端口号。$/&"/' \
            "$package_dir/po/zh_Hans/smartdns.po"
        header_po="$package_dir/po/zh_Hans/smartdns.po.header"
        {
            printf 'msgid ""\nmsgstr ""\n'
            printf '"Project-Id-Version: luci-app-smartdns\\n"\n'
            printf '"PO-Revision-Date: 2026-10-23 00:00+0800\\n"\n'
            printf '"Last-Translator: OpenWrt Builder\\n"\n'
            printf '"Language-Team: Chinese (Simplified)\\n"\n'
            printf '"Language: zh_CN\\n"\n'
            printf '"MIME-Version: 1.0\\n"\n'
            printf '"Content-Type: text/plain; charset=UTF-8\\n"\n'
            printf '"Content-Transfer-Encoding: 8bit\\n"\n'
            printf '"Plural-Forms: nplurals=1; plural=0;\\n"\n\n'
            cat "$package_dir/po/zh_Hans/smartdns.po"
        } > "$header_po"
        mv "$header_po" "$package_dir/po/zh_Hans/smartdns.po"
        normalized_po="$package_dir/po/zh_Hans/smartdns.po.normalized"
        msguniq --use-first "$package_dir/po/zh_Hans/smartdns.po" \
            -o "$normalized_po"
        mv "$normalized_po" "$package_dir/po/zh_Hans/smartdns.po"
        msgfmt --check -o /dev/null "$package_dir/po/zh_Hans/smartdns.po"
        if [[ "$luci_language" == 'zh_Hant' ]]; then
            command -v opencc >/dev/null 2>&1 || {
                printf 'OpenCC is required to generate SmartDNS zh-tw translations.\n' >&2
                exit 1
            }
            mkdir -p "$package_dir/po/zh_Hant"
            opencc_config="${OPENCC_CONFIG:-s2tw.json}"
            opencc -c "$opencc_config" \
                -i "$package_dir/po/zh_Hans/smartdns.po" \
                -o "$package_dir/po/zh_Hant/smartdns.po"
            sed -i \
                -e 's/Language-Team: Chinese (Simplified)/Language-Team: Chinese (Traditional)/' \
                -e 's/Language: zh_CN/Language: zh_TW/' \
                "$package_dir/po/zh_Hant/smartdns.po"
            msgfmt --check -o /dev/null "$package_dir/po/zh_Hant/smartdns.po"
        fi
        ;;
    *)
        printf 'Unsupported SmartDNS package: %s\n' "$package_name" >&2
        exit 2
        ;;
esac
