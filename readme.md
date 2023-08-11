# macpaperd

Disclaimer: although the name includes 'mac' and this is built for Macs, this is not sponsored or run by Apple, and I am not affiliated with Apple.

### Read before use

macpaperd is still alpha software, and as such it can damage your system. Currently only single display setups are supported, and multi-display setups may break entirely. By break, I mean that Launchpad, the Dock, and swiping between spaces will not function at all until you open a Terminal (accessible from Spotlight Search found in the spyglass icon in macOS menubar) and run 'rm ~/Library/Application\ Support/desktoppicture.db && killall Dock'. Oh and wallpaper won't work while it's broken, and when you fix it via the above command all the spaces' wallpapers will be reset. That said, feel free to try it out; just don't come crying if you can't figure out why it's broken.

## Building

The executable can be built with `zig build`, and the resulting executable can be found at `zig-out/bin/macpaperd`.

## Usage

At the moment, macpaperd is a command line utility, and you can set the wallpaper with `macpaperd --set '/absolute/path/to/wallpaper.png'`. It only accecpts `.png` and `.jpg` at the moment, I still need to figure out other accepted formats (and if they require different database setups).

### Licensing and attributions

macpaperd is released under the GPLv3, which can be found at `./COPYING`

Additionally, it uses the zig-sqlite project by Vincent Rischmann:
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

#### TODO

[ ] Configuration file
[ ] Acquire space / display data using the same method as `yabai`
[ ] Cycle through all desktops / spaces and (using AppleScript) set desktop image (just to make sure it is a local jpg and thus we can affect the space / desktop)
  - Only need to happen the first time
[ ] Be daemon instead of just command
[ ] Way more saftey checks
[ ] Automatically detect changes to the relevant files
[ ] Write up proper documentation of `desktoppicture.db`.
[ ] Support different wallpapers on different desktops / spaces
[ ] Cycling
[ ] Support multiple displays:
   - `createDb` is fine
   - `copyFromOld` currently only copies one display and shows a warning, we'll just have to make a small change for that
   - `addData`, `insertPreference`, and `insertSpaceData` all need more thought to support multiple displays.