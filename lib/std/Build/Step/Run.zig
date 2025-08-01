const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = Build.Step;
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const EnvMap = process.EnvMap;
const assert = std.debug.assert;
const Path = Build.Cache.Path;

const Run = @This();

pub const base_id: Step.Id = .run;

step: Step,

/// See also addArg and addArgs to modifying this directly
argv: std.ArrayListUnmanaged(Arg),

/// Use `setCwd` to set the initial current working directory
cwd: ?Build.LazyPath,

/// Override this field to modify the environment, or use setEnvironmentVariable
env_map: ?*EnvMap,

/// When `true` prevents `ZIG_PROGRESS` environment variable from being passed
/// to the child process, which otherwise would be used for the child to send
/// progress updates to the parent.
disable_zig_progress: bool,

/// Configures whether the Run step is considered to have side-effects, and also
/// whether the Run step will inherit stdio streams, forwarding them to the
/// parent process, in which case will require a global lock to prevent other
/// steps from interfering with stdio while the subprocess associated with this
/// Run step is running.
/// If the Run step is determined to not have side-effects, then execution will
/// be skipped if all output files are up-to-date and input files are
/// unchanged.
stdio: StdIo,

/// This field must be `.none` if stdio is `inherit`.
/// It should be only set using `setStdIn`.
stdin: StdIn,

/// Additional input files that, when modified, indicate that the Run step
/// should be re-executed.
/// If the Run step is determined to have side-effects, the Run step is always
/// executed when it appears in the build graph, regardless of whether these
/// files have been modified.
file_inputs: std.ArrayListUnmanaged(std.Build.LazyPath),

/// After adding an output argument, this step will by default rename itself
/// for a better display name in the build summary.
/// This can be disabled by setting this to false.
rename_step_with_output_arg: bool,

/// If this is true, a Run step which is configured to check the output of the
/// executed binary will not fail the build if the binary cannot be executed
/// due to being for a foreign binary to the host system which is running the
/// build graph.
/// Command-line arguments such as -fqemu and -fwasmtime may affect whether a
/// binary is detected as foreign, as well as system configuration such as
/// Rosetta (macOS) and binfmt_misc (Linux).
/// If this Run step is considered to have side-effects, then this flag does
/// nothing.
skip_foreign_checks: bool,

/// If this is true, failing to execute a foreign binary will be considered an
/// error. However if this is false, the step will be skipped on failure instead.
///
/// This allows for a Run step to attempt to execute a foreign binary using an
/// external executor (such as qemu) but not fail if the executor is unavailable.
failing_to_execute_foreign_is_an_error: bool,

/// Deprecated in favor of `stdio_limit`.
max_stdio_size: usize,

/// If stderr or stdout exceeds this amount, the child process is killed and
/// the step fails.
stdio_limit: std.Io.Limit,

captured_stdout: ?*Output,
captured_stderr: ?*Output,

dep_output_file: ?*Output,

has_side_effects: bool,

/// If this is a Zig unit test binary, this tracks the indexes of the unit
/// tests that are also fuzz tests.
fuzz_tests: std.ArrayListUnmanaged(u32),
cached_test_metadata: ?CachedTestMetadata = null,

/// Populated during the fuzz phase if this run step corresponds to a unit test
/// executable that contains fuzz tests.
rebuilt_executable: ?Path,

/// If this Run step was produced by a Compile step, it is tracked here.
producer: ?*Step.Compile,

pub const StdIn = union(enum) {
    none,
    bytes: []const u8,
    lazy_path: std.Build.LazyPath,
};

pub const StdIo = union(enum) {
    /// Whether the Run step has side-effects will be determined by whether or not one
    /// of the args is an output file (added with `addOutputFileArg`).
    /// If the Run step is determined to have side-effects, this is the same as `inherit`.
    /// The step will fail if the subprocess crashes or returns a non-zero exit code.
    infer_from_args,
    /// Causes the Run step to be considered to have side-effects, and therefore
    /// always execute when it appears in the build graph.
    /// It also means that this step will obtain a global lock to prevent other
    /// steps from running in the meantime.
    /// The step will fail if the subprocess crashes or returns a non-zero exit code.
    inherit,
    /// Causes the Run step to be considered to *not* have side-effects. The
    /// process will be re-executed if any of the input dependencies are
    /// modified. The exit code and standard I/O streams will be checked for
    /// certain conditions, and the step will succeed or fail based on these
    /// conditions.
    /// Note that an explicit check for exit code 0 needs to be added to this
    /// list if such a check is desirable.
    check: std.ArrayListUnmanaged(Check),
    /// This Run step is running a zig unit test binary and will communicate
    /// extra metadata over the IPC protocol.
    zig_test,

    pub const Check = union(enum) {
        expect_stderr_exact: []const u8,
        expect_stderr_match: []const u8,
        expect_stdout_exact: []const u8,
        expect_stdout_match: []const u8,
        expect_term: std.process.Child.Term,
    };
};

pub const Arg = union(enum) {
    artifact: PrefixedArtifact,
    lazy_path: PrefixedLazyPath,
    decorated_directory: DecoratedLazyPath,
    bytes: []u8,
    output_file: *Output,
    output_directory: *Output,
};

pub const PrefixedArtifact = struct {
    prefix: []const u8,
    artifact: *Step.Compile,
};

pub const PrefixedLazyPath = struct {
    prefix: []const u8,
    lazy_path: std.Build.LazyPath,
};

pub const DecoratedLazyPath = struct {
    prefix: []const u8,
    lazy_path: std.Build.LazyPath,
    suffix: []const u8,
};

pub const Output = struct {
    generated_file: std.Build.GeneratedFile,
    prefix: []const u8,
    basename: []const u8,
};

pub fn create(owner: *std.Build, name: []const u8) *Run {
    const run = owner.allocator.create(Run) catch @panic("OOM");
    run.* = .{
        .step = .init(.{
            .id = base_id,
            .name = name,
            .owner = owner,
            .makeFn = make,
        }),
        .argv = .{},
        .cwd = null,
        .env_map = null,
        .disable_zig_progress = false,
        .stdio = .infer_from_args,
        .stdin = .none,
        .file_inputs = .{},
        .rename_step_with_output_arg = true,
        .skip_foreign_checks = false,
        .failing_to_execute_foreign_is_an_error = true,
        .max_stdio_size = 10 * 1024 * 1024,
        .stdio_limit = .unlimited,
        .captured_stdout = null,
        .captured_stderr = null,
        .dep_output_file = null,
        .has_side_effects = false,
        .fuzz_tests = .{},
        .rebuilt_executable = null,
        .producer = null,
    };
    return run;
}

pub fn setName(run: *Run, name: []const u8) void {
    run.step.name = name;
    run.rename_step_with_output_arg = false;
}

pub fn enableTestRunnerMode(run: *Run) void {
    const b = run.step.owner;
    run.stdio = .zig_test;
    run.addPrefixedDirectoryArg("--cache-dir=", .{ .cwd_relative = b.cache_root.path orelse "." });
    run.addArgs(&.{
        b.fmt("--seed=0x{x}", .{b.graph.random_seed}),
        "--listen=-",
    });
}

pub fn addArtifactArg(run: *Run, artifact: *Step.Compile) void {
    run.addPrefixedArtifactArg("", artifact);
}

pub fn addPrefixedArtifactArg(run: *Run, prefix: []const u8, artifact: *Step.Compile) void {
    const b = run.step.owner;

    const prefixed_artifact: PrefixedArtifact = .{
        .prefix = b.dupe(prefix),
        .artifact = artifact,
    };
    run.argv.append(b.allocator, .{ .artifact = prefixed_artifact }) catch @panic("OOM");

    const bin_file = artifact.getEmittedBin();
    bin_file.addStepDependencies(&run.step);
}

/// Provides a file path as a command line argument to the command being run.
///
/// Returns a `std.Build.LazyPath` which can be used as inputs to other APIs
/// throughout the build system.
///
/// Related:
/// * `addPrefixedOutputFileArg` - same thing but prepends a string to the argument
/// * `addFileArg` - for input files given to the child process
pub fn addOutputFileArg(run: *Run, basename: []const u8) std.Build.LazyPath {
    return run.addPrefixedOutputFileArg("", basename);
}

