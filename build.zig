const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();

    const assets = [_][]const u8{
        "assets/0.png",
        "assets/1.png",
        "assets/2.png",
        "assets/3.png",
        "assets/4.png",
        "assets/5.png",
        "assets/6.png",
        "assets/7.png",
        "assets/8.png",
        "assets/bomb.png",
        "assets/border.png",
        "assets/unk.png",
        "assets/bombsweeper_card.png",
        "pdxinfo",
    };
    const pdx_file_name = "bombsweeper.pdx";

    const playdate_sdk_path = try std.process.getEnvVarOwned(b.allocator, "PLAYDATE_SDK_PATH");
    const pdc_path = try std.fmt.allocPrint(b.allocator, "{s}/bin/pdc", .{playdate_sdk_path});
    const pd_simulator_path = try std.fmt.allocPrint(
        b.allocator,
        "{s}/bin/PlaydateSimulator",
        .{playdate_sdk_path},
    );

    const lib = b.addSharedLibrary("pdex", "src/main.zig", .unversioned);

    const output_path = try std.fs.path.join(b.allocator, &.{ b.install_path, "Source" });
    lib.setOutputDir(output_path);

    lib.setBuildMode(mode);
    lib.install();

    const game_elf = b.addExecutable("pdex.elf", "src/playdate_hardware_main.zig");
    game_elf.step.dependOn(&lib.step);
    game_elf.link_function_sections = true;
    game_elf.stack_size = 61800;
    game_elf.setLinkerScriptPath(.{ .path = "link_map.ld" });
    game_elf.setOutputDir(b.install_path);
    game_elf.setBuildMode(mode);
    const playdate_target = try std.zig.CrossTarget.parse(.{
        .arch_os_abi = "thumb-freestanding-eabihf",
        .cpu_features = "cortex_m7-fp64-fp_armv8d16-fpregs64-vfp2-vfp3d16-vfp4d16",
    });
    game_elf.setTarget(playdate_target);
    if (b.is_release) {
        game_elf.omit_frame_pointer = true;
    }
    game_elf.install();

    const rename_so = b.addSystemCommand(&.{
        "mv",
        "zig-out/Source/libpdex.so",
        "zig-out/Source/pdex.so",
    });
    rename_so.step.dependOn(&game_elf.step);

    const pdc = b.addSystemCommand(&.{
        pdc_path,
        "--skip-unknown",
        "--strip",
        "zig-out/Source",
        "zig-out/" ++ pdx_file_name,
    });

    for (assets) |asset| {
        const copy_assets = b.addSystemCommand(&.{ "cp", asset, "zig-out/Source" });
        copy_assets.step.dependOn(&game_elf.step);
        pdc.step.dependOn(&copy_assets.step);
    }

    const emit_device_binary = b.addSystemCommand(&.{
        "arm-none-eabi-objcopy",
        "-Obinary",
        "zig-out/pdex.elf",
        "zig-out/Source/pdex.bin",
    });
    emit_device_binary.step.dependOn(&game_elf.step);

    pdc.step.dependOn(&rename_so.step);
    pdc.step.dependOn(&emit_device_binary.step);

    b.getInstallStep().dependOn(&pdc.step);

    const run_cmd = b.addSystemCommand(
        &.{ pd_simulator_path, "zig-out/" ++ pdx_file_name },
    );
    run_cmd.step.dependOn(&pdc.step);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
