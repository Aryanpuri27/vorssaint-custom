# notchctl — end-to-end checks on the real notch

Build: `swiftc -O -o build/notchctl Tools/notchctl/main.swift`

Needs Screen Recording and Accessibility for the terminal you run it from
(`./build/notchctl perms` asks for them).

| Command | What it does |
|---|---|
| `notchctl info` | display, camera notch and the app's windows |
| `notchctl shot FILE [x y w h]` | screenshot (default: around the notch) |
| `notchctl hover [center\|hoo-left\|hoo-right\|below] [secs]` | hover like a hand would |
| `notchctl press TITLE` | press a button by name, through accessibility (no pointer) |
| `notchctl click X Y` / `dclick X Y` | click at a point |
| `notchctl scroll DX DY [option]` | scroll, optionally holding Option |
| `notchctl ax [depth]` | the app's accessibility tree, with frames |
| `notchctl away` | park the pointer away from the notch |

`Tools/notchctl/claude-event.sh ask|question|plan|step|done|waiting|end` sends
sample Claude Code hook events. Prefer `press` over `click`: a click lands on
whatever is under the pointer.
