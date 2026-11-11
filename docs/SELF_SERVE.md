# Try zig-cobs

Encode and decode a byte frame using the README quickstart.

Use Zig 0.16.0:

```sh
zig build test -Doptimize=ReleaseSafe --summary all
zig build example-quickstart -Doptimize=ReleaseSafe
```

The fixture needs no external account or sibling checkout. With Python 3.12,
package committed source into a new directory outside this checkout:

```sh
python3 tools/selfserve.py selfserve.json --repo . --out ../zig-cobs-pack
```

The tool verifies a fresh archive of HEAD and writes source, the example
binary, task output, result.json, TRY.md and SHA256SUMS. Missing binaries,
failed commands, timeouts and absent unit-test evidence refuse PASS.

The workflow checks Linux and macOS, including a monthly smoke check. A
maintainer-pushed selfserve-* tag may create a prerelease only after both
platform jobs pass. No tag or visibility change is made here. Hosted jobs
remain blocked by account billing; this configuration is not a hosted pass.
