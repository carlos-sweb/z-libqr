const std = @import("std");

/// Package version, single source of truth: build.zig.zon.
/// Pattern taken from arrufat/zignal tag 0.11.0, build.zig.
const zqr_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;

/// The three distribution tiers. Each one is a separate C root that
/// instantiates `cWrapper(max_version, prefix)` from src/c_api.zig.
const tiers = [_][]const u8{ "t1", "t2", "t3" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path 1: Zig source module, consumed via build.zig.zon + @import("zqr").
    // `optimize` is intentionally left unset so that it is inherited from
    // the consumer's compilation (same as the `zig init` 0.17 template).
    const zqr = b.addModule("zqr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const test_step = b.step("test", "Run all tests and build every library artifact");

    const zqr_tests = b.addTest(.{ .root_module = zqr });
    test_step.dependOn(&b.addRunArtifact(zqr_tests).step);

    // Tests for the C ABI layer (status-code mapping, argument validation).
    const c_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zqr", .module = zqr }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(c_api_tests).step);

    // Golden fixture tests against Nayuki reference vectors
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zqr", .module = zqr }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(golden_tests).step);

    // Paths 2 and 3: static (.a) and dynamic (.so) libraries per tier, both
    // built from the same C root module so they export identical symbols.
    var static_libs: [tiers.len]*std.Build.Step.Compile = undefined;
    inline for (tiers, 0..) |tier, i| {
        const c_root = b.createModule(.{
            .root_source_file = b.path("src/c_" ++ tier ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zqr", .module = zqr }},
            // There is no C code in these libraries; without this, Debug
            // builds bundle the UBSan runtime and the .so exports ~35
            // `__ubsan_handle_*` symbols (and grows from ~84 KB to ~10 MB).
            .sanitize_c = .off,
            // Allow the static archives to be linked into shared objects.
            .pic = true,
        });

        const static_lib = b.addLibrary(.{
            .name = "zqr_" ++ tier,
            .linkage = .static,
            .root_module = c_root,
        });
        static_libs[i] = static_lib;
        // The SONAME (libzqr_tN.so.<major>) is derived from `.version`;
        // std.Build in 0.17 has no separate linker-argument API for it.
        const dynamic_lib = b.addLibrary(.{
            .name = "zqr_" ++ tier,
            .linkage = .dynamic,
            .root_module = c_root,
            .version = zqr_version,
        });

        b.installArtifact(static_lib);
        b.installArtifact(dynamic_lib);
        test_step.dependOn(&static_lib.step);
        test_step.dependOn(&dynamic_lib.step);
    }

    // C ABI integration test: links all 3 static libraries simultaneously into one C binary,
    // verifying include/zqr.h, structs, status codes, and multi-tier symbol isolation.
    const c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_mod.addCSourceFile(.{
        .file = b.path("tests/c_integration.c"),
        .flags = &[_][]const u8{ "-std=c99", "-Wall", "-Wextra" },
    });
    c_mod.addIncludePath(b.path("include"));
    for (static_libs) |lib| {
        c_mod.linkLibrary(lib);
    }

    const c_integration_exe = b.addExecutable(.{
        .name = "c_integration",
        .root_module = c_mod,
    });

    const run_c_integration = b.addRunArtifact(c_integration_exe);
    const test_c_step = b.step("test-c-integration", "Run C ABI integration test");
    test_c_step.dependOn(&run_c_integration.step);
    test_step.dependOn(&run_c_integration.step);

    b.installFile("include/zqr.h", "include/zqr.h");

    const fmt_step = b.step("fmt", "Check source formatting (zig fmt --check)");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") },
        .check = true,
    }).step);
}
