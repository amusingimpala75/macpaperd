# macpaperd

Disclaimer: although the name includes 'mac' and this is built for macOS, this is not sponsored or run by Apple, and I am not affiliated with Apple.

### Read before use

macpaperd is still alpha software, and as such it can damage your system. Currently only single display setups are supported, and multi-display setups may break entirely. By break, I mean that Launchpad, the Dock, and swiping between spaces will not function at all until you open a Terminal (accessible from Spotlight Search found in the spyglass icon in macOS menubar) and run `rm ~/Library/Application\ Support/desktoppicture.db && killall Dock`. Oh and wallpaper won't work while it's broken, and when you fix it via the above command all the spaces' wallpapers will be reset. That said, feel free to try it out; just don't come crying if you can't figure out why it's broken.

## Dependencies

`macpaperd` uses the `zig-sqlite` sqlite bindings in order to access databases. By default we link the executable to the system `sqlite3` installation, but with the compilation flag `-Dbundle-sqlite` we instead statically link the one provided with the bindings. It does increase the executable size by about 6Mb.
`macpaperd` uses the official Zig package manager, and as such requires a version > 0.11.0. `zig-master` is not tested.

## Building

The executable can be built with `zig build`, and the resulting executable can be found at `zig-out/bin/macpaperd`.

## Usage

At the moment, macpaperd is a command line utility, and you can set the wallpaper with `macpaperd --set '/absolute/path/to/wallpaper.png'`. It only accecpts `.png` and `.jpg` at the moment, I still need to figure out other accepted formats (and if they require different database setups). Also, for those curious, the `--displays` command lists the displays, their UUIDs and spaces, and their spaces' UUIDs and whether-or-not they are fullscreen.

#### Features

- [x] Create fake `desktoppicture.db` and swap it with the actual, killing `Dock.app` afterwords to change the wallpaper
- [x] Acquire space / display data using the same method as `yabai`
- [ ] Support multiple displays. TODO:
   - [x] `createDb` is fine
   - [ ] `copyFromOld` currently only copies one display and shows a warning, we'll just have to make a small change for that
   - [ ] `addData`, `insertPreference`, and `insertSpaceData` all need more thought to support multiple displays.
- [ ] Be daemon instead of just command
- [ ] Configuration file
- [ ] Automatically detect changes to the relevant files
- [ ] Write up proper documentation of `desktoppicture.db`.
- [ ] Cycling
- [ ] Support different wallpapers on different desktops / spaces

### Licensing and attributions

The `macpaperd` source code is released under the GPLv3, which can be found at `./COPYING`
The documenation found under the `docs` folder is licensed under the Creative Commons Attribution-ShareAlike 4.0 International, which can be found at `./CC-BY-SA-4.0.txt`

Additionally, `macpaperd` uses the `zig-sqlite` project by Vincent Rischmann:
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
