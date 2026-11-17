; ===========================================================================
;  Bangla Text Converter  -  ANSI (Bijoy) <-> Unicode
;  Two boxes: type or paste in one, then press "To ANSI" / "To Unicode" to convert.
;  Needs AutoHotkey v2. Mapping tables live in the Encodings folder as *.txt
;  (plain) or *.een (same text, lightly scrambled for distribution).
;  Format: one "ansi<TAB>unicode" pair per line, lines starting with # are
;  comments. Use Tools\Pupo Encrypter.ahk to turn a .txt into a .een.
; ===========================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
SetWorkingDir A_ScriptDir

class Cv {
    static fw := ""              ; ANSI text -> Unicode text
    static rv := ""              ; Unicode text -> ANSI text
    static fwMax := 1
    static rvMax := 1
    static rephAnsi := ""
    static ansi := ""
    static uni := ""
    static gui := ""
    static sg := ""
    static sb := ""
    static subCb := 0
    static b1 := ""
    static b2 := ""
    static b3 := ""
    static b4 := ""
    static dd := ""
    static ini := A_AppData . "\Bangla Keyboard\Text Converter.dat"
    static fontA := "SutonnyMJ"
    static sizeA := 15
    static fontU := "Nirmala UI"
    static sizeU := 13
    static files := []
    static layout := "H"         ; H = stacked, V = side by side, T = tabs
    static tab := ""
    static ek := "BanglaConverter"    ; scramble key for .een files (see EenDecode)
    static lastA := ""
    static lastU := ""
    ; draggable divider between the two boxes
    static ratioH := 0.5         ; share of the space the top box gets (stacked view)
    static ratioV := 0.5         ; share of the space the left box gets (side by side view)
    static sx := 0               ; divider rectangle (client pixels); sw = 0 means "no divider"
    static sy := 0
    static sw := 0
    static sh := 0
    static sOrigin := 0          ; where the box area starts along the drag axis
    static sTotal := 1           ; box area size along the drag axis (without the divider)
    static sMin := 40            ; smallest allowed box size
    static sGrip := 6            ; divider thickness
    static dragging := false
    static theme := "L"          ; L = light (the default), S = follow Windows, D = dark
    static dark := false
    static bg := "F0F0F0"        ; window colours (RRGGBB), set by CvApplyTheme
    static fg := "000000"
    static ebg := "FFFFFF"       ; text box colours
    static efg := "000000"
    static tabSel := "FFFFFF"    ; tab header colours
    static tabIdle := "E1E1E1"
    static tabLine := "ACACAC"
    static tabNames := ["Unicode", "ANSI"]
    static fd := ""              ; toolbar: ANSI font dropdown
    static sz := ""              ; toolbar: ANSI font size box
    static fonts := []
    static sizes := ["8", "10", "12", "14", "16", "18", "20", "24", "28", "32", "36", "40", "48", "60", "72"]
    static lastDown := 0
    ; Bangla characters (written as codes so the script does not depend on file encoding)
    static HAS := Chr(0x09CD)                    ; hasanta  ্
    static ZWNJ := Chr(0x200C)
    static ZWJ := Chr(0x200D)
    static VI := Chr(0x09BF)                     ; ি
    static VE := Chr(0x09C7)                     ; ে
    static VAI := Chr(0x09C8)                    ; ৈ
    static AA := Chr(0x09BE)                     ; া
    static AU := Chr(0x09D7)                     ; ৗ
    static O := Chr(0x09CB)                      ; ো
    static AUU := Chr(0x09CC)                    ; ৌ
    static RA := Chr(0x09B0)                     ; র
    static REPH := Chr(0x09B0) . Chr(0x09CD)     ; র্
    static SIGNS := Chr(0x09BE) . Chr(0x09BF) . Chr(0x09C0) . Chr(0x09C1) . Chr(0x09C2) . Chr(0x09C3) . Chr(0x09C7) . Chr(0x09C8) . Chr(0x09D7) . Chr(0x0981) . Chr(0x0982) . Chr(0x0983)
}

; ---------------------------------------------------------------------------
;  Mapping table
; ---------------------------------------------------------------------------
; .een = a text mapping file, scrambled byte by byte. Layout: "EEN" + 0x01 + the text length (4 bytes),
; then each byte is (plain XOR key[i]) + (i*31+17), all modulo 256. This is only meant to stop the
; file being read at a glance; it is not real encryption. A .een file that holds plain text is read as it is.
EenDecode(buf) {
    if (buf.Size = 0)
        return ""
    if (buf.Size < 8 || NumGet(buf, 0, "UChar") != 0x45 || NumGet(buf, 1, "UChar") != 0x45
        || NumGet(buf, 2, "UChar") != 0x4E || NumGet(buf, 3, "UChar") != 1)
        return StrGet(buf, buf.Size, "UTF-8")
    n := NumGet(buf, 4, "UInt")
    if (n > buf.Size - 8)
        throw Error("This .een file is damaged (it ends too early).")
    if (n = 0)
        return ""
    out := Buffer(n, 0)
    kl := StrLen(Cv.ek)
    Loop n {
        i := A_Index - 1
        e := NumGet(buf, 8 + i, "UChar")
        d := ((e - (i * 31 + 17)) & 0xFF) ^ Ord(SubStr(Cv.ek, Mod(i, kl) + 1, 1))
        NumPut("UChar", d, out, i)
    }
    return StrGet(out, n, "UTF-8")
}

