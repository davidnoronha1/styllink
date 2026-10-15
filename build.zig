const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{}) orelse .fast;
    const page = b.createModule(.{ .root_source_file = b.path("web/page.zig") });
    const server = b.addExecutable(.{
        .name = "styllink",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            .link_libc = false,
            .imports = &.{.{ .name = "page", .module = page }},
        }),
    });
    b.installArtifact(server);

    const server_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{.{ .name = "page", .module = page }},
        }),
    });
    b.step("test", "Run server tests").dependOn(&b.addRunArtifact(server_tests).step);
    const link_tests = b.addSystemCommand(&.{ "python3", "tests/check_link.py" });
    link_tests.setCwd(b.path("."));
    link_tests.has_side_effects = true;
    b.step("test-link", "Run Java WebSocket tests (requires a JDK)").dependOn(&link_tests.step);

    // Zig owns the build graph and output path; Android SDK tools compile Java,
    // package resources, and sign the APK. Rebuild to pick up SDK/key changes.
    const apk = b.addSystemCommand(&.{"sh"});
    apk.addFileArg(b.path("android/build.sh"));
    apk.addArg("--output");
    const apk_file = apk.addOutputFileArg("styllink.apk");
    apk.has_side_effects = true;
    const install_apk = b.addInstallFile(apk_file, "android/styllink.apk");
    b.step("apk", "Build and install the APK into zig-out/android").dependOn(&install_apk.step);

    const adb = b.addSystemCommand(&.{ "adb", "install", "-r" });
    adb.addFileArg(apk_file);
    adb.has_side_effects = true;
    b.step("apk-install", "Build and install the APK on a connected tablet").dependOn(&adb.step);

    const all = b.step("all", "Build the Linux server and Android APK");
    all.dependOn(b.getInstallStep());
    all.dependOn(&install_apk.step);
}
