# Aurora core — gomobile bind of sing-box libbox
#
# Toolchain (verified working on Windows):
#   - Go >= 1.24.7 (sing-box v1.13.14 go.mod)
#   - sagernet's gomobile fork (NOT upstream golang.org/x/mobile — it can't use NDK r26+):
#       go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
#       gomobile init
#       go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
#     init installs gobind@latest internally, so pin gobind AFTER init. Verify the
#     actual gomobile/gobind command paths with `go version -m`: both main modules
#     must be github.com/sagernet/gomobile v0.1.12 (as checked in both CI builds).
#   - ANDROID_NDK_HOME -> a concrete NDK (r28 / 28.2.x works with sagernet gomobile + -androidapi 23)
#   - go.mod MUST pin github.com/sagernet/sing-tun v0.8.11 (what sing-box v1.13.14 requires),
#     else libbox fails to compile (DefaultInterfaceMonitor.MyInterfaces mismatch). `replace`
#     dirs from sing-box are NOT inherited, so transitive sagernet deps can drift — pin if a
#     build breaks.
#
# -androidapi 23 + -checklinkname=0 + badlinkname,tfogo_checklinkname0 mirror sing-box's
# own cmd/internal/build_libbox recipe. -javapkg=io.nekohasekai -libname=box => Java pkg
# io.nekohasekai.libbox (matches sing-box-for-android reference).
#
# NOTE (Windows/PowerShell): pass the whole arg list verbatim with `gomobile --% bind ...`
# so PowerShell does not split `=`/`,` flags. In make/bash the rule below is fine as-is.

SINGBOX_VER ?= v1.13.14
TAGS        ?= with_gvisor,with_quic,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0
ABIS        ?= android/arm64,android/amd64
ANDROIDAPI  ?= 23
# Matches app/android/app/build.gradle.kts (the retired vpn module is unused).
ANDROID_LIB ?= ../app/android/app/libs/libbox.aar

# Qualification targets opt into the upstream userspace endpoint. Keep the
# ordinary libraries unchanged until actual mobile memory/traffic acceptance.
TAILNET_TAGS := with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird

# iOS bind (macOS only). No badlinkname/tfogo tags — those are Android-NDK
# linkname workarounds; Apple's linker doesn't need them.
IOS_TAGS    ?= with_gvisor,with_quic,with_utls,with_clash_api
IOSVERSION  ?= 15.0
IOS_EXTRA_FLAGS ?=

.PHONY: android ios android-tailnet ios-tailnet

android:
	mkdir -p "$(dir $(ANDROID_LIB))"
	gomobile bind -v -androidapi $(ANDROIDAPI) -target=$(ABIS) \
	  -javapkg=io.nekohasekai -libname=box \
	  -tags=$(TAGS) -ldflags=-checklinkname=0 -trimpath -buildvcs=false \
	  -o "$(ANDROID_LIB)" \
	  github.com/sagernet/sing-box/experimental/libbox

android-tailnet:
	$(MAKE) android TAGS="$(TAGS),$(TAILNET_TAGS)"

# iOS + macOS (build on macOS only). Produces a STATIC Libbox.xcframework with
# ios device/simulator AND macos slices from a single bind. sagernet gomobile
# supports the macos target; this is SFM's own recipe and does NOT fork sing-box.
# The macOS PacketTunnel system extension links the macos slice; the iOS app +
# extension link the ios slices. HISTORY: v1.13.13 is UNBUILDABLE for Apple — sagernet
# retagged it (2026-06) to content whose libbox lacks MyInterfaces while every sing-tun
# v0.8.10+ requires it; the old "from-source" v1.13.13 zip no longer exists anywhere
# (go.sum j+yZ… ≠ sumdb pkaR7…). v1.13.14 is that fixed content, released properly
# (libbox implements MyInterfaces, requires sing-tun v0.8.11); go.mod now pins it.
# All targets link it statically and add -lresolv
# (Flutter/*.xcconfig + ext build settings) to satisfy Go's libresolv (_res_9_*).
ios:
	cd $(CURDIR) && gomobile bind -v -target=ios,macos -iosversion=$(IOSVERSION) \
	  -tags=$(IOS_TAGS) $(IOS_EXTRA_FLAGS) -trimpath -buildvcs=false \
	  -o ../app/ios/PacketTunnel/Libbox.xcframework \
	  github.com/sagernet/sing-box/experimental/libbox

ios-tailnet:
	$(MAKE) ios IOS_TAGS="$(IOS_TAGS),$(TAILNET_TAGS)" \
	  IOS_EXTRA_FLAGS="$(IOS_EXTRA_FLAGS) -tags-not-macos=with_low_memory"
