# Android native recovery regression

`run.sh` compiles `app/src/main/kotlin/com/aurora/vpn/*.kt` directly and replaces
only the Android system calls and the libbox JNI with test doubles; the code under
test is not copied. It needs JDK 17+ and Kotlin 2.2+:

```sh
JAVA_HOME=/path/to/jdk KOTLINC=/path/to/kotlinc bash app/android/native-test/run.sh
```

The tests create no system TUN, change no local routes and read no real contract.
NetworkInterface names and indexes come from the machine's actual interfaces; all
other connectivity is driven explicitly by callbacks. The libbox double follows
the surface used from `core/go.mod` (v1.13.14). This suite does not replace
compiling against the real AAR and Android SDK, or testing on a phone.

Network assertions cover the API 24/25 initial snapshot, the API 26+ ordered
initial callbacks, standby network churn, delayed LinkProperties, re-selection
after the chosen network is lost, the physical OS default, preferring a validated
network, VPN exclusion, and stale callbacks after close.

Service assertions cover destruction during startup, the stop callback of an old
core, a blocked native close, an old start completing or throwing, and exclusive
ownership by the replacement TUN. Control-flow assertions cover merged recovery of
two streams, replay of select and latency-test requests, a failed first dial,
isolation of stale callbacks, a connection arriving late during stop, and a
blocking selector RPC.

Foreground-notification startup is covered for API 24, 25, 26 and the current test
SDK: old systems allow only the available single-argument Builder, while new
systems must carry a notification channel. The boundary double rejects the new
constructor on an old SDK and a channel-less foreground notification on a new SDK,
so a service start cannot crash while only the network callbacks look compatible.

A transient exception from a standalone select or latency-test RPC is retried even
on a healthy stream, at 250 ms and 500 ms; after three consecutive failures the
request is dropped and logged, and a new user request gets a fresh budget.
Regression coverage includes successful recovery, budget exhaustion, stop, a
running or queued request replaced by a newer version, and an old retry not
continuing after the connection changes. A successful selection is still reported
to the UI by the following group stream.

The work queue fully reclaims the old native engine before starting a new one: when
close is stuck the UI stays responsive, but a second engine that would share the
same libbox global resources is never created concurrently. This change adds no
forced app-process kill and no Android background auto-start policy.
