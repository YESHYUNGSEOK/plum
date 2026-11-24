# Terminal preserving security update

## Intent

Keep the eleven running terminal sessions reachable while installing the hardened Plum app. Existing sessions must not be signaled, closed, or silently removed from saved state.

## Approaches

- Replace the app and reject the old host: secure immediately, but active sessions become inaccessible. Rejected.
- Accept the old host for every terminal: sessions survive, but new terminals continue to use vulnerable code. Rejected.
- Keep the old host only for its existing sessions and launch a separate hardened host for new sessions. Chosen by the user on 2026-11-24.

## Design

Use a new host socket version for the hardened host. The first attempted version 2 host holds five additional sessions and cannot accept the final binary's code signature, so the final hardened host uses version 3. At startup, connect to the version 1 socket only if its peer matches the code hash of the published 0.1.10 app, `b9b3230b9540d5f174d0e60c8729a53ba7cea9a9`; never launch a version 1 host. The live host reports `errSecCSStaticCodeChanged` because its executable was replaced on disk while it stayed running, so this one-time connection accepts that status only when the legacy code hash still matches. The published 0.1.10 asset was downloaded and its bundle code hash verified before using this value. Restore version 1 tabs through that client, and route new tabs to the version 3 host. Keep the version 3 host alive while its GUI client is connected, and retry connecting when a new tab is opened after a failed startup. Park, resize, and close each tab through the host that owns it. Preserve saved tabs and split layouts if either expected host cannot be reached or an attach fails. Unknown workspaces must not cause automatic session closure. Once all legacy tabs finish, the legacy host exits on its normal idle timeout. The five version 2 sessions remain running for separate recovery.

Test against an isolated legacy host before touching the live app. Switch the GUI only after the test shows the same shell PID and usable input/output after reconnecting. Verify the eleven live PIDs before and after the switch.

## Limits

The old host remains vulnerable to same-user socket access while it holds active sessions. The compatibility path trusts any process running the exact published 0.1.10 code at the legacy socket; it cannot distinguish another copy of that binary from the original host. It cannot transfer its pty masters to a new host because its protocol has no transfer operation. Do not describe the host as fully hardened until those sessions end and the old host exits.
