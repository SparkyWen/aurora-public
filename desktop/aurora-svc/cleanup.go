package main

import (
	"os"
	"time"
)

// uninstallCleanupBudget bounds the wait for the tunnel adapter to disappear
// during an uninstall. Longer than the ordinary teardown budget on purpose:
// there is no next connect to salvage here, and an uninstaller that returns
// while the adapter is still up is precisely how a machine ends up with an
// aurora0 and no Aurora left to remove it.
const uninstallCleanupBudget = 15 * time.Second

// purgeMachineState is everything an uninstall must leave behind zero of, apart
// from the service registration itself (which is platform-specific and handled
// by uninstallService).
//
// Reported: uninstalls were frequently incomplete ("uninstall leaves things behind"). Three things survived a
// removal. The tunnel device, because the uninstaller only asked the service to
// stop and then deleted the binaries — nothing waited for the adapter, and once
// the binaries are gone nothing on the machine can remove it. The machine state
// directory, which holds the shared bearer token, the compiled config the
// service last ran (real credentials, in plain text, SYSTEM-owned) and the log:
// the installer's [UninstallDelete] covered it, but only when the uninstaller
// itself ran to completion, and not at all for a tarball/manual install or a
// `aurora-svc uninstall` run by hand. And the resolver cache, which is the
// reason a machine can still be following tunnel-era answers after Aurora is
// gone entirely.
//
// Best effort throughout: an uninstall that fails partway is worse than one
// that cannot do every last step. The caller reports what it could not do
// rather than refusing to uninstall over it.
func purgeMachineState(paths Paths) {
	waitForTunnelGone(auroraTunInterfaceName, uninstallCleanupBudget)
	flushResolverCache()
	_ = os.RemoveAll(paths.StateDir)
}