LoadMapping(path) {
    SplitPath(path, , , &ext)
    if (StrLower(ext) = "een")
        txt := EenDecode(FileRead(path, "RAW"))
    else
        txt := FileRead(path, "UTF-8")
    if (SubStr(txt, 1, 1) == Chr(0xFEFF))
        txt := SubStr(txt, 2)
    fw := Map()
    fw.CaseSense := "On"
    rv := Map()
    rv.CaseSense := "On"
    fmax := 1
    rmax := 1
    Loop Parse txt, "`n", "`r" {
        line := A_LoopField
        if (line = "" || SubStr(line, 1, 1) = "#")
            continue
        parts := StrSplit(line, "`t")
        if (parts.Length < 2)
            continue
        a := parts[1]
        u := parts[2]
        if (a = "" || u = "")
            continue
        if !fw.Has(a) {
            fw[a] := u
            fmax := Max(fmax, StrLen(a))
        }
        if !rv.Has(u) {
            rv[u] := a
            rmax := Max(rmax, StrLen(u))
        }
    }
    ; where the table lists several equal glyphs, prefer the usual ones
    if fw.Has(Chr(0x02C6))
        rv[Cv.VAI] := Chr(0x02C6)
    if fw.Has(Chr(0x00D6))
        rv[Cv.HAS . Cv.RA] := Chr(0x00D6)
    Cv.fw := fw
    Cv.rv := rv
    Cv.fwMax := fmax
    Cv.rvMax := rmax
    Cv.rephAnsi := rv.Get(Cv.REPH, "")
}

; ---------------------------------------------------------------------------
;  Helpers
; ---------------------------------------------------------------------------
IsConsCode(o) {
    return (o >= 0x0995 && o <= 0x09B9) || o = 0x09DC || o = 0x09DD || o = 0x09DF
}

IsConsTok(t) {
    return (t != "" && IsConsCode(Ord(t)))
}

IsZW(ch) {
    return (ch == Cv.ZWNJ || ch == Cv.ZWJ)
}

; Longest-match split of s using map m. Returns an array of converted pieces.
; Characters that are not in the table are passed through unchanged.
Tokenize(s, m, maxLen, skipKey := "") {
    toks := []
    n := StrLen(s)
    i := 1
    while (i <= n) {
        hit := false
        L := Min(maxLen, n - i + 1)
        while (L >= 1) {
            k := SubStr(s, i, L)
            if (m.Has(k) && !(skipKey != "" && k == skipKey)) {
                toks.Push(m[k])
                i += L
                hit := true
                break
            }
            L -= 1
        }
        if !hit {
            toks.Push(SubStr(s, i, 1))
            i += 1
        }
    }
    return toks
}

JoinTokens(arr) {
    r := ""
    for v in arr {
        r .= v
    }
    return r
}

MapUni(x) {
    return JoinTokens(Tokenize(x, Cv.rv, Cv.rvMax, Cv.REPH))
}

; ---------------------------------------------------------------------------
;  ANSI (Bijoy) -> Unicode
;  In ANSI the vowel signs i/e/oi come BEFORE the consonant group and the reph
;  comes AFTER it; Unicode wants the opposite, so the pieces are re-ordered.
; ---------------------------------------------------------------------------
AnsiToUni(s) {
    toks := Tokenize(s, Cv.fw, Cv.fwMax)
    n := toks.Length
    out := ""
    i := 1
    while (i <= n) {
        t := toks[i]
        pre := ""
        if (t == Cv.VI || t == Cv.VE || t == Cv.VAI) {
            if (i < n && IsConsTok(toks[i + 1])) {
                pre := t
                i += 1
                t := toks[i]
            } else {
                out .= t
                i += 1
                continue
            }
        }
        if IsConsTok(t) {
            cl := t
            i += 1
            while (i <= n) {
                u := toks[i]
                if (u == Cv.HAS) {
                    if (i < n && IsConsTok(toks[i + 1])) {
                        cl .= u . toks[i + 1]
                        i += 2
                    } else {
                        break
                    }
                } else if (SubStr(u, 1, 1) == Cv.HAS) {
                    cl .= u
                    i += 1
                } else {
                    break
                }
            }
            res := cl
            if (i <= n && toks[i] == Cv.REPH) {
                res := Cv.REPH . cl
                i += 1
            }
            if (pre == Cv.VE) {
                if (i <= n && toks[i] == Cv.AA) {
                    res .= Cv.O
                    i += 1
                } else if (i <= n && toks[i] == Cv.AU) {
                    res .= Cv.AUU
                    i += 1
                } else {
                    res .= pre
                }
            } else if (pre != "") {
                res .= pre
            }
            out .= res
        } else {
            out .= t
            i += 1
        }
    }
    return out
}

; ---------------------------------------------------------------------------
;  Unicode -> ANSI (Bijoy)
; ---------------------------------------------------------------------------
UniToAnsi(s) {
    s := StrReplace(s, Cv.O, Cv.VE . Cv.AA)
    s := StrReplace(s, Cv.AUU, Cv.VE . Cv.AU)
    s := StrReplace(s, Chr(0x09A1) . Chr(0x09BC), Chr(0x09DC))
    s := StrReplace(s, Chr(0x09A2) . Chr(0x09BC), Chr(0x09DD))
    s := StrReplace(s, Chr(0x09AF) . Chr(0x09BC), Chr(0x09DF))
    n := StrLen(s)
    out := ""
    i := 1
    while (i <= n) {
        c := SubStr(s, i, 1)
        j := i
        reph := false
        if (c == Cv.RA && j + 2 <= n && SubStr(s, j + 1, 1) == Cv.HAS && IsConsTok(SubStr(s, j + 2, 1))) {
            reph := true
            j += 2
        }
        if IsConsTok(SubStr(s, j, 1)) {
            k := j + 1
            while true {
                m := k
                if (m <= n && IsZW(SubStr(s, m, 1)))
                    m += 1
                if (m + 1 <= n && SubStr(s, m, 1) == Cv.HAS && IsConsTok(SubStr(s, m + 1, 1))) {
                    k := m + 2
                } else {
                    break
                }
            }
            chain := SubStr(s, j, k - j)
            pre := ""
            post := ""
            while (k <= n) {
                ch := SubStr(s, k, 1)
                if !InStr(Cv.SIGNS, ch, true)
                    break
                if (pre = "" && (ch == Cv.VI || ch == Cv.VE || ch == Cv.VAI)) {
                    pre := ch
                } else {
                    post .= ch
                }
                k += 1
            }
            a := ""
            if (pre != "")
                a := Cv.rv.Get(pre, pre)
            if reph {
                a .= MapUni(chain) . Cv.rephAnsi . MapUni(post)
            } else {
                a .= MapUni(chain . post)
            }
            out .= a
            i := k
        } else {
            out .= MapUni(c)
            i += 1
        }
    }
    return out
}

