// Package core exists only to drive `gomobile bind` of sing-box's libbox.
//
// gomobile binds github.com/sagernet/sing-box/experimental/libbox directly
// (passed on the command line); this blank import keeps that module pinned in
// go.mod after `go mod tidy`. We never fork sing-box — we link its published
// experimental/libbox release library and select features purely via build tags
// (with_gvisor,with_quic,with_utls,with_clash_api).
package core

import _ "github.com/sagernet/sing-box/experimental/libbox"
