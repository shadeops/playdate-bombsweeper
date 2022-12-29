const std = @import("std");
const board = @import("board.zig");
const pdapi = @import("playdate_api_definitions.zig");

const bitmap_names = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "border", "unk", "bomb" };
const menu_options = [_][]const u8{ "20", "40", "80" };

const checks = pdapi.LCDPattern{
    0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55,
    0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55,
};

const inv_checks = pdapi.LCDPattern{
    0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55,
    0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa,
};

// Global State
var bitmaps = [_]*pdapi.LCDBitmap{undefined} ** 12;
var game_board: board.GameBoard = undefined;
var num_mines: u32 = 40;
var cur_pos = [2]usize{ 0, 0 };
var mines_menu: ?*pdapi.PDMenuItem = null;

// 1, 2,    4, 5,    8, 10,         16, 20,     25,     40,     50,     80, 100,      200,      400
// 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 16, 20, 24,     30, 40, 48,     60, 80,      120,      240

// playdate.graphics.getBitmapData
// rowbytes is how many bytes are stored in a row. While the API exposes these as u8
// it appears internally they are backed by u32. Since a 8x8 bitmap reports rowbytes=4
// and a 36x36 bitmap reports rowbytes=8, this is further reinforced by the C_API
// Exposure example since it operates in 32bit increments.

//fn buildBitmaps(playdate: *pdapi.PlaydateAPI) void {
//    var mask = playdate.graphics.newBitmap(tile_size, tile_size, @enumToInt(pdapi.LCDSolidColor.ColorBlack)).?;
//    {
//        playdate.graphics.pushContext(mask);
//        defer playdate.graphics.popContext();
//        playdate.graphics.fillRect(1, 1, 6, 6, @enumToInt(pdapi.LCDSolidColor.ColorWhite));
//    }
//    for (bitmaps) |*bitmap, i| {
//        bitmap.* = playdate.graphics.newBitmap(tile_size, tile_size, @enumToInt(pdapi.LCDSolidColor.ColorWhite)).?;
//        playdate.graphics.pushContext(bitmap.*);
//        defer playdate.graphics.popContext();
//
//        if (i!=9) _ = playdate.graphics.setBitmapMask(bitmap.*, mask);
//        var rowbytes: c_int = undefined;
//        var data: [*c]u8 = undefined;
//        playdate.graphics.getBitmapData(bitmap.*, null, null, &rowbytes, null, &data);
//        if (data == null) {
//            playdate.system.logToConsole("Bitmap %d not initialized", i);
//            continue;
//        }
//        var row: u8 = 0;
//        while (row < tile_size) : (row+=1) {
//            data[row*@intCast(u8, rowbytes)] = bitdata[i][row];
//        }
//        //playdate.system.logToConsole("%d\n", data.?[0]);
//    }
//}

fn loadBitmaps(playdate: *pdapi.PlaydateAPI) void {
    for (bitmaps) |*bitmap, i| {
        bitmap.* = playdate.graphics.loadBitmap(bitmap_names[i].ptr, null).?;
        var width: c_int = undefined;
        var height: c_int = undefined;
        playdate.graphics.getBitmapData(bitmap.*, &width, &height, null, null, null);
        //playdate.system.logToConsole("%d x %d", width, height);
    }
}

fn restartGame(userdata: ?*anyopaque) callconv(.C) void {
    const playdate = @ptrCast(*pdapi.PlaydateAPI, @alignCast(@alignOf(pdapi.PlaydateAPI), userdata.?));
    resetBoard(playdate);
}

fn setNumMines(userdata: ?*anyopaque) callconv(.C) void {
    const playdate = @ptrCast(*pdapi.PlaydateAPI, @alignCast(@alignOf(pdapi.PlaydateAPI), userdata.?));
    if (mines_menu != null) {
        var option = playdate.system.getMenuItemValue(mines_menu);
        switch (option) {
            0 => num_mines = 20,
            1 => num_mines = 40,
            2 => num_mines = 80,
            else => playdate.system.logToConsole("Unknown menu setting"),
        }
    }
    //playdate.system.logToConsole("menu");
}

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            const font = playdate.graphics.loadFont("/System/Fonts/Asheville-Sans-14-Bold.pft", null).?;
            playdate.graphics.setFont(font);
            loadBitmaps(playdate);
            resetBoard(playdate);
            playdate.system.setUpdateCallback(update_and_render, playdate);

            _ = playdate.system.addMenuItem("Restart", restartGame, playdate);

            // TODO: This seems wrong, we shouldn't have to realloc for const values?
            var options = @ptrCast(
                [*c][*c]const u8,
                @alignCast(
                    @alignOf(*c_int),
                    playdate.system.realloc(null, @sizeOf(*c_int) * menu_options.len).?,
                ),
            );
            for (options[0..menu_options.len]) |*option, i| option.* = menu_options[i].ptr;
            mines_menu = playdate.system.addOptionsMenuItem(
                "Mines",
                options,
                menu_options.len,
                setNumMines,
                playdate,
            );
            playdate.system.setMenuItemValue(mines_menu, 1);
        },
        .EventTerminate => {
            for (bitmaps) |*bitmap| {
                playdate.graphics.freeBitmap(bitmap.*);
            }
        },
        else => {},
    }
    return 0;
}

fn resetBoard(playdate: *pdapi.PlaydateAPI) void {
    var seed = playdate.system.getSecondsSinceEpoch(null);
    game_board = board.GameBoard.init(num_mines, seed);
}

