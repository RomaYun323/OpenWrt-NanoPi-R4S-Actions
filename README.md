# OpenWrt NanoPi R4S Actions

使用 GitHub Actions 與 OpenWrt 官方 SDK／ImageBuilder，為 FriendlyARM NanoPi R4S 4GB 產生 Release 或 Snapshot 映像。

## 建置

1. 開啟 **Actions**。
2. 選擇 **Build public OpenWrt firmware**。
3. 按 **Run workflow**，設定版本、語言、Rootfs 大小與插件。
4. 完成後下載 `openwrt-*-nanopi-r4s` artifact。

`zh_Hant` 會自動加入所有已安裝 `luci-app-*` 對應且存在的 `luci-i18n-*-zh-tw` 語言包。