; ---------------------------------------------------------------------------
;  Window
; ---------------------------------------------------------------------------
; Conversion only happens when one of the two buttons is pressed.
; "To Unicode": ANSI box -> Unicode box
CvToUnicode(*) {
    Cv.uni.Value := AnsiToUni(Cv.ansi.Value)
}

; "To ANSI": Unicode box -> ANSI box
CvToAnsi(*) {
    Cv.ansi.Value := UniToAnsi(Cv.uni.Value)
}

CvMappingChanged(*) {
    idx := Cv.dd.Value
    if (idx < 1)
        return
    try {
        LoadMapping(Cv.files[idx])
    } catch as e {
        MsgBox("Could not read the mapping file:`n" . Cv.files[idx] . "`n`n" . e.Message, "Bangla Text Converter", 0x10)
        return
    }
    ; texts stay as they are; they are only converted when a button is pressed
}

; ANSI preview font / size, chosen from the toolbar. Both boxes accept a pick from the
; list or typed text. The text is read a moment after the event, because right after a
; list pick the box can still hold its old text.
CvToolFont(*) {
    SetTimer(CvApplyToolFont.Bind(false), -80)
}

CvToolFontDone(*) {                                  ; focus left the box: accept any typed name
    SetTimer(CvApplyToolFont.Bind(true), -10)
}

CvApplyToolFont(any) {
    f := Trim(Cv.fd.Text)
    if (f = "")
        return
    found := false
    for n in Cv.fonts {
        if (n = f) {                                 ; case-insensitive match with an installed font
            f := n
            found := true
            break
        }
    }
    if (!found && !any)
        return                                       ; still typing: wait for a full name
    if (f = Cv.fontA)
        return
    Cv.fontA := f
    CvApplyFonts()
    CvSaveSettings()
}

CvToolSize(*) {
    SetTimer(CvApplyToolSize, -80)
}

CvApplyToolSize() {
    v := Trim(Cv.sz.Text)
    if (!IsInteger(v) || v < 6 || v > 72)
        return                                       ; ignore half-typed values like "1"
    if (Integer(v) = Cv.sizeA)
        return
    Cv.sizeA := Integer(v)
    CvApplyFonts()
    CvSaveSettings()
}

CvClear(*) {
    Cv.ansi.Value := ""
    Cv.uni.Value := ""
    CvFocusBox()
}

; Height (pixels) of the closed dropdown box, so the buttons can match it.
CvDdHeight() {
    try {
        buf := Buffer(A_PtrSize = 8 ? 64 : 52, 0)
        NumPut("UInt", buf.Size, buf, 0)
        SendMessage(0x164, 0, buf.Ptr, Cv.dd.Hwnd)      ; CB_GETCOMBOBOXINFO
        h := NumGet(buf, 24, "Int") + NumGet(buf, 32, "Int")
        if (h >= 16 && h <= 60)
            return h
    }
    return Round(23 * A_ScreenDPI / 96)
}

; Height of the tab strip (tab view only).
CvTabHeight() {
    d := A_ScreenDPI / 96
    try {
        rc := Buffer(16, 0)
        if SendMessage(0x130A, 0, rc.Ptr, Cv.tab.Hwnd) {     ; TCM_GETITEMRECT
            b := NumGet(rc, 12, "Int")
            if (b >= 10 && b <= 80)
                return b + Round(4 * d)
        }
    }
    return Round(28 * d)
}

; Make the two tab headers share the full width (50% each).
CvTabFit(availW) {
    try {
        rc := Buffer(16, 0)
        if !SendMessage(0x130A, 0, rc.Ptr, Cv.tab.Hwnd)         ; TCM_GETITEMRECT
            return
        ih := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
        iw := (availW - Round(5 * A_ScreenDPI / 96)) // 2
        if (ih > 0 && iw > 20)
            SendMessage(0x1329, 0, (ih << 16) | (iw & 0xFFFF), Cv.tab.Hwnd)   ; TCM_SETITEMSIZE
    }
}

