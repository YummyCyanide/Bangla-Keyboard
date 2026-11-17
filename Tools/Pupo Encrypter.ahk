; ===========================================================================
;  Pupo Encrypter - locks (encrypts) and unlocks (decrypts) the layouts and encoding tables of Bangla Keyboard,
;  so they cannot be read or changed by accident. Double-click to open.
;    Layouts:   name.xml <-> name.bkl   (read by Bangla Keyboard)
;    Encodings: name.txt <-> name.een   (read by Text Converter and Docs Converter)
;  Add files (or drag and drop many at once), then Encrypt or Decrypt. Layouts and encodings are recognised by themselves.
;  Files that are already in the wanted state are skipped. The original files are never changed:
;  the result is a new file next to the original (or in the "Save to" folder).
;  This is basic protection against accidents, not real security.
;  Needs AutoHotkey v2. Keep the keys below the same as in the programs that read the files.
; ===========================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

global Keys := Map("een", "BanglaConverter", "bkl", "BanglaLayoutKey")
global Magic := Map("een", [0x45, 0x45, 0x4E], "bkl", [0x42, 0x4B, 0x4C])       ; "EEN" / "BKL"
global outDir := "", running := false, stopFlag := false, seen := Map(), lastDir := ""
global G, LV, BtnAdd, BtnRemove, BtnClear, BtnSave, BtnEnc, BtnDec, BtnHelp, LblOut, ChkReplace, SB, PB, HelpGui := ""

Px(n) => Round(n * A_ScreenDPI / 96)

; ---- the locked format ------------------------------------------------------
; plain bytes -> magic (3 bytes) + 0x01 + length (4 bytes) + scrambled bytes
Pack(raw, kind) {
    n := raw.Size
    out := Buffer(n + 8, 0)
    m := Magic[kind]
    NumPut("UChar", m[1], out, 0)
    NumPut("UChar", m[2], out, 1)
    NumPut("UChar", m[3], out, 2)
    NumPut("UChar", 1, out, 3)
    NumPut("UInt", n, out, 4)
    key := Keys[kind]
    kl := StrLen(key)
    Loop n {
        i := A_Index - 1
        b := NumGet(raw, i, "UChar") ^ Ord(SubStr(key, Mod(i, kl) + 1, 1))
        NumPut("UChar", (b + i * 31 + 17) & 0xFF, out, 8 + i)
    }
    return out
}

; locked bytes -> {buf, size} of the plain bytes
Unpack(buf, kind) {
    m := Magic[kind]
    if (buf.Size < 8 || NumGet(buf, 0, "UChar") != m[1] || NumGet(buf, 1, "UChar") != m[2]
        || NumGet(buf, 2, "UChar") != m[3] || NumGet(buf, 3, "UChar") != 1)
        throw Error("Not a valid ." . kind . " file.")
    n := NumGet(buf, 4, "UInt")
    if (n > buf.Size - 8)
        throw Error("This ." . kind . " file is damaged (it ends too early).")
    out := Buffer(Max(n, 1), 0)
    key := Keys[kind]
    kl := StrLen(key)
    Loop n {
        i := A_Index - 1
        e := NumGet(buf, 8 + i, "UChar")
        NumPut("UChar", ((e - (i * 31 + 17)) & 0xFF) ^ Ord(SubStr(key, Mod(i, kl) + 1, 1)), out, i)
    }
    return {buf: out, size: n}
}

SameBytes(a, b, n) {
    Loop n {
        if (NumGet(a, A_Index - 1, "UChar") != NumGet(b, A_Index - 1, "UChar"))
            return false
    }
    return true
}

; a layout must look like XML: the first real character is "<"
CheckXml(raw) {
    i := 0
    if (raw.Size >= 3 && NumGet(raw, 0, "UChar") = 0xEF && NumGet(raw, 1, "UChar") = 0xBB && NumGet(raw, 2, "UChar") = 0xBF)
        i := 3
    while (i < raw.Size && InStr(" `t`r`n", Chr(NumGet(raw, i, "UChar"))))
        i++
    if (i >= raw.Size || NumGet(raw, i, "UChar") != 0x3C)
        throw Error("This does not look like a layout (.xml) file.")
}