fn drawTile(tile_offset: usize, playdate: *pdapi.PlaydateAPI) void {
    const coord = board.toCoord(tile_offset);
    const tile = game_board.tiles[tile_offset];
    const pixel_x = @intCast(c_int, coord[0] * board.tile_size);
    const pixel_y = @intCast(c_int, coord[1] * board.tile_size);
    var bitmap_idx: usize = 0;
    if (tile.is_bomb and tile.is_visible) {
        bitmap_idx = 11;
    } else if (!tile.is_visible and tile.is_marked) {
        bitmap_idx = 10;
    } else if (tile.is_visible) {
        bitmap_idx = tile.local_bombs;
    } else {
        playdate.graphics.fillRect(
            pixel_x + 1,
            pixel_y + 1,
            15,
            15,
            @enumToInt(pdapi.LCDSolidColor.ColorWhite),
        );
        return;
    }
    playdate.graphics.drawBitmap(
        bitmaps[bitmap_idx],
        pixel_x + 1,
        pixel_y + 1,
        pdapi.LCDBitmapFlip.BitmapUnflipped,
    );
    return;
}

fn update_and_render(userdata: ?*anyopaque) callconv(.C) c_int {
    const playdate = @ptrCast(*pdapi.PlaydateAPI, @alignCast(@alignOf(pdapi.PlaydateAPI), userdata.?));

    var current_buttons: pdapi.PDButtons = undefined;
    var pushed_buttons: pdapi.PDButtons = undefined;
    var released_buttons: pdapi.PDButtons = undefined;
    playdate.system.getButtonState(&current_buttons, &pushed_buttons, &released_buttons);
    //var any_action = (current_buttons | released_buttons | pushed_buttons);
    var any_action = released_buttons;

    playdate.graphics.clear(@enumToInt(pdapi.LCDSolidColor.ColorBlack));

    //var tile_i: usize = 0;
    //var row: usize = 0;
    playdate.graphics.tileBitmap(bitmaps[9], 0, 0, 399, 239, pdapi.LCDBitmapFlip.BitmapUnflipped);
    //while (row < 240) : (row += 16) {
    //    var col: usize = 0;
    //    while (col < 400) : (col += 16) {
    //        defer {
    //            tile_i += 1;
    //        }
    //        var bitmap_idx: usize = 0;
    //        var tile = game_board.tiles[tile_i];
    //        if (tile.is_bomb and tile.is_visible) {
    //            bitmap_idx = 11;
    //        } else if (!tile.is_visible and tile.is_marked) {
    //            bitmap_idx = 10;
    //        } else if (tile.is_visible) {
    //            bitmap_idx = tile.local_bombs;
    //        } else {
    //            playdate.graphics.fillRect(
    //                @intCast(c_int, col + 1),
    //                @intCast(c_int, row + 1),
    //                15,
    //                15,
    //                @enumToInt(pdapi.LCDSolidColor.ColorWhite),
    //            );
    //            continue;
    //        }
    //        playdate.graphics.drawBitmap(
    //            bitmaps[bitmap_idx],
    //            @intCast(c_int, col + 1),
    //            @intCast(c_int, row + 1),
    //            pdapi.LCDBitmapFlip.BitmapUnflipped,
    //        );
    //    }
    //}
    var iter = board.tileIterator(0, 0, board.tiles_x, board.tiles_y);
    while (iter.next()) |tile_offset| {
        drawTile(tile_offset, playdate);
    }

    if (!game_board.failed) {
        if ((any_action & pdapi.BUTTON_LEFT) > 0) {
            cur_pos[0] = if (cur_pos[0] > 1) cur_pos[0] - 1 else 0;
        } else if ((any_action & pdapi.BUTTON_RIGHT) > 0) {
            cur_pos[0] = @min(cur_pos[0] + 1, board.tiles_x - 1);
        } else if ((any_action & pdapi.BUTTON_UP) > 0) {
            cur_pos[1] = if (cur_pos[1] > 1) cur_pos[1] - 1 else 0;
        } else if ((any_action & pdapi.BUTTON_DOWN) > 0) {
            cur_pos[1] = @min(cur_pos[1] + 1, board.tiles_y - 1);
        }

        if ((released_buttons & pdapi.BUTTON_A) > 0) {
            _ = game_board.reveal(board.toTile(cur_pos[0], cur_pos[1]));
        }
        if ((released_buttons & pdapi.BUTTON_B) > 0) {
            game_board.mark(board.toTile(cur_pos[0], cur_pos[1]));
        }
    } else {
        if ((released_buttons & (pdapi.BUTTON_A | pdapi.BUTTON_B)) > 0) {
            resetBoard(playdate);
        }
    }

    {
        //playdate.graphics.setDrawMode(pdapi.LCDBitmapDrawMode.DrawModeInverted);
        playdate.graphics.setDrawMode(pdapi.LCDBitmapDrawMode.DrawModeXOR);
        defer playdate.graphics.setDrawMode(pdapi.LCDBitmapDrawMode.DrawModeCopy);
        var tile = game_board.tiles[board.toTile(cur_pos[0], cur_pos[1])];
        playdate.graphics.fillRect(
            @intCast(c_int, cur_pos[0] * board.tile_size),
            @intCast(c_int, cur_pos[1] * board.tile_size),
            16,
            16,
            @ptrToInt(if (tile.is_visible) &checks else &inv_checks),
        );
    }
    //returning 1 signals to the OS to draw the frame.
    return 1;
}