CvSize(gObj, minMax, w, h) {
    if (minMax = -1)
        return
    d := A_ScreenDPI / 96
    m := Round(10 * d)                           ; side margin (toolbar, boxes)
    tm := Round(4 * d)
    gap := Round(3 * d)
    bh := CvDdHeight()
    bw := Round(88 * d)
    ddw := Round(120 * d)
    fdw := Round(140 * d)
    szw := Round(52 * d)
    ; spread any extra width over the toolbar: dropdowns get most, buttons a little
    extra := (w - 2 * m) - (4 * bw + ddw + fdw + szw + 6 * gap)
    if (extra > 0) {
        bw += Round(extra * 0.10)
        ddw += Round(extra * 0.25)
        fdw += Round(extra * 0.25)
        szw += Round(extra * 0.10)
    }

    ; toolbar (fixed size): To ANSI | mapping | To Unicode | ANSI font | ANSI size | Clear both | Settings
    x := m
    Cv.b1.Move(x, tm, bw, bh)
    x += bw + gap
    Cv.dd.Move(x, tm, ddw)
    x += ddw + gap
    Cv.b2.Move(x, tm, bw, bh)
    x += bw + gap
    Cv.fd.Move(x, tm, fdw)
    x += fdw + gap
    Cv.sz.Move(x, tm, szw)
    x += szw + gap
    Cv.b3.Move(x, tm, bw, bh)
    x += bw + gap
    Cv.b4.Move(x, tm, bw, bh)

    ; the two boxes (area between the toolbar and the status bar)
    sbh := Round(22 * d)
    Cv.sb.Move(0, h - sbh, w, sbh)
    top := tm + bh + gap
    availW := w - 2 * m
    availH := h - sbh - top - gap
    if (availW < 100 || availH < 80)
        return
    sg := Round(Cv.sGrip * d)                    ; divider thickness
    mn := Round(60 * d)                          ; smallest box
    Cv.sMin := mn
    Cv.sw := 0
    if (Cv.layout = "V") {                       ; side by side, divider is vertical
        total := availW - sg
        w1 := Min(Max(Round(total * Cv.ratioV), mn), Max(mn, total - mn))
        Cv.uni.Move(m, top, w1, availH)
        Cv.ansi.Move(m + w1 + sg, top, total - w1, availH)
        Cv.sx := m + w1, Cv.sy := top, Cv.sw := sg, Cv.sh := availH
        Cv.sOrigin := m, Cv.sTotal := total
    } else if (Cv.layout = "T") {                ; tabs (no divider)
        th := CvTabHeight()
        Cv.tab.Move(m, top, availW, th)
        CvTabFit(availW)
        th := CvTabHeight()
        Cv.tab.Move(m, top, availW, th)
        Cv.uni.Move(m, top + th, availW, availH - th)
        Cv.ansi.Move(m, top + th, availW, availH - th)
    } else {                                     ; stacked: Unicode on top, ANSI underneath
        total := availH - sg
        h1 := Min(Max(Round(total * Cv.ratioH), mn), Max(mn, total - mn))
        Cv.uni.Move(m, top, availW, h1)
        Cv.ansi.Move(m, top + h1 + sg, availW, total - h1)
        Cv.sx := m, Cv.sy := top + h1, Cv.sw := availW, Cv.sh := sg
        Cv.sOrigin := top, Cv.sTotal := total
    }
}

; ---------------------------------------------------------------------------
;  Draggable divider between the two boxes (stacked and side by side views)
; ---------------------------------------------------------------------------
CvCursorClient(&x, &y) {
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    DllCall("ScreenToClient", "Ptr", Cv.gui.Hwnd, "Ptr", pt)
    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")
}

CvOnDivider(x, y) {
    if (Cv.sw <= 0)
        return false
    t := Round(2 * A_ScreenDPI / 96)             ; a little slack around the thin bar
    return (x >= Cv.sx - t && x < Cv.sx + Cv.sw + t && y >= Cv.sy - t && y < Cv.sy + Cv.sh + t)
}

CvSetRatio(x, y) {
    pos := (Cv.layout = "V") ? x : y
    half := Cv.sGrip * (A_ScreenDPI / 96) / 2
    first := pos - Cv.sOrigin - half             ; wanted size of the first box
    first := Min(Max(first, Cv.sMin), Max(Cv.sMin, Cv.sTotal - Cv.sMin))
    r := first / Cv.sTotal
    if (Cv.layout = "V")
        Cv.ratioV := r
    else
        Cv.ratioH := r
    CvRelayout()
}

CvWmSetCursor(wParam, lParam, msg, hwnd) {
    if (hwnd != Cv.gui.Hwnd)
        return
    CvCursorClient(&x, &y)
    if (Cv.dragging || (wParam = Cv.gui.Hwnd && CvOnDivider(x, y))) {
        cur := DllCall("LoadCursor", "Ptr", 0, "Ptr", (Cv.layout = "V") ? 32644 : 32645, "Ptr")   ; size WE / NS
        DllCall("SetCursor", "Ptr", cur)
        return 1
    }
}

CvWmLButtonDown(wParam, lParam, msg, hwnd) {
    if (hwnd != Cv.gui.Hwnd)
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if !CvOnDivider(x, y)
        return
    now := A_TickCount
    if (now - Cv.lastDown <= DllCall("GetDoubleClickTime", "UInt")) {      ; double click: back to 50/50
        Cv.lastDown := 0
        if (Cv.layout = "V")
            Cv.ratioV := 0.5
        else
            Cv.ratioH := 0.5
        CvRelayout()
        CvSaveSettings()
        return 0
    }
    Cv.lastDown := now
    Cv.dragging := true
    DllCall("SetCapture", "Ptr", Cv.gui.Hwnd)
    return 0
}

CvWmMouseMove(wParam, lParam, msg, hwnd) {
    if (!Cv.dragging || hwnd != Cv.gui.Hwnd)
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if (x > 32767)
        x -= 65536
    if (y > 32767)
        y -= 65536
    CvSetRatio(x, y)
    return 0
}

CvWmLButtonUp(wParam, lParam, msg, hwnd) {
    if (!Cv.dragging || hwnd != Cv.gui.Hwnd)
        return
    Cv.dragging := false
    DllCall("ReleaseCapture")
    CvSaveSettings()
    return 0
}

CvStatus(s) {
    Cv.sb.Text := s
}

CvRelayout() {
    try {
        Cv.gui.GetClientPos(, , &w, &h)
        CvSize(Cv.gui, 0, w, h)
    }
}

; Show / hide the boxes and the tab strip for the current layout.
CvApplyLayout() {
    isTab := (Cv.layout = "T")
    Cv.tab.Visible := isTab
    if isTab {
        sel := Cv.tab.Value
        Cv.uni.Visible := (sel = 1)
        Cv.ansi.Visible := (sel = 2)
        CvStatus("  Unicode and ANSI text are in separate tabs.")
    } else {
        Cv.uni.Visible := true
        Cv.ansi.Visible := true
        if (Cv.layout = "V")
            CvStatus("  Left box for Unicode text and right for ANSI. Drag the divider to resize.")
        else
            CvStatus("  Top box for Unicode text and bottom for ANSI. Drag the divider to resize.")
    }
    CvRelayout()
}

