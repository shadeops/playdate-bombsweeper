const std = @import("std");

pub const board_width = 400;
pub const board_height = 240;
pub const tile_size = 16;
pub const tiles_x = board_width / tile_size;
pub const tiles_y = board_height / tile_size;
pub const total_tiles = tiles_x * tiles_y;

const TileState = struct {
    is_bomb: bool = false,
    is_visible: bool = false,
    is_marked: bool = false,
    local_bombs: u4 = 0,
};

const Coord = [2]usize;
pub fn toCoord(offset: usize) Coord {
    return .{
        offset % tiles_x,
        offset / tiles_x,
    };
}

pub fn toTile(x: usize, y: usize) usize {
    return y * tiles_x + x;
}
    
const NeighbourIterator = struct {
    index: usize = 0,
    offset: usize,

    fn next(self: *NeighbourIterator) ?usize {
        if (self.index > 7) return null;
        
        var coord = toCoord(self.offset);
        var x = @intCast(i32, coord[0]);
        switch (self.index) {
            0,6,7 => x -= 1,
            2,3,4 => x += 1,
            else => {},
        }
        var y = @intCast(i32, coord[1]);
        switch (self.index) {
            0,1,2 => y -= 1,
            4,5,6 => y += 1,
            else => {},
        }

        self.index += 1;
        if (x < 0 or y < 0 or x >= tiles_x or y >= tiles_y) return self.next();
        return toTile(@intCast(usize, x), @intCast(usize, y));
    }
};

fn neighbourIterator(offset: usize) NeighbourIterator {
    return .{ .offset = offset };
}

const TileIterator = struct {
    x_idx: usize = 0,
    y_idx: usize = 0,
    x_size: usize,
    y_size: usize,
    x_start: usize,
    y_start: usize,

    pub fn next(self: *TileIterator) ?usize {
        if (self.y_idx >= self.y_size) return null;
     
        var x = self.x_idx + self.x_start;
        var y = self.y_idx + self.y_start;

        self.x_idx += 1;
        if (self.x_idx>=self.x_size) self.y_idx +=1;
        self.x_idx %= self.x_size;

        if (x >= tiles_x or y >= tiles_y) return self.next();
        return toTile(x, y);
    }
};

pub fn tileIterator(x_start: usize, y_start: usize, x_size: usize, y_size: usize) TileIterator{
    return .{
        .x_start = x_start,
        .y_start = y_start,
        .x_size = x_size,
        .y_size = y_size,
    };
}

pub const GameBoard = struct {
    const Self = @This();
    tiles: [total_tiles]TileState,
    num_bombs: u32,
    num_hidden: u32,
    failed: bool,

    pub fn init(bombs: u32, seed: u32) Self {
        var board = Self{
            .tiles = [_]TileState{.{}} ** total_tiles,
            .num_bombs = bombs,
            .num_hidden = total_tiles,
            .failed = false,
        };

        var prng = std.rand.DefaultPrng.init(seed);
        const rand = prng.random();
        {
            var i: usize = 0;
            while (i < bombs) {
                var picked_pos = rand.intRangeLessThan(u32, 0, total_tiles);
                if (board.tiles[picked_pos].is_bomb) continue;

                board.tiles[picked_pos].is_bomb = true;
                var iter = neighbourIterator(picked_pos);
                while (iter.next()) |tile_offset| {
                    board.tiles[tile_offset].local_bombs += 1;
                }
                i += 1;
            }
        }

        return board;
    }

    pub fn winningState(self: GameBoard) bool {
        return (self.num_bombs == self.num_hidden) and (self.failed == false);
    }

    pub fn reveal(self: *GameBoard, tile: usize) bool {
        self.tiles[tile].is_visible = true;
        if (self.tiles[tile].is_bomb) {
            self.failed = true;
            self.revealBoard();
            return false;
        }
        self.num_hidden -= 1;
        if (self.tiles[tile].local_bombs == 0) self.exposeSafe(tile);
        return true;
    }

    pub fn mark(self: *GameBoard, tile: usize) void {
        self.tiles[tile].is_marked = !self.tiles[tile].is_marked;
    }

    fn exposeSafe(self: *GameBoard, tile: usize) void {
        var iter = neighbourIterator(tile);
        while (iter.next()) |tile_offset| {
            if (self.tiles[tile_offset].is_visible) continue;
            if (self.tiles[tile_offset].is_bomb) continue;
            self.tiles[tile_offset].is_visible = true;
            if (self.tiles[tile_offset].local_bombs == 0) {
                self.exposeSafe(tile_offset);
            }
        }
    }

    fn revealBoard(self: *GameBoard) void {
        for (self.tiles) |*tile| {
            if (tile.is_bomb) tile.is_visible = true;
        }
    }
};
