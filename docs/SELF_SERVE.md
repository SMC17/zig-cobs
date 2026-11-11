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

## Common questions

- **The pack says FAIL.** Read the first failing step in result.json and its
  log. A completed build with no executed tests is insufficient; a missing
  promised binary is also a failure.
- **Where do I report a failure?** Use the self-serve task issue form with the
  source commit/checksum, platform, exact command, expected result and output.
  You do not need a private message or an external service to reproduce it.
- **Will the schedule run forever?** GitHub can disable scheduled workflows in
  inactive public repositories after 60 days. Push/manual triggers remain
  separate. Inspect Actions when a monthly result becomes stale; this system
  does not manufacture commits to keep schedules alive.

[GitHub's schedule policy](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/disable-and-enable-workflows)