CvTabChanged(*) {
    sel := Cv.tab.Value
    Cv.uni.Visible := (sel = 1)
    Cv.ansi.Visible := (sel = 2)
    CvFocusBox()
}

; Put the cursor in a box that is actually visible.
CvFocusBox() {
    try {
        if (Cv.layout = "T" && Cv.tab.Value = 2)
            Cv.ansi.Focus()
        else
            Cv.uni.Focus()
    }
}

; ---------------------------------------------------------------------------
;  Light / dark theme
; ---------------------------------------------------------------------------
CvSysDark() {
    try return (RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme") = 0)
    return false
}

CvIsDark() {
    if (Cv.theme = "D")
        return true
    if (Cv.theme = "L")
        return false
    return CvSysDark()
}

CvBGR(hex) {
    r := Integer("0x" . SubStr(hex, 1, 2))
    g := Integer("0x" . SubStr(hex, 3, 2))
    b := Integer("0x" . SubStr(hex, 5, 2))
    return r | (g << 8) | (b << 16)
}

; Ask Windows to draw this process's own popup menus (the right-click menu) dark or light.
CvAppMode(dark) {
    try {
        h := DllCall("GetModuleHandle", "Str", "uxtheme", "Ptr")
        f := DllCall("GetProcAddress", "Ptr", h, "Ptr", 135, "Ptr")      ; SetPreferredAppMode
        if f
            DllCall(f, "Int", dark ? 2 : 0)
        f := DllCall("GetProcAddress", "Ptr", h, "Ptr", 136, "Ptr")      ; FlushMenuThemes
        if f
            DllCall(f)
    }
}

CvTitleBar(hwnd, dark) {
    v := dark ? 1 : 0
    try {
        if (DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "Int", 20, "Int*", v, "Int", 4) != 0)
            DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "Int", 19, "Int*", v, "Int", 4)
    }
}

; kind: "btn" (buttons), "cb" (drop-down boxes), "edit" (scroll bars)
CvCtlTheme(ctl, kind, dark) {
    try {
        if !dark {
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctl.Hwnd, "Ptr", 0, "Ptr", 0)       ; back to the default look
        } else if (kind = "cb") {
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctl.Hwnd, "Str", "DarkMode_CFD", "Ptr", 0)
        } else {
            DllCall("uxtheme\SetWindowTheme", "Ptr", ctl.Hwnd, "Str", "DarkMode_Explorer", "Ptr", 0)
        }
    }
}

; Editable drop-down boxes: colour the text area and the list, and give the inner
; edit field the dark theme too (otherwise it stays white).
CvComboColors(ctl, dark) {
    CvCtlTheme(ctl, "cb", dark)
    try {
        ctl.Opt("+Background" . (dark ? Cv.ebg : "FFFFFF"))
        ctl.SetFont("s9 c" . (dark ? Cv.efg : "000000"), "Segoe UI")
    }
    try {
        buf := Buffer(A_PtrSize = 8 ? 64 : 52, 0)
        NumPut("UInt", buf.Size, buf, 0)
        SendMessage(0x164, 0, buf.Ptr, ctl.Hwnd)                      ; CB_GETCOMBOBOXINFO
        po := (A_PtrSize = 8) ? 48 : 44
        edit := NumGet(buf, po, "Ptr")
        list := NumGet(buf, po + A_PtrSize, "Ptr")
        for h in [edit, list] {
            if !h
                continue
            if !dark
                DllCall("uxtheme\SetWindowTheme", "Ptr", h, "Ptr", 0, "Ptr", 0)
            else
                DllCall("uxtheme\SetWindowTheme", "Ptr", h, "Str", "DarkMode_CFD", "Ptr", 0)
        }
        DllCall("InvalidateRect", "Ptr", ctl.Hwnd, "Ptr", 0, "Int", 1)
    }
}

CvApplyTheme() {
    dark := CvIsDark()
    Cv.dark := dark
    if dark {
        Cv.bg := "202020", Cv.fg := "E6E6E6", Cv.ebg := "1E1E1E", Cv.efg := "E6E6E6"
        Cv.tabSel := "1E1E1E", Cv.tabIdle := "303030", Cv.tabLine := "555555"
    } else {
        Cv.bg := "F0F0F0", Cv.fg := "000000", Cv.ebg := "FFFFFF", Cv.efg := "000000"
        Cv.tabSel := "FFFFFF", Cv.tabIdle := "E1E1E1", Cv.tabLine := "ACACAC"
    }
    CvAppMode(dark)
    CvTitleBar(Cv.gui.Hwnd, dark)
    Cv.gui.BackColor := Cv.bg
    for c in [Cv.b1, Cv.b2, Cv.b3, Cv.b4]
        CvCtlTheme(c, "btn", dark)
    CvCtlTheme(Cv.dd, "cb", dark)
    CvComboColors(Cv.fd, dark)
    CvComboColors(Cv.sz, dark)
    for c in [Cv.uni, Cv.ansi]
        CvCtlTheme(c, "edit", dark)
    Cv.uni.Opt("+Background" . Cv.ebg)
    Cv.ansi.Opt("+Background" . Cv.ebg)
    Cv.sb.Opt("+Background" . Cv.bg)
    Cv.sb.SetFont("s9 c" . Cv.fg, "Segoe UI")
    CvApplyFonts()
    try DllCall("InvalidateRect", "Ptr", Cv.tab.Hwnd, "Ptr", 0, "Int", 1)
    try DllCall("RedrawWindow", "Ptr", Cv.gui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x585)
}