/// Provides a file path as a command line argument to the command being run.
/// Asserts `basename` is not empty.
///
/// For example, a prefix of "-o" and basename of "output.txt" will result in
/// the child process seeing something like this: "-ozig-cache/.../output.txt"
///
/// The child process will see a single argument, regardless of whether the
/// prefix or basename have spaces.
///
/// The returned `std.Build.LazyPath` can be used as inputs to other APIs
/// throughout the build system.
///
/// Related:
/// * `addOutputFileArg` - same thing but without the prefix
/// * `addFileArg` - for input files given to the child process
pub fn addPrefixedOutputFileArg(
    run: *Run,
    prefix: []const u8,
    basename: []const u8,
) std.Build.LazyPath {
    const b = run.step.owner;
    if (basename.len == 0) @panic("basename must not be empty");

    const output = b.allocator.create(Output) catch @panic("OOM");
    output.* = .{
        .prefix = b.dupe(prefix),
        .basename = b.dupe(basename),
        .generated_file = .{ .step = &run.step },
    };
    run.argv.append(b.allocator, .{ .output_file = output }) catch @panic("OOM");

    if (run.rename_step_with_output_arg) {
        run.setName(b.fmt("{s} ({s})", .{ run.step.name, basename }));
    }

    return .{ .generated = .{ .file = &output.generated_file } };
}

/// Appends an input file to the command line arguments.
///
/// The child process will see a file path. Modifications to this file will be
/// detected as a cache miss in subsequent builds, causing the child process to
/// be re-executed.
///
/// Related:
/// * `addPrefixedFileArg` - same thing but prepends a string to the argument
/// * `addOutputFileArg` - for files generated by the child process
pub fn addFileArg(run: *Run, lp: std.Build.LazyPath) void {
    run.addPrefixedFileArg("", lp);
}

/// Appends an input file to the command line arguments prepended with a string.
///
/// For example, a prefix of "-F" will result in the child process seeing something
/// like this: "-Fexample.txt"
///
/// The child process will see a single argument, even if the prefix has
/// spaces. Modifications to this file will be detected as a cache miss in
/// subsequent builds, causing the child process to be re-executed.
///
/// Related:
/// * `addFileArg` - same thing but without the prefix
/// * `addOutputFileArg` - for files generated by the child process
pub fn addPrefixedFileArg(run: *Run, prefix: []const u8, lp: std.Build.LazyPath) void {
    const b = run.step.owner;

    const prefixed_file_source: PrefixedLazyPath = .{
        .prefix = b.dupe(prefix),
        .lazy_path = lp.dupe(b),
    };
    run.argv.append(b.allocator, .{ .lazy_path = prefixed_file_source }) catch @panic("OOM");
    lp.addStepDependencies(&run.step);
}

/// Provides a directory path as a command line argument to the command being run.
///
/// Returns a `std.Build.LazyPath` which can be used as inputs to other APIs
/// throughout the build system.
///
/// Related:
/// * `addPrefixedOutputDirectoryArg` - same thing but prepends a string to the argument
/// * `addDirectoryArg` - for input directories given to the child process
pub fn addOutputDirectoryArg(run: *Run, basename: []const u8) std.Build.LazyPath {
    return run.addPrefixedOutputDirectoryArg("", basename);
}

/// Provides a directory path as a command line argument to the command being run.
/// Asserts `basename` is not empty.
///
/// For example, a prefix of "-o" and basename of "output_dir" will result in
/// the child process seeing something like this: "-ozig-cache/.../output_dir"
///
/// The child process will see a single argument, regardless of whether the
/// prefix or basename have spaces.
///
/// The returned `std.Build.LazyPath` can be used as inputs to other APIs
/// throughout the build system.
///
/// Related:
/// * `addOutputDirectoryArg` - same thing but without the prefix
/// * `addDirectoryArg` - for input directories given to the child process
pub fn addPrefixedOutputDirectoryArg(
    run: *Run,
    prefix: []const u8,
    basename: []const u8,
) std.Build.LazyPath {
    if (basename.len == 0) @panic("basename must not be empty");
    const b = run.step.owner;

    const output = b.allocator.create(Output) catch @panic("OOM");
    output.* = .{
        .prefix = b.dupe(prefix),
        .basename = b.dupe(basename),
        .generated_file = .{ .step = &run.step },
    };
    run.argv.append(b.allocator, .{ .output_directory = output }) catch @panic("OOM");

    if (run.rename_step_with_output_arg) {
        run.setName(b.fmt("{s} ({s})", .{ run.step.name, basename }));
    }

    return .{ .generated = .{ .file = &output.generated_file } };
}

pub fn addDirectoryArg(run: *Run, lazy_directory: std.Build.LazyPath) void {
    run.addDecoratedDirectoryArg("", lazy_directory, "");
}

pub fn addPrefixedDirectoryArg(run: *Run, prefix: []const u8, lazy_directory: std.Build.LazyPath) void {
    const b = run.step.owner;
    run.argv.append(b.allocator, .{ .decorated_directory = .{
        .prefix = b.dupe(prefix),
        .lazy_path = lazy_directory.dupe(b),
        .suffix = "",
    } }) catch @panic("OOM");
    lazy_directory.addStepDependencies(&run.step);
}

pub fn addDecoratedDirectoryArg(
    run: *Run,
    prefix: []const u8,
    lazy_directory: std.Build.LazyPath,
    suffix: []const u8,
) void {
    const b = run.step.owner;
    run.argv.append(b.allocator, .{ .decorated_directory = .{
        .prefix = b.dupe(prefix),
        .lazy_path = lazy_directory.dupe(b),
        .suffix = b.dupe(suffix),
    } }) catch @panic("OOM");
    lazy_directory.addStepDependencies(&run.step);
}

/// Add a path argument to a dep file (.d) for the child process to write its
/// discovered additional dependencies.
/// Only one dep file argument is allowed by instance.
pub fn addDepFileOutputArg(run: *Run, basename: []const u8) std.Build.LazyPath {
    return run.addPrefixedDepFileOutputArg("", basename);
}

/// Add a prefixed path argument to a dep file (.d) for the child process to
/// write its discovered additional dependencies.
/// Only one dep file argument is allowed by instance.
pub fn addPrefixedDepFileOutputArg(run: *Run, prefix: []const u8, basename: []const u8) std.Build.LazyPath {
    const b = run.step.owner;
    assert(run.dep_output_file == null);

    const dep_file = b.allocator.create(Output) catch @panic("OOM");
    dep_file.* = .{
        .prefix = b.dupe(prefix),
        .basename = b.dupe(basename),
        .generated_file = .{ .step = &run.step },
    };

    run.dep_output_file = dep_file;

    run.argv.append(b.allocator, .{ .output_file = dep_file }) catch @panic("OOM");

    return .{ .generated = .{ .file = &dep_file.generated_file } };
}

pub fn addArg(run: *Run, arg: []const u8) void {
    const b = run.step.owner;
    run.argv.append(b.allocator, .{ .bytes = b.dupe(arg) }) catch @panic("OOM");
}

pub fn addArgs(run: *Run, args: []const []const u8) void {
    for (args) |arg| run.addArg(arg);
}

pub fn setStdIn(run: *Run, stdin: StdIn) void {
    switch (stdin) {
        .lazy_path => |lazy_path| lazy_path.addStepDependencies(&run.step),
        .bytes, .none => {},
    }
    run.stdin = stdin;
}

pub fn setCwd(run: *Run, cwd: Build.LazyPath) void {
    cwd.addStepDependencies(&run.step);
    run.cwd = cwd.dupe(run.step.owner);
}

pub fn clearEnvironment(run: *Run) void {
    const b = run.step.owner;
    const new_env_map = b.allocator.create(EnvMap) catch @panic("OOM");
    new_env_map.* = EnvMap.init(b.allocator);
    run.env_map = new_env_map;
}

pub fn addPathDir(run: *Run, search_path: []const u8) void {
    const b = run.step.owner;
    const env_map = getEnvMapInternal(run);

    const use_wine = b.enable_wine and b.graph.host.result.os.tag != .windows and use_wine: switch (run.argv.items[0]) {
        .artifact => |p| p.artifact.rootModuleTarget().os.tag == .windows,
        .lazy_path => |p| {
            switch (p.lazy_path) {
                .generated => |g| if (g.file.step.cast(Step.Compile)) |cs| break :use_wine cs.rootModuleTarget().os.tag == .windows,
                else => {},
            }
            break :use_wine std.mem.endsWith(u8, p.lazy_path.basename(b, &run.step), ".exe");
        },
        .decorated_directory => false,
        .bytes => |bytes| std.mem.endsWith(u8, bytes, ".exe"),
        .output_file, .output_directory => false,
    };
    const key = if (use_wine) "WINEPATH" else "PATH";
    const prev_path = env_map.get(key);

    if (prev_path) |pp| {
        const new_path = b.fmt("{s}{c}{s}", .{
            pp,
            if (use_wine) fs.path.delimiter_windows else fs.path.delimiter,
            search_path,
        });
        env_map.put(key, new_path) catch @panic("OOM");
    } else {
        env_map.put(key, b.dupePath(search_path)) catch @panic("OOM");
    }
}

