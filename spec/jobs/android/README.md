# Android APK Runner probe

## Scope

Execute the unchanged production `bilicomics/jobs/runner.lua` in the ordinary
UID of the official KOReader `v2026.07.1` x86 APK on the existing remote API 30
emulator. The only injected behavior is the Runner's supported synthetic worker
closure and a UI observation adapter that delegates scheduling and standby
operations to the real `UIManager`. No protocol client, account, session,
Bilibili endpoint, or real purchase is used.

The dedicated research `main.lua` schedules its first step after the real UI
event loop starts. Every scenario has a deadline and cleanup. The probe records
the app UID, SELinux context when available, loaded production source paths,
SHA-256 digests, real child PIDs, pipe capacity, callback counts, wait status,
standby ownership, and UI heartbeat timing.

Sequential scenarios:

1. Return a 1 MiB payload through a real child pipe and compare every byte. Read
   the actual pipe capacity. Before releasing that child, require a marker proving
   it is already blocked and observe at least 0.35 seconds of UI heartbeats with
   a bounded maximum gap. Continue measuring while the large result drains.
2. Cancel a started child; require one callback, a collected child, and balanced
   standby calls.
3. Time out a started child with automatic retries explicitly disabled; require
   a timeout result and the same cleanup guarantees.
4. Suspend a started read, observe the retained queue without a child or standby
   ownership, then resume and require a single successful callback from the new
   attempt.
5. Suspend a synthetic `purchase_submit` using default cancelability options,
   queue urgent read work, and prove the original purchase process executes only
   once and is not preempted or resubmitted.

The heartbeat is a callback scheduled through the actual Android application's
`UIManager`, not a host-side timer or a fake event queue. This establishes event
loop responsiveness for these synthetic worker operations. It is not physical
e-ink refresh, real network, device-suspend, or ARM-device evidence.

## Exclusive APK coordination

The shared APK must have one operator. The agreed queue is the Session probe,
the protocol owner's final native-loader probe, then this Runner probe. Do not
restart the APK or overwrite its research plugin until the previous owner
explicitly hands off the slot. The remote launcher additionally takes
`/var/tmp/bili-android-emulator-20260912/apk-operation.lock`; this does not replace
the explicit agent handoff.

Use the existing emulator and dedicated adb endpoint: port `5038`, serial
`emulator-5580`. The launcher temporarily replaces only the research plugin's
`main.lua`, stages three unmodified production Lua modules, and uses an independent
report filename. It restores every overwritten file byte-for-byte and removes
only probe files that did not previously exist. A failed or timed-out probe is
force-stopped while the operator still holds the lock. The launcher does not
modify or re-sign the APK or change production sources.

Run all deployment and execution through `ssh test-env`. The launcher requires
`--slot-confirmed` after the handoff and records the source snapshot it deploys.
Do not run it on the local workstation.

## Recorded execution

The final run in `remote-results.json` passed all 44 assertions across all five
scenarios. It executed inside app process `7968`, UID `10167`, with SELinux
context `u:r:untrusted_app:s0:c167,c256,c512,c768`. The host independently matched
that PID and UID to `org.koreader.launcher`.

| Observation | Result |
| --- | --- |
| Installed APK | Official KOReader `v2026.07.1`, versionCode `119463`, x86 |
| Android image | API 30, SELinux Enforcing |
| Actual kernel pipe capacity | 65,536 bytes |
| Verified child payload | 1,048,576 bytes, compared in full |
| Blocked-worker observation window | At least 0.35 seconds, after a real child-start marker |
| Maximum UI heartbeat gap during the large-result scenario | 81.8 ms, below the asserted 250 ms bound |
| Child cleanup | All seven child PIDs were already reaped by Runner (`waitpid=-1`, `ECHILD`) |
| Standby ownership | Seven paired acquire/release calls; actual UIManager count returned to zero for every scenario |
| Read suspension | First child collected, queue retained without polling, second PID returns one final callback |
| Synthetic purchase | Original PID survives suspension and urgent work; exactly one execution |

The installed APK SHA-256 was checked against the pinned official release asset:
`3cd979cc6474308ce37c408a8753fce27898249599e6ec6875d34ecd9b3d4144`.
The unchanged production Runner SHA-256 was
`a56c1ae56c3a3aabb20f65cc23f28edf32013e2dbd71ed4013c488ed0efca3d2`.
The report also contains loaded source paths and the Util/Codec digests.

The first exploratory run passed but review identified a timing assertion that
needed to include an overdue current heartbeat gap, plus incomplete launcher
cleanup. Those test-only issues were corrected before the final evidence run.
The current predicate includes `now - last_heartbeat` and final cleanup timing;
the launcher distinguishes nonexistent files with `adb shell test -f`, because
`adb exec-out` alone did not reliably expose the remote `cat` exit status.

The final launcher restored the previous native research main and all three
staged production modules, removed its new input manifest, and left the APK
running with no live probe child. Session data and result files were not read or
modified. The operator slot and host lock were released after completion.

This is API 30 x86 emulator evidence for synthetic worker scheduling and IPC.
It does not establish physical device behavior, e-ink refresh, ARM execution,
Android parent-process-death cleanup, real Bilibili network access, or a real
purchase transaction.