; The tab headers are drawn here so they can follow the theme.
CvWmDrawItem(wParam, lParam, msg, hwnd) {
    if (hwnd != Cv.gui.Hwnd)
        return
    off := (A_PtrSize = 8) ? 24 : 20
    if (NumGet(lParam, off, "Ptr") != Cv.tab.Hwnd)
        return
    item := NumGet(lParam, 8, "UInt")
    sel := NumGet(lParam, 16, "UInt") & 1
    hdc := NumGet(lParam, off + A_PtrSize, "Ptr")
    rc := lParam + off + 2 * A_PtrSize
    b1 := DllCall("CreateSolidBrush", "UInt", CvBGR(sel ? Cv.tabSel : Cv.tabIdle), "Ptr")
    b2 := DllCall("CreateSolidBrush", "UInt", CvBGR(Cv.tabLine), "Ptr")
    DllCall("FillRect", "Ptr", hdc, "Ptr", rc, "Ptr", b1)
    DllCall("FrameRect", "Ptr", hdc, "Ptr", rc, "Ptr", b2)
    hf := SendMessage(0x31, 0, 0, Cv.tab.Hwnd)               ; WM_GETFONT
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hf, "Ptr")
    DllCall("SetBkMode", "Ptr", hdc, "Int", 1)
    DllCall("SetTextColor", "Ptr", hdc, "UInt", CvBGR(Cv.fg))
    DllCall("DrawText", "Ptr", hdc, "Str", Cv.tabNames[item + 1], "Int", -1, "Ptr", rc, "UInt", 0x25)   ; centred
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
    DllCall("DeleteObject", "Ptr", b1)
    DllCall("DeleteObject", "Ptr", b2)
    return 1
}

; Windows light/dark switch while "System" is selected.
CvWmSettingChange(wParam, lParam, msg, hwnd) {
    if (hwnd != Cv.gui.Hwnd || Cv.theme != "S" || !lParam)
        return
    try {
        if (StrGet(lParam, "UTF-16") = "ImmersiveColorSet")
            SetTimer(CvApplyTheme, -100)
    }
}

