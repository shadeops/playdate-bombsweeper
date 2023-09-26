const std = @import("std");
const board = @import("board.zig");
const pdapi = @import("playdate_api_definitions.zig");

const bitmap_names = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "border", "unk", "bomb" };

const checks = pdapi.LCDPattern{
    0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55,
    0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55,
};

const inv_checks = pdapi.LCDPattern{
    0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55,
    0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa,
};

const GameState = enum {
    active,
    refresh,
    end,
    start,
};

// Global State
var game_state = GameState.active;
var bitmaps = [_]*pdapi.LCDBitmap{undefined} ** 12;
var failed_map: *pdapi.LCDBitmap = undefined;
var won_map: *pdapi.LCDBitmap = undefined;
var game_board: board.GameBoard = undefined;
var num_mines: u32 = 40;
var mines_menu: ?*pdapi.PDMenuItem = null;
var cursor = Cursor{};
var font: ?*pdapi.LCDFont = null;

// NOTE: Common factors of 400x240
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

const Cursor = struct {
    accel: usize = 0,
    x: usize = 0,
    y: usize = 0,
    px: usize = 0,
    py: usize = 0,
    prev_button: c_int = 0,
    delay: usize = 3,

    fn tileOffset(self: Cursor) usize {
        return board.toTile(self.x, self.y);
    }

    fn prevTileOffset(self: Cursor) usize {
        return board.toTile(self.px, self.py);
    }

    fn draw(self: Cursor, playdate: *const pdapi.PlaydateAPI) void {
        playdate.graphics.setDrawMode(pdapi.LCDBitmapDrawMode.DrawModeXOR);
        defer playdate.graphics.setDrawMode(pdapi.LCDBitmapDrawMode.DrawModeCopy);

        drawTile(self.tileOffset(), playdate);
        var tile = game_board.tiles[self.tileOffset()];
        playdate.graphics.fillRect(
            @as(c_int, @intCast(self.x * board.tile_size + 1)),
            @as(c_int, @intCast(self.y * board.tile_size + 1)),
            board.tile_size - 1,
            board.tile_size - 1,
            @intFromPtr(if (tile.is_visible) &checks else &inv_checks),
        );
    }

    fn move(self: *Cursor, button: c_int) void {
        if (button & pdapi.BUTTON_LEFT != 0) {
            self.x = if (self.x > 1) self.x - 1 else 0;
        }
        if (button & pdapi.BUTTON_RIGHT != 0) {
            self.x = @min(self.x + 1, board.tiles_x - 1);
        }
        if (button & pdapi.BUTTON_UP != 0) {
            self.y = if (self.y > 1) self.y - 1 else 0;
        }
        if (button & pdapi.BUTTON_DOWN != 0) {
            self.y = @min(self.y + 1, board.tiles_y - 1);
        }
    }

    fn update(self: *Cursor, playdate: *const pdapi.PlaydateAPI) bool {
        self.px = self.x;
        self.py = self.y;

        var current: pdapi.PDButtons = undefined;
        var pushed: pdapi.PDButtons = undefined;
        var released: pdapi.PDButtons = undefined;

        playdate.system.getButtonState(
            &current,
            &pushed,
            &released,
        );

        // We didn't move so there isn't anything to update.
        if (current & 0b1111 == 0 and released & 0b1111 == 0) {
            self.accel = 0;
            self.prev_button = 0;
            return false;
        }

        // Button was released, so go prefer that over holding
        if (released & 0b1111 != 0) {
            self.move(released);
            self.accel = 0;
            self.prev_button = 0;
            return true;
        }

        if (current & 0b1111 != 0 and pushed & 0b1111 == 0) {
            // If there was a change in direction stop accel
            // set new direction
            if ((self.prev_button & current) == 0) {
                self.accel = 0;
                self.prev_button = current & 0b1111;
            } else if (self.prev_button == current & 0b1111) {
                self.accel += 1;
            }
            self.accel %= self.delay + 1;
            if (self.accel == self.delay) {
                self.move(current);
                return true;
            } else {
                return false;
            }
        }

        self.accel = 0;
        self.prev_button = 0;
        return false;
    }
};

