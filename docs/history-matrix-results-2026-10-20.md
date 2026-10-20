# Window matrix, 2026-10-20 21:11

R = /Applications/Claude.app (orange, the original), B = ~/Applications/Claude Blue.app (untouched copy, blue icon); S = saenidev folder, J = second folder. Checked 25 s after each action (the guard runs every 5 s).

| start | entry | want | got | most windows on one folder | Cookies holders S/J | Keychain prompt | result |
|---|---|---|---|---|---|---|---|
| none | hand-blue | B@S | B@S | 1 | 1/0 | no | pass |
| saen | hand-blue | B@S | B@S | 1 | 1/0 | no | pass |
| jey | hand-blue | B@S R@J | B@S R@J | 1 | 1/1 | no | pass |
| both | hand-blue | B@S R@J | B@S R@J | 1 | 1/1 | no | pass |
| none | hand-orange | B@S | B@S | 1 | 1/0 | no | pass |
| saen | hand-orange | B@S | B@S | 1 | 1/0 | no | pass |
| jey | hand-orange | R@J | R@J | 1 | 0/1 | no | pass |
| both | hand-orange | B@S R@J | B@S R@J | 1 | 1/1 | no | pass |
| none | link | B@S | B@S | 1 | 1/0 | no | pass |
| saen | link | B@S | B@S | 1 | 1/0 | no | pass |
| jey | link | R@J | R@J | 1 | 0/1 | no | pass |
| both | link | B@S R@J | B@S R@J | 1 | 1/1 | no | pass |
| none | relay-jey | R@J | R@J | 1 | 0/1 | no | pass |
| saen | relay-jey | B@S R@J | B@S R@J | 1 | 1/1 | no | pass |
| jey | relay-jey | R@J | R@J | 1 | 0/1 | no | pass |
| both | relay-jey | B@S R@J | B@S R@J | 1 | 1/1 | no | pass |

## App update

- blue copy behind (version set to 0.0.1), then the relay opens saenidev: blue now 3.1623.0 (orange 3.1623.0), signature valid, windows B@S: **pass**
- blue copy loses its icon and its Info.plist changes: icon back and signature valid: **FAIL**
- Keychain prompt during the matrix: no

**17 passed, 1 failed.**

## Notes after the run

- The "blue copy behind" check passed without testing anything: macOS blocked the job from changing the launched blue copy's version (`Operation not permitted`). The real refresh, from the old re-signed blue 2.42304.2 to an untouched 3.1623.0, ran at 21:11:22 and worked.
- The icon check failed for the same reason. Icon restoring now runs from the mod, inside Claude, where macOS allows it.
- Jun clicked Claude icons during the run. The guard caught an orange window on saenidev's folder at 21:11:44 and moved it to blue. Every cell still ended with one window per folder, in the right app.
- LaunchServices still listed three copies in the Trash as `claude://` handlers. They are unregistered now, and refresh unregisters old copies from here on.