; ---------------------------------------------------------------------------
;  Settings (view layout and preview fonts)
; ---------------------------------------------------------------------------
CvLoadSettings() {
    if !FileExist(Cv.ini) {
        for prev in ["text_converter_config.ini", "txc_cfg.dat"] {          ; names used by earlier builds
            if FileExist(A_AppData . "\Bangla Keyboard\" . prev) {
                try FileMove(A_AppData . "\Bangla Keyboard\" . prev, Cv.ini)
                break
            }
        }
    }
    if !FileExist(Cv.ini)
        return
    try {
        Cv.fontA := IniRead(Cv.ini, "Preview", "AnsiFont", Cv.fontA)
        Cv.fontU := IniRead(Cv.ini, "Preview", "UnicodeFont", Cv.fontU)
        a := IniRead(Cv.ini, "Preview", "AnsiSize", Cv.sizeA)
        u := IniRead(Cv.ini, "Preview", "UnicodeSize", Cv.sizeU)
        if IsInteger(a)
            Cv.sizeA := Min(72, Max(6, Integer(a)))
        if IsInteger(u)
            Cv.sizeU := Min(72, Max(6, Integer(u)))
        l := IniRead(Cv.ini, "View", "Layout", Cv.layout)
        if (l = "H" || l = "V" || l = "T")
            Cv.layout := StrUpper(l)
        th := StrUpper(IniRead(Cv.ini, "View", "Theme", Cv.theme))
        if (th = "S" || th = "L" || th = "D")
            Cv.theme := th
        sh := IniRead(Cv.ini, "View", "SplitH", 50)
        sv := IniRead(Cv.ini, "View", "SplitV", 50)
        if IsNumber(sh)
            Cv.ratioH := Min(90, Max(10, Number(sh))) / 100
        if IsNumber(sv)
            Cv.ratioV := Min(90, Max(10, Number(sv))) / 100
    }
}

; Settings are kept in %APPDATA%\Bangla Keyboard\Text Converter.dat
CvSaveSettings() {
    try {
        DirCreate(A_AppData . "\Bangla Keyboard")
        IniWrite(Cv.fontA, Cv.ini, "Preview", "AnsiFont")
        IniWrite(Cv.sizeA, Cv.ini, "Preview", "AnsiSize")
        IniWrite(Cv.fontU, Cv.ini, "Preview", "UnicodeFont")
        IniWrite(Cv.sizeU, Cv.ini, "Preview", "UnicodeSize")
        IniWrite(Cv.layout, Cv.ini, "View", "Layout")
        IniWrite(Cv.theme, Cv.ini, "View", "Theme")
        IniWrite(Round(Cv.ratioH * 100), Cv.ini, "View", "SplitH")
        IniWrite(Round(Cv.ratioV * 100), Cv.ini, "View", "SplitV")
    }
}

CvApplyFonts() {
    Cv.ansi.SetFont("s" . Cv.sizeA . " c" . Cv.efg, Cv.fontA)
    Cv.uni.SetFont("s" . Cv.sizeU . " c" . Cv.efg, Cv.fontU)
    CvRefreshEdit(Cv.ansi)
    CvRefreshEdit(Cv.uni)
}

; SetFont alone leaves an edit box showing the old font until its text changes.
; Hand the font to the box again with the "redraw" flag set, then repaint it.
CvRefreshEdit(ctl) {
    hf := SendMessage(0x31, 0, 0, ctl.Hwnd)               ; WM_GETFONT
    SendMessage(0x30, hf, 1, ctl.Hwnd)                    ; WM_SETFONT, redraw = TRUE
    DllCall("RedrawWindow", "Ptr", ctl.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x505)   ; invalidate + erase + frame + update now
}

; Installed font names, read from the registry (a Map enumerates in sorted order).
CvFontNames() {
    names := Map()
    names.CaseSense := "Off"
    for root in ["HKLM", "HKCU"] {
        try {
            Loop Reg root . "\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts", "V" {
                n := RegExReplace(A_LoopRegName, "\s*\([^)]*\)\s*$")
                for part in StrSplit(n, " & ") {
                    part := Trim(part)
                    if (part = "" || RegExMatch(part, "i)\s(Bold|Italic|Oblique)$"))
                        continue
                    names[part] := 1
                }
            }
        }
    }
    names[Cv.fontA] := 1
    names[Cv.fontU] := 1
    list := []
    for k in names {
        list.Push(k)
    }
    return list
}

CvSettings(*) {
    if (Cv.sg != "") {
        return
    }
    fonts := Cv.fonts
    sg := Gui("+Owner" . Cv.gui.Hwnd, "Settings")
    Cv.sg := sg
    dk := Cv.dark
    sg.SetFont("s9 c" . Cv.fg, "Segoe UI")
    sg.BackColor := Cv.bg
    CvTitleBar(sg.Hwnd, dk)
    rOpt := dk ? " -Theme" : ""          ; unthemed radio buttons can show light text

    sg.Add("Text", "x12 y14 w340", "Unicode preview font")
    cbU := sg.Add("ComboBox", "x12 y34 w230 R12", fonts)
    cbU.Text := Cv.fontU
    sg.Add("Text", "x254 y37 w30", "Size")
    cbS := sg.Add("ComboBox", "x288 y34 w54 R12", Cv.sizes)
    cbS.Text := Cv.sizeU

    sg.Add("Text", "x12 y74 w340", "View (how the two boxes are split)")
    r1 := sg.Add("Radio", "x24 y96 w320" . rOpt, "Horizontal - Unicode on top, ANSI below")
    r2 := sg.Add("Radio", "x24 y118 w320" . rOpt, "Vertical - Unicode left, ANSI right")
    r3 := sg.Add("Radio", "x24 y140 w320" . rOpt, "Tabs - one tab for Unicode, one for ANSI")
    if (Cv.layout = "V")
        r2.Value := 1
    else if (Cv.layout = "T")
        r3.Value := 1
    else
        r1.Value := 1

    sg.Add("Text", "x12 y174 w340", "Theme")
    t1 := sg.Add("Radio", "x24 y196 w90 Group" . rOpt, "System")
    t2 := sg.Add("Radio", "x120 y196 w90" . rOpt, "Light")
    t3 := sg.Add("Radio", "x206 y196 w90" . rOpt, "Dark")
    if (Cv.theme = "L")
        t2.Value := 1
    else if (Cv.theme = "D")
        t3.Value := 1
    else
        t1.Value := 1

    okBtn := sg.Add("Button", "x180 y238 w80 h28 Default", "OK")
    caBtn := sg.Add("Button", "x266 y238 w80 h28", "Cancel")
    CvComboColors(cbU, dk)
    CvComboColors(cbS, dk)
    CvCtlTheme(okBtn, "btn", dk)
    CvCtlTheme(caBtn, "btn", dk)

    Done(*) {
        Cv.gui.Opt("-Disabled")
        sg.Destroy()
        Cv.sg := ""
        Cv.gui.Show()
    }
    Ok(*) {
        fu := Trim(cbU.Text)
        if (fu != "")
            Cv.fontU := fu
        sv := Trim(cbS.Text)
        if IsInteger(sv)
            Cv.sizeU := Min(72, Max(6, Integer(sv)))
        newL := r2.Value ? "V" : (r3.Value ? "T" : "H")
        layoutChanged := (newL != Cv.layout)
        Cv.layout := newL
        newT := t2.Value ? "L" : (t3.Value ? "D" : "S")
        themeChanged := (newT != Cv.theme)
        Cv.theme := newT
        CvApplyFonts()
        CvSaveSettings()
        Done()
        if themeChanged
            CvApplyTheme()
        if layoutChanged
            CvApplyLayout()
    }
    okBtn.OnEvent("Click", Ok)
    caBtn.OnEvent("Click", Done)
    sg.OnEvent("Close", Done)
    sg.OnEvent("Escape", Done)

    Cv.gui.Opt("+Disabled")
    sg.Show("w360 h280")
}

; ---------------------------------------------------------------------------
;  Right-click menu for the two boxes: only the basic edit commands.
;  (Replaces the Windows menu with its reading-order / Unicode-control / IME items.)
; ---------------------------------------------------------------------------
CvEditMenu(wParam, lParam, *) {
    if (wParam != Cv.uni.Hwnd && wParam != Cv.ansi.Hwnd)
        return
    ctl := (wParam = Cv.uni.Hwnd) ? Cv.uni : Cv.ansi
    ctl.Focus()
    s := Buffer(4, 0)
    e := Buffer(4, 0)
    SendMessage(0xB0, s.Ptr, e.Ptr, ctl.Hwnd)           ; EM_GETSEL
    hasSel := NumGet(e, 0, "UInt") > NumGet(s, 0, "UInt")
    hasText := StrLen(ctl.Value) > 0
    canUndo := SendMessage(0xC6, 0, 0, ctl.Hwnd)        ; EM_CANUNDO
    canPaste := DllCall("IsClipboardFormatAvailable", "UInt", 13)

    m := Menu()
    m.Add("Undo", (*) => SendMessage(0xC7, 0, 0, ctl.Hwnd))
    m.Add()
    m.Add("Cut", (*) => SendMessage(0x300, 0, 0, ctl.Hwnd))
    m.Add("Copy", (*) => SendMessage(0x301, 0, 0, ctl.Hwnd))
    m.Add("Paste", (*) => SendMessage(0x302, 0, 0, ctl.Hwnd))
    m.Add("Delete", (*) => SendMessage(0x303, 0, 0, ctl.Hwnd))
    m.Add()
    m.Add("Select All", (*) => SendMessage(0xB1, 0, -1, ctl.Hwnd))
    if !canUndo
        m.Disable("Undo")
    if !hasSel {
        m.Disable("Cut")
        m.Disable("Copy")
        m.Disable("Delete")
    }
    if !canPaste
        m.Disable("Paste")
    if !hasText
        m.Disable("Select All")
    if ((lParam & 0xFFFFFFFF) = 0xFFFFFFFF) {           ; opened from the keyboard
        ctl.GetPos(&cx, &cy)
        m.Show(cx + 10, cy + 10)
    } else {
        m.Show()
    }
    return 0
}

; A text box handles WM_CONTEXTMENU itself, so the parent window never sees it.
; Subclass the two boxes to catch it and show our own menu instead of the Windows one.
CvSubclass(ctl) {
    if !Cv.subCb
        Cv.subCb := CallbackCreate(CvSubProc, , 6)
    DllCall("comctl32\SetWindowSubclass", "Ptr", ctl.Hwnd, "Ptr", Cv.subCb, "UPtr", 1, "UPtr", 0)
}

CvSubProc(hWnd, uMsg, wParam, lParam, uIdSubclass, dwRefData) {
    if (uMsg = 0x7B) {                                   ; WM_CONTEXTMENU
        SetTimer(CvEditMenu.Bind(hWnd, lParam), -1)
        return 0
    }
    return DllCall("comctl32\DefSubclassProc", "Ptr", hWnd, "UInt", uMsg, "UPtr", wParam, "Ptr", lParam, "Ptr")
}

; Mapping files in Encodings: *.txt and *.een. If both exist under the same name,
; the .txt is used.
CvFindMaps() {
    list := []
    seen := Map()
    seen.CaseSense := "Off"
    for ext in ["txt", "een"] {
        Loop Files, A_ScriptDir . "\Encodings\*." . ext {
            SplitPath(A_LoopFileFullPath, , , &e, &nm)
            if (StrLower(e) != ext || seen.Has(nm))     ; the pattern can also match longer extensions
                continue
            seen[nm] := 1
            list.Push(A_LoopFileFullPath)
        }
    }
    return list
}

CvStart() {
    Cv.files := CvFindMaps()
    if (Cv.files.Length = 0) {
        MsgBox("No mapping file found.`nPut a mapping file (.txt or .een) in the Encodings folder.", "Bangla Text Converter", 0x10)
        ExitApp()
    }
    names := []
    for f in Cv.files {
        SplitPath(f, , , , &nm)
        names.Push(nm)
    }
    try {
        LoadMapping(Cv.files[1])
    } catch as e {
        MsgBox("Could not read the mapping file:`n" . Cv.files[1] . "`n`n" . e.Message, "Bangla Text Converter", 0x10)
        ExitApp()
    }
    CvLoadSettings()
    Cv.fonts := CvFontNames()

    g := Gui("+Resize +MinSize760x440 +0x2000000", "Bangla Text Converter")   ; 0x2000000 = clip children (less flicker)
    Cv.gui := g
    g.SetFont("s9", "Segoe UI")

    ; toolbar (positions are set in CvSize)
    Cv.b1 := g.Add("Button", "x12 y12 w104 h24", "To ANSI")
    Cv.dd := g.Add("DropDownList", "x124 y12 w170", names)
    Cv.b2 := g.Add("Button", "x302 y12 w104 h24", "To Unicode")
    Cv.dd.Choose(1)
    Cv.fd := g.Add("ComboBox", "x414 y12 w140 R15", Cv.fonts)
    Cv.fd.Text := Cv.fontA
    Cv.sz := g.Add("ComboBox", "x560 y12 w52 R15", Cv.sizes)
    Cv.sz.Text := Cv.sizeA
    Cv.b3 := g.Add("Button", "x618 y12 w88 h24", "Clear both")
    Cv.b4 := g.Add("Button", "x710 y12 w88 h24", "Settings")
    Cv.b1.OnEvent("Click", CvToAnsi)
    Cv.b2.OnEvent("Click", CvToUnicode)
    Cv.dd.OnEvent("Change", CvMappingChanged)
    Cv.b3.OnEvent("Click", CvClear)
    Cv.b4.OnEvent("Click", CvSettings)
    Cv.fd.OnEvent("Change", CvToolFont)
    Cv.fd.OnEvent("LoseFocus", CvToolFontDone)
    Cv.sz.OnEvent("Change", CvToolSize)

    ; tab strip (only shown in the tab view; sized in CvSize)
    Cv.tab := g.Add("Tab3", "x12 y50 w300 h28 +0x400 +0x2000", Cv.tabNames)      ; 0x400 = fixed-width tabs, 0x2000 = we draw the tab headers (for dark mode)
    Cv.tab.OnEvent("Change", CvTabChanged)
    Cv.tab.UseTab()          ; controls added after this are NOT children of the tab

    ; Unicode and ANSI boxes (placed according to the chosen layout in CvSize)
    Cv.uni := g.Add("Edit", "x12 y50 w300 h200 Multi +VScroll Limit1000000")
    Cv.ansi := g.Add("Edit", "x12 y262 w300 h200 Multi +VScroll Limit1000000")
    Cv.sb := g.Add("Text", "x0 y430 w700 h22 +0x200", "")      ; 0x200 = centre text vertically
    CvApplyTheme()
    CvApplyLayout()

    CvSubclass(Cv.uni)
    CvSubclass(Cv.ansi)
    g.OnEvent("Size", CvSize)
    OnMessage(0x2B, CvWmDrawItem)        ; WM_DRAWITEM (tab headers)
    OnMessage(0x1A, CvWmSettingChange)   ; WM_SETTINGCHANGE (Windows theme switch)
    OnMessage(0x20, CvWmSetCursor)       ; WM_SETCURSOR
    OnMessage(0x201, CvWmLButtonDown)    ; WM_LBUTTONDOWN
    OnMessage(0x200, CvWmMouseMove)      ; WM_MOUSEMOVE
    OnMessage(0x202, CvWmLButtonUp)      ; WM_LBUTTONUP
    g.OnEvent("Close", (*) => ExitApp())
    g.Show("w780 h520")
}

CvStart()