pub fn getEnvMap(run: *Run) *EnvMap {
    return getEnvMapInternal(run);
}

fn getEnvMapInternal(run: *Run) *EnvMap {
    const arena = run.step.owner.allocator;
    return run.env_map orelse {
        const env_map = arena.create(EnvMap) catch @panic("OOM");
        env_map.* = process.getEnvMap(arena) catch @panic("unhandled error");
        run.env_map = env_map;
        return env_map;
    };
}

pub fn setEnvironmentVariable(run: *Run, key: []const u8, value: []const u8) void {
    const b = run.step.owner;
    const env_map = run.getEnvMap();
    env_map.put(b.dupe(key), b.dupe(value)) catch @panic("unhandled error");
}

pub fn removeEnvironmentVariable(run: *Run, key: []const u8) void {
    run.getEnvMap().remove(key);
}

/// Adds a check for exact stderr match. Does not add any other checks.
pub fn expectStdErrEqual(run: *Run, bytes: []const u8) void {
    const new_check: StdIo.Check = .{ .expect_stderr_exact = run.step.owner.dupe(bytes) };
    run.addCheck(new_check);
}

/// Adds a check for exact stdout match as well as a check for exit code 0, if
/// there is not already an expected termination check.
pub fn expectStdOutEqual(run: *Run, bytes: []const u8) void {
    const new_check: StdIo.Check = .{ .expect_stdout_exact = run.step.owner.dupe(bytes) };
    run.addCheck(new_check);
    if (!run.hasTermCheck()) {
        run.expectExitCode(0);
    }
}

pub fn expectExitCode(run: *Run, code: u8) void {
    const new_check: StdIo.Check = .{ .expect_term = .{ .Exited = code } };
    run.addCheck(new_check);
}

pub fn hasTermCheck(run: Run) bool {
    for (run.stdio.check.items) |check| switch (check) {
        .expect_term => return true,
        else => continue,
    };
    return false;
}

pub fn addCheck(run: *Run, new_check: StdIo.Check) void {
    const b = run.step.owner;

    switch (run.stdio) {
        .infer_from_args => {
            run.stdio = .{ .check = .{} };
            run.stdio.check.append(b.allocator, new_check) catch @panic("OOM");
        },
        .check => |*checks| checks.append(b.allocator, new_check) catch @panic("OOM"),
        else => @panic("illegal call to addCheck: conflicting helper method calls. Suggest to directly set stdio field of Run instead"),
    }
}

pub fn captureStdErr(run: *Run) std.Build.LazyPath {
    assert(run.stdio != .inherit);

    if (run.captured_stderr) |output| return .{ .generated = .{ .file = &output.generated_file } };

    const output = run.step.owner.allocator.create(Output) catch @panic("OOM");
    output.* = .{
        .prefix = "",
        .basename = "stderr",
        .generated_file = .{ .step = &run.step },
    };
    run.captured_stderr = output;
    return .{ .generated = .{ .file = &output.generated_file } };
}

pub fn captureStdOut(run: *Run) std.Build.LazyPath {
    assert(run.stdio != .inherit);

    if (run.captured_stdout) |output| return .{ .generated = .{ .file = &output.generated_file } };

    const output = run.step.owner.allocator.create(Output) catch @panic("OOM");
    output.* = .{
        .prefix = "",
        .basename = "stdout",
        .generated_file = .{ .step = &run.step },
    };
    run.captured_stdout = output;
    return .{ .generated = .{ .file = &output.generated_file } };
}

/// Adds an additional input files that, when modified, indicates that this Run
/// step should be re-executed.
/// If the Run step is determined to have side-effects, the Run step is always
/// executed when it appears in the build graph, regardless of whether this
/// file has been modified.
pub fn addFileInput(self: *Run, file_input: std.Build.LazyPath) void {
    file_input.addStepDependencies(&self.step);
    self.file_inputs.append(self.step.owner.allocator, file_input.dupe(self.step.owner)) catch @panic("OOM");
}

/// Returns whether the Run step has side effects *other than* updating the output arguments.
fn hasSideEffects(run: Run) bool {
    if (run.has_side_effects) return true;
    return switch (run.stdio) {
        .infer_from_args => !run.hasAnyOutputArgs(),
        .inherit => true,
        .check => false,
        .zig_test => false,
    };
}

fn hasAnyOutputArgs(run: Run) bool {
    if (run.captured_stdout != null) return true;
    if (run.captured_stderr != null) return true;
    for (run.argv.items) |arg| switch (arg) {
        .output_file, .output_directory => return true,
        else => continue,
    };
    return false;
}

fn checksContainStdout(checks: []const StdIo.Check) bool {
    for (checks) |check| switch (check) {
        .expect_stderr_exact,
        .expect_stderr_match,
        .expect_term,
        => continue,

        .expect_stdout_exact,
        .expect_stdout_match,
        => return true,
    };
    return false;
}

fn checksContainStderr(checks: []const StdIo.Check) bool {
    for (checks) |check| switch (check) {
        .expect_stdout_exact,
        .expect_stdout_match,
        .expect_term,
        => continue,

        .expect_stderr_exact,
        .expect_stderr_match,
        => return true,
    };
    return false;
}

/// If `path` is cwd-relative, make it relative to the cwd of the child instead.
///
/// Whenever a path is included in the argv of a child, it should be put through this function first
/// to make sure the child doesn't see paths relative to a cwd other than its own.
fn convertPathArg(run: *Run, path: Build.Cache.Path) []const u8 {
    const b = run.step.owner;
    const path_str = path.toString(b.graph.arena) catch @panic("OOM");
    if (std.fs.path.isAbsolute(path_str)) {
        // Absolute paths don't need changing.
        return path_str;
    }
    const child_cwd_rel: []const u8 = rel: {
        const child_lazy_cwd = run.cwd orelse break :rel path_str;
        const child_cwd = child_lazy_cwd.getPath3(b, &run.step).toString(b.graph.arena) catch @panic("OOM");
        // Convert it from relative to *our* cwd, to relative to the *child's* cwd.
        break :rel std.fs.path.relative(b.graph.arena, child_cwd, path_str) catch @panic("OOM");
    };
    assert(!std.fs.path.isAbsolute(child_cwd_rel));
    // We're not done yet. In some cases this path must be prefixed with './':
    // * On POSIX, the executable name cannot be a single component like 'foo'
    // * Some executables might treat a leading '-' like a flag, which we must avoid
    // There's no harm in it, so just *always* apply this prefix.
    return std.fs.path.join(b.graph.arena, &.{ ".", child_cwd_rel }) catch @panic("OOM");
}

