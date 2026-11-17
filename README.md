# Bangla Keyboard

A small, fast **Bijoy-style Bangla typing engine for Windows**. It sits in a thin always-on-top bar and a tray icon, and lets you type Bangla in **any program**: no clipboard tricks, no installer. Written in AutoHotkey v2.

> **This is a core engine only.** It ships with the typing engine, three layouts, converters and a few helper tools. **No paid or licensed fonts are included.**

**Current version:** 2.0.3

---

## Contents

- [What's New](#whats-new)
- [Download](#download)
- [Features](#features)
- [Included Tools](#included-tools-tools-folder)
- [Requirements](#requirements)
- [How to Use](#how-to-use)
- [Folder Structure](#folder-structure)
- [Uninstall / Clear Everything](#uninstall--clear-everything)
- [License](#license)
- [Disclaimer](#disclaimer)
- [Credits](#credits)

---

## What's New

- **Pupo Encrypter (new tool).** Locks and unlocks layouts (`.xml` <-> `.bkl`) and encoding tables (`.txt` <-> `.een`) so nobody changes them by accident. Add files or drag and drop many at once; the tool recognises layouts and encodings automatically.
- **`.bkl` locked layouts.** Bangla Keyboard can now read `.bkl` layout files as well as `.xml`. If a `.bkl` and a `.xml` share a name, the `.bkl` is used.
- **`.een` encoding files.** Text Converter and Docs Converter now read `.een` files as well as `.txt` from `Tools\Encodings`.
- **Built-in button icons.** The two extra bar buttons now offer ready-made icons grouped by tool (Docs, Text, Layout, Note). You can still add your own pictures in `Skins\Button Icons`.
- **New app icon** for Pupo Encrypter in the `_icon` folder.
- **Updated documentation**, including system requirements for Pupo Encrypter.

> **Note:** `.bkl` and `.een` only protect files from being read or changed by accident. This is light scrambling, **not real encryption**.

---

## Download

Get the latest ready-to-run build from the [**Releases**](https://github.com/YummyCyanide/Bangla-Keyboard/releases/latest) page.

1. Download **Bangla Keyboard vX.X.X.exe** (or the `.zip`, if one is attached, and extract it first).
2. Run it. The bar and tray icon appear. No installation needed.
3. Some antivirus tools may flag the exe as a false positive, because it is built with AutoHotkey. The full source code is in this repository so you can verify it yourself.

Prefer to run from source? See [Requirements](#requirements) and [How to Use](#how-to-use).

---

## Features

- **Type Bangla anywhere**: works in any Windows program.
- **Layouts included**: Bijoy Classic (ANSI), Bijoy Unicode and UniBijoy. More can be added or built.
- **Fast switching**: click the tray icon to toggle English / Bangla. Every layout can have its own shortcut key.
- **Mode switching**: one global mode, or let each window/application remember its own.
- **Automatic fonts**: the font follows the layout in Word, Excel, PowerPoint, Outlook, WPS Office and LibreOffice / OpenOffice Writer.
- **Manual font shortcuts**: up to 10 hotkeys, each applying a font and size to the cursor or selection.
- **Eight bar styles** with 23 colour themes (for the Default styles), adjustable icon size and up to two extra buttons that launch your own tools.
- **Locked layouts**: use `.xml` or locked `.bkl` layout files.
- **Settings**: shortcuts, fonts, start with Windows, splash screen, tray behaviour, per-tab reset to defaults.
- **Portable-friendly**: settings are stored in `%AppData%`, so updates never wipe your choices.

---

## Included Tools (`Tools` folder)

| Tool | What it does |
|---|---|
| **Docs Converter** | Converts Word / PowerPoint documents (and text files) between legacy ANSI fonts (Bijoy, Proshika...) and Unicode. You pick which fonts to convert; the original file is never changed. |
| **Text Converter** | Two boxes: paste in one, convert to ANSI or Unicode. Mapping tables live in `Tools\Encodings` (Bijoy V1, Bijoy V2, Proshika). |
| **Pupo Encrypter** | Locks (encrypts) and unlocks (decrypts) layouts (`.xml` <-> `.bkl`) and encoding tables (`.txt` <-> `.een`). Add files or drag and drop many at once, then Encrypt or Decrypt. Both converters read `.txt` and `.een` from `Tools\Encodings`; Bangla Keyboard reads `.bkl` and `.xml` layouts. |
| **Layout Builder** | Create and edit layouts (`.xml`) with a "Try it" tab for testing. |
| **Quick Note** | A small rich-text editor for Bangla with an automatic recovery draft. |

Open them from the tray menu, or assign them to the bar's extra buttons (**Settings > General**). Any `.ahk` / `.exe` you drop into `Tools` also appears in the tray menu.

---

## Requirements

- Windows (uses Windows APIs, tray, RichEdit and Office COM)
- [AutoHotkey v2](https://www.autohotkey.com/) (the portable exe is fine). **Only needed to run from source** (`.ahk` files); the compiled release exe does not need it. Any tool in the `Tools` folder that is still an `.ahk` script also needs it.
- A Bangla font of your choice. Unicode layouts work with fonts like *Nirmala UI* (built into Windows). ANSI layouts (Bijoy Classic) need a matching ANSI font such as SutonnyMJ, which you must obtain yourself.
- Microsoft Office / WPS / LibreOffice is only needed for the automatic-font feature and for converting `.doc`, `.ppt` and similar older formats.

### System requirements for Pupo Encrypter

- Windows 10 or 11 (Windows 7 or later also works with AutoHotkey v2).
- [AutoHotkey v2](https://www.autohotkey.com/) to run `Pupo Encrypter.ahk` from source. A compiled exe needs nothing installed.
- A screen of at least 800 x 600; the window is resizable.
- Almost no resources: a few MB of memory and no extra disk space beyond the files you convert. No internet, no Office and no administrator rights.

---

## How to Use

*(Running from source. If you downloaded the exe from Releases, just run it.)*

1. Install AutoHotkey v2.
2. Download / clone this repo and keep the folder structure intact.
3. Double-click **`Bangla Keyboard.ahk`**. The bar and tray icon appear.
4. Pick a layout from the bar's dropdown, or use the shortcuts below. Start typing.

**Default shortcuts**

| Layout | Shortcut |
|---|---|
| Bijoy Classic | `Ctrl + Alt + B` |
| Bijoy Unicode | `Ctrl + Alt + V` |
| UniBijoy | `Ctrl + Alt + U` |

All of these can be changed in **Settings > Shortcuts**.

**Tray icon:** single click = toggle English / last Bangla layout, double click = show / hide the bar, right click = menu (layouts, tools, Settings, About, Exit).

**Settings** (three tabs): *General* (style, theme, icon size, startup, splash, extra buttons), *Shortcuts*, *Fonts* (automatic and manual font control). Each tab has **Reset**, and nothing is saved until you press **Save**.

**Adding a layout:** drop a `.xml` or `.bkl` file into `Layouts` and restart, or build one with the Layout Builder. If a `.bkl` and a `.xml` share a name, the `.bkl` is used.

**Locking a layout or encoding table:** open **Pupo Encrypter**, add your files (or drag and drop them), then press Encrypt. To edit a locked file again, press Decrypt.

**Button icons:** the two extra buttons offer built-in icons grouped by tool (Docs, Text, Layout, Note). For your own, put pictures in `Skins\Button Icons`, reopen Settings, then pick the file name from the icon list.

---

## Folder Structure

```
Bangla Keyboard/
├── Bangla Keyboard.ahk      Main program
├── README.md
├── LICENSE
├── Icons/                   Layout icons (Classic, English, Unicode)
├── Layouts/                 Layout files (.xml / .bkl)
├── Skins/                   Bar skins and Button Icons
├── Splash/                  Splash screen images (static and animated)
├── Tools/
│   ├── Docs Converter.ahk
│   ├── Text Converter.ahk
│   ├── Pupo Encrypter.ahk
│   ├── Layout Builder.ahk
│   ├── Quick Note.ahk
│   └── Encodings/           Mapping tables (.txt / .een)
└── _icon/                   Application icons for the program and tools
```

---

## Uninstall / Clear Everything

There is no installer, so removal is manual:

1. Right-click the tray icon > **Exit**.
2. If you enabled *Start with Windows*, untick it in **Settings > General** first, or delete `Bangla Keyboard.lnk` from the Startup folder (`Win + R` > `shell:startup`).
3. Delete the program folder.
4. Delete saved settings: `%AppData%\Bangla Keyboard` (`Win + R`, paste the path).
5. Optional: delete the temp file `%Temp%\BanglaKeyboard_tray.ico`.

To only **reset settings**, press **Reset** in each Settings tab, or delete the `%AppData%\Bangla Keyboard` folder. Defaults are restored on next launch. Nothing is written to the registry.

---

## License

The source code of this project is released under the **[GNU General Public License v3.0](LICENSE)**. You may use, study, modify and share it, but any redistributed version must stay open source under the same license.

**Not covered by the GPL:** the bar skins, icons, splash images, and any other UI artwork inspired by existing Bangla keyboard software. Those remain the property of their respective owners and are for **non-commercial and personal use only**.

---

## Disclaimer

- This project is **only a core engine**. **No paid, commercial or licensed fonts are included or distributed.** Please obtain any fonts you need legally from their owners.
- All related names, designs and trademarks belong to their respective owners. This project is **not affiliated with or endorsed by** them.
- **I do not sell this app.** That is exactly why it is open source and free. Please do not sell or repackage it as a paid product.
- `.bkl` and `.een` files are only lightly scrambled to prevent accidental changes. They are **not secure encryption**.
- Provided **as is**, without warranty. Use at your own risk, and keep backups of important documents before bulk-converting them.

---

## Credits

Made by **Sherlock Holmes**, with the assistance of AI.

Issues and suggestions are welcome.
