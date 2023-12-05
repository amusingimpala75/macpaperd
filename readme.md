# macpaperd

[![](https://badgers.space/github/license/amusingimpala75/macpaperd)](./COPYING)

Disclaimer: although the name includes 'mac' and this is built for macOS, this is not sponsored or run by Apple, and I am not affiliated with Apple.

## As of macOS Sonoma, the wallpaper engine was entirely re-done, and I have yet to find where the configuration files reside
(along with the ones for the system-wide constrast/highlight colors), and so for now this program WILL NOT WORK on macOS 14

### Read before use

`macpaperd` is still beta software, and as such it could theoretically damage your system. Currently only single display setups are supported, and multi-display setups may break entirely. In the case of breakage, Launchpad, the Dock, and swiping between spaces will not function at all until you open a Terminal (accessible from Spotlight Search found in the spyglass icon in the macOS menu bar, or an already open terminal) and run `macpaperd --reset`. Until it is reset, the wallpaper will be black, and when you reset it all the spaces' wallpapers will be reset. That said, I haven't run into any issues that resetting does not resolve.

## Dependencies

`zig` >= 0.11.0  
`macOS` 12-13 (only Monterey and Ventura on M1 tested, Sonoma currently fails as Apple re-did the wallpaper system)

## Building

The executable can be built with `zig build`, and the resulting executable can be found at `zig-out/bin/macpaperd`.  
The `-Dbundle-sqlite` build option will bundle `zig-sqlite`'s sqlite3 instead of using the system installation, increasing binary size by about 6MB but removing the runtime dependency

## Usage

```
Usage:
  Set a wallpaper image:
  macpaperd --set [file]         Set 'file' as the wallpaper.
            --orientation [type] Set the orientation of the image.
                                 'orientation' must be one of 'full', 'center',
                                 'fit', 'tile', or 'stretch'.
            --color [color]      Set 'hex color' as the background color.
                                 'hex color' must be a valid, 6 character
                                 hexidecimal number, no '0x' prefix. Only
                                 required if the image is transparent or the
                                 orientation is not 'full'.
            --dynamic [type]     Set the image as dynamic. 'type' must be one
                                 of 'none', 'dynamic', 'light', or 'dark'.

  Set a wallpaper color:
  macpaperd --color [color]      Set 'hex color' as the background color.
                                 'hex color' must be a valid, 6 character
                                 hexidecimal number, no '0x' prefix.

  Debug help:
  macpaperd --displays           List the connected displays and their associated spaces.
  macpaperd --help               Show this information.
  macpaperd --reset              Reset the wallpaper to the default.

Export 'LOG_DEBUG=1' to enable debug logging.
```

#### Features \ TODO

- [x] Create fake `desktoppicture.db` and swap it with the actual, killing `Dock.app` afterwords to change the wallpaper
- [x] Acquire space / display data using the same method as `yabai`, allowing a fresh installation without any other configuration required.
- [x] Support different desktop types:
   - [x] Colors
   - [x] Image Formats:
      - [x] JPEG
      - [x] PNG
      - [x] TIFF
      - [x] HEIC
   - [x] Dynamic Wallpapers
- [ ] Support multiple displays. TODO:
   - [ ] decode format changes
   - [x] `createDb` is fine
   - [ ] `fillDisplaysAndSpaces` currently only copies one display and shows a warning, we'll just have to make a small change for that
   - [ ] `fillPicturesPreferences` and `fill[x]Data` will need more thought to support multiple displays.
- [ ] Be daemon instead of just a command
- [ ] Configuration file
- [ ] Automatically detect changes to the relevant files
- [ ] Write up proper documentation of `desktoppicture.db`.
- [ ] Cycling
- [ ] Support different wallpapers on different desktops / spaces
- [x] Different image fit types:
   - [x] Full (scale until both edges reach or extend past edge of screen)
   - [x] Fit (until both edges reach or are within screen, using background color where necessary)
   - [x] Stretch (scale until one edge reaches screen edge, then stretch along other axis)
   - [x] Tile (repeat image vertically and horizontally)
   - [x] Center (place in center with no scaling, using background color where necessary)

### `desktoppicture.db` Documentation

[The documentation for `desktoppicture.db` can be found here](./doc/desktoppicture_db.md)
The most up-to-date reference is the code itself; the state of the documentation will lag behind

### Licensing and attributions

The `macpaperd` source code is released under the GPLv3, which can be found at `./COPYING`
The documenation found under the `docs` folder is licensed under the Creative Commons Attribution-ShareAlike 4.0 International, which can be found at `./CC-BY-SA-4.0.txt`

Additionally, `macpaperd` uses the [`zig-sqlite`](https://github.com/vrischmann/zig-sqlite) project by Vincent Rischmann:
```
MIT License

Copyright (c) 2020 Vincent Rischmann <vincent@rischmann.fr>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