const IndexedOutput = struct {
    index: usize,
    tag: @typeInfo(Arg).@"union".tag_type.?,
    output: *Output,
};
fn make(step: *Step, options: Step.MakeOptions) !void {
    const prog_node = options.progress_node;
    const b = step.owner;
    const arena = b.allocator;
    const run: *Run = @fieldParentPtr("step", step);
    const has_side_effects = run.hasSideEffects();

    var argv_list = std.ArrayList([]const u8).init(arena);
    var output_placeholders = std.ArrayList(IndexedOutput).init(arena);

    var man = b.graph.cache.obtain();
    defer man.deinit();

    if (run.env_map) |env_map| {
        const KV = struct { []const u8, []const u8 };
        var kv_pairs = try std.ArrayList(KV).initCapacity(arena, env_map.count());
        var iter = env_map.iterator();
        while (iter.next()) |entry| {
            kv_pairs.appendAssumeCapacity(.{ entry.key_ptr.*, entry.value_ptr.* });
        }

        std.mem.sortUnstable(KV, kv_pairs.items, {}, struct {
            fn lessThan(_: void, kv1: KV, kv2: KV) bool {
                const k1 = kv1[0];
                const k2 = kv2[0];

                if (k1.len != k2.len) return k1.len < k2.len;

                for (k1, k2) |c1, c2| {
                    if (c1 == c2) continue;
                    return c1 < c2;
                }
                unreachable; // two keys cannot be equal
            }
        }.lessThan);

        for (kv_pairs.items) |kv| {
            man.hash.addBytes(kv[0]);
            man.hash.addBytes(kv[1]);
        }
    }

    for (run.argv.items) |arg| {
        switch (arg) {
            .bytes => |bytes| {
                try argv_list.append(bytes);
                man.hash.addBytes(bytes);
            },
            .lazy_path => |file| {
                const file_path = file.lazy_path.getPath3(b, step);
                try argv_list.append(b.fmt("{s}{s}", .{ file.prefix, run.convertPathArg(file_path) }));
                man.hash.addBytes(file.prefix);
                _ = try man.addFilePath(file_path, null);
            },
            .decorated_directory => |dd| {
                const file_path = dd.lazy_path.getPath3(b, step);
                const resolved_arg = b.fmt("{s}{s}{s}", .{ dd.prefix, run.convertPathArg(file_path), dd.suffix });
                try argv_list.append(resolved_arg);
                man.hash.addBytes(resolved_arg);
            },
            .artifact => |pa| {
                const artifact = pa.artifact;

                if (artifact.rootModuleTarget().os.tag == .windows) {
                    // On Windows we don't have rpaths so we have to add .dll search paths to PATH
                    run.addPathForDynLibs(artifact);
                }
                const file_path = artifact.installed_path orelse artifact.generated_bin.?.path.?;

                try argv_list.append(b.fmt("{s}{s}", .{
                    pa.prefix,
                    run.convertPathArg(.{ .root_dir = .cwd(), .sub_path = file_path }),
                }));

                _ = try man.addFile(file_path, null);
            },
            .output_file, .output_directory => |output| {
                man.hash.addBytes(output.prefix);
                man.hash.addBytes(output.basename);
                // Add a placeholder into the argument list because we need the
                // manifest hash to be updated with all arguments before the
                // object directory is computed.
                try output_placeholders.append(.{
                    .index = argv_list.items.len,
                    .tag = arg,
                    .output = output,
                });
                _ = try argv_list.addOne();
            },
        }
    }

    switch (run.stdin) {
        .bytes => |bytes| {
            man.hash.addBytes(bytes);
        },
        .lazy_path => |lazy_path| {
            const file_path = lazy_path.getPath2(b, step);
            _ = try man.addFile(file_path, null);
        },
        .none => {},
    }

    if (run.captured_stdout) |output| {
        man.hash.addBytes(output.basename);
    }

    if (run.captured_stderr) |output| {
        man.hash.addBytes(output.basename);
    }

    hashStdIo(&man.hash, run.stdio);

    for (run.file_inputs.items) |lazy_path| {
        _ = try man.addFile(lazy_path.getPath2(b, step), null);
    }

    if (run.cwd) |cwd| {
        const cwd_path = cwd.getPath3(b, step);
        _ = man.hash.addBytes(try cwd_path.toString(arena));
    }

    if (!has_side_effects and try step.cacheHitAndWatch(&man)) {
        // cache hit, skip running command
        const digest = man.final();

        try populateGeneratedPaths(
            arena,
            output_placeholders.items,
            run.captured_stdout,
            run.captured_stderr,
            b.cache_root,
            &digest,
        );

        step.result_cached = true;
        return;
    }

    const dep_output_file = run.dep_output_file orelse {
        // We already know the final output paths, use them directly.
        const digest = if (has_side_effects)
            man.hash.final()
        else
            man.final();

        try populateGeneratedPaths(
            arena,
            output_placeholders.items,
            run.captured_stdout,
            run.captured_stderr,
            b.cache_root,
            &digest,
        );

        const output_dir_path = "o" ++ fs.path.sep_str ++ &digest;
        for (output_placeholders.items) |placeholder| {
            const output_sub_path = b.pathJoin(&.{ output_dir_path, placeholder.output.basename });
            const output_sub_dir_path = switch (placeholder.tag) {
                .output_file => fs.path.dirname(output_sub_path).?,
                .output_directory => output_sub_path,
                else => unreachable,
            };
            b.cache_root.handle.makePath(output_sub_dir_path) catch |err| {
                return step.fail("unable to make path '{f}{s}': {s}", .{
                    b.cache_root, output_sub_dir_path, @errorName(err),
                });
            };
            const arg_output_path = run.convertPathArg(.{
                .root_dir = .cwd(),
                .sub_path = placeholder.output.generated_file.getPath(),
            });
            argv_list.items[placeholder.index] = if (placeholder.output.prefix.len == 0)
                arg_output_path
            else
                b.fmt("{s}{s}", .{ placeholder.output.prefix, arg_output_path });
        }

        try runCommand(run, argv_list.items, has_side_effects, output_dir_path, prog_node, null);
        if (!has_side_effects) try step.writeManifestAndWatch(&man);
        return;
    };

    // We do not know the final output paths yet, use temp paths to run the command.
    const rand_int = std.crypto.random.int(u64);
    const tmp_dir_path = "tmp" ++ fs.path.sep_str ++ std.fmt.hex(rand_int);

    for (output_placeholders.items) |placeholder| {
        const output_components = .{ tmp_dir_path, placeholder.output.basename };
        const output_sub_path = b.pathJoin(&output_components);
        const output_sub_dir_path = switch (placeholder.tag) {
            .output_file => fs.path.dirname(output_sub_path).?,
            .output_directory => output_sub_path,
            else => unreachable,
        };
        b.cache_root.handle.makePath(output_sub_dir_path) catch |err| {
            return step.fail("unable to make path '{f}{s}': {s}", .{
                b.cache_root, output_sub_dir_path, @errorName(err),
            });
        };
        const raw_output_path: Build.Cache.Path = .{
            .root_dir = b.cache_root,
            .sub_path = b.pathJoin(&output_components),
        };
        placeholder.output.generated_file.path = raw_output_path.toString(b.graph.arena) catch @panic("OOM");
        argv_list.items[placeholder.index] = b.fmt("{s}{s}", .{
            placeholder.output.prefix,
            run.convertPathArg(raw_output_path),
        });
    }

    try runCommand(run, argv_list.items, has_side_effects, tmp_dir_path, prog_node, null);

    const dep_file_dir = std.fs.cwd();
    const dep_file_basename = dep_output_file.generated_file.getPath2(b, step);
    if (has_side_effects)
        try man.addDepFile(dep_file_dir, dep_file_basename)
    else
        try man.addDepFilePost(dep_file_dir, dep_file_basename);

    const digest = if (has_side_effects)
        man.hash.final()
    else
        man.final();

    const any_output = output_placeholders.items.len > 0 or
        run.captured_stdout != null or run.captured_stderr != null;

    // Rename into place
    if (any_output) {
        const o_sub_path = "o" ++ fs.path.sep_str ++ &digest;

        b.cache_root.handle.rename(tmp_dir_path, o_sub_path) catch |err| {
            if (err == error.PathAlreadyExists) {
                b.cache_root.handle.deleteTree(o_sub_path) catch |del_err| {
                    return step.fail("unable to remove dir '{f}'{s}: {s}", .{
                        b.cache_root,
                        tmp_dir_path,
                        @errorName(del_err),
                    });
                };
                b.cache_root.handle.rename(tmp_dir_path, o_sub_path) catch |retry_err| {
                    return step.fail("unable to rename dir '{f}{s}' to '{f}{s}': {s}", .{
                        b.cache_root,          tmp_dir_path,
                        b.cache_root,          o_sub_path,
                        @errorName(retry_err),
                    });
                };
            } else {
                return step.fail("unable to rename dir '{f}{s}' to '{f}{s}': {s}", .{
                    b.cache_root,    tmp_dir_path,
                    b.cache_root,    o_sub_path,
                    @errorName(err),
                });
            }
        };
    }

    if (!has_side_effects) try step.writeManifestAndWatch(&man);

    try populateGeneratedPaths(
        arena,
        output_placeholders.items,
        run.captured_stdout,
        run.captured_stderr,
        b.cache_root,
        &digest,
    );
}