; ---- what a file is ---------------------------------------------------------
FmtSize(b) {
    if (b < 1024)
        return b . " B"
    if (b < 1048576)
        return Round(b / 1024, 1) . " KB"
    return Round(b / 1048576, 1) . " MB"
}

; Type: Layout / Encoding / Other.  Status: Encrypted / Unencrypted / Invalid (a .bkl / .een that is not a real locked file) / -
Inspect(path) {
    SplitPath(path, &name, &dir, &ext)
    ext := StrLower(ext)
    size := 0
    try size := FileGetSize(path)
    type := "Other"
    status := "-"
    head := Buffer(8, 0)
    got := 0
    try {
        f := FileOpen(path, "r")
        got := f.RawRead(head, 8)
        f.Close()
    }
    locked := ""
    if (got >= 8 && NumGet(head, 3, "UChar") = 1) {
        for kind, m in Magic {
            if (NumGet(head, 0, "UChar") = m[1] && NumGet(head, 1, "UChar") = m[2] && NumGet(head, 2, "UChar") = m[3])
                locked := kind
        }
    }
    if (locked != "") {
        type := (locked = "bkl") ? "Layout" : "Encoding"
        status := (NumGet(head, 4, "UInt") <= size - 8) ? "Encrypted" : "Invalid"
    } else if (ext = "xml") {
        type := "Layout"
        status := "Unencrypted"
    } else if (ext = "txt") {
        type := "Encoding"
        status := "Unencrypted"
    } else if (ext = "bkl" || ext = "een") {
        type := (ext = "bkl") ? "Layout" : "Encoding"
        status := "Invalid"
    }
    return {name: name, dir: dir, ext: "." . ext, size: FmtSize(size), type: type, status: status}
}

; ---- the list ---------------------------------------------------------------
AddOne(path) {
    key := StrLower(path)
    if seen.Has(key)
        return false
    i := Inspect(path)
    seen[key] := 1
    LV.Add("", i.name, i.type, i.status, i.size, i.ext, i.dir, "")
    return true
}

AddPaths(paths) {
    global lastDir
    added := 0, dup := 0
    LV.Opt("-Redraw")
    for p in paths {
        if DirExist(p) {
            Loop Files, p . "\*", "FR" {
                if AddOne(A_LoopFileFullPath)
                    added++
                else
                    dup++
            }
        } else if FileExist(p) {
            if AddOne(p)
                added++
            else
                dup++
            SplitPath(p, , &lastDir)
        }
    }
    LV.Opt("+Redraw")
    UpdateCounts()
    if (dup > 0)
        SetStatus(added . " file(s) added, " . dup . " already in the list.")
}

AddDialog(*) {
    if running
        return
    start := (lastDir != "" && DirExist(lastDir)) ? lastDir : A_ScriptDir
    sel := FileSelect("M3", start, "Add files", "Layouts and encodings (*.xml; *.bkl; *.txt; *.een)")
    if IsObject(sel)
        AddPaths(sel)
}

Dropped(gObj, ctrl, fileArray, x, y) {
    if !running
        AddPaths(fileArray)
}

SelectedRows() {
    rows := []
    r := 0
    while (r := LV.GetNext(r))
        rows.Push(r)
    return rows
}

RowPath(r) => LV.GetText(r, 6) . "\" . LV.GetText(r, 1)

RemoveSelected(*) {
    if running
        return
    rows := SelectedRows()
    LV.Opt("-Redraw")
    Loop rows.Length {
        r := rows[rows.Length - A_Index + 1]
        seen.Delete(StrLower(RowPath(r)))
        LV.Delete(r)
    }
    LV.Opt("+Redraw")
    UpdateCounts()
}

ClearAll(*) {
    global seen
    if running
        return
    LV.Delete()
    seen := Map()
    PB.Value := 0
    UpdateCounts()
}