fn drawBitmaps(playdate: *const pdapi.PlaydateAPI) void {
    const won_text = "Found All Bombs!";
    var height = playdate.graphics.getFontHeight(font);
    var width = playdate.graphics.getTextWidth(font, won_text, won_text.len, pdapi.PDStringEncoding.ASCIIEncoding, 0);
    won_map = playdate.graphics.newBitmap(width + 2, height + 2, @intFromEnum(pdapi.LCDSolidColor.ColorClear)).?;
    {
        playdate.graphics.pushContext(won_map);
        defer playdate.graphics.popContext();
        _ = playdate.graphics.drawText(won_text, won_text.len, pdapi.PDStringEncoding.ASCIIEncoding, 1, 1);
    }

    const failed_text = "Bomb Triggered!";
    width = playdate.graphics.getTextWidth(font, failed_text, failed_text.len, pdapi.PDStringEncoding.ASCIIEncoding, 0);
    failed_map = playdate.graphics.newBitmap(width + 2, height + 2, @intFromEnum(pdapi.LCDSolidColor.ColorClear)).?;
    {
        playdate.graphics.pushContext(failed_map);
        defer playdate.graphics.popContext();
        _ = playdate.graphics.drawText(failed_text, failed_text.len, pdapi.PDStringEncoding.ASCIIEncoding, 1, 1);
    }
}

fn loadBitmaps(playdate: *const pdapi.PlaydateAPI) void {
    for (&bitmaps, 0..) |*bitmap, i| {
        bitmap.* = playdate.graphics.loadBitmap(bitmap_names[i].ptr, null).?;
        var width: c_int = undefined;
        var height: c_int = undefined;
        playdate.graphics.getBitmapData(bitmap.*, &width, &height, null, null, null);
    }
}

fn refreshBoard(playdate: *const pdapi.PlaydateAPI) void {
    var iter = board.tileIterator(0, 0, board.tiles_x, board.tiles_y);
    while (iter.next()) |tile_offset| {
        drawTile(tile_offset, playdate);
    }
    cursor.draw(playdate);
    game_state = .active;
}

fn resetBoard(playdate: *const pdapi.PlaydateAPI) void {
    var seed = playdate.system.getSecondsSinceEpoch(null);
    game_board = board.GameBoard.init(num_mines, seed);

    playdate.graphics.clear(@intFromEnum(pdapi.LCDSolidColor.ColorBlack));
    playdate.graphics.tileBitmap(bitmaps[9], 0, 0, 399, 239, pdapi.LCDBitmapFlip.BitmapUnflipped);

    refreshBoard(playdate);
}