pub fn rerunInFuzzMode(
    run: *Run,
    fuzz: *std.Build.Fuzz,
    unit_test_index: u32,
    prog_node: std.Progress.Node,
) !void {
    const step = &run.step;
    const b = step.owner;
    const arena = b.allocator;
    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (run.argv.items) |arg| {
        switch (arg) {
            .bytes => |bytes| {
                try argv_list.append(arena, bytes);
            },
            .lazy_path => |file| {
                const file_path = file.lazy_path.getPath3(b, step);
                try argv_list.append(arena, b.fmt("{s}{s}", .{ file.prefix, run.convertPathArg(file_path) }));
            },
            .decorated_directory => |dd| {
                const file_path = dd.lazy_path.getPath3(b, step);
                try argv_list.append(arena, b.fmt("{s}{s}{s}", .{ dd.prefix, run.convertPathArg(file_path), dd.suffix }));
            },
            .artifact => |pa| {
                const artifact = pa.artifact;
                const file_path: []const u8 = p: {
                    if (artifact == run.producer.?) break :p b.fmt("{f}", .{run.rebuilt_executable.?});
                    break :p artifact.installed_path orelse artifact.generated_bin.?.path.?;
                };
                try argv_list.append(arena, b.fmt("{s}{s}", .{
                    pa.prefix,
                    run.convertPathArg(.{ .root_dir = .cwd(), .sub_path = file_path }),
                }));
            },
            .output_file, .output_directory => unreachable,
        }
    }
    const has_side_effects = false;
    const rand_int = std.crypto.random.int(u64);
    const tmp_dir_path = "tmp" ++ fs.path.sep_str ++ std.fmt.hex(rand_int);
    try runCommand(run, argv_list.items, has_side_effects, tmp_dir_path, prog_node, .{
        .unit_test_index = unit_test_index,
        .fuzz = fuzz,
    });
}

fn populateGeneratedPaths(
    arena: std.mem.Allocator,
    output_placeholders: []const IndexedOutput,
    captured_stdout: ?*Output,
    captured_stderr: ?*Output,
    cache_root: Build.Cache.Directory,
    digest: *const Build.Cache.HexDigest,
) !void {
    for (output_placeholders) |placeholder| {
        placeholder.output.generated_file.path = try cache_root.join(arena, &.{
            "o", digest, placeholder.output.basename,
        });
    }

    if (captured_stdout) |output| {
        output.generated_file.path = try cache_root.join(arena, &.{
            "o", digest, output.basename,
        });
    }

    if (captured_stderr) |output| {
        output.generated_file.path = try cache_root.join(arena, &.{
            "o", digest, output.basename,
        });
    }
}

fn formatTerm(term: ?std.process.Child.Term, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (term) |t| switch (t) {
        .Exited => |code| try w.print("exited with code {d}", .{code}),
        .Signal => |sig| try w.print("terminated with signal {d}", .{sig}),
        .Stopped => |sig| try w.print("stopped with signal {d}", .{sig}),
        .Unknown => |code| try w.print("terminated for unknown reason with code {d}", .{code}),
    } else {
        try w.writeAll("exited with any code");
    }
}
fn fmtTerm(term: ?std.process.Child.Term) std.fmt.Formatter(?std.process.Child.Term, formatTerm) {
    return .{ .data = term };
}

fn termMatches(expected: ?std.process.Child.Term, actual: std.process.Child.Term) bool {
    return if (expected) |e| switch (e) {
        .Exited => |expected_code| switch (actual) {
            .Exited => |actual_code| expected_code == actual_code,
            else => false,
        },
        .Signal => |expected_sig| switch (actual) {
            .Signal => |actual_sig| expected_sig == actual_sig,
            else => false,
        },
        .Stopped => |expected_sig| switch (actual) {
            .Stopped => |actual_sig| expected_sig == actual_sig,
            else => false,
        },
        .Unknown => |expected_code| switch (actual) {
            .Unknown => |actual_code| expected_code == actual_code,
            else => false,
        },
    } else switch (actual) {
        .Exited => true,
        else => false,
    };
}

const FuzzContext = struct {
    fuzz: *std.Build.Fuzz,
    unit_test_index: u32,
};

