// Package libaurora exists only to pin sing-box/experimental/libbox into the
// module graph so `gomobile bind` can target it. No app logic lives here — the
// Aurora config "compiler" is in Dart (app/lib/core); see docs/architecture.md.
package libaurora

import _ "github.com/sagernet/sing-box/experimental/libbox"