UpdateCounts() {
    n := LV.GetCount()
    if (n = 0) {
        SetStatus("Add layout (.xml / .bkl) or encoding (.txt / .een) files, or drop them on this window.")
        return
    }
    e := 0
    Loop n {
        if (LV.GetText(A_Index, 3) = "Encrypted")
            e++
    }
    SetStatus(n . " file(s)  -  " . e . " encrypted, " . (n - e) . " not encrypted")
}

SetStatus(text) {
    try SB.SetText("  " . text, 2)
    catch {
        SB.SetParts(Px(210))                      ; the second part did not exist yet: create it, then retry
        try SB.SetText("  " . text, 2)
    }
}

LvMenu(ctrl, item, isRight, x, y) {
    if running
        return
    m := Menu()
    m.Add("Remove", RemoveSelected)
    m.Add("Show in folder", ShowInFolder)
    m.Add()
    m.Add("Select all`tCtrl+A", (*) => LV.Modify(0, "Select"))
    if (SelectedRows().Length = 0) {
        m.Disable("Remove")
        m.Disable("Show in folder")
    }
    m.Show()
}

ShowInFolder(*) {
    rows := SelectedRows()
    if (rows.Length > 0)
        Run('explorer.exe /select,"' . RowPath(rows[1]) . '"')
}

; ---- Save to ----------------------------------------------------------------
SaveToMenu(*) {
    if running
        return
    m := Menu()
    m.Add("Choose a folder...", ChooseOut)
    m.Add("Next to each original file", (*) => SetOut(""))
    m.Check(outDir = "" ? "Next to each original file" : "Choose a folder...")
    BtnSave.GetPos(&x, &y, , &h)
    m.Show(x, y + h)
}