fn drawTile(tile_offset: usize, playdate: *const pdapi.PlaydateAPI) void {
    const coord = board.toCoord(tile_offset);
    const tile = game_board.tiles[tile_offset];
    const pixel_x = @as(c_int, @intCast(coord[0] * board.tile_size));
    const pixel_y = @as(c_int, @intCast(coord[1] * board.tile_size));
    var bitmap_idx: usize = 0;
    playdate.graphics.fillRect(
        pixel_x + 1,
        pixel_y + 1,
        board.tile_size - 1,
        board.tile_size - 1,
        @intFromEnum(pdapi.LCDSolidColor.ColorBlack),
    );
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
            board.tile_size - 1,
            board.tile_size - 1,
            @intFromEnum(pdapi.LCDSolidColor.ColorWhite),
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

fn drawEndBoard(playdate: *const pdapi.PlaydateAPI, map: *pdapi.LCDBitmap) void {
    var iter = board.tileIterator(0, 0, board.tiles_x, board.tiles_y);
    while (iter.next()) |tile_offset| {
        var tile = game_board.tiles[tile_offset];
        var xy = board.toCoord(tile_offset);
        playdate.graphics.fillRect(
            @as(c_int, @intCast(xy[0] * board.tile_size + 1)),
            @as(c_int, @intCast(xy[1] * board.tile_size + 1)),
            board.tile_size - 1,
            board.tile_size - 1,
            @intFromPtr(if (tile.is_visible) &checks else &inv_checks),
        );
    }
    var width: c_int = undefined;
    var height: c_int = undefined;
    playdate.graphics.getBitmapData(map, &width, &height, null, null, null);
    width = @divFloor(400 - (width * 3), 2);
    height = @divFloor(240 - (height * 3), 2);
    playdate.graphics.drawScaledBitmap(map, width, height, 3, 3);
}

fn restartGameCallback(userdata: ?*anyopaque) callconv(.C) void {
    const playdate: *pdapi.PlaydateAPI = @ptrCast(@alignCast(userdata.?));
    resetBoard(playdate);
}

fn setNumMinesCallback(userdata: ?*anyopaque) callconv(.C) void {
    const playdate: *pdapi.PlaydateAPI = @ptrCast(@alignCast(userdata.?));
    if (mines_menu != null) {
        var option = playdate.system.getMenuItemValue(mines_menu);
        switch (option) {
            0 => num_mines = 20,
            1 => num_mines = 40,
            2 => num_mines = 80,
            else => playdate.system.logToConsole("Unknown menu setting"),
        }
    }
}

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            font = playdate.graphics.loadFont("/System/Fonts/Asheville-Sans-14-Bold.pft", null).?;
            playdate.graphics.setFont(font);
            drawBitmaps(playdate);

            loadBitmaps(playdate);
            game_state = .start;
            playdate.system.setUpdateCallback(update_and_render, playdate);

            _ = playdate.system.addMenuItem("Restart", restartGameCallback, playdate);

            var options = [_][*c]const u8{ "20", "40", "80" };
            mines_menu = playdate.system.addOptionsMenuItem(
                "Mines",
                @as([*c][*c]const u8, @ptrCast(@alignCast(&options))),
                options.len,
                setNumMinesCallback,
                playdate,
            );
            playdate.system.setMenuItemValue(mines_menu, 1);
        },
        .EventUnlock => {
            game_state = .refresh;
        },
        .EventTerminate => {
            for (&bitmaps) |*bitmap| {
                playdate.graphics.freeBitmap(bitmap.*);
            }
            playdate.graphics.freeBitmap(won_map);
            playdate.graphics.freeBitmap(failed_map);
        },
        else => {},
    }
    return 0;
}

fn update_and_render(userdata: ?*anyopaque) callconv(.C) c_int {
    const playdate: *pdapi.PlaydateAPI = @ptrCast(@alignCast(userdata.?));

    var current_buttons: pdapi.PDButtons = undefined;
    var pushed_buttons: pdapi.PDButtons = undefined;
    var released_buttons: pdapi.PDButtons = undefined;
    playdate.system.getButtonState(&current_buttons, &pushed_buttons, &released_buttons);

    switch (game_state) {
        .start => {
            resetBoard(playdate);
            return 1;
        },
        .end => {
            if ((released_buttons & (pdapi.BUTTON_A | pdapi.BUTTON_B)) != 0) {
                game_state = .start;
                return 1;
            }
            return 0;
        },
        .refresh => {
            refreshBoard(playdate);
            return 1;
        },
        else => {},
    }

    switch (game_board.state) {
        .active => {
            var redraw = false;
            var moved = cursor.update(playdate);
            if ((released_buttons & pdapi.BUTTON_A) != 0) {
                var tile_iter = game_board.reveal(cursor.tileOffset());
                while (tile_iter.next()) |tile_offset| {
                    drawTile(tile_offset, playdate);
                }
                redraw = true;
            }
            if (released_buttons & pdapi.BUTTON_B != 0) {
                game_board.mark(cursor.tileOffset());
                drawTile(cursor.tileOffset(), playdate);
                redraw = true;
            }
            if (moved) {
                drawTile(cursor.prevTileOffset(), playdate);
                redraw = true;
            }
            if (redraw) {
                cursor.draw(playdate);
                return 1;
            }
        },
        .failed => {
            drawEndBoard(playdate, failed_map);
            game_state = .end;
            return 1;
        },
        .won => {
            drawEndBoard(playdate, won_map);
            game_state = .end;
            return 1;
        },
    }

    //returning 1 signals to the OS to draw the frame.
    return 0;
}