fn runCommand(
    run: *Run,
    argv: []const []const u8,
    has_side_effects: bool,
    output_dir_path: []const u8,
    prog_node: std.Progress.Node,
    fuzz_context: ?FuzzContext,
) !void {
    const step = &run.step;
    const b = step.owner;
    const arena = b.allocator;

    const cwd: ?[]const u8 = if (run.cwd) |lazy_cwd| lazy_cwd.getPath2(b, step) else null;

    try step.handleChildProcUnsupported(cwd, argv);
    try Step.handleVerbose2(step.owner, cwd, run.env_map, argv);

    const allow_skip = switch (run.stdio) {
        .check, .zig_test => run.skip_foreign_checks,
        else => false,
    };

    var interp_argv = std.ArrayList([]const u8).init(b.allocator);
    defer interp_argv.deinit();

    var env_map = run.env_map orelse &b.graph.env_map;

    const result = spawnChildAndCollect(run, argv, env_map, has_side_effects, prog_node, fuzz_context) catch |err| term: {
        // InvalidExe: cpu arch mismatch
        // FileNotFound: can happen with a wrong dynamic linker path
        if (err == error.InvalidExe or err == error.FileNotFound) interpret: {
            // TODO: learn the target from the binary directly rather than from
            // relying on it being a Compile step. This will make this logic
            // work even for the edge case that the binary was produced by a
            // third party.
            const exe = switch (run.argv.items[0]) {
                .artifact => |exe| exe.artifact,
                else => break :interpret,
            };
            switch (exe.kind) {
                .exe, .@"test" => {},
                else => break :interpret,
            }

            const root_target = exe.rootModuleTarget();
            const need_cross_libc = exe.is_linking_libc and
                (root_target.isGnuLibC() or (root_target.isMuslLibC() and exe.linkage == .dynamic));
            const other_target = exe.root_module.resolved_target.?.result;
            switch (std.zig.system.getExternalExecutor(&b.graph.host.result, &other_target, .{
                .qemu_fixes_dl = need_cross_libc and b.libc_runtimes_dir != null,
                .link_libc = exe.is_linking_libc,
            })) {
                .native, .rosetta => {
                    if (allow_skip) return error.MakeSkipped;
                    break :interpret;
                },
                .wine => |bin_name| {
                    if (b.enable_wine) {
                        try interp_argv.append(bin_name);
                        try interp_argv.appendSlice(argv);

                        // Wine's excessive stderr logging is only situationally helpful. Disable it by default, but
                        // allow the user to override it (e.g. with `WINEDEBUG=err+all`) if desired.
                        if (env_map.get("WINEDEBUG") == null) {
                            // We don't own `env_map` at this point, so create a copy in order to modify it.
                            const new_env_map = arena.create(EnvMap) catch @panic("OOM");
                            new_env_map.hash_map = try env_map.hash_map.cloneWithAllocator(arena);
                            try new_env_map.put("WINEDEBUG", "-all");

                            env_map = new_env_map;
                        }
                    } else {
                        return failForeign(run, "-fwine", argv[0], exe);
                    }
                },
                .qemu => |bin_name| {
                    if (b.enable_qemu) {
                        try interp_argv.append(bin_name);

                        if (need_cross_libc) {
                            if (b.libc_runtimes_dir) |dir| {
                                try interp_argv.append("-L");
                                try interp_argv.append(b.pathJoin(&.{
                                    dir,
                                    try if (root_target.isGnuLibC()) std.zig.target.glibcRuntimeTriple(
                                        b.allocator,
                                        root_target.cpu.arch,
                                        root_target.os.tag,
                                        root_target.abi,
                                    ) else if (root_target.isMuslLibC()) std.zig.target.muslRuntimeTriple(
                                        b.allocator,
                                        root_target.cpu.arch,
                                        root_target.abi,
                                    ) else unreachable,
                                }));
                            } else return failForeign(run, "--libc-runtimes", argv[0], exe);
                        }

                        try interp_argv.appendSlice(argv);
                    } else return failForeign(run, "-fqemu", argv[0], exe);
                },
                .darling => |bin_name| {
                    if (b.enable_darling) {
                        try interp_argv.append(bin_name);
                        try interp_argv.appendSlice(argv);
                    } else {
                        return failForeign(run, "-fdarling", argv[0], exe);
                    }
                },
                .wasmtime => |bin_name| {
                    if (b.enable_wasmtime) {
                        // https://github.com/bytecodealliance/wasmtime/issues/7384
                        //
                        // In Wasmtime versions prior to 14, options passed after the module name
                        // could be interpreted by Wasmtime if it recognized them. As with many CLI
                        // tools, the `--` token is used to stop that behavior and indicate that the
                        // remaining arguments are for the WASM program being executed. Historically,
                        // we passed `--` after the module name here.
                        //
                        // After version 14, the `--` can no longer be passed after the module name,
                        // but is also not necessary as Wasmtime will no longer try to interpret
                        // options after the module name. So, we could just simply omit `--` for
                        // newer Wasmtime versions. But to maintain compatibility for older versions
                        // that still try to interpret options after the module name, we have moved
                        // the `--` before the module name. This appears to work for both old and
                        // new Wasmtime versions.
                        try interp_argv.append(bin_name);
                        try interp_argv.append("--dir=.");
                        try interp_argv.append("--");
                        try interp_argv.append(argv[0]);
                        try interp_argv.appendSlice(argv[1..]);
                    } else {
                        return failForeign(run, "-fwasmtime", argv[0], exe);
                    }
                },
                .bad_dl => |foreign_dl| {
                    if (allow_skip) return error.MakeSkipped;

                    const host_dl = b.graph.host.result.dynamic_linker.get() orelse "(none)";

                    return step.fail(
                        \\the host system is unable to execute binaries from the target
                        \\  because the host dynamic linker is '{s}',
                        \\  while the target dynamic linker is '{s}'.
                        \\  consider setting the dynamic linker or enabling skip_foreign_checks in the Run step
                    , .{ host_dl, foreign_dl });
                },
                .bad_os_or_cpu => {
                    if (allow_skip) return error.MakeSkipped;

                    const host_name = try b.graph.host.result.zigTriple(b.allocator);
                    const foreign_name = try root_target.zigTriple(b.allocator);

                    return step.fail("the host system ({s}) is unable to execute binaries from the target ({s})", .{
                        host_name, foreign_name,
                    });
                },
            }

            if (root_target.os.tag == .windows) {
                // On Windows we don't have rpaths so we have to add .dll search paths to PATH
                run.addPathForDynLibs(exe);
            }

            try Step.handleVerbose2(step.owner, cwd, run.env_map, interp_argv.items);

            break :term spawnChildAndCollect(run, interp_argv.items, env_map, has_side_effects, prog_node, fuzz_context) catch |e| {
                if (!run.failing_to_execute_foreign_is_an_error) return error.MakeSkipped;

                return step.fail("unable to spawn interpreter {s}: {s}", .{
                    interp_argv.items[0], @errorName(e),
                });
            };
        }

        return step.fail("failed to spawn and capture stdio from {s}: {s}", .{ argv[0], @errorName(err) });
    };

    step.result_duration_ns = result.elapsed_ns;
    step.result_peak_rss = result.peak_rss;
    step.test_results = result.stdio.test_results;
    if (result.stdio.test_metadata) |tm|
        run.cached_test_metadata = tm.toCachedTestMetadata();

    const final_argv = if (interp_argv.items.len == 0) argv else interp_argv.items;

    if (fuzz_context != null) {
        try step.handleChildProcessTerm(result.term, cwd, final_argv);
        return;
    }

    // Capture stdout and stderr to GeneratedFile objects.
    const Stream = struct {
        captured: ?*Output,
        bytes: ?[]const u8,
    };
    for ([_]Stream{
        .{
            .captured = run.captured_stdout,
            .bytes = result.stdio.stdout,
        },
        .{
            .captured = run.captured_stderr,
            .bytes = result.stdio.stderr,
        },
    }) |stream| {
        if (stream.captured) |output| {
            const output_components = .{ output_dir_path, output.basename };
            const output_path = try b.cache_root.join(arena, &output_components);
            output.generated_file.path = output_path;

            const sub_path = b.pathJoin(&output_components);
            const sub_path_dirname = fs.path.dirname(sub_path).?;
            b.cache_root.handle.makePath(sub_path_dirname) catch |err| {
                return step.fail("unable to make path '{f}{s}': {s}", .{
                    b.cache_root, sub_path_dirname, @errorName(err),
                });
            };
            b.cache_root.handle.writeFile(.{ .sub_path = sub_path, .data = stream.bytes.? }) catch |err| {
                return step.fail("unable to write file '{f}{s}': {s}", .{
                    b.cache_root, sub_path, @errorName(err),
                });
            };
        }
    }

    switch (run.stdio) {
        .check => |checks| for (checks.items) |check| switch (check) {
            .expect_stderr_exact => |expected_bytes| {
                if (!mem.eql(u8, expected_bytes, result.stdio.stderr.?)) {
                    return step.fail(
                        \\
                        \\========= expected this stderr: =========
                        \\{s}
                        \\========= but found: ====================
                        \\{s}
                        \\========= from the following command: ===
                        \\{s}
                    , .{
                        expected_bytes,
                        result.stdio.stderr.?,
                        try Step.allocPrintCmd(arena, cwd, final_argv),
                    });
                }
            },
            .expect_stderr_match => |match| {
                if (mem.indexOf(u8, result.stdio.stderr.?, match) == null) {
                    return step.fail(
                        \\
                        \\========= expected to find in stderr: =========
                        \\{s}
                        \\========= but stderr does not contain it: =====
                        \\{s}
                        \\========= from the following command: =========
                        \\{s}
                    , .{
                        match,
                        result.stdio.stderr.?,
                        try Step.allocPrintCmd(arena, cwd, final_argv),
                    });
                }
            },
            .expect_stdout_exact => |expected_bytes| {
                if (!mem.eql(u8, expected_bytes, result.stdio.stdout.?)) {
                    return step.fail(
                        \\
                        \\========= expected this stdout: =========
                        \\{s}
                        \\========= but found: ====================
                        \\{s}
                        \\========= from the following command: ===
                        \\{s}
                    , .{
                        expected_bytes,
                        result.stdio.stdout.?,
                        try Step.allocPrintCmd(arena, cwd, final_argv),
                    });
                }
            },
            .expect_stdout_match => |match| {
                if (mem.indexOf(u8, result.stdio.stdout.?, match) == null) {
                    return step.fail(
                        \\
                        \\========= expected to find in stdout: =========
                        \\{s}
                        \\========= but stdout does not contain it: =====
                        \\{s}
                        \\========= from the following command: =========
                        \\{s}
                    , .{
                        match,
                        result.stdio.stdout.?,
                        try Step.allocPrintCmd(arena, cwd, final_argv),
                    });
                }
            },
            .expect_term => |expected_term| {
                if (!termMatches(expected_term, result.term)) {
                    return step.fail("the following command {f} (expected {f}):\n{s}", .{
                        fmtTerm(result.term),
                        fmtTerm(expected_term),
                        try Step.allocPrintCmd(arena, cwd, final_argv),
                    });
                }
            },
        },
        .zig_test => {
            const prefix: []const u8 = p: {
                if (result.stdio.test_metadata) |tm| {
                    if (tm.next_index > 0 and tm.next_index <= tm.names.len) {
                        const name = tm.testName(tm.next_index - 1);
                        break :p b.fmt("while executing test '{s}', ", .{name});
                    }
                }
                break :p "";
            };
            const expected_term: std.process.Child.Term = .{ .Exited = 0 };
            if (!termMatches(expected_term, result.term)) {
                return step.fail("{s}the following command {f} (expected {f}):\n{s}", .{
                    prefix,
                    fmtTerm(result.term),
                    fmtTerm(expected_term),
                    try Step.allocPrintCmd(arena, cwd, final_argv),
                });
            }
            if (!result.stdio.test_results.isSuccess()) {
                return step.fail(
                    "{s}the following test command failed:\n{s}",
                    .{ prefix, try Step.allocPrintCmd(arena, cwd, final_argv) },
                );
            }
        },
        else => {
            // On failure, print stderr if captured.
            const bad_exit = switch (result.term) {
                .Exited => |code| code != 0,
                .Signal, .Stopped, .Unknown => true,
            };

            if (bad_exit) if (result.stdio.stderr) |err| {
                try step.addError("stderr:\n{s}", .{err});
            };

            try step.handleChildProcessTerm(result.term, cwd, final_argv);
        },
    }
}

const ChildProcResult = struct {
    term: std.process.Child.Term,
    elapsed_ns: u64,
    peak_rss: usize,

    stdio: StdIoResult,
};

