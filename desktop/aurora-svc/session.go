package main

// publishRunning binds the controller credentials to the same snapshot as the
// current child state. A relaunched GUI cannot guess its random port or secret.
// Copy the probe so caller mutations cannot change an already-published value.
func (rn *Runner) publishRunning(probe *clashProbe) {
	current := &runnerState{state: "running"}
	if probe != nil {
		copy := *probe
		current.probe = &copy
	}
	rn.snapshot.Store(current)
}

func (rn *Runner) statusSnapshot() runnerState {
	if current := rn.snapshot.Load(); current != nil {
		return *current
	}
	return runnerState{state: "stopped"}
}

// A stop may spend several seconds reaping the core/removing its adapter.
// Drop its credentials before that wait, while preserving the actual state
// until stop/fail publishes its final outcome.
func (rn *Runner) clearSession() {
	for {
		current := rn.snapshot.Load()
		if current == nil || current.probe == nil {
			return
		}
		next := *current
		next.probe = nil
		if rn.snapshot.CompareAndSwap(current, &next) {
			return
		}
	}
}
