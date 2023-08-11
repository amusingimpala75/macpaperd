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

The `displays` table contains a list of the uuids for each display that has had the wallpaper configured for at least one if it's spaces. A list of the currently connected displays (including the uuids) can be retrieved using the `yabai` window manager (`yabai -m query --displays`).

#### `spaces`

Like the `displays` table, the `spaces` table contains a list of the uuids of each space, regardless of display, that has had it's wallpaper configured. A list of the current spaces (regardless of if it is native fullscreen, and thus no wallpaper, or not) can be retrived using the `yabai` window manager (`yabai -m query --spaces`).

#### `prefs`

Oddly enough, I have only seen this table empty. Granted, I do not use desktop image cycling, which may be for what it is, but as for as I have seen it does not have a use.

#### `data`

The `data` tables can contain one of three types for a given index: firstly, it can be a number, for some unknown purpose (maybe to distinguish the two types of files?). Next, it can be a path to a folder containing wallpapers (either current or past). Lastly, it can be a path to a wallpaper, or just the file name.

#### `pictures`

// TODO

#### `preferences`

// TODO