fn spawnChildAndCollect(
    run: *Run,
    argv: []const []const u8,
    env_map: *EnvMap,
    has_side_effects: bool,
    prog_node: std.Progress.Node,
    fuzz_context: ?FuzzContext,
) !ChildProcResult {
    const b = run.step.owner;
    const arena = b.allocator;

    if (fuzz_context != null) {
        assert(!has_side_effects);
        assert(run.stdio == .zig_test);
    }

    var child = std.process.Child.init(argv, arena);
    if (run.cwd) |lazy_cwd| {
        child.cwd = lazy_cwd.getPath2(b, &run.step);
    }
    child.env_map = env_map;
    child.request_resource_usage_statistics = true;

    child.stdin_behavior = switch (run.stdio) {
        .infer_from_args => if (has_side_effects) .Inherit else .Ignore,
        .inherit => .Inherit,
        .check => .Ignore,
        .zig_test => .Pipe,
    };
    child.stdout_behavior = switch (run.stdio) {
        .infer_from_args => if (has_side_effects) .Inherit else .Ignore,
        .inherit => .Inherit,
        .check => |checks| if (checksContainStdout(checks.items)) .Pipe else .Ignore,
        .zig_test => .Pipe,
    };
    child.stderr_behavior = switch (run.stdio) {
        .infer_from_args => if (has_side_effects) .Inherit else .Pipe,
        .inherit => .Inherit,
        .check => .Pipe,
        .zig_test => .Pipe,
    };
    if (run.captured_stdout != null) child.stdout_behavior = .Pipe;
    if (run.captured_stderr != null) child.stderr_behavior = .Pipe;
    if (run.stdin != .none) {
        assert(run.stdio != .inherit);
        child.stdin_behavior = .Pipe;
    }

    const inherit = child.stdout_behavior == .Inherit or child.stderr_behavior == .Inherit;

    if (run.stdio != .zig_test and !run.disable_zig_progress and !inherit) {
        child.progress_node = prog_node;
    }

    const term, const result, const elapsed_ns = t: {
        if (inherit) std.debug.lockStdErr();
        defer if (inherit) std.debug.unlockStdErr();

        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
        }

        // We need to report `error.InvalidExe` *now* if applicable.
        try child.waitForSpawn();

        var timer = try std.time.Timer.start();

        const result = if (run.stdio == .zig_test)
            try evalZigTest(run, &child, prog_node, fuzz_context)
        else
            try evalGeneric(run, &child);

        break :t .{ try child.wait(), result, timer.read() };
    };

    return .{
        .stdio = result,
        .term = term,
        .elapsed_ns = elapsed_ns,
        .peak_rss = child.resource_usage_statistics.getMaxRss() orelse 0,
    };
}

const StdIoResult = struct {
    stdout: ?[]const u8,
    stderr: ?[]const u8,
    test_results: Step.TestResults,
    test_metadata: ?TestMetadata,
};

fn evalZigTest(
    run: *Run,
    child: *std.process.Child,
    prog_node: std.Progress.Node,
    fuzz_context: ?FuzzContext,
) !StdIoResult {
    const gpa = run.step.owner.allocator;
    const arena = run.step.owner.allocator;

    var poller = std.Io.poll(gpa, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    // If this is `true`, we avoid ever entering the polling loop below, because the stdin pipe has
    // somehow already closed; instead, we go straight to capturing stderr in case it has anything
    // useful.
    const first_write_failed = if (fuzz_context) |fuzz| failed: {
        sendRunTestMessage(child.stdin.?, .start_fuzzing, fuzz.unit_test_index) catch |err| {
            try run.step.addError("unable to write stdin: {s}", .{@errorName(err)});
            break :failed true;
        };
        break :failed false;
    } else failed: {
        run.fuzz_tests.clearRetainingCapacity();
        sendMessage(child.stdin.?, .query_test_metadata) catch |err| {
            try run.step.addError("unable to write stdin: {s}", .{@errorName(err)});
            break :failed true;
        };
        break :failed false;
    };

    var fail_count: u32 = 0;
    var skip_count: u32 = 0;
    var leak_count: u32 = 0;
    var test_count: u32 = 0;
    var log_err_count: u32 = 0;

    var metadata: ?TestMetadata = null;
    var coverage_id: ?u64 = null;

    var sub_prog_node: ?std.Progress.Node = null;
    defer if (sub_prog_node) |n| n.end();

    const stdout = poller.reader(.stdout);
    const stderr = poller.reader(.stderr);
    const any_write_failed = first_write_failed or poll: while (true) {
        const Header = std.zig.Server.Message.Header;
        while (stdout.buffered().len < @sizeOf(Header)) if (!try poller.poll()) break :poll false;
        const header = stdout.takeStruct(Header, .little) catch unreachable;
        while (stdout.buffered().len < header.bytes_len) if (!try poller.poll()) break :poll false;
        const body = stdout.take(header.bytes_len) catch unreachable;
        switch (header.tag) {
            .zig_version => {
                if (!std.mem.eql(u8, builtin.zig_version_string, body)) {
                    return run.step.fail(
                        "zig version mismatch build runner vs compiler: '{s}' vs '{s}'",
                        .{ builtin.zig_version_string, body },
                    );
                }
            },
            .test_metadata => {
                assert(fuzz_context == null);
                const TmHdr = std.zig.Server.Message.TestMetadata;
                const tm_hdr = @as(*align(1) const TmHdr, @ptrCast(body));
                test_count = tm_hdr.tests_len;

                const names_bytes = body[@sizeOf(TmHdr)..][0 .. test_count * @sizeOf(u32)];
                const expected_panic_msgs_bytes = body[@sizeOf(TmHdr) + names_bytes.len ..][0 .. test_count * @sizeOf(u32)];
                const string_bytes = body[@sizeOf(TmHdr) + names_bytes.len + expected_panic_msgs_bytes.len ..][0..tm_hdr.string_bytes_len];

                const names = std.mem.bytesAsSlice(u32, names_bytes);
                const expected_panic_msgs = std.mem.bytesAsSlice(u32, expected_panic_msgs_bytes);
                const names_aligned = try arena.alloc(u32, names.len);
                for (names_aligned, names) |*dest, src| dest.* = src;

                const expected_panic_msgs_aligned = try arena.alloc(u32, expected_panic_msgs.len);
                for (expected_panic_msgs_aligned, expected_panic_msgs) |*dest, src| dest.* = src;

                prog_node.setEstimatedTotalItems(names.len);
                metadata = .{
                    .string_bytes = try arena.dupe(u8, string_bytes),
                    .names = names_aligned,
                    .expected_panic_msgs = expected_panic_msgs_aligned,
                    .next_index = 0,
                    .prog_node = prog_node,
                };

                requestNextTest(child.stdin.?, &metadata.?, &sub_prog_node) catch |err| {
                    try run.step.addError("unable to write stdin: {s}", .{@errorName(err)});
                    break :poll true;
                };
            },
            .test_results => {
                assert(fuzz_context == null);
                const md = metadata.?;

                const TrHdr = std.zig.Server.Message.TestResults;
                const tr_hdr = @as(*align(1) const TrHdr, @ptrCast(body));
                fail_count +|= @intFromBool(tr_hdr.flags.fail);
                skip_count +|= @intFromBool(tr_hdr.flags.skip);
                leak_count +|= @intFromBool(tr_hdr.flags.leak);
                log_err_count +|= tr_hdr.flags.log_err_count;

                if (tr_hdr.flags.fuzz) try run.fuzz_tests.append(gpa, tr_hdr.index);

                if (tr_hdr.flags.fail or tr_hdr.flags.leak or tr_hdr.flags.log_err_count > 0) {
                    const name = std.mem.sliceTo(md.string_bytes[md.names[tr_hdr.index]..], 0);
                    const stderr_contents = stderr.buffered();
                    stderr.toss(stderr_contents.len);
                    const msg = std.mem.trim(u8, stderr_contents, "\n");
                    const label = if (tr_hdr.flags.fail)
                        "failed"
                    else if (tr_hdr.flags.leak)
                        "leaked"
                    else if (tr_hdr.flags.log_err_count > 0)
                        "logged errors"
                    else
                        unreachable;
                    if (msg.len > 0) {
                        try run.step.addError("'{s}' {s}: {s}", .{ name, label, msg });
                    } else {
                        try run.step.addError("'{s}' {s}", .{ name, label });
                    }
                }

                requestNextTest(child.stdin.?, &metadata.?, &sub_prog_node) catch |err| {
                    try run.step.addError("unable to write stdin: {s}", .{@errorName(err)});
                    break :poll true;
                };
            },
            .coverage_id => {
                const fuzz = fuzz_context.?.fuzz;
                const msg_ptr: *align(1) const u64 = @ptrCast(body);
                coverage_id = msg_ptr.*;
                {
                    fuzz.queue_mutex.lock();
                    defer fuzz.queue_mutex.unlock();
                    try fuzz.msg_queue.append(fuzz.ws.gpa, .{ .coverage = .{
                        .id = coverage_id.?,
                        .run = run,
                    } });
                    fuzz.queue_cond.signal();
                }
            },
            .fuzz_start_addr => {
                const fuzz = fuzz_context.?.fuzz;
                const msg_ptr: *align(1) const u64 = @ptrCast(body);
                const addr = msg_ptr.*;
                {
                    fuzz.queue_mutex.lock();
                    defer fuzz.queue_mutex.unlock();
                    try fuzz.msg_queue.append(fuzz.ws.gpa, .{ .entry_point = .{
                        .addr = addr,
                        .coverage_id = coverage_id.?,
                    } });
                    fuzz.queue_cond.signal();
                }
            },
            else => {}, // ignore other messages
        }
    };

    if (any_write_failed) {
        // The compiler unexpectedly closed stdin; something is very wrong and has probably crashed.
        // We want to make sure we've captured all of stderr so that it's logged below.
        while (try poller.poll()) {}
    }

    const stderr_contents = std.mem.trim(u8, stderr.buffered(), "\n");
    if (stderr_contents.len > 0) {
        run.step.result_stderr = try arena.dupe(u8, stderr_contents);
    }

    // Send EOF to stdin.
    child.stdin.?.close();
    child.stdin = null;

    return .{
        .stdout = null,
        .stderr = null,
        .test_results = .{
            .test_count = test_count,
            .fail_count = fail_count,
            .skip_count = skip_count,
            .leak_count = leak_count,
            .log_err_count = log_err_count,
        },
        .test_metadata = metadata,
    };
}

const TestMetadata = struct {
    names: []const u32,
    expected_panic_msgs: []const u32,
    string_bytes: []const u8,
    next_index: u32,
    prog_node: std.Progress.Node,

    fn toCachedTestMetadata(tm: TestMetadata) CachedTestMetadata {
        return .{
            .names = tm.names,
            .string_bytes = tm.string_bytes,
        };
    }

    fn testName(tm: TestMetadata, index: u32) []const u8 {
        return tm.toCachedTestMetadata().testName(index);
    }
};

pub const CachedTestMetadata = struct {
    names: []const u32,
    string_bytes: []const u8,

    pub fn testName(tm: CachedTestMetadata, index: u32) []const u8 {
        return std.mem.sliceTo(tm.string_bytes[tm.names[index]..], 0);
    }
};

fn requestNextTest(in: fs.File, metadata: *TestMetadata, sub_prog_node: *?std.Progress.Node) !void {
    while (metadata.next_index < metadata.names.len) {
        const i = metadata.next_index;
        metadata.next_index += 1;

        if (metadata.expected_panic_msgs[i] != 0) continue;

        const name = metadata.testName(i);
        if (sub_prog_node.*) |n| n.end();
        sub_prog_node.* = metadata.prog_node.start(name, 0);

        try sendRunTestMessage(in, .run_test, i);
        return;
    } else {
        try sendMessage(in, .exit);
    }
}

fn sendMessage(file: std.fs.File, tag: std.zig.Client.Message.Tag) !void {
    const header: std.zig.Client.Message.Header = .{
        .tag = tag,
        .bytes_len = 0,
    };
    try file.writeAll(@ptrCast(&header));
}

fn sendRunTestMessage(file: std.fs.File, tag: std.zig.Client.Message.Tag, index: u32) !void {
    const header: std.zig.Client.Message.Header = .{
        .tag = tag,
        .bytes_len = 4,
    };
    const full_msg = std.mem.asBytes(&header) ++ std.mem.asBytes(&index);
    try file.writeAll(full_msg);
}

fn evalGeneric(run: *Run, child: *std.process.Child) !StdIoResult {
    const b = run.step.owner;
    const arena = b.allocator;

    switch (run.stdin) {
        .bytes => |bytes| {
            child.stdin.?.writeAll(bytes) catch |err| {
                return run.step.fail("unable to write stdin: {s}", .{@errorName(err)});
            };
            child.stdin.?.close();
            child.stdin = null;
        },
        .lazy_path => |lazy_path| {
            const path = lazy_path.getPath3(b, &run.step);
            const file = path.root_dir.handle.openFile(path.subPathOrDot(), .{}) catch |err| {
                return run.step.fail("unable to open stdin file: {s}", .{@errorName(err)});
            };
            defer file.close();
            // TODO https://github.com/ziglang/zig/issues/23955
            var buffer: [1024]u8 = undefined;
            var file_reader = file.reader(&buffer);
            var stdin_writer = child.stdin.?.writer(&.{});
            _ = stdin_writer.interface.sendFileAll(&file_reader, .unlimited) catch |err| switch (err) {
                error.ReadFailed => return run.step.fail("failed to read from {f}: {t}", .{
                    path, file_reader.err.?,
                }),
                error.WriteFailed => return run.step.fail("failed to write to stdin: {t}", .{
                    stdin_writer.err.?,
                }),
            };
            child.stdin.?.close();
            child.stdin = null;
        },
        .none => {},
    }

    var stdout_bytes: ?[]const u8 = null;
    var stderr_bytes: ?[]const u8 = null;

    run.stdio_limit = run.stdio_limit.min(.limited(run.max_stdio_size));
    if (child.stdout) |stdout| {
        if (child.stderr) |stderr| {
            var poller = std.Io.poll(arena, enum { stdout, stderr }, .{
                .stdout = stdout,
                .stderr = stderr,
            });
            defer poller.deinit();

            while (try poller.poll()) {
                if (run.stdio_limit.toInt()) |limit| {
                    if (poller.reader(.stderr).buffered().len > limit)
                        return error.StdoutStreamTooLong;
                    if (poller.reader(.stderr).buffered().len > limit)
                        return error.StderrStreamTooLong;
                }
            }

            stdout_bytes = try poller.toOwnedSlice(.stdout);
            stderr_bytes = try poller.toOwnedSlice(.stderr);
        } else {
            var small_buffer: [1]u8 = undefined;
            var stdout_reader = stdout.readerStreaming(&small_buffer);
            stdout_bytes = stdout_reader.interface.allocRemaining(arena, run.stdio_limit) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadFailed => return stdout_reader.err.?,
                error.StreamTooLong => return error.StdoutStreamTooLong,
            };
        }
    } else if (child.stderr) |stderr| {
        var small_buffer: [1]u8 = undefined;
        var stderr_reader = stderr.readerStreaming(&small_buffer);
        stderr_bytes = stderr_reader.interface.allocRemaining(arena, run.stdio_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return stderr_reader.err.?,
            error.StreamTooLong => return error.StderrStreamTooLong,
        };
    }

    if (stderr_bytes) |bytes| if (bytes.len > 0) {
        // Treat stderr as an error message.
        const stderr_is_diagnostic = run.captured_stderr == null and switch (run.stdio) {
            .check => |checks| !checksContainStderr(checks.items),
            else => true,
        };
        if (stderr_is_diagnostic) {
            run.step.result_stderr = bytes;
        }
    };

    return .{
        .stdout = stdout_bytes,
        .stderr = stderr_bytes,
        .test_results = .{},
        .test_metadata = null,
    };
}

