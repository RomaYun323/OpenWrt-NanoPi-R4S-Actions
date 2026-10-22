include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0~git@SMARTDNS_COMMIT_SHORT@
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for SmartDNS
LUCI_DEPENDS:=+luci-base +smartdns
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk
