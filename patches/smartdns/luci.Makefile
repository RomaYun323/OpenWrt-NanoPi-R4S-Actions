include $(TOPDIR)/rules.mk

PKG_VERSION:=1.@SMARTDNS_COMMIT_DATE@
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for SmartDNS
LUCI_DEPENDS:=+luci-base +smartdns
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk
