# Zig Implementation of Bombsweeper for the Playdate

![Bombsweeper](/img/playdate.png)

## Overview

Simple implementation of Bombsweeper (Minesweeper) written in Zig.

This uses the wonderful [Zig Playdate Template](https://github.com/DanB91/Zig-Playdate-Template)
created by [Daniel Bokser](https://twitter.com/dbokser91).

## Requirements

* Playdate SDK, with `$PLAYDATE_SDK_PATH` set.
* Zig 0.10.0+

The build.zig is setup for Linux only, to compile on Windows or OSX you should refer to the Zig Playdate Template.

## Install
`zig build`
or
`zig build run`

The compiled Playdate package will be in `zig-out/bombsweeper.pdx`