ChooseOut(*) {
    start := (outDir != "" && DirExist(outDir)) ? outDir : ((lastDir != "" && DirExist(lastDir)) ? lastDir : A_ScriptDir)
    dir := DirSelect("*" . start, 3, "Save the results in this folder")
    if (dir != "")
        SetOut(RTrim(dir, "\"))
}

SetOut(dir) {
    global outDir
    outDir := dir
    LblOut.Text := (dir = "") ? "Save to:  next to each original file" : "Save to:  " . dir
}

; ---- Encrypt / Decrypt ------------------------------------------------------
; returns [state, text]; state is done / skipped / failed
ProcessOne(path, type, status, enc) {
    if (type = "Other")
        return ["skipped", "Not a layout or encoding file"]
    if (status = "Invalid")
        return ["failed", "Not a valid locked file (damaged?)"]
    if (enc && status = "Encrypted")
        return ["skipped", "Already encrypted"]
    if (!enc && status = "Unencrypted")
        return ["skipped", "Not encrypted"]
    SplitPath(path, , &dir, , &nm)
    kind := (type = "Layout") ? "bkl" : "een"
    plain := (type = "Layout") ? "xml" : "txt"
    tdir := (outDir != "") ? outDir : dir
    outName := nm . "." . (enc ? kind : plain)
    target := tdir . "\" . outName
    if (StrLower(target) = StrLower(path))
        return ["skipped", "The result would replace the original"]
    raw := FileRead(path, "RAW")
    if enc {
        if (kind = "bkl")
            CheckXml(raw)
        data := Pack(raw, kind)
        back := Unpack(data, kind)                         ; check: it must read back exactly
        if (back.size != raw.Size || !SameBytes(back.buf, raw, raw.Size))
            throw Error("Check failed: the locked file does not read back the same.")
        size := data.Size
    } else {
        back := Unpack(raw, kind)
        data := back.buf
        size := back.size
    }
    if (FileExist(target) && !ChkReplace.Value) {
        if (MsgBox("Replace the existing file?`n`n" . target, "Pupo Encrypter", 0x34) != "Yes")
            return ["skipped", "Existing file kept"]
    }
    if !DirExist(tdir)
        DirCreate(tdir)
    f := FileOpen(target, "w")
    f.RawWrite(data, size)
    f.Close()
    return ["done", "Saved: " . outName]
}

Run(enc) {
    global running, stopFlag
    if running {                                           ; the busy button says "Stop"
        stopFlag := true
        return
    }
    total := LV.GetCount()
    if (total = 0) {
        MsgBox("Add some files first (Add file, or drop them on the window).", "Pupo Encrypter", 0x40)
        return
    }
    running := true
    stopFlag := false
    busy := enc ? BtnEnc : BtnDec
    idle := enc ? BtnDec : BtnEnc
    word := enc ? "Encrypt" : "Decrypt"
    busy.Text := "Stop"
    idle.Enabled := false
    for c in [BtnAdd, BtnRemove, BtnClear, BtnSave]
        c.Enabled := false
    done := 0, skipped := 0, failed := 0, handled := 0
    problems := ""
    Loop total {
        if stopFlag
            break
        i := A_Index
        SetStatus(word . "ing " . i . " of " . total . " ...")
        PB.Value := Round((i - 1) * 100 / total)
        try {
            r := ProcessOne(RowPath(i), LV.GetText(i, 2), LV.GetText(i, 3), enc)
        } catch as e {
            r := ["failed", e.Message]
        }
        LV.Modify(i, "Col7", (r[1] = "done") ? r[2] : ((r[1] = "skipped") ? "Skipped: " . r[2] : "Failed: " . r[2]))
        if (r[1] = "done")
            done++
        else if (r[1] = "skipped")
            skipped++
        else {
            failed++
            if (failed <= 10)
                problems .= "`n" . LV.GetText(i, 1) . "  (" . r[2] . ")"
        }
        handled := i
        Sleep(1)                                           ; lets a click on Stop through
    }
    PB.Value := stopFlag ? Round(handled * 100 / total) : 100
    wasStopped := stopFlag
    running := false
    busy.Text := word
    idle.Enabled := true
    for c in [BtnAdd, BtnRemove, BtnClear, BtnSave]
        c.Enabled := true
    UpdateCounts()
    msg := (wasStopped ? "Stopped after " . handled . " of " . total . " file(s)." : "Completed with " . failed . " error(s).")
    msg .= "`n`n" . done . " done, " . skipped . " skipped, " . failed . " failed."
    if (skipped > 0)
        msg .= "`nSkipped files were already in the wanted state or are not layouts / encodings (see the Result column)."
    if (failed > 0)
        msg .= "`n`nFailed:" . problems . ((failed > 10) ? "`n..." : "")
    MsgBox(msg, "Pupo Encrypter", failed > 0 ? 0x30 : 0x40)
}

; ---- Help -------------------------------------------------------------------
HelpAbout() {
    return "Pupo Encrypter (Pupo is an Italian word)`n"
        . "`n"
        . "A small helper for Bangla Keyboard. It locks (encrypts) your keyboard layouts and encoding tables so that other people cannot read them or change them by accident, and it unlocks (decrypts) them again.`n"
        . "`n"
        . "This is basic protection against accidents. It is not real security: anyone who has the program files can unlock the files.`n"
        . "`n"
        . "Part of Bangla Keyboard. Free and open source."
}

HelpGuide() {
    return "Quick guide`n"
        . "`n"
        . "1.  Press Add file, or drag and drop as many files as you like onto the window.`n"
        . "2.  Optional: press Save to... to choose a folder for the results. Without it, each result is saved next to its original.`n"
        . "3.  Press Encrypt to lock files, or Decrypt to get the original .xml / .txt back. Layouts (.xml / .bkl) and encodings (.txt / .een) can be mixed in one batch: the program recognises each file by itself.`n"
        . "4.  A message tells you how many files were done, skipped or failed.`n"
        . "`n"
        . "Other buttons`n"
        . "  Remove: takes the selected files out of the list (Delete key works too).`n"
        . "  Clear: empties the list.`n"
        . "  Replace existing files: tick it to overwrite results that already exist without asking.`n"
        . "  Stop: while a batch runs, the button you pressed turns into Stop.`n"
        . "  Right-click a file for Remove / Show in folder. Ctrl+A selects all files.`n"
        . "`n"
        . "Where the locked files go`n"
        . "  Layouts (.bkl or .xml): the Layouts folder of Bangla Keyboard. If a .bkl and a .xml have the same name, the .bkl is used.`n"
        . "  Encodings (.een or .txt): Tools\Encodings."
}

HelpWhat() {
    return "What it does`n"
        . "`n"
        . "Encrypt: a plain file becomes a locked file.`n"
        . "  Layout    name.xml  ->  name.bkl`n"
        . "  Encoding  name.txt  ->  name.een`n"
        . "Decrypt: a locked file becomes the original plain file again.`n"
        . "`n"
        . "The original file is never changed. The result is a new file. After locking a file, the result is checked by reading it back.`n"
        . "`n"
        . "Columns`n"
        . "  Type: Layout, Encoding, or Other (files this program cannot lock; they are skipped).`n"
        . "  Status: Encrypted (locked), Unencrypted (plain), or Invalid (a .bkl / .een that is not a real locked file).`n"
        . "  Result: what happened to the file in the last run (Saved, Skipped with the reason, or Failed with the reason).`n"
        . "`n"
        . "Skipping`n"
        . "  Encrypt ignores files that are already encrypted. Decrypt ignores files that are not encrypted. Files of another kind (Other) are ignored too.`n"
        . "  Nothing is ever locked twice, so a batch can safely contain a mix."
}

ShowHelp(*) {
    global HelpGui
    if IsObject(HelpGui) {
        HelpGui.Show()
        return
    }
    HelpGui := Gui("+Owner" . G.Hwnd . " +Resize +MinSize" . Px(420) . "x" . Px(320), "Pupo Encrypter - Help")
    HelpGui.SetFont("s9", "Segoe UI")
    tb := HelpGui.Add("Tab3", "x8 y8 w" . Px(504) . " h" . Px(370), ["About", "Quick guide", "What it does"])
    HelpGui.eds := []
    for k, txt in [HelpAbout(), HelpGuide(), HelpWhat()] {
        tb.UseTab(k)
        e := HelpGui.Add("Edit", "x16 y" . Px(40) . " w" . Px(488) . " h" . Px(328) . " ReadOnly Multi +VScroll", StrReplace(txt, "`n", "`r`n"))
        HelpGui.eds.Push(e)
    }
    tb.UseTab()
    HelpGui.tb := tb
    HelpGui.btn := HelpGui.Add("Button", "x0 y0 w" . Px(90) . " h" . Px(28), "Close")
    HelpGui.btn.OnEvent("Click", (*) => HelpGui.Hide())
    HelpGui.OnEvent("Close", (*) => HelpGui.Hide())
    HelpGui.OnEvent("Size", HelpSize)
    HelpGui.Show("w" . Px(520) . " h" . Px(430))
}

HelpSize(gObj, minMax, w, h) {
    if (minMax = -1)
        return
    m := Px(8)
    bh := Px(28)
    HelpGui.tb.Move(m, m, w - 2 * m, h - 3 * m - bh)
    for e in HelpGui.eds
        e.Move(m + Px(8), m + Px(32), w - 2 * m - Px(16), h - 3 * m - bh - Px(40))
    HelpGui.btn.Move(w - m - Px(90), h - m - bh, Px(90), bh)
}

; ---- the window -------------------------------------------------------------
OnSize(gObj, minMax, w, h) {
    if (minMax = -1)
        return
    d := A_ScreenDPI / 96
    m := Round(10 * d)
    tm := Round(8 * d)
    gap := Round(6 * d)
    bh := Round(28 * d)
    ; the toolbar fills the whole width: every button the same width
    bw := Max(Px(60), Round((w - 2 * m - 6 * gap) / 7))
    x := m
    for c in [BtnAdd, BtnRemove, BtnClear, BtnSave, BtnEnc, BtnDec, BtnHelp] {
        c.Move(x, tm, bw, bh)
        x += bw + gap
    }
    ; status bar: progress bar on the left, text next to it
    sbh := 0
    SB.GetPos(, , , &sbh)
    pw := Px(210)
    SB.SetParts(pw)
    pbH := Max(8, sbh - Round(8 * d))
    DllCall("SetWindowPos", "Ptr", PB.Hwnd, "Ptr", 0, "Int", Round(4 * d), "Int", Max(0, (sbh - pbH) // 2)
        , "Int", pw - Round(12 * d), "Int", pbH, "UInt", 0x40)
    DllCall("RedrawWindow", "Ptr", PB.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x105)
    ; second row: where the results go + replace box, then the list
    y2 := tm + bh + gap
    lh := Round(20 * d)
    cw := Px(190)
    LblOut.Move(m, y2, Max(Px(60), w - 2 * m - cw - gap), lh)
    ChkReplace.Move(w - m - cw, y2, cw, lh)
    ly := y2 + lh + gap
    LV.Move(m, ly, w - 2 * m, Max(Px(60), h - sbh - ly - gap))
    used := Px(170) + Px(80) + Px(100) + Px(70) + Px(80) + Px(230)
    LV.ModifyCol(7, Max(Px(160), w - 2 * m - used - Px(24)))
}

BuildGui() {
    global G, LV, BtnAdd, BtnRemove, BtnClear, BtnSave, BtnEnc, BtnDec, BtnHelp, LblOut, ChkReplace, SB, PB
    G := Gui("+Resize +0x2000000", "Pupo Encrypter")           ; 0x2000000 = clip children (less flicker)
    G.SetFont("s9", "Segoe UI")
    G.Opt("+MinSize" . Px(760) . "x" . Px(380))
    BtnAdd := G.Add("Button", "x0 y0 w80 h24", "Add file")
    BtnRemove := G.Add("Button", "x0 y0 w80 h24", "Remove")
    BtnClear := G.Add("Button", "x0 y0 w80 h24", "Clear")
    BtnSave := G.Add("Button", "x0 y0 w80 h24", "Save to...")
    BtnEnc := G.Add("Button", "x0 y0 w80 h24", "Encrypt")
    BtnDec := G.Add("Button", "x0 y0 w80 h24", "Decrypt")
    BtnHelp := G.Add("Button", "x0 y0 w80 h24", "Help")
    LblOut := G.Add("Text", "x0 y0 w300 h20 +0x200 +0x8000", "Save to:  next to each original file")
    ChkReplace := G.Add("Checkbox", "x0 y0 w180 h20", "Replace existing files")
    LV := G.Add("ListView", "x0 y0 w700 h300 +Multi NoSort Grid", ["Name", "Type", "Status", "Size", "Extension", "Folder", "Result"])
    for k, w in [170, 80, 100, 70, 80, 230, 200]
        LV.ModifyCol(k, Px(w))
    SB := G.Add("StatusBar", , "")
    SB.SetParts(Px(210))                                       ; part 1 = progress bar, part 2 = text (must exist before the first SetStatus)
    PB := G.Add("Progress", "x0 y0 w100 h14 Range0-100", 0)
    DllCall("SetParent", "Ptr", PB.Hwnd, "Ptr", SB.Hwnd)         ; the progress bar lives inside the left end of the status bar
    BtnAdd.OnEvent("Click", AddDialog)
    BtnRemove.OnEvent("Click", RemoveSelected)
    BtnClear.OnEvent("Click", ClearAll)
    BtnSave.OnEvent("Click", SaveToMenu)
    BtnEnc.OnEvent("Click", (*) => Run(true))
    BtnDec.OnEvent("Click", (*) => Run(false))
    BtnHelp.OnEvent("Click", ShowHelp)
    LV.OnEvent("ContextMenu", LvMenu)
    G.OnEvent("DropFiles", Dropped)
    G.OnEvent("Size", OnSize)
    G.OnEvent("Close", (*) => ExitApp())
    UpdateCounts()
    G.Show("w" . Px(900) . " h" . Px(520))
}

BuildGui()
paths := []
for a in A_Args
    paths.Push(a)
if (paths.Length > 0)
    AddPaths(paths)

#HotIf IsObject(G) && WinActive("ahk_id " . G.Hwnd)
^a::{
    if !running
        LV.Modify(0, "Select")
}
Delete::RemoveSelected()
#HotIf
