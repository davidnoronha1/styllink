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
    const video_tests = b.addSystemCommand(&.{ "python3", "tests/check_video.py" });
    video_tests.addArtifactArg(server);
    video_tests.setCwd(b.path("."));
    video_tests.has_side_effects = true;
    b.step("test-video", "Run the remote screen check (Xvfb, ffmpeg, python-xlib, lz4, numpy)").dependOn(&video_tests.step);

    const apk_file = buildApk(b);
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

fn command(b: *std.Build, name: []const u8, argv: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(argv);
    run.rename_step_with_output_arg = false;
    run.setName(name);
    return run;
}

fn sourceFiles(b: *std.Build, directory: []const u8, extension: ?[]const u8) []const []const u8 {
    const io = b.graph.io;
    var dir = b.root.openDir(io, directory, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}: {t}", .{ directory, err });
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("out of memory");
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch |err| std.debug.panic("cannot read {s}: {t}", .{ directory, err })) |entry| {
        if (entry.kind != .file) continue;
        if (extension) |ext| {
            if (!std.mem.endsWith(u8, entry.path, ext)) continue;
        }
        files.append(b.allocator, b.pathJoin(&.{ directory, entry.path })) catch @panic("out of memory");
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.less);
    return files.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

fn buildApk(b: *std.Build) std.Build.LazyPath {
    const sdk = b.option([]const u8, "android-sdk", "Android SDK directory") orelse
        b.graph.environ_map.get("ANDROID_HOME") orelse
        b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse ".", "Android", "Sdk" });
    const tools = b.pathJoin(&.{ sdk, "build-tools", "36.0.0" });
    const android_jar = b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "platforms", "android-36", "android.jar" }));
    const aapt2 = b.pathJoin(&.{ tools, "aapt2" });
    const resources = command(b, "compile Android resources", &.{ aapt2, "compile", "--dir" });
    resources.addDirectoryArg(b.path("android/res"));
    resources.addArg("-o");
    const resource_zip = resources.addOutputFileArg("resources.zip");
    resources.addFileInput(b.graph.cwdRelativePath(aapt2));
    for (sourceFiles(b, "android/res", null)) |file| resources.addFileInput(b.path(file));

    const link = command(b, "link Android resources", &.{ aapt2, "link", "-o" });
    const unsigned_apk = link.addOutputFileArg("unsigned.apk");
    link.addArg("-I");
    link.addFileArg(android_jar);
    link.addArg("--manifest");
    link.addFileArg(b.path("android/AndroidManifest.xml"));
    link.addArgs(&.{ "--min-sdk-version", "30", "--target-sdk-version", "36", "--version-code", "1", "--version-name", "1.0", "--java" });
    const generated_java = link.addOutputDirectoryArg("generated-java");
    link.addFileArg(resource_zip);
    link.addFileInput(b.graph.cwdRelativePath(aapt2));

    const javac = command(b, "compile Android Java", &.{ "javac", "-nowarn", "-Xlint:-options", "-source", "11", "-target", "11", "-classpath" });
    javac.addFileArg(android_jar);
    javac.addArg("-d");
    const classes = javac.addOutputDirectoryArg("classes");
    for (sourceFiles(b, "android/src", ".java")) |file| javac.addFileArg(b.path(file));
    javac.addFileArg(generated_java.path(b, "dev/styllink/R.java"));

    const jar = command(b, "package Java classes", &.{ "jar", "--create", "--file" });
    const class_jar = jar.addOutputFileArg("classes.jar");
    jar.addArg("-C");
    jar.addDirectoryArg(classes);
    jar.addArg(".");

    const d8_path = b.pathJoin(&.{ tools, "d8" });
    const d8 = command(b, "compile Android DEX", &.{ d8_path, "--min-api", "30", "--lib" });
    d8.addFileArg(android_jar);
    d8.addArg("--output");
    const dex = d8.addOutputDirectoryArg("dex");
    d8.addFileArg(class_jar);
    d8.addFileInput(b.graph.cwdRelativePath(d8_path));
    d8.addFileInput(b.graph.cwdRelativePath(b.pathJoin(&.{ tools, "lib", "d8.jar" })));

    // --out writes a new archive, preserving the cached resource APK.
    const zip = command(b, "package Android APK", &.{ "zip", "-qj" });
    zip.addFileArg(unsigned_apk);
    zip.addFileArg(dex.path(b, "classes.dex"));
    zip.addArg("--out");
    const packaged_apk = zip.addOutputFileArg("packaged.apk");

    const align_path = b.pathJoin(&.{ tools, "zipalign" });
    const align_step = command(b, "align Android APK", &.{ align_path, "-f", "-p", "4" });
    align_step.addFileArg(packaged_apk);
    const aligned_apk = align_step.addOutputFileArg("aligned.apk");
    align_step.addFileInput(b.graph.cwdRelativePath(align_path));

    const key = signingKey(b);
    const signer_path = b.pathJoin(&.{ tools, "apksigner" });
    const sign = command(b, "sign Android APK", &.{ signer_path, "sign", "--ks" });
    sign.addFileArg(key);
    sign.addArgs(&.{ "--ks-pass", "pass:android", "--key-pass", "pass:android", "--v4-signing-enabled", "false", "--out" });
    const apk = sign.addOutputFileArg("styllink.apk");
    sign.addFileArg(aligned_apk);
    sign.addFileInput(b.graph.cwdRelativePath(signer_path));
    sign.addFileInput(b.graph.cwdRelativePath(b.pathJoin(&.{ tools, "lib", "apksigner.jar" })));
    return apk;
}

fn signingKey(b: *std.Build) std.Build.LazyPath {
    if (b.option([]const u8, "android-keystore", "Development keystore (alias styllink, passwords android)")) |path|
        return b.graph.cwdRelativePath(path);
    if (b.root.statFile(b.graph.io, "android/debug.keystore")) |_| {
        return b.path("android/debug.keystore");
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("cannot read Android keystore: {t}", .{err}),
    }
    const keytool = command(b, "generate Android development key", &.{ "keytool", "-genkeypair", "-keystore" });
    const key = keytool.addOutputFileArg("debug.keystore");
    keytool.addArgs(&.{ "-storepass", "android", "-keypass", "android", "-alias", "styllink", "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000", "-dname", "CN=StylLink debug" });
    return key;
}