fn addPathForDynLibs(run: *Run, artifact: *Step.Compile) void {
    const b = run.step.owner;
    const compiles = artifact.getCompileDependencies(true);
    for (compiles) |compile| {
        if (compile.root_module.resolved_target.?.result.os.tag == .windows and
            compile.isDynamicLibrary())
        {
            addPathDir(run, fs.path.dirname(compile.getEmittedBin().getPath2(b, &run.step)).?);
        }
    }
}

fn failForeign(
    run: *Run,
    suggested_flag: []const u8,
    argv0: []const u8,
    exe: *Step.Compile,
) error{ MakeFailed, MakeSkipped, OutOfMemory } {
    switch (run.stdio) {
        .check, .zig_test => {
            if (run.skip_foreign_checks)
                return error.MakeSkipped;

            const b = run.step.owner;
            const host_name = try b.graph.host.result.zigTriple(b.allocator);
            const foreign_name = try exe.rootModuleTarget().zigTriple(b.allocator);

            return run.step.fail(
                \\unable to spawn foreign binary '{s}' ({s}) on host system ({s})
                \\  consider using {s} or enabling skip_foreign_checks in the Run step
            , .{ argv0, foreign_name, host_name, suggested_flag });
        },
        else => {
            return run.step.fail("unable to spawn foreign binary '{s}'", .{argv0});
        },
    }
}

fn hashStdIo(hh: *std.Build.Cache.HashHelper, stdio: StdIo) void {
    switch (stdio) {
        .infer_from_args, .inherit, .zig_test => {},
        .check => |checks| for (checks.items) |check| {
            hh.add(@as(std.meta.Tag(StdIo.Check), check));
            switch (check) {
                .expect_stderr_exact,
                .expect_stderr_match,
                .expect_stdout_exact,
                .expect_stdout_match,
                => |s| hh.addBytes(s),

                .expect_term => |term| {
                    hh.add(@as(std.meta.Tag(std.process.Child.Term), term));
                    switch (term) {
                        .Exited => |x| hh.add(x),
                        .Signal, .Stopped, .Unknown => |x| hh.add(x),
                    }
                },
            }
        },
    }
}
