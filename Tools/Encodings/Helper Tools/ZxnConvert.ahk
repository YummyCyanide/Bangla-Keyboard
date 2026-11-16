; ===========================================================================
;  ZxnConvert - turns a mapping .txt into a scrambled .zxn, and back again.
;  Drag one or more files onto this script, or run it and pick files.
;    name.txt -> name.zxn   (use this before you distribute the app)
;    name.zxn -> name.txt   (use this when you want to edit the table again)
;  The result is saved next to the original file. Needs AutoHotkey v2.
;  Keep the key below the same as Cv.zk in BanglaConverter.ahk.
; ===========================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

ZxnKey := "BanglaConverter"

; plain bytes -> "ZXN" + 0x01 + scrambled bytes
ZxnEncode(src) {
    n := src.Size
    out := Buffer(n + 4, 0)
    NumPut("UChar", 0x5A, out, 0)
    NumPut("UChar", 0x58, out, 1)
    NumPut("UChar", 0x4E, out, 2)
    NumPut("UChar", 1, out, 3)
    kl := StrLen(ZxnKey)
    Loop n {
        i := A_Index - 1
        b := NumGet(src, i, "UChar") ^ Ord(SubStr(ZxnKey, Mod(i, kl) + 1, 1))
        NumPut("UChar", (b + (i * 31 + 17)) & 0xFF, out, 4 + i)
    }
    return out
}

; scrambled file bytes -> plain bytes
ZxnDecode(buf) {
    n := buf.Size - 4
    if (n < 0 || NumGet(buf, 0, "UChar") != 0x5A || NumGet(buf, 1, "UChar") != 0x58
        || NumGet(buf, 2, "UChar") != 0x4E || NumGet(buf, 3, "UChar") != 1)
        throw Error("Not a valid .zxn file.")
    out := Buffer(n, 0)
    kl := StrLen(ZxnKey)
    Loop n {
        i := A_Index - 1
        e := NumGet(buf, 4 + i, "UChar")
        d := ((e - (i * 31 + 17)) & 0xFF) ^ Ord(SubStr(ZxnKey, Mod(i, kl) + 1, 1))
        NumPut("UChar", d, out, i)
    }
    return out
}

ConvertFile(path) {
    SplitPath(path, , &dir, &ext, &nm)
    ext := StrLower(ext)
    if (ext = "txt") {
        target := dir . "\" . nm . ".zxn"
        data := ZxnEncode(FileRead(path, "RAW"))
    } else if (ext = "zxn") {
        target := dir . "\" . nm . ".txt"
        data := ZxnDecode(FileRead(path, "RAW"))
    } else {
        throw Error("Only .txt and .zxn files are supported.")
    }
    if FileExist(target) {
        if (MsgBox("Replace the existing file?`n`n" . target, "ZxnConvert", 0x34) != "Yes")
            return "Skipped: " . target
    }
    f := FileOpen(target, "w")
    f.RawWrite(data)
    f.Close()
    return "Saved: " . target
}

files := []
for a in A_Args {
    files.Push(a)
}
if (files.Length = 0) {
    sel := FileSelect("M3", A_ScriptDir . "\..\src_enc", "Pick .txt or .zxn mapping files", "Mapping files (*.txt; *.zxn)")
    if !IsObject(sel)
        ExitApp()
    for f in sel {
        files.Push(f)
    }
}

report := ""
for f in files {
    try {
        report .= ConvertFile(f) . "`n"
    } catch as e {
        report .= "Failed: " . f . "  (" . e.Message . ")`n"
    }
}
MsgBox(report, "ZxnConvert")
