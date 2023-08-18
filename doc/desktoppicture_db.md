# Documentation for `desktoppicture.db`

TODO: figure out how `yabai` gets the space / display uuids and document that here.

The database contains 6 tables:
- `data` which maps to a `value`
- `displays` which maps to a varchar `display_uuid
- `pictures` which maps to an integer `space_id` and integer `display_uuid` 
- `preferences` which maps to an integer `key`, integer `data_id`, and integer `picture_id`
- `prefs` which maps to an integer `key` and `data`
- `spaces` which maps to a `space_uuid`

It also contains an index for each table:
- `data` uses `value` as `data_index`
- `displays` uses `display_uuid` as `displays_index`
- `pictures` uses `pictures_uuid` as `pictures_index`
- `preferences` uses `picture_id` and `data_id` as `preferences_index`
- `prefs` uses `key` as `prefs_index`
- `spaces` uses `spaces_uuid` as `spaces_index`

Lastly it contains some triggers for deletion to help cleanup data strewn across other tables (for instance, when a `spaces` entry is deleted, the relevant rows in `pictures` is removed as well). The names are derived from the table name by adding `_deleted` to the singular form (with the exception being `preferences_deleted` for `preferences`).

## Tables

#### `displays`

The `displays` table contains a list of the UUIDs for each display that has had the wallpaper configured for at least one if it's spaces. A list of the currently connected displays (including the UUIDs) can be retrieved using the `CGGetActiveDisplayList` function found in the `Carbon` headers.

#### `spaces`

Like the `displays` table, the `spaces` table contains a list of the UUIDs of each space, regardless of display, that has had it's wallpaper configured. Using the internal SkyLight function `SLSCopyManagedDisplaySpaces`, a Display's UUID can be used to find the list of spaces associated with the display, and `SLSSpaceCopyName` can retrieve the space's UUID.

#### `prefs`

Oddly enough, I have only seen this table empty. Granted, I do not use desktop image cycling, which may be for what it is, but as for as I have seen it does not have a use.

#### `data`

Generaly dumping place for data that is used in the preferences table. This consists of file and folder paths, unsigned integers, and decimals.

#### `pictures`

// TODO

#### `preferences`

Each picture entry will have keys and values associated with it. The following keys are valid:
- '1': index into the `data` table that denotes the picture's wallpaper file.
- '10': index into the `data` table that denotes the picture's wallpaper's folder.
- '20': index into the `data` table that, at least so far, is '0'.
Those three are always present, even if the background is just a solid color (in that case the folder is `/System/Library/Desktop Pictures/Solid Colors` and the file is `/System/Library/PreferencePanes/DesktopScreenEffectsPref.prefPane/Contents/Resources/DesktopPictures.prefPane/Contents/Resources/Transparent.tiff`; I know, a mouthful).
- '15': when present, indicates a background color should be drawn. The value it points to is always '3' regardless of index (maybe to interpret the colorspace?)
- '3', '4', '5': indices into the `data` tables to denote R, G, and B (respectively) for the background color

No doubt since cycling and different fit method exist, there are more. But those that are currently used by `macpaperd` are those above.
