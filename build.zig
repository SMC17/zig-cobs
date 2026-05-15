const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("cobs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Examples
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/roundtrip.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("cobs", mod);
    const example_exe = b.addExecutable(.{
        .name = "example-roundtrip",
        .root_module = example_mod,
    });
    b.installArtifact(example_exe);
    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example-roundtrip", "Run the roundtrip example");
    example_step.dependOn(&run_example.step);

    // README Quickstart example — vendored verbatim from README.md as the
    // executable form of the documentation. Backed by `tools/doctest.sh`
    // which diff-checks the README block against this file; drift between
    // README and code fails the doc-test.
    const quickstart_mod = b.createModule(.{
        .root_source_file = b.path("examples/quickstart.zig"),
        .target = target,
        .optimize = optimize,
    });
    quickstart_mod.addImport("cobs", mod);
    const quickstart_exe = b.addExecutable(.{
        .name = "example-quickstart",
        .root_module = quickstart_mod,
    });
    b.installArtifact(quickstart_exe);
    const run_quickstart = b.addRunArtifact(quickstart_exe);
    const quickstart_step = b.step("example-quickstart", "Run the README Quickstart example");
    quickstart_step.dependOn(&run_quickstart.step);

    // Doc-tests: extract the README's Quickstart block + diff against the
    // vendored examples/quickstart.zig + run the binary + check output.
    const doctest = b.addSystemCommand(&.{ "bash", "tools/doctest.sh" });
    doctest.step.dependOn(b.getInstallStep());
    const doctest_step = b.step("doctest", "Verify README code examples match the executable source + run cleanly");
    doctest_step.dependOn(&doctest.step);

    // Coverage driver — a plain executable (NOT a `zig test` runner) that
    // exercises every public API + every public error path in src/root.zig
    // from a single binary. The Zig test runner's debug-info layout on
    // Zig 0.16 does not currently surface line-coverage to kcov through
    // the nixpkgs build (built without libbfd); see STATUS.md → "Coverage".
    // A plain exe avoids that and gives kcov a clean target.
    //
    // Run with: `zig build install && kcov --include-pattern=root.zig
    // coverage-out ./zig-out/bin/coverage-driver`.
    const cov_mod = b.createModule(.{
        .root_source_file = b.path("examples/coverage_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    cov_mod.addImport("cobs", mod);
    const cov_exe = b.addExecutable(.{
        .name = "coverage-driver",
        .root_module = cov_mod,
    });
    b.installArtifact(cov_exe);
    const run_cov = b.addRunArtifact(cov_exe);
    const cov_step = b.step("coverage-driver", "Run the kcov coverage driver (every public API + every error path)");
    cov_step.dependOn(&run_cov.step);

    // Fuzz harness — three-property check (round-trip, zero-freeness,
    // decoder-soundness on adversarial inputs). The full pass runs
    // 100K random + 12K boundary + 5K adversarial trials.
    //
    // CI runs the smaller fuzz-as-test variant via `zig build test`
    // (1.2K boundary + 1K random + 200 adversarial); the full pass
    // is `zig build fuzz` and is run pre-release.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    fuzz_mod.addImport("cobs", mod);
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = fuzz_mod,
    });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| run_fuzz.addArgs(args);
    run_fuzz.has_side_effects = true;
    const fuzz_step = b.step("fuzz", "Run the full fuzz harness (~120K trials, ReleaseFast)");
    fuzz_step.dependOn(&run_fuzz.step);

    // CI-friendly fuzz subset wired into `zig build test`
    const fuzz_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_test_mod.addImport("cobs", mod);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_test_mod });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    test_step.dependOn(&run_fuzz_tests.step);

    // Differential conformance — cross-checks Zig encoder/decoder against an
    // independent C reference written from the Cheshire/Baker 1997 paper
    // (`tests/c_ref/cobs_ref.h`) plus the canonical paper test vectors
    // (Table 1, IEEE/ACM ToN 1999). Moves the proof level from
    // self-consistent fuzz (Zig vs Zig) to differential (Zig vs C +
    // published ground truth).
    const diff_mod = b.createModule(.{
        .root_source_file = b.path("tests/differential.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    diff_mod.addImport("cobs", mod);
    diff_mod.addIncludePath(b.path("tests/c_ref"));
    diff_mod.addCSourceFile(.{
        .file = b.path("tests/c_ref/cobs_ref.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2" },
    });
    const diff_exe = b.addExecutable(.{
        .name = "differential",
        .root_module = diff_mod,
    });
    const run_diff = b.addRunArtifact(diff_exe);
    run_diff.has_side_effects = true;
    const diff_step = b.step("differential", "Run differential conformance test (Zig vs C reference + paper vectors)");
    diff_step.dependOn(&run_diff.step);

    // Benchmarks — separate step (`zig build bench`) so `zig build test`
    // stays fast. Always built in ReleaseFast so numbers reflect optimised
    // codegen regardless of the user's top-level optimize flag.
    const bench_step = b.step("bench", "Run encode/decode/worst-case throughput benchmarks");
    const bench_sources = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "bench-encode", .path = "bench/bench_encode.zig" },
        .{ .name = "bench-decode", .path = "bench/bench_decode.zig" },
        .{ .name = "bench-worst-case", .path = "bench/bench_worst_case.zig" },
    };
    for (bench_sources) |bs| {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path(bs.path),
            .target = target,
            .optimize = .ReleaseFast,
        });
        bench_mod.addImport("cobs", mod);
        const bench_exe = b.addExecutable(.{
            .name = bs.name,
            .root_module = bench_mod,
        });
        const run_bench = b.addRunArtifact(bench_exe);
        run_bench.has_side_effects = true; // ensure rerun on `zig build bench`
        bench_step.dependOn(&run_bench.step);
    }
}
