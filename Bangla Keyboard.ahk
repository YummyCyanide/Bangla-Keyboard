; ===========================================================================
;  Bangla Keyboard  -  small, fast Bijoy-style typing tool for Windows
;  Needs AutoHotkey v2 (portable exe is fine). Layouts live in the Layouts folder.
; ===========================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreadsBuffer True
Persistent()
SetWorkingDir A_ScriptDir
CoordMode "Mouse", "Screen"
CoordMode "Menu", "Screen"
A_MaxHotkeysPerInterval := 2000
KeyHistory(0)
ProcessSetPriority "AboveNormal"

; ---------------------------------------------------------------------------
;  Layout: reads one of the layout files (.bkl or .xml - both hold XML, the same format as Bijoy Bayanno;
;  a .bkl is the locked (scrambled) form made with Tools\Pupo Encrypter.ahk)
; ---------------------------------------------------------------------------
; .bkl = a layout (XML) file scrambled byte by byte. Layout: "BKL" + 0x01 + the text length (4 bytes), then each byte is
; (plain XOR key[i]) + (i*31+17), all modulo 256. It only stops the file being read or changed by accident; it is not
; real encryption. Keep the key the same as in Tools\Pupo Encrypter.ahk.
BklDecode(buf) {
    static key := "BanglaLayoutKey"
    if (buf.Size < 8 || NumGet(buf, 0, "UChar") != 0x42 || NumGet(buf, 1, "UChar") != 0x4B
        || NumGet(buf, 2, "UChar") != 0x4C || NumGet(buf, 3, "UChar") != 1)
        throw Error("This is not a valid .bkl layout file.")
    n := NumGet(buf, 4, "UInt")
    if (n > buf.Size - 8)
        throw Error("This .bkl layout file is damaged (it ends too early).")
    if (n = 0)
        return ""
    out := Buffer(n, 0)
    kl := StrLen(key)
    Loop n {
        i := A_Index - 1
        e := NumGet(buf, 8 + i, "UChar")
        NumPut("UChar", ((e - (i * 31 + 17)) & 0xFF) ^ Ord(SubStr(key, Mod(i, kl) + 1, 1)), out, i)
    }
    return StrGet(out, n, "UTF-8")
}

class Layout {
    name := ""
    hotkey := ""
    icon := ""        ; <IconName> in the layout file -> Icons\<IconName>.png (first choice) or .ico
    nor := Map()      ; vk -> text without Shift
    sh := Map()       ; vk -> text with Shift
    optN := Map()     ; vk -> option name (Delay, DeInc1, DeInc2, MoveL, Xtra)
    optS := Map()
    juks := Map()     ; joining rules: typed sequence -> replacement
    maxSeq := 1

    static Unesc(s) {
        while RegExMatch(s, "&#(\d+);", &m)
            s := StrReplace(s, m[0], Chr(Integer(m[1])))
        while RegExMatch(s, "i)&#x([0-9a-f]+);", &m)
            s := StrReplace(s, m[0], Chr(Integer("0x" m[1])))
        s := StrReplace(s, "&lt;", "<")
        s := StrReplace(s, "&gt;", ">")
        s := StrReplace(s, "&quot;", '"')
        s := StrReplace(s, "&apos;", "'")
        return StrReplace(s, "&amp;", "&")
    }

    static Load(path) {
        SplitPath(path, , , &fext)
        txt := (StrLower(fext) = "bkl") ? BklDecode(FileRead(path, "RAW")) : FileRead(path, "UTF-8")
        L := Layout()
        if RegExMatch(txt, "s)<Name>(.*?)</Name>", &m) {
            L.name := Layout.Unesc(m[1])
        } else {
            SplitPath(path, , , , &nm)
            L.name := nm
        }
        if RegExMatch(txt, "s)<IconName>(.*?)</IconName>", &m)
            L.icon := Trim(Layout.Unesc(m[1]))
        if RegExMatch(txt, "s)<Shortcut>(.*?)</Shortcut>", &m) {
            sc := m[1]
            mods := ""
            if InStr(sc, "<Ctrl>True")
                mods .= "^"
            if InStr(sc, "<Alt>True")
                mods .= "!"
            if InStr(sc, "<Shift>True")
                mods .= "+"
            if RegExMatch(sc, "<KeyCode>(\d+)</KeyCode>", &k)
                L.hotkey := mods . Format("vk{:X}", Integer(k[1]))
        }
        keyRe := 's)<Key KeyCode="(\d+)"([^>]*)>\s*<Normal>(.*?)</Normal>\s*<Shift>(.*?)</Shift>\s*</Key>'
        pos := 1
        while (pos := RegExMatch(txt, keyRe, &m, pos)) {
            pos += m.Len[0]
            vk := Integer(m[1])
            L.nor[vk] := Layout.Unesc(m[3])
            L.sh[vk] := Layout.Unesc(m[4])
            if RegExMatch(m[2], 'Normal_Option="([^"]*)"', &o)
                L.optN[vk] := o[1]
            if RegExMatch(m[2], 'Shift_Option="([^"]*)"', &o)
                L.optS[vk] := o[1]
        }
        jukRe := 's)<Juk>\s*<Seq>(.*?)</Seq>\s*<Out>(.*?)</Out>\s*</Juk>'
        pos := 1
        while (pos := RegExMatch(txt, jukRe, &m, pos)) {
            pos += m.Len[0]
            seq := Layout.Unesc(m[1])
            out := Layout.Unesc(m[2])
            ; some outputs carry a stray leading space that the sequence does not have
            if (SubStr(out, 1, 1) == " " && SubStr(seq, 1, 1) != " ")
                out := LTrim(out, " ")
            L.juks[seq] := out
            if (StrLen(seq) > L.maxSeq)
                L.maxSeq := StrLen(seq)
        }
        return L
    }
}

; ---------------------------------------------------------------------------
;  Engine: turns one key press into "backspaces + text to type"
; ---------------------------------------------------------------------------
class Engine {
    static HAS := Chr(0x09CD)
    static ZWNJ := Chr(0x200C)
    static ZWJ := Chr(0x200D)
    static MAXBUF := 24

    buf := ""       ; what we typed recently (so joining rules can look back)
    vowel := ""     ; a vowel sign (i, e, ai) still waiting to follow its consonant
    mode := ""      ; "lead" = typed before its consonant, "tail" = already after it

    __New(lay) {
        this.lay := lay
    }

    Reset() {
        this.buf := ""
        this.vowel := ""
        this.mode := ""
    }

    Track(ch) {
        b := this.buf . ch
        if (StrLen(b) > Engine.MAXBUF)
            b := SubStr(b, -Engine.MAXBUF)
        this.buf := b
        this.vowel := ""
        this.mode := ""
    }

    static IsCons(ch) {
        o := Ord(ch)
        return (o >= 0x0995 && o <= 0x09B9) || o = 0x09CE || o = 0x09DC || o = 0x09DD || o = 0x09DF
    }

    static IsSign(ch) {
        o := Ord(ch)
        return (o >= 0x09BE && o <= 0x09C4) || o = 0x09C7 || o = 0x09C8 || o = 0x09CB || o = 0x09CC
            || o = 0x09D7 || o = 0x0981 || o = 0x0982 || o = 0x0983 || o = 0x09BC
    }

    ; 1-based index where the last consonant cluster starts (0 = none). Used for ref (র্).
    static ClusterStart(s) {
        i := StrLen(s)
        while (i >= 1 && Engine.IsSign(SubStr(s, i, 1)))
            i--
        if (i < 1 || !Engine.IsCons(SubStr(s, i, 1)))
            return 0
        Loop {
            if (i < 3 || SubStr(s, i - 1, 1) != Engine.HAS)
                break
            j := i - 2
            c := SubStr(s, j, 1)
            if (c == Engine.ZWNJ || c == Engine.ZWJ) {
                j--
                if (j < 1)
                    break
                c := SubStr(s, j, 1)
            }
            if !Engine.IsCons(c)
                break
            i := j
        }
        return i
    }

    ; Returns [backspaces, text] or false when this layout has nothing for the key.
    Press(vk, shifted) {
        lay := this.lay
        if shifted {
            if !lay.sh.Has(vk)
                return false
            out := lay.sh[vk]
            opt := lay.optS.Get(vk, "")
        } else {
            if !lay.nor.Has(vk)
                return false
            out := lay.nor[vk]
            opt := lay.optN.Get(vk, "")
        }
        old := this.buf
        vw := this.vowel
        md := this.mode
        hasTail := (vw != "" && md != "" && SubStr(old, -StrLen(vw)) == vw)
        base := hasTail ? SubStr(old, 1, StrLen(old) - StrLen(vw)) : old
        nw := old . out
        nvw := ""
        nmd := ""
        reorder := false

        if (opt = "Delay") {
            ; vowel typed before its consonant (Bijoy style): show it now, move it later
            nvw := out
            nmd := "lead"
        } else if (opt = "DeInc1" || opt = "DeInc2") {
            ; hasanta / ra-phala / ya-phala: goes before a waiting vowel sign
            o2 := out
            if (opt = "DeInc1" && out == (Engine.HAS . Chr(0x09AF)) && SubStr(base, -1) == Chr(0x09B0))
                o2 := Engine.ZWNJ . out
            if hasTail {
                nw := base . o2 . vw
                nvw := vw
                nmd := "tail"
                reorder := (md = "tail")
            } else {
                nw := old . o2
            }
        } else if (opt = "MoveL") {
            ; ref (র্) is typed after the letter but belongs before the whole cluster
            st := Engine.ClusterStart(old)
            if st
                nw := SubStr(old, 1, st - 1) . out . SubStr(old, st)
            else
                nw := old . out
        } else if (StrLen(out) = 1 && Engine.IsCons(out)) {
            if (hasTail && (md = "lead" || (md = "tail" && SubStr(base, -1) == Engine.HAS))) {
                nw := base . out . vw
                nvw := vw
                nmd := "tail"
                reorder := true
            }
        }

        ; joining rules: longest typed sequence at the end wins
        changed := false
        if !reorder {
            L := Min(lay.maxSeq, StrLen(nw))
            while (L >= 1) {
                s := SubStr(nw, -L)
                if lay.juks.Has(s) {
                    r := lay.juks[s]
                    if !(r == s) {
                        nw := SubStr(nw, 1, StrLen(nw) - L) . r
                        changed := true
                    }
                    break
                }
                L--
            }
        }
        if changed {
            nvw := ""
            nmd := ""
        }

        ; what must change on screen: delete the differing tail, type the rest
        n := Min(StrLen(old), StrLen(nw))
        lcp := 0
        while (lcp < n && Ord(SubStr(old, lcp + 1, 1)) = Ord(SubStr(nw, lcp + 1, 1)))
            lcp++
        bs := StrLen(old) - lcp
        txt := SubStr(nw, lcp + 1)
        if (StrLen(nw) > Engine.MAXBUF)
            nw := SubStr(nw, -Engine.MAXBUF)
        this.buf := nw
        this.vowel := nvw
        this.mode := nmd
        return [bs, txt]
    }
}

; Types the result of Engine.Press (works in any program, no clipboard)
SendOut(bs, txt) {
    s := ""
    if (bs > 0)
        s := "{BS " bs "}"
    Loop Parse txt
        s .= "{U+" . Format("{:04X}", Ord(A_LoopField)) . "}"
    if (s != "")
        Send(s)
}

; ---------------------------------------------------------------------------
;  App state, settings, layout switching, hotkeys, tray
; ---------------------------------------------------------------------------
class App {
    static dir := A_ScriptDir                                  ; program files (read-only is fine)
    static dataDir := A_AppData "\Bangla Keyboard"             ; settings live here (always writable; shared with the tools in the Tools folder)
    static ini := A_AppData "\Bangla Keyboard\Bangla Keyboard.dat"
    static layouts := []
    static cur := 0              ; 0 = English, otherwise index into layouts
    static lastBn := 1           ; Bangla layout used by the English <-> Bangla toggle
    static eng := ""
    static bar := ""
    static pic := ""
    static nameCtl := ""
    static dlg := ""
    static dlgSt := ""            ; the state object of the Settings window while it is open (used by its scroll bar)
    static scrollHooked := false
    static about := ""           ; the About window while it is open
    static version := "2.0.3"
    static onTop := true
    static theme := "DarkGreen"
    static style := "GreenBangla"  ; bar style: Classic | ClassicExt | AeroDark | PurpleRaised | GreenBangla | EkusheDark | EkusheBN | BanglaKb
    static rebuilding := false     ; true while the bar is being destroyed and built again (UpdateBar must not touch it then)
    static rebuildAgain := false   ; a rebuild was asked for while one was running: it is done once more afterwards
    static ext := []               ; the two extra bar buttons of the "Ext" styles: {on: shown on the bar (button 1 is always on), act: file in Tools, icon: icon name}
    static picSz := 20
    static iconSize := 1           ; position in IconSizes() of the icon size on the bar (1 = Original, 20 px)
    static barX := ""
    static barY := ""
    static tipShown := false
    static typingNames := []
    static typingOn := false
    static msgHooked := false
    static hov := []             ; bar buttons that light up under the mouse: {ctl, hwnds, norm, hov, pw, ph, top}
    static hovCur := 0           ; the one that is lit now (0 = none)
    static hovTimer := false     ; true while the hover check runs (only while the mouse is over the bar)
    static shortcuts := Map()    ; action id -> hotkey text ("" = no shortcut)
    static shown := Map()        ; action id -> true/false: is this item listed in the application (menus) and its shortcut active?
    static regNames := []        ; shortcut hotkeys that are currently registered
    static perWin := false       ; false = Global (one mode for all windows), true = each window keeps its own mode
    static winModes := Map()     ; window handle -> layout index (0 = English), used when perWin is true
    static curWin := 0           ; the window whose mode is showing now (last normal window that was active)
    static fgHook := 0
    static trayHooked := false
    static trayDbl := false
    static startMin := false     ; start with the bar minimized to the tray
    static trayAlways := true    ; keep the tray icon visible all the time (false = only while the bar is minimized)
    static confirmClose := true  ; ask "Yes / No" before the bar's close button exits the program
    static splashOn := true      ; show the splash screen when the program starts
    static splashMs := 2000      ; how long it stays (milliseconds)
    static splash := ""          ; the splash window while it is visible
    static tips := true          ; show a hint when the mouse rests on an option in Settings
    static menuPrev := 0         ; window that was active before the bar's layout menu opened
    static fontOn := false       ; Fonts tab: change the font automatically in Office apps
    static fonts := Map()        ; layout name (or "English") -> {on, font, size, keep}
    static fontDirty := false    ; the cursor probably moved: check the font before the next key
    static lastKey := 0          ; tick of the last typed key
    static fontCom := Map()      ; COM connections to Word / Excel / PowerPoint (dropped when you leave those apps)
    static globMode := 0         ; mode used by all non-Office windows when Mode switching is "Global"
    static userFont := Map()     ; "window|layout" -> the font you last used for that layout in that window
    static ansiSeen := Map()     ; fonts you used while an ANSI layout was active (so English can move away from them)
    static manualOn := false     ; Fonts tab: manual font shortcuts (work with or without the automatic font change)
    static slots := []           ; manual font slots: {key, font, size}
    static manualHold := 0       ; window whose font was just set by hand: the automatic change leaves it alone until the layout / window changes
}

; ---- colour themes for the bar ---------------------------------------------
;  bg = bar background, fld/ftx = layout box + its text, arr = arrow,
;  stb/mnb/clb = settings / minimize / close buttons, btx = button text
ThemeNames() {
    return ["Navy", "Blue", "Sky", "Cyan", "Teal", "Green", "DarkGreen", "Lime", "Yellow", "Orange", "Red", "Maroon", "Brown", "Pink", "Purple", "Indigo", "Slate", "Gray", "Light", "Dark", "Charcoal", "Midnight", "Black"]
}

Themes() {
    static t := ""
    if IsObject(t)
        return t
    t := Map()
    t["Navy"]      := {bg: "1B2238", fld: "FFF3E0", ftx: "1B2238", arr: "55607A", stb: "3F6FB5", mnb: "5B6B85", clb: "C0392B", btx: "FFFFFF"}
    t["Blue"]      := {bg: "1E5AA8", fld: "E8F1FF", ftx: "0F2E57", arr: "3C6AA8", stb: "143F75", mnb: "3E78C2", clb: "D64545", btx: "FFFFFF"}
    t["Green"]     := {bg: "2E8B57", fld: "EAF8EF", ftx: "14452B", arr: "3F8F63", stb: "1F6B41", mnb: "4FA574", clb: "D64545", btx: "FFFFFF"}
    t["DarkGreen"] := {bg: "12301F", fld: "D9EFE0", ftx: "0E2A1A", arr: "3F7A58", stb: "1F6B41", mnb: "2D5A41", clb: "B03A2E", btx: "FFFFFF"}
    t["Purple"]    := {bg: "5B3A9A", fld: "F1EAFB", ftx: "2D1B52", arr: "6B4FA3", stb: "7A4FC2", mnb: "7860A8", clb: "D64545", btx: "FFFFFF"}
    t["Dark"]      := {bg: "1E1E1E", fld: "2D2D30", ftx: "E6E6E6", arr: "9A9A9A", stb: "3B3B3F", mnb: "3B3B3F", clb: "B03A2E", btx: "FFFFFF"}
    t["Light"]     := {bg: "F0F0F0", fld: "FFFFFF", ftx: "202020", arr: "666666", stb: "D9E6F7", mnb: "E1E1E1", clb: "F2C2C2", btx: "202020"}
    t["Teal"]      := {bg: "0F766E", fld: "E6FFFB", ftx: "073B37", arr: "2A8F87", stb: "0B5A54", mnb: "2F918A", clb: "D64545", btx: "FFFFFF"}
    t["Red"]       := {bg: "9B2226", fld: "FDECEC", ftx: "4A1013", arr: "9B4B4E", stb: "7A1A1D", mnb: "B24A4E", clb: "3D0E10", btx: "FFFFFF"}
    t["Orange"]    := {bg: "D9731A", fld: "FFF3E6", ftx: "5A2D05", arr: "A8641E", stb: "A85A12", mnb: "C98641", clb: "8E2A1F", btx: "FFFFFF"}
    t["Pink"]      := {bg: "C2417C", fld: "FFEAF3", ftx: "5C1636", arr: "9C4A72", stb: "9C2F62", mnb: "D06A9B", clb: "8E2A1F", btx: "FFFFFF"}
    t["Slate"]     := {bg: "4A5560", fld: "ECEFF2", ftx: "232A31", arr: "5E6B78", stb: "36404A", mnb: "6A7782", clb: "B03A2E", btx: "FFFFFF"}
    t["Sky"]       := {bg: "3AA0E0", fld: "EAF6FF", ftx: "0B3A5C", arr: "3C86B8", stb: "1F78B4", mnb: "5CB3E8", clb: "D64545", btx: "FFFFFF"}
    t["Cyan"]      := {bg: "0891A5", fld: "E3FAFD", ftx: "053B44", arr: "2A8A99", stb: "06707F", mnb: "2AA3B5", clb: "D64545", btx: "FFFFFF"}
    t["Lime"]      := {bg: "7CB518", fld: "F4FBE3", ftx: "2A3F05", arr: "5C8A12", stb: "5A8A0F", mnb: "91C23A", clb: "C0392B", btx: "FFFFFF"}
    t["Yellow"]    := {bg: "F2C230", fld: "FFFBE6", ftx: "4A3A00", arr: "9A7B10", stb: "8A6A00", mnb: "A67F00", clb: "B03A2E", btx: "FFFFFF"}
    t["Maroon"]    := {bg: "6B1B2E", fld: "FBE9EE", ftx: "3A0D18", arr: "9C5565", stb: "4D1220", mnb: "8A3A4C", clb: "2E0A12", btx: "FFFFFF"}
    t["Brown"]     := {bg: "5D4037", fld: "F3E9E4", ftx: "2E1D17", arr: "8D6E63", stb: "3E2723", mnb: "7A5A4F", clb: "C0392B", btx: "FFFFFF"}
    t["Indigo"]    := {bg: "3F3D9E", fld: "ECEBFF", ftx: "1F1E5A", arr: "5A58B8", stb: "2E2C7A", mnb: "5B59B5", clb: "D64545", btx: "FFFFFF"}
    t["Gray"]      := {bg: "8A8F98", fld: "F2F3F5", ftx: "22262B", arr: "5F656E", stb: "5A606A", mnb: "6F757F", clb: "B03A2E", btx: "FFFFFF"}
    t["Charcoal"]  := {bg: "2B2F36", fld: "3A3F47", ftx: "ECECEC", arr: "A0A6AF", stb: "4A505A", mnb: "4A505A", clb: "B03A2E", btx: "FFFFFF"}
    t["Midnight"]  := {bg: "0B1530", fld: "1B2A4F", ftx: "DCE6FF", arr: "7F93C4", stb: "2F4C93", mnb: "26396B", clb: "B03A2E", btx: "FFFFFF"}
    t["Black"]     := {bg: "000000", fld: "1A1A1A", ftx: "F2F2F2", arr: "8A8A8A", stb: "2B2B2B", mnb: "2B2B2B", clb: "B03A2E", btx: "FFFFFF"}
    return t
}

; Settings are kept in %AppData%\Bangla Keyboard\Bangla Keyboard.dat so the program also works when
; installed in Program Files. Earlier builds used other names or places (bangla_keyboard_config.ini, the
; BanglaKeyboard folder, Settings.ini): the first one found is carried over once.
PrepareDataDir() {
    try DirCreate(App.dataDir)
    if FileExist(App.ini)
        return
    oldDir := A_AppData "\BanglaKeyboard"                         ; folder name of the first builds (no space)
    for prev in [App.dataDir "\bangla_keyboard_config.ini", App.dataDir "\bkb_cfg.dat", oldDir "\bangla_keyboard_config.ini"
        , oldDir "\Settings.ini", App.dataDir "\Settings.ini"] {
        if FileExist(prev) {
            try FileMove(prev, App.ini)
            if FileExist(App.ini) {
                try DirDelete(oldDir)                              ; only succeeds when the old folder is empty
                return
            }
        }
    }
    old := A_ScriptDir "\Settings.ini"
    if FileExist(old)
        try FileCopy(old, App.ini)
}

LoadSettings() {
    App.onTop := (IniRead(App.ini, "General", "AlwaysOnTop", "1") = "1")
    App.theme := IniRead(App.ini, "General", "Theme", "DarkGreen")
    if !Themes().Has(App.theme)
        App.theme := "DarkGreen"
    App.style := IniRead(App.ini, "General", "BarStyle", "GreenBangla")
    if (StyleIds()[StyleIndex(App.style)] != App.style)
        App.style := "GreenBangla"
    n := IniRead(App.ini, "General", "IconPx", "20")        ; saved as the size in pixels
    App.iconSize := 1
    for k, v in IconSizes() {
        if (v = n)
            App.iconSize := k
    }
    App.barX := IniRead(App.ini, "Bar", "X", "")
    App.barY := IniRead(App.ini, "Bar", "Y", "")
    App.perWin := (IniRead(App.ini, "General", "ModeSwitching", "Global") = "PerWindow")
    App.splashOn := (IniRead(App.ini, "General", "ShowSplash", "1") = "1")
    App.startMin := (IniRead(App.ini, "General", "StartMinimized", "0") = "1")
    App.trayAlways := (IniRead(App.ini, "General", "TrayAlways", "1") = "1")
    App.confirmClose := (IniRead(App.ini, "General", "ConfirmClose", "1") = "1")
    App.tips := (IniRead(App.ini, "General", "ShowTips", "1") = "1")
    secs := IniRead(App.ini, "General", "SplashSeconds", "2")
    App.splashMs := (IsNumber(secs) && secs >= 1 && secs <= 5) ? Round(secs) * 1000 : 2000      ; 1 - 5 seconds
}

; the two extra buttons of the "Default Ext" / "Ekushey BN" bar styles (each one has its own tick box in Settings)
LoadExtButtons() {
    App.ext := []
    Loop 2                                                         ; button 1 is always on, button 2 only when ticked (off by default)
        App.ext.Push({on: (A_Index = 1) ? true : (IniRead(App.ini, "ExtButtons", "Button" . A_Index . ".Enabled", "0") = "1")
            , act: IniRead(App.ini, "ExtButtons", "Button" . A_Index . ".Action", "")
            , icon: IniRead(App.ini, "ExtButtons", "Button" . A_Index . ".Icon", "App icon")})
}

; the numbers of the extra buttons shown on the bar: [1] or [1, 2]
ExtShown() {
    a := []
    for i, b in App.ext {
        if b.on
            a.Push(i)
    }
    return a
}

SaveSetting(section, key, value) {
    try IniWrite(value, App.ini, section, key)
}

; A layout file is XML. It may be a plain .xml, or a locked .bkl (made with Tools\Pupo Encrypter.ahk; same content, scrambled).
; Both are read. If both exist with the same name, the .bkl one is used (the .xml is listed first, so the .bkl replaces it).
LoadLayouts() {
    App.layouts := []
    found := Map()
    for ext in ["xml", "bkl"] {
        Loop Files A_ScriptDir "\Layouts\*." . ext {
            if (StrLower(A_LoopFileExt) != ext)
                continue
            SplitPath(A_LoopFileFullPath, , , , &nm)
            found[StrLower(nm)] := {nm: nm, file: A_LoopFileName, path: A_LoopFileFullPath}
        }
    }
    files := []
    for k, f in found
        files.Push(f)
    Loop files.Length {                                  ; keep the layouts in file-name order
        i := A_Index
        f := files[i]
        j := i - 1
        while (j >= 1 && StrCompare(files[j].nm, f.nm) > 0) {
            files[j + 1] := files[j]
            j--
        }
        files[j + 1] := f
    }
    for f in files {
        try {
            App.layouts.Push(Layout.Load(f.path))
        } catch as e {
            MsgBox("Could not read this layout file:`n" f.file "`n`n" e.Message, "Bangla Keyboard", 0x10)
        }
    }
    if (App.layouts.Length = 0) {
        MsgBox("No layout files were found in the Layouts folder.", "Bangla Keyboard", 0x10)
        ExitApp()
    }
    App.lastBn := 1
    for i, L in App.layouts {
        if InStr(L.name, "unicode") {
            App.lastBn := i
            break
        }
    }
}

; ---- typing ----------------------------------------------------------------
TypingKey(vk, shifted, *) {
    Critical "On"
    if App.fontOn {                                   ; Fonts feature: re-check the font when typing starts after a pause / the cursor moved
        now := A_TickCount
        if (App.fontDirty || now - App.lastKey > 1500)
            FontApply()
        App.lastKey := now
    }
    eng := App.eng
    lay := eng.lay
    has := shifted ? lay.sh.Has(vk) : lay.nor.Has(vk)
    if !has {
        ; this layout does not use the key: let it through as normal
        eng.Reset()
        Send("{Blind}{vk" . Format("{:X}", vk) . "}")
        return
    }
    txt := shifted ? lay.sh[vk] : lay.nor[vk]
    if (txt == " ") {
        eng.Track(" ")
        Send("{Blind}{Space}")
        return
    }
    r := eng.Press(vk, shifted)
    SendOut(r[1], r[2])
}

ResetKey(*) {
    if (App.fontOn && !RegExMatch(A_ThisHotkey, "i)^~[LR](Ctrl|Alt|Win)$"))
        App.fontDirty := true
    if IsObject(App.eng)
        App.eng.Reset()
}

RegisterTypingKeys() {
    vks := Map()
    for L in App.layouts {
        for vk in L.nor
            vks[vk] := 1
        for vk in L.sh
            vks[vk] := 1
    }
    Loop 10
        vks[47 + A_Index] := 1
    for vk in [32, 186, 187, 188, 189, 190, 191, 192, 219, 220, 221, 222]
        vks[vk] := 1
    HotIf()
    names := []
    for vk in vks {
        n := Format("vk{:X}", vk)
        Hotkey("$" . n, TypingKey.Bind(vk, false), "Off")
        Hotkey("$+" . n, TypingKey.Bind(vk, true), "Off")
        names.Push("$" . n, "$+" . n)
    }
    ; keys that only clear the look-back buffer and then behave normally
    for n in ["~*Enter", "~*NumpadEnter", "~*Tab", "~*Esc", "~*BS", "~*Delete", "~*Left", "~*Right"
        , "~*Up", "~*Down", "~*Home", "~*End", "~*PgUp", "~*PgDn", "~*LButton", "~*RButton", "~*MButton"
        , "~LCtrl", "~RCtrl", "~LAlt", "~RAlt", "~LWin", "~RWin"] {
        Hotkey(n, ResetKey, "Off")
        names.Push(n)
    }
    HotIf()
    App.typingNames := names
}

; Typing hotkeys exist only while a Bangla layout is active, so English is untouched.
EnableTyping(on) {
    if (on = App.typingOn)
        return
    HotIf()
    for n in App.typingNames {
        try Hotkey(n, on ? "On" : "Off")
    }
    HotIf()
    App.typingOn := on
}

; ---- keyboard mode switching: Global / Per Application-Window ---------------
; Can this window own a mode? (not our own windows, not the taskbar / desktop)
IsBindable(hwnd) {
    if !hwnd
        return false
    try {
        if (WinGetPID("ahk_id " . hwnd) = ProcessExist())
            return false
        cls := WinGetClass("ahk_id " . hwnd)
        if RegExMatch(cls, "^(Shell_TrayWnd|Shell_SecondaryTrayWnd|NotifyIconOverflowWindow|TopLevelWindowForOverflowXamlIsland|Progman|WorkerW|#32768)$")
            return false
        return true
    }
    return false
}

; Windows tells us at once when another window becomes the active one
InstallForegroundHook() {
    cb := CallbackCreate(OnForeground, , 7)
    App.fgHook := DllCall("SetWinEventHook", "UInt", 3, "UInt", 3, "Ptr", 0, "Ptr", cb, "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")
    OnExit(CleanupOnExit)
}

; Must return 0 (or nothing): a non-zero return value cancels the exit.
CleanupOnExit(*) {
    if App.fgHook {
        DllCall("UnhookWinEvent", "Ptr", App.fgHook)
        App.fgHook := 0
    }
    return 0
}

; Per-window mode: switch to the mode that the newly active window had (new windows start in English)
OnForeground(hHook, ev, hwnd, idObj, idChild, thr, tm) {
    if App.onTop
        SetTimer(KeepOnTop, -80)               ; the newly active window may have covered the bar: bring it back
    if (!(App.perWin || App.fontOn) || !IsBindable(hwnd) || hwnd = App.curWin)
        return
    App.curWin := hwnd
    fa := IsFontApp(hwnd)                   ; Office app with the Fonts feature on: it remembers its own mode
    if !fa
        App.fontCom := Map()                ; let go of Word / Excel / PowerPoint
    if (App.winModes.Count > 300) {
        for h in App.winModes.Clone() {
            if !WinExist("ahk_id " . h)
                App.winModes.Delete(h)
        }
    }
    m := (App.perWin || fa) ? App.winModes.Get(hwnd, 0) : App.globMode
    if (m > 0 && !IsShown("L:" . App.layouts[m].name))
        m := 0
    ApplyLayout(m)
}

; ---- switching layouts -----------------------------------------------------
SetLayout(i, *) {
    if (i < 0 || i > App.layouts.Length)
        return
    if (App.curWin && (App.perWin || IsFontApp(App.curWin)))
        App.winModes[App.curWin] := i          ; only the current window changes
    else
        App.globMode := i
    if (i > 0)
        App.lastBn := i
    ApplyLayout(i)
}

ApplyLayout(i) {
    App.cur := i
    App.manualHold := 0
    if (i > 0)
        App.eng := Engine(App.layouts[i])
    EnableTyping(i > 0 ? true : false)
    RefreshUI()
    if App.fontOn
        FontKick()
}

; Shortcut of a layout: first press switches it on, pressing it again goes back to English
ToggleLayout(i, *) {
    SetLayout(App.cur = i ? 0 : i)
}

ToggleEnglish(*) {
    SetLayout(App.cur = 0 ? App.lastBn : 0)
}

ToggleBar(*) {
    if DllCall("IsWindowVisible", "ptr", App.bar.Hwnd)
        HideBar()
    else
        ShowBar()
}

CurrentName() {
    return App.cur = 0 ? "English" : App.layouts[App.cur].name
}

; Icon files for English (i = 0) or a layout, best first. The names are tried in this order: <IconName> from the layout file,
; the layout's own name, then "Unicode"; and for each name a picture Icons\<name>.png wins over Icons\<name>.ico.
IconCandidates(i) {
    names := []
    if (i = 0)
        names := ["English"]
    else {
        L := App.layouts[i]
        names := [L.icon, L.name, "Unicode"]
    }
    list := []
    for n in names {
        if (n = "")
            continue
        for ext in ["png", "ico"] {
            p := App.dir . "\Icons\" . n . "." . ext
            if FileExist(p)
                list.Push(p)
        }
    }
    return list
}

; the best icon file of English / a layout ("" when there is none)
IconFor(i) {
    c := IconCandidates(i)
    return c.Length ? c[1] : ""
}

; the icon sizes in pixels, biggest first (same order as the names in IconSizeLabels)
IconSizes() {
    return [20, 19, 18, 17, 16, 15, 14]
}

IconSizeLabels() {
    return ["Original", "Regular", "Medium", "Reduced", "Compact", "Petite", "Smaller"]
}

; Put a .png in an icon box of the tray: the tray wants an icon file, so the picture is wrapped in a small .ico (a PNG is a valid
; icon image). Pictures bigger than 256 px cannot be wrapped: those are skipped (the next candidate, usually the .ico, is used).
PngAsIcon(png) {
    try {
        f := FileOpen(png, "r")
        n := f.Length
        buf := Buffer(n)
        f.RawRead(buf, n)
        f.Close()
        if (n < 24 || NumGet(buf, 1, "UChar") != 0x50 || NumGet(buf, 2, "UChar") != 0x4E || NumGet(buf, 3, "UChar") != 0x47)
            return ""
        w := NumGet(buf, 18, "UChar") * 256 + NumGet(buf, 19, "UChar")       ; width / height are big-endian in the PNG header
        h := NumGet(buf, 22, "UChar") * 256 + NumGet(buf, 23, "UChar")
        if (w < 1 || h < 1 || w > 256 || h > 256)
            return ""
        ico := Buffer(22 + n, 0)
        NumPut("UShort", 0, "UShort", 1, "UShort", 1, ico, 0)                ; ICONDIR: reserved, type = icon, 1 image
        NumPut("UChar", (w = 256) ? 0 : w, "UChar", (h = 256) ? 0 : h, "UChar", 0, "UChar", 0, ico, 6)
        NumPut("UShort", 1, "UShort", 32, "UInt", n, "UInt", 22, ico, 10)    ; planes, bits, size of the image, where it starts
        DllCall("RtlMoveMemory", "ptr", ico.Ptr + 22, "ptr", buf.Ptr, "uptr", n)
        out := A_Temp . "\BanglaKeyboard_tray.ico"
        o := FileOpen(out, "w")
        o.RawWrite(ico, ico.Size)
        o.Close()
        return out
    }
    return ""
}

; the tray icon follows the current layout: the same files as the bar, .png first
SetTrayIconFile() {
    for p in IconCandidates(App.cur) {
        if (StrLower(SubStr(p, -4)) = ".png") {
            q := PngAsIcon(p)
            if (q != "") {
                try {
                    TraySetIcon(q)
                    return
                }
            }
            continue
        }
        try {
            TraySetIcon(p)
            return
        }
    }
}

; ---- shortcut keys -----------------------------------------------------------
; Every action that can have a shortcut. "def" is the built-in default.
ActionList() {
    a := []
    a.Push({id: "Toggle", label: "Toggle On/Off", def: "F5", cb: ToggleEnglish})
    a.Push({id: "English", label: "English", def: "^!e", cb: ToggleEnglish})
    for i, L in App.layouts
        a.Push({id: "L:" . L.name, label: L.name, def: L.hotkey, cb: ToggleLayout.Bind(i)})
    for f in ToolFiles()                                ; every program / script found in the Tools folder (ticked = its shortcut starts it)
        a.Push({id: "R:" . f.full, label: f.name, def: "", cb: RunTool.Bind(f.path)})
    return a
}

; Win-key combinations and the old "special key" shortcuts (~ & |) cannot be shown in the key box
IsUnsupportedHk(hk) {
    return RegExMatch(hk, "[#&~|]") ? true : false
}

IniKey(id) {
    return "Key_" . RegExReplace(id, "[^\w]", "_")
}

LoadShortcuts() {
    App.shortcuts := Map()
    for a in ActionList() {
        v := IniRead(App.ini, "Shortcuts", IniKey(a.id), "<default>")
        if (v = "<default>") {
            v := a.def
            if (a.id = "Toggle") {
                old := IniRead(App.ini, "General", "ToggleHotkey", "")      ; settings file of older versions
                if (old != "")
                    v := old
            }
        } else if (v = "none")
            v := ""
        else if IsUnsupportedHk(v)
            v := a.def                      ; older versions allowed Win / special keys; they are gone now
        App.shortcuts[a.id] := v
    }
}

; Items ticked in Settings > Shortcuts are listed in the bar menu / tray menu and their shortcut works.
; Unticked items are hidden and their shortcut is switched off. (Tools programs are always listed in the tray menu;
; the tick only switches their shortcut on, and starts unticked.)
IsShown(id) {
    return App.shown.Get(id, true)
}

LoadShown() {
    App.shown := Map()
    any := false
    for a in ActionList() {
        v := (IniRead(App.ini, "Shown", IniKey(a.id), (SubStr(a.id, 1, 2) = "R:") ? "0" : "1") != "0")
        App.shown[a.id] := v
        if (v && SubStr(a.id, 1, 2) = "L:")
            any := true
    }
    if !any {                                   ; never leave the program without a Bangla layout
        for L in App.layouts
            App.shown["L:" . L.name] := true
    }
    FixLastBn()
}

; the layout used by the On/Off toggle must be one that is listed
FixLastBn() {
    if (App.lastBn >= 1 && App.lastBn <= App.layouts.Length && IsShown("L:" . App.layouts[App.lastBn].name))
        return
    for i, L in App.layouts {
        if IsShown("L:" . L.name) {
            App.lastBn := i
            return
        }
    }
}

UnregisterShortcuts() {
    HotIf()
    for n in App.regNames {
        try Hotkey(n, "Off")
    }
    App.regNames := []
}

ApplyShortcuts() {
    UnregisterShortcuts()
    HotIf()
    for a in ActionList() {
        hk := App.shortcuts.Get(a.id, "")
        if (hk = "" || !IsShown(a.id))
            continue
        for part in StrSplit(hk, "|") {
            if (part = "")
                continue
            try {
                Hotkey(part, a.cb, "On")
                App.regNames.Push(part)
            }
        }
    }
    if App.manualOn {                                     ; manual font slots (Win key allowed; "$" = always catch it, even over Windows' own Win+number)
        for i, sl in App.slots {
            if (sl.key = "" || sl.font = "")
                continue
            try {
                Hotkey("$" . sl.key, FontManual.Bind(i), "On")
                App.regNames.Push("$" . sl.key)
            }
        }
    }
}

; "^!vk56" -> {mods: "^!", key: "vk56"}
SplitHk(hk) {
    mods := ""
    while (hk != "" && InStr("^!+#", SubStr(hk, 1, 1))) {
        mods .= SubStr(hk, 1, 1)
        hk := SubStr(hk, 2)
    }
    return {mods: mods, key: hk}
}

PrettyHk(hk) {
    if (hk = "")
        return "(none)"
    p := SplitHk(hk)
    s := ""
    Loop Parse p.mods
        s .= (A_LoopField = "^") ? "Ctrl+" : (A_LoopField = "!") ? "Alt+" : (A_LoopField = "+") ? "Shift+" : "Win+"
    return s . StrUpper(GetKeyName(p.key))
}

; ---- tray -------------------------------------------------------------------
BuildTrayMenu() {
    tm := A_TrayMenu
    tm.Delete()
    tm.Add("Show / Hide bar", ToggleBar)
    tm.Add()
    if IsShown("English")
        tm.Add("English", SetLayout.Bind(0))
    for i, L in App.layouts {
        if IsShown("L:" . L.name)
            tm.Add(L.name, SetLayout.Bind(i))
    }
    tm.Add()
    files := ToolFiles()                   ; programs / scripts in the Tools folder (section only appears when there are some)
    if (files.Length > 0) {
        for f in files
            tm.Add(StrReplace(f.name, "&", "&&"), RunTool.Bind(f.path))
        tm.Add()
    }
    tm.Add("Settings...", ShowSettings)
    tm.Add("About...", ShowAbout)
    tm.Add("Exit", CloseBar)
    ; no default menu item: left clicks on the tray icon are handled by TrayClick below
    ;   single click = toggle On/Off (English <-> last Bangla layout), double click = show / hide the bar
    if !App.trayHooked {
        OnMessage(0x404, TrayClick)          ; AHK_NOTIFYICON
        App.trayHooked := true
    }
}

; every .exe and .ahk file in the Tools folder next to this script
ToolFiles() {
    list := []
    count := Map()
    Loop Files App.dir . "\Tools\*.*" {
        if RegExMatch(A_LoopFileExt, "i)^(exe|ahk)$") {
            base := RegExReplace(A_LoopFileName, "\.[^.]*$")             ; file name without the extension
            count[StrLower(base)] := count.Get(StrLower(base), 0) + 1
            list.Push({name: base, full: A_LoopFileName, path: A_LoopFileFullPath})
        }
    }
    for f in list {
        if (count[StrLower(f.name)] > 1)
            f.name := f.full                                              ; same name twice (e.g. Tool.exe + Tool.ahk): keep the extension so both show
    }
    return list
}

RunTool(path, *) {
    SplitPath(path, &nm, &dir, &ext)
    try {
        if (StrLower(ext) = "ahk" && FileExist(A_AhkPath))
            Run('"' . A_AhkPath . '" "' . path . '"', dir)
        else
            Run('"' . path . '"', dir)
    } catch as e {
        MsgBox("Could not start " . nm . "`n`n" . e.Message, "Bangla Keyboard", 0x10)
    }
}

TrayClick(wParam, lParam, msg, hwnd) {
    if (hwnd != A_ScriptHwnd)
        return
    if (lParam = 0x205) {                    ; WM_RBUTTONUP: the menu is about to open - re-read the Tools folder first
        BuildTrayMenu()
        try A_TrayMenu.Check(CurrentName())
        return
    }
    if (lParam = 0x203) {                    ; WM_LBUTTONDBLCLK
        SetTimer(ToggleEnglish, 0)           ; cancel the pending single-click action
        App.trayDbl := true
        ToggleBar()
        return 0
    }
    if (lParam = 0x202) {                    ; WM_LBUTTONUP
        if App.trayDbl {                     ; the release that ends a double click
            App.trayDbl := false
            return 0
        }
        SetTimer(ToggleEnglish, -DllCall("GetDoubleClickTime", "UInt"))   ; wait to see if a 2nd click follows
        return 0
    }
}

; The tray icon is always shown, or - when "Always show the tray icon" is off - only while the bar is hidden.
SyncTray() {
    if !IsObject(App.bar)
        return
    want := App.trayAlways ? false : (DllCall("IsWindowVisible", "ptr", App.bar.Hwnd) != 0)     ; hide the icon while the bar is on screen (unless it is set to stay)
    try {
        if (A_IconHidden != want)
            A_IconHidden := want
    }
}

UpdateTray() {
    tm := A_TrayMenu
    try tm.Uncheck("English")
    for L in App.layouts
        try tm.Uncheck(L.name)
    try tm.Check(CurrentName())
    SetTrayIconFile()
    A_IconTip := "Bangla Keyboard - " . CurrentName() . (App.perWin ? " (per window)" : "")
    SyncTray()                  ; TraySetIcon must not bring the icon back while the bar is visible
}

RefreshUI() {
    UpdateTray()
    UpdateBar()
}

; ---- start with Windows -------------------------------------------------------
StartupLink() {
    return A_Startup "\Bangla Keyboard.lnk"
}

IsAutoStart() {
    return FileExist(StartupLink()) != ""
}

SetAutoStart(on) {
    lnk := StartupLink()
    try {
        if on {
            if A_IsCompiled {          ; installed .exe: start the program itself
                FileCreateShortcut(A_ScriptFullPath, lnk, A_ScriptDir, "", "Bangla Keyboard", App.dir "\Icons\Unicode.ico")
            } else {
                FileCreateShortcut(A_AhkPath, lnk, A_ScriptDir, '"' A_ScriptFullPath '"', "Bangla Keyboard", App.dir "\Icons\Unicode.ico")
            }
        } else if FileExist(lnk) {
            FileDelete(lnk)
        }
    }
}

; Picture-control text for the current encoding's icon (loaded as a handle, which is the most reliable way).
; The first file that loads wins: a .png before an .ico (see IconCandidates). It is loaded at the size of the icon box (App.picSz).
PicSpec() {
    sz := App.picSz
    for f in IconCandidates(App.cur) {
        h := 0
        type := 0
        isIco := (StrLower(SubStr(f, -4)) = ".ico")
        try {
            h := LoadPicture(f, (isIco ? "Icon1 " : "") . "w" . sz . " h" . sz, &type)
        }
        if h
            return ((type = 1) ? "HICON:" : "HBITMAP:") . h
    }
    throw Error("no icon picture")                       ; the caller shows the letter badge instead
}

; The icon of the bar: a square that always stays centred on the middle of its place (x = left edge of the old 20 px icon box, so
; the centre is x + 10, and the middle of the bar height), whatever the "Icon size" setting is: Original = 20 px (as it always was),
; then Regular 19, Medium 18, Reduced 17, Compact 16, Petite 15, Smaller 14 (see IconSizes). It never gets wider than the room up to the name box (nameX).
AddBarIcon(g, x, nameX, barH, badgeOpt) {
    cx := x + 10
    s := IconSizes()[Min(7, Max(1, App.iconSize))]
    s := Max(8, Min(s, barH, 2 * (nameX - cx), 2 * cx))
    ix := cx - s // 2
    iy := (barH - s) // 2
    App.picSz := s
    pos := "x" . ix . " y" . iy . " w" . s . " h" . s
    try {
        App.pic := g.Add("Picture", pos . " BackgroundTrans", PicSpec())
    } catch {
        ; never fail because of the icon: show a small letter badge instead
        App.pic := g.Add("Text", pos . " Center +0x200 " . badgeOpt, IconBadge())
        App.pic.SetFont("s" . Max(6, Min(10, s * 2 // 5)) . " bold", "Segoe UI")
    }
}

IconBadge() {
    if (App.cur = 0)
        return "E"
    n := App.layouts[App.cur].icon
    return (n = "") ? "B" : SubStr(n, 1, 1)
}

; ---------------------------------------------------------------------------
;  The top bar:  [icon + drag] [layout dropdown] [settings] [minimize to tray] [close]
; ---------------------------------------------------------------------------
BuildBar() {
    th := Themes()[App.theme]
    opts := "-Caption +ToolWindow +E0x08000000 " . (App.onTop ? "+AlwaysOnTop" : "")
    g := Gui(opts, "Bangla Keyboard")
    g.BackColor := th.bg
    g.MarginX := 0
    g.MarginY := 0
    App.bar := g
    App.hov := []                      ; (the old buttons are gone with the old bar)
    App.hovCur := 0

    barW := 232
    barH := 24
    App.picSz := 20
    if (!UsesTheme(App.style) && FileExist(StyleDir() . "bar_bg.png")) {
        barH := (App.style = "GreenBangla") ? 26 : 24      ; every style is as thin as Classic, except Bijoy Bayanno (1 px more on top and bottom)
        if (App.style = "AeroDark") {
            BuildBarAero(g)
            barW := 258
        } else if (App.style = "PurpleRaised") {
            BuildBarPurple(g)
            barW := 258
        } else if (App.style = "EkusheDark") {
            barW := BuildBarEkushe(g)
        } else if (App.style = "EkusheBN") {
            barW := BuildBarEkushe(g, true, ExtShown())
        } else if (App.style = "BanglaKb") {
            barW := BuildBarBanglaKb(g, ExtShown())
        } else {
            BuildBarGreen(g)
            barW := 260
        }
    } else
        barW := BuildBarClassic(g, th, App.style = "ClassicExt" ? ExtShown() : [])

    if !App.msgHooked {
        OnMessage(0x201, BarMouseDown)     ; WM_LBUTTONDOWN: drag from the icon / empty parts
        OnMessage(0x232, BarMoved)         ; WM_EXITSIZEMOVE: remember where it was dropped
        OnMessage(0x200, HoverMove)        ; WM_MOUSEMOVE: light up the bar button under the mouse
        App.msgHooked := true
    }

    realW := Round(barW * A_ScreenDPI / 96)
    x := App.barX
    y := App.barY
    if !(IsNumber(x) && IsNumber(y) && PointOnScreen(x + 20, y + 10)) {
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        x := l + (r - l - realW) // 2
        y := t
    }
    g.Show("NoActivate w" . barW . " h" . barH . " x" . x . " y" . y)
    WinGetPos(, , &w, &h, "ahk_id " . g.Hwnd)
}

BuildBarClassic(g, th, ext := []) {
    ; icon of the current encoding = state indicator and the handle for moving the bar
    AddBarIcon(g, 4, 28, 24, "Background" . th.fld . " c" . th.ftx)

    ; "dropdown": a box that opens the layout list (a little narrower on "Default Ext", to make room for its buttons)
    nw := 100 - 6 * ext.Length
    App.nameCtl := g.Add("Text", "x28 y2 w" . nw . " h20 +0x200 +0x100 Background" . th.fld . " c" . th.ftx, "  " . CurrentName())
    App.nameCtl.SetFont("s8 bold", "Segoe UI")
    x := 28 + nw
    arrow := g.Add("Text", "x" . x . " y2 w18 h20 Center +0x200 +0x100 Background" . th.fld . " c" . th.arr, "▼")
    arrow.SetFont("s8", "Segoe UI Symbol")
    App.nameCtl.OnEvent("Click", ShowLayoutMenu)
    arrow.OnEvent("Click", ShowLayoutMenu)
    x += 23

    for i in ext {                                                 ; the ticked extra buttons, left of the settings button
        AddExtButton(g, i, x, 2, 24, 20, "", th.stb, th.btx, 16)
        x += 27
    }

    ; settings, minimize to tray, close
    bSet := g.Add("Text", "x" . x . " y2 w24 h20 Center +0x200 +0x100 Background" . th.stb . " c" . th.btx, "⚙")
    bSet.SetFont("s9", "Segoe UI Symbol")
    bSet.OnEvent("Click", ShowSettings)
    AddColorHover(bSet, th.stb)
    x += 27
    bMin := g.Add("Text", "x" . x . " y2 w24 h20 Center +0x200 +0x100 Background" . th.mnb . " c" . th.btx, "−")
    bMin.SetFont("s10 bold", "Segoe UI")
    bMin.OnEvent("Click", HideBar)
    AddColorHover(bMin, th.mnb)
    x += 27
    bClose := g.Add("Text", "x" . x . " y2 w24 h20 Center +0x200 +0x100 Background" . th.clb . " c" . th.btx, "×")
    bClose.SetFont("s10 bold", "Segoe UI")
    bClose.OnEvent("Click", CloseBar)
    AddColorHover(bClose, th.clb)
    bClose.OnEvent("DoubleClick", CloseBar)      ; a quick second click would otherwise be ignored
    g.OnEvent("Close", BarCloseEvent)            ; Alt+F4 etc. behave the same as the [x] button
    return x + 27                                ; width of the bar
}

; ---- the two extra buttons ("Default Ext" and "Ekushey BN" styles) ----------------------------------------------
; Each button starts one program / script from the Tools folder (chosen in Settings > General) and shows the icon
; chosen there. Pictures put in Skins\Button Icons appear in that icon list too.
; The built-in icons are grouped by the tool they suit: Docs Converter, Text Converter, Layout Builder, Quick Note.
ExtGlyphs() {
    ; icons that suit the tools that come with the program, with a few variants each (name, Unicode character)
    static t := [["Docs: File", 0x1F4C4], ["Docs: Pages", 0x1F4D1], ["Docs: Curl", 0x1F4C3], ["Docs: Convert", 0x1F504]
        , ["Text: Aa", 0x1F524], ["Text: abc", 0x1F521], ["Text: ABC", 0x1F520]
        , ["Text: Arrows", 0x21C4], ["Text: Swap", 0x21C6]
        , ["Layout: Keys", 0x2328], ["Layout: Ruler", 0x1F4D0], ["Layout: Wrench", 0x1F527], ["Layout: Puzzle", 0x1F9E9]
        , ["Layout: Tools", 0x1F6E0]
        , ["Note: Memo", 0x1F4DD], ["Note: Pad", 0x1F5D2], ["Note: Book", 0x1F4D3], ["Note: Pencil", 0x270E]
        , ["Note: Pin", 0x1F4CC]]
    return t
}

; names for the icon list in Settings: (None) = empty button, the program's own icon, the built-in icons, then your own pictures
ExtIconNames() {
    a := ["(None)", "App icon"]
    for g in ExtGlyphs()
        a.Push(g[1])
    Loop Files App.dir . "\Skins\Button Icons\*.*" {
        if RegExMatch(A_LoopFileExt, "i)^(png|ico|jpg|jpeg|bmp|gif)$")
            a.Push(A_LoopFileName)
    }
    return a
}

; what extra button i shows: a picture (pic, with its icon option) or a text symbol (glyph)
ExtIconInfo(i) {
    b := App.ext[i]
    path := (b.act = "") ? "" : App.dir . "\Tools\" . b.act
    if (b.icon = "(None)")
        return {glyph: "", pic: "", opt: "", none: true}                 ; empty button: no icon at all
    if (b.icon = "App icon") {
        if (path != "" && FileExist(path)) {
            SplitPath(path, , , &ext)
            if (StrLower(ext) = "exe")
                return {glyph: "", pic: path, opt: "Icon1"}
            if FileExist(A_AhkPath)
                return {glyph: "", pic: A_AhkPath, opt: "Icon1"}      ; a script: the AutoHotkey icon
        }
        return {glyph: "+", pic: "", opt: ""}                         ; nothing assigned yet
    }
    for g in ExtGlyphs() {
        if (g[1] = b.icon)
            return {glyph: Chr(g[2]), pic: "", opt: ""}
    }
    f := App.dir . "\Skins\Button Icons\" . b.icon
    if FileExist(f)
        return {glyph: "", pic: f, opt: ""}
    return {glyph: Chr(ExtGlyphs()[1][2]), pic: "", opt: ""}
}

; ---- hover effect of the bar buttons ------------------------------------------------------------------------
; Every button has a picture (name.png) and a lit picture (name_hover.png) in its style folder; the colour-based
; buttons of the Classic styles are simply drawn in a lighter colour while the mouse is over them.
BtnFile(d, name, hover := false) {
    f := d . name . (hover ? "_hover" : "") . ".png"
    return FileExist(f) ? f : ""
}

; a picture button of the bar (x, y, w, h in normal 96-dpi units); it lights up when the mouse is over it
AddPicBtn(g, d, name, x, y, w, h) {
    norm := BtnFile(d, name)
    ; Aero Dark icons are transparent PNGs: let the bar picture show through instead of the window colour
    pic := g.Add("Picture", "x" . x . " y" . y . " w" . w . " h" . h . (App.style = "AeroDark" ? " +BackgroundTrans" : ""), norm)
    AddHover(pic, [pic.Hwnd], norm, BtnFile(d, name, true), w, h)
    return pic
}

; remember a picture control and its two pictures (normal / lit); top = a control lying over it that must be redrawn too
AddHover(ctl, hwnds, norm, hov, w, h, top := "") {
    if (norm = "" || hov = "")
        return
    k := A_ScreenDPI / 96
    App.hov.Push({ctl: ctl, hwnds: hwnds, norm: norm, hov: hov, pw: Round(w * k), ph: Round(h * k), top: top, col: false})
}

; a button that is just a coloured box (Classic styles): lit = the same colour, lighter (darker for very light colours)
AddColorHover(ctl, hex, top := "") {
    App.hov.Push({ctl: ctl, hwnds: [ctl.Hwnd], norm: hex, hov: HoverColor(hex), pw: 0, ph: 0, top: top, col: true})
}

HoverColor(hex) {
    r := Integer("0x" . SubStr(hex, 1, 2)), g := Integer("0x" . SubStr(hex, 3, 2)), b := Integer("0x" . SubStr(hex, 5, 2))
    if ((r * 299 + g * 587 + b * 114) / 1000 > 170) {            ; light colour: a little darker
        r := Round(r * 0.88), g := Round(g * 0.88), b := Round(b * 0.88)
    } else {                                                      ; dark colour: a little lighter
        r := Round(r + (255 - r) * 0.24), g := Round(g + (255 - g) * 0.24), b := Round(b + (255 - b) * 0.24)
    }
    return Format("{:02X}{:02X}{:02X}", r, g, b)
}

HoverFind(h) {
    for it in App.hov {
        for x in it.hwnds {
            if (x = h)
                return it
        }
    }
    return 0
}

HoverSet(it, on) {
    try {
        if it.col {
            it.ctl.Opt("Background" . (on ? it.hov : it.norm))
            it.ctl.Redraw()
        } else {
            it.ctl.Value := "*w" . it.pw . " *h" . it.ph . " " . (on ? it.hov : it.norm)
            if (App.style = "AeroDark")
                it.ctl.Redraw()                                    ; transparent picture: repaint what lies behind it
        }
        if IsObject(it.top)
            it.top.Redraw()
    }
}

; WM_MOUSEMOVE over the bar: check now and keep checking (every 40 ms) until the mouse has left the bar again.
; Nothing runs while the mouse is somewhere else.
HoverMove(wParam, lParam, msg, hwnd) {
    if (App.hov.Length = 0 || !IsObject(App.bar))
        return
    if (hwnd != App.bar.Hwnd) {
        c := GuiCtrlFromHwnd(hwnd)
        if !(IsObject(c) && c.Gui.Hwnd = App.bar.Hwnd)
            return
    }
    HoverTick()
    if !App.hovTimer {
        App.hovTimer := true
        SetTimer(HoverTick, 40)
    }
}

HoverTick() {
    it := 0
    over := false
    try {
        MouseGetPos(, , &win, &ctl, 2)
        if (IsObject(App.bar) && win = App.bar.Hwnd) {
            over := true
            it := HoverFind(ctl)
        }
    }
    if (it != App.hovCur) {
        if IsObject(App.hovCur)
            HoverSet(App.hovCur, false)
        if IsObject(it)
            HoverSet(it, true)
        App.hovCur := it
    }
    if !over {
        SetTimer(HoverTick, 0)
        App.hovTimer := false
    }
}

; one button: a face (colour or picture) with the icon on top. sz = icon size in pixels
AddExtButton(g, i, x, y, w, h, facePic, bg, fg, sz, hovPic := "") {
    if (facePic != "")
        face := g.Add("Picture", "x" . x . " y" . y . " w" . w . " h" . h, facePic)
    else
        face := g.Add("Text", "x" . x . " y" . y . " w" . w . " h" . h . " +0x100 Background" . bg)
    face.OnEvent("Click", ExtClick.Bind(i))
    ic := ExtIconInfo(i)
    top := ""
    if (ic.pic != "") {
        try top := g.Add("Picture", "x" . (x + (w - sz) // 2) . " y" . (y + (h - sz) // 2) . " w" . sz . " h" . sz . " BackgroundTrans " . ic.opt, ic.pic)
    }
    if !IsObject(top) {
        top := g.Add("Text", "x" . x . " y" . y . " w" . w . " h" . h . " Center +0x200 +0x100 BackgroundTrans c" . fg, (ic.glyph != "" || ic.HasProp("none")) ? ic.glyph : "+")
        top.SetFont(sz > 14 ? "s9" : "s8", "Segoe UI Symbol")
    }
    top.OnEvent("Click", ExtClick.Bind(i))
    if (facePic != "" && hovPic != "")
        AddHover(face, [face.Hwnd, top.Hwnd], facePic, hovPic, w, h, top)
    else if (facePic = "" && bg != "") {
        AddColorHover(face, bg, top)
        App.hov[App.hov.Length].hwnds.Push(top.Hwnd)
    }
}

ExtClick(i, *) {
    b := App.ext[i]
    if (b.act = "") {
        ExtTip("No action is assigned to button " . i . ".`nChoose one in Settings > General.")
        return
    }
    path := App.dir . "\Tools\" . b.act
    if !FileExist(path) {
        ExtTip(b.act . " was not found in the Tools folder.`nChoose another one in Settings > General.")
        return
    }
    RunTool(path)
}

ExtTip(msg) {
    ToolTip(msg)
    SetTimer(ToolTip, -2500)
}

; folder with the pictures of the current bar style
StyleDir() {
    return App.dir "\Skins\" . (App.style = "AeroDark" ? "Ekushey New" : App.style = "PurpleRaised" ? "Bijoy Ekattor" : App.style = "EkusheDark" ? "Ekushey Old" : App.style = "EkusheBN" ? "Ekushey" : App.style = "BanglaKb" ? "Bangla" : "Bijoy Bayanno") . "\"
}

; ---- "Purple Raised" style: purple bar, peach dropdown, raised red / grey buttons ----
;  [icon] [English  | v] [কিবোর্ড]  [wrench = settings] [minimize] [close]
BuildBarPurple(g) {
    d := StyleDir()
    g.BackColor := "3E226A"
    g.Add("Picture", "x0 y0 w258 h24", d . "bar_bg.png")
    AddBarIcon(g, 4, 28, 24, "BackgroundFFFFFF c000000")
    App.nameCtl := g.Add("Text", "x28 y3 w76 h18 +0x200 +0x100 BackgroundFBE9D8 c303030", "  " . CurrentName())
    App.nameCtl.SetFont("s7 bold", "Segoe UI")
    App.nameCtl.OnEvent("Click", ShowLayoutMenu)
    arrow := g.Add("Picture", "x104 y3 w22 h18", d . "arrow.png")
    arrow.OnEvent("Click", ShowLayoutMenu)

    bSet := AddPicBtn(g, d, "settings", 185, 4, 21, 16)
    bSet.OnEvent("Click", ShowSettings)
    bMin := AddPicBtn(g, d, "min", 209, 4, 21, 16)
    bMin.OnEvent("Click", HideBar)
    bClose := AddPicBtn(g, d, "close", 233, 4, 21, 16)
    bClose.OnEvent("Click", CloseBar)
    bClose.OnEvent("DoubleClick", CloseBar)
    g.OnEvent("Close", BarCloseEvent)
}

; ---- "Green Bangla" style (Bijoy Bayanno): dark green bar ----
;  [icon = settings] [English  v] [green arrow = minimize] [red x = close]
;  (click the icon for Settings)
BuildBarGreen(g) {
    d := StyleDir()
    g.BackColor := "345044"
    g.Add("Picture", "x0 y0 w260 h26", d . "bar_bg.png")           ; 26 px high: everything below sits 1 px lower than before

    AddBarIcon(g, 86, 108, 26, "BackgroundFFFFFF c000000")           ; this bar is 26 px high
    App.pic.OnEvent("Click", ShowSettings)                           ; the icon still shows the current mode, and clicking it opens Settings
    App.nameCtl := g.Add("Text", "x108 y4 w80 h18 +0x200 +0x100 BackgroundFFFFFF c000000", "  " . CurrentName())
    App.nameCtl.SetFont("s8", "Times New Roman")
    App.nameCtl.OnEvent("Click", ShowLayoutMenu)
    arrow := g.Add("Picture", "x188 y4 w20 h18", d . "arrow.png")
    arrow.OnEvent("Click", ShowLayoutMenu)

    bMin := AddPicBtn(g, d, "min", 213, 4, 18, 18)
    bMin.OnEvent("Click", HideBar)
    bClose := AddPicBtn(g, d, "close", 236, 3, 20, 20)
    bClose.OnEvent("Click", CloseBar)
    bClose.OnEvent("DoubleClick", CloseBar)
    g.OnEvent("Close", BarCloseEvent)
}

; ---- "Aero Dark" style: dark glass bar built from the pictures in Skins\Ekushey New ----
;  [icon] [English      v] [কিবোর্ড] [gear = settings] [minimize] [close]
;  (colour theme does not apply to this style: the colours are part of the pictures)
BuildBarAero(g) {
    d := StyleDir()
    g.BackColor := "050C22"
    g.Add("Picture", "x0 y0 w258 h24", d . "bar_bg.png")           ; frame + glass gradient (clicks pass through = drag)

    AddBarIcon(g, 4, 30, 24, "BackgroundFFFFFF c000000")

    nmY := 4, nmH := 16                                            ; the name box and the arrow button share the same top and height
    App.nameCtl := g.Add("Text", "x30 y" . nmY . " w84 h" . nmH . " +0x200 +0x100 BackgroundFFFFFF c000000", "  " . CurrentName())
    App.nameCtl.SetFont("s7 bold", "Segoe UI")
    App.nameCtl.OnEvent("Click", ShowLayoutMenu)
    arrow := AddPicBtn(g, d, "arrow", 114, nmY, 18, nmH)
    arrow.OnEvent("Click", ShowLayoutMenu)

    bSet := AddPicBtn(g, d, "settings", 192, 4, 17, 17)
    bSet.OnEvent("Click", ShowSettings)
    bMin := AddPicBtn(g, d, "min", 212, 2, 20, 20)
    bMin.OnEvent("Click", HideBar)
    bClose := AddPicBtn(g, d, "close", 236, 4, 17, 17)
    bClose.OnEvent("Click", CloseBar)
    bClose.OnEvent("DoubleClick", CloseBar)
    g.OnEvent("Close", BarCloseEvent)
}

; ---- "Ekushe Dark" style: black glossy bar like the Bijoy Ekushe 2016 tool bar ----
;  [icon] [English  | v] [grip]  [wrench = settings] [minimize] [close]   (no caption label)
BuildBarEkushe(g, bn := false, ext := []) {
    d := StyleDir()
    g.BackColor := "000000"
    bw := !bn ? 224 : 207 + 24 * ext.Length                        ; bar width: Ekushey Old | Ekushey BN: 207 + 24 for each ticked extra button
    bg := (bn && ext.Length = 1) ? BarBgOne(d) : "bar_bg.png"     ; Ekushey BN: the 1-button picture, or the 2-button one
    try
        g.Add("Picture", "x0 y0 w" . bw . " h24", d . bg)
    catch                                                          ; a picture that cannot be read: use the standard one instead of failing
        g.Add("Picture", "x0 y0 w" . bw . " h24", d . "bar_bg.png")
    AddBarIcon(g, 4, 32, 24, "BackgroundFFFFFF c000000")
    App.nameCtl := g.Add("Text", "x32 y6 w78 h12 +0x200 +0x100 BackgroundFBE9D8 c101030", "  " . CurrentName())
    App.nameCtl.SetFont("s7 bold", "Segoe UI")
    App.nameCtl.OnEvent("Click", ShowLayoutMenu)
    arrow := g.Add("Picture", "x110 y5 w18 h14", d . "arrow.png")
    arrow.OnEvent("Click", ShowLayoutMenu)

    x := bn ? 134 : 151                                            ; "Ekushey BN" has no dotted grip, so everything sits closer
    for i in ext {
        AddExtButton(g, i, x, 4, 21, 16, BtnFile(d, "button_bg"), "", "22242E", 14, BtnFile(d, "button_bg", true))
        x += 24
    }
    bSet := AddPicBtn(g, d, "settings", x, 4, 21, 16)
    bSet.OnEvent("Click", ShowSettings)
    bMin := AddPicBtn(g, d, "min", x + 24, 4, 21, 16)
    bMin.OnEvent("Click", HideBar)
    bClose := AddPicBtn(g, d, "close", x + 48, 4, 21, 16)
    bClose.OnEvent("Click", CloseBar)
    bClose.OnEvent("DoubleClick", CloseBar)
    g.OnEvent("Close", BarCloseEvent)
    return bw
}

; ---- "Bangla [+]" style: teal bar, dynamic left buttons, state icon, white dropdown, blue settings, green minimize, red close ----
;  [button 1] | [button 2] | [icon] [English        v] | [green arrow = minimize] | [red x = close]
;  The buttons on the left are the extra buttons (Settings > General): button 1 is always there, button 2 when ticked.
;  Settings: use the layout menu (last item) or the tray icon.
BuildBarBanglaKb(g, ext := []) {
    d := StyleDir()
    bar := "115048"
    g.BackColor := bar
    sepC := "9FC4BB"
    bgPic := g.Add("Picture", "x0 y0 w248 h24", d . "bar_bg.png")      ; resized below once the width is known
    x := 4
    for i in ext {                                                 ; the dynamic buttons, then a separator after each
        AddExtButton(g, i, x, 2, 22, 20, "", bar, "E6F2EE", 16)
        g.Add("Text", "x" . (x + 25) . " y4 w1 h16 Background" . sepC)
        x += 30
    }
    AddBarIcon(g, x, x + 24, 24, "BackgroundFFFFFF c000000")      ; icon of the current encoding, just left of the name box
    x += 24
    App.nameCtl := g.Add("Text", "x" . x . " y3 w86 h18 +0x200 +0x100 BackgroundFFFFFF c000000", "  " . CurrentName())
    App.nameCtl.SetFont("s8", "Segoe UI")
    App.nameCtl.OnEvent("Click", ShowLayoutMenu)
    arrow := g.Add("Picture", "x" . (x + 86) . " y3 w18 h18", d . "arrow.png")
    arrow.OnEvent("Click", ShowLayoutMenu)
    x += 108
    g.Add("Text", "x" . x . " y4 w1 h16 Background" . sepC)
    bSet := AddPicBtn(g, d, "settings", x + 4, 4, 16, 16)          ; settings button, same size as minimize
    bSet.OnEvent("Click", ShowSettings)
    x += 24
    g.Add("Text", "x" . x . " y4 w1 h16 Background" . sepC)
    bMin := AddPicBtn(g, d, "min", x + 4, 4, 16, 16)               ; smaller than the close button
    bMin.OnEvent("Click", HideBar)
    x += 24
    g.Add("Text", "x" . x . " y4 w1 h16 Background" . sepC)
    bClose := AddPicBtn(g, d, "close", x + 4, 2, 20, 20)
    bClose.OnEvent("Click", CloseBar)
    bClose.OnEvent("DoubleClick", CloseBar)
    g.OnEvent("Close", BarCloseEvent)
    barW := x + 28
    bgPic.Move(, , barW, 24)
    return barW
}

; the bar picture of "Ekushey BN" with ONE extra button (the normal case). It is also kept inside this script, so if the file is
; missing (e.g. only BanglaKeyboard.ahk was copied) it is written again; the 2-button picture is the last resort.
BarBgOne(d) {
    static b64 := "iVBORw0KGgoAAAANSUhEUgAAAOcAAAAYCAYAAAABMOrsAAABAklEQVR42u3bsQ2DMBBG4T8SBROwhAs6KjdswGSsRMMCdEhMAGIF7lKlIyXxSXnfApFsP86ylNc4jn4chwDE0TSNKjPTuq6sBhDIvu+qzvPUtm2sBhBI13Wq3F1m9vMfX5aFHQikbVsWIdq1tlSckjTPM7sQQM652BnAPXcvG6ck9X3PThQ0TZMkESdxIirOQMA4zUzXdbEaf44zEO9jyeQEk5NrLYgTxAniJE4QJx6LkwchSDwIRfxYMjnB5ORaC+IEcYI4iRPEicfi5EEIEg9CET+WTE4wObnW3vv8KwLEiUBx5pzZBeJEtDjrumYHgMjXWgBf4kwpaRgGVgMIJKWkNzjjBRBMrpiDAAAAAElFTkSuQmCC"
    f := d . "bar_bg_one.png"
    if FileExist(f)
        return "bar_bg_one.png"
    try {
        n := 0
        DllCall("Crypt32\CryptStringToBinaryW", "str", b64, "uint", 0, "uint", 1, "ptr", 0, "uint*", &n, "ptr", 0, "ptr", 0)
        buf := Buffer(n)
        DllCall("Crypt32\CryptStringToBinaryW", "str", b64, "uint", 0, "uint", 1, "ptr", buf, "uint*", &n, "ptr", 0, "ptr", 0)
        h := FileOpen(f, "w")
        h.RawWrite(buf, n)
        h.Close()
        return "bar_bg_one.png"
    }
    return "bar_bg.png"
}

; Re-create the bar (used when the colour theme or style changes)
RebuildBar() {
    if App.rebuilding {                    ; another click / event came in while the bar is being built: never build two at once,
        App.rebuildAgain := true           ; just remember it and do it once more when the running one is finished
        return
    }
    App.rebuilding := true                 ; also keeps UpdateBar away from the half-built bar
    vis := true
    try {
        Loop {
            App.rebuildAgain := false
            if IsObject(App.bar) {
                if (A_Index = 1)
                    vis := (DllCall("IsWindowVisible", "ptr", App.bar.Hwnd) != 0)
                old := App.bar
                App.bar := 0                   ; detach first: while the old window is being destroyed, mouse/hover messages
                App.hov := []                  ; must not find a dead Gui in App.bar (that was the "Gui has no window" error)
                App.hovCur := 0
                try old.Destroy()
            }
            BuildBar()
            if !App.rebuildAgain
                break
        }
    } finally
        App.rebuilding := false
    UpdateBar()
    if !vis
        App.bar.Hide()
    SyncTray()
}

StyleIds() {
    ; the two Default styles first, the rest in alphabetical order of their names (see StyleLabels); values saved in the settings file
    return ["Classic", "ClassicExt", "BanglaKb", "GreenBangla", "PurpleRaised", "EkusheBN", "AeroDark", "EkusheDark"]
}

StyleLabels() {
    names := Map("Classic", "Default Bar", "ClassicExt", "Default", "BanglaKb", "Bangla", "GreenBangla", "Bijoy Bayanno"
        , "PurpleRaised", "Bijoy Ekattor", "EkusheBN", "Ekushey", "AeroDark", "Ekushey New", "EkusheDark", "Ekushey Old")
    a := []
    for id in StyleIds()
        a.Push(names[id] . (IsExtStyle(id) ? " [+]" : ""))        ; [+] = this style has the extra buttons you can set up
    return a
}

; the styles that have the extra buttons
IsExtStyle(id) {
    return (id = "ClassicExt" || id = "EkusheBN" || id = "BanglaKb") ? true : false
}

; the styles drawn from the colour themes (the others use their own pictures)
UsesTheme(id) {
    return (id = "Classic" || id = "ClassicExt") ? true : false
}

StyleIndex(id) {
    for i, v in StyleIds()
        if (v = id)
            return i
    return 1
}

ApplyStyle(name) {
    if (StyleIds()[StyleIndex(name)] != name)
        return
    App.style := name
    RebuildBar()
}

ApplyTheme(name) {
    if !Themes().Has(name)
        return
    App.theme := name
    RebuildBar()
}

PointOnScreen(x, y) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (x >= l && x < r && y >= t && y < b)
            return true
    }
    return false
}

BarMouseDown(wParam, lParam, msg, hwnd) {
    if (IsObject(App.bar) && hwnd = App.bar.Hwnd)
        PostMessage(0xA1, 2, 0, , "ahk_id " . hwnd)     ; WM_NCLBUTTONDOWN + HTCAPTION = drag the window
}

BarMoved(wParam, lParam, msg, hwnd) {
    if (IsObject(App.bar) && hwnd = App.bar.Hwnd) {
        WinGetPos(&x, &y, , , "ahk_id " . hwnd)
        SaveSetting("Bar", "X", x)
        SaveSetting("Bar", "Y", y)
        App.barX := x
        App.barY := y
    }
}

ShowBar(*) {
    App.bar.Show("NoActivate")
    KeepOnTop()
    SyncTray()
}

; Keeps the bar above every other window. The "always on top" flag alone is not enough: any other topmost
; window that gets activated later (or a window that raises itself) ends up above the bar. So the bar is put back
; on top right after every window change and by a light timer; nothing happens while it is already first.
KeepOnTop(*) {
    if (!App.onTop || !IsObject(App.bar) || App.menuPrev)       ; (not while the layout menu is open)
        return
    try {
        h := App.bar.Hwnd
        if !DllCall("IsWindowVisible", "Ptr", h)
            return
        if DllCall("GetWindow", "Ptr", h, "UInt", 3, "Ptr")      ; GW_HWNDPREV: some window is above the bar
            DllCall("SetWindowPos", "Ptr", h, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x213)   ; HWND_TOPMOST, no move / size / activate
    }
}

HideBar(*) {
    App.bar.Hide()
    SyncTray()                  ; icon appears in the tray now
    if !App.tipShown {
        App.tipShown := true
        TrayTip("Still running in the tray. Double-click the tray icon to bring the bar back.", "Bangla Keyboard")
    }
}

GiveFocusBack(hwnd) {
    if (hwnd && hwnd != App.bar.Hwnd && WinExist("ahk_id " . hwnd))
        try WinActivate("ahk_id " . hwnd)
}

UpdateBar() {
    if (!IsObject(App.bar) || App.rebuilding)
        return
    try App.nameCtl.Text := "  " . CurrentName()     ; (a bar that was just replaced is skipped; RebuildBar updates the new one)
    try {
        App.pic.Value := PicSpec()
    } catch {
        try App.pic.Text := IconBadge()
    }
}

ShowLayoutMenu(*) {
    m := Menu()
    if IsShown("English")
        m.Add("English", SetLayout.Bind(0))
    for i, L in App.layouts {
        if IsShown("L:" . L.name)
            m.Add(L.name, SetLayout.Bind(i))
    }
    try m.Check(CurrentName())
    if (App.style = "BanglaKb") {                  ; this style has a settings button, so only About is added here
        m.Add()
        m.Add("About...", ShowAbout)
    }
    App.nameCtl.GetPos(&cx, &cy, , &ch)
    WinGetClientPos(&wx, &wy, , , "ahk_id " . App.bar.Hwnd)
    prev := WinExist("A")
    App.menuPrev := prev
    WinActivate("ahk_id " . App.bar.Hwnd)          ; lets the menu close when you click elsewhere
    m.Show(wx + cx, wy + cy + ch)
    App.menuPrev := 0
    GiveFocusBack(prev)
}

; ---- every way of closing (bar [x], tray "Exit", Alt+F4) ends up here ----------------
; Asks first when "Confirm before closing" is ticked in Settings.
BarCloseEvent(*) {
    CloseBar()
    return true                                  ; never let Windows destroy the bar by itself
}

CloseBar(*) {
    static asking := false
    if App.confirmClose {
        if asking
            return
        asking := true
        r := MsgBox("Close Bangla Keyboard?`n`nBangla typing will stop until you start it again.", "Bangla Keyboard", 0x40124)   ; Yes/No + question icon + No is default + on top
        asking := false
        if (r != "Yes")
            return
    }
    ExitApp()
}

; ---- About window ------------------------------------------------------------------------------------------------
; Opened from the tray menu (just above Exit) and from the layout menu of the "Bangla [+]" bar.
ShowAbout(*) {
    if IsObject(App.about) {
        try {
            App.about.Show()
            return
        }
        App.about := ""
    }
    DllCall("LoadLibrary", "Str", "Msftedit.dll")                  ; the rich text (RichEdit 5) control
    g := Gui("+AlwaysOnTop -MinimizeBox", "About Bangla Keyboard")
    g.MarginX := 10
    g.MarginY := 10
    g.SetFont("s9", "Segoe UI")

    ; top: the name, the version and the credit, starting at the left edge (a small rich text box that looks like part of the window)
    head := AboutRich(g, "x18 y8 w488 h92", false)
    AboutSetRtf(head, AboutHeadRtf())

    ; three tabs, each one a rich text box with its own scroll bar (it appears when the text is longer than the box)
    tb := g.Add("Tab3", "x10 y106 w496 h352 +0x400", ["About", "Keyboard", "Tools"])      ; 0x400 = all tabs the same width
    for k, rtf in [AboutRtfApp(), AboutRtfKeyboard(), AboutRtfTools()] {
        tb.UseTab(k)
        e := AboutRich(g, "x18 y138 w480 h312", true)
        AboutSetRtf(e, rtf)
    }
    tb.UseTab()
    ok := g.Add("Button", "x416 y468 w90 h28 Default", "OK")
    ok.OnEvent("Click", AboutClose)
    g.OnEvent("Close", AboutClose)
    g.OnEvent("Escape", AboutClose)
    App.about := g
    g.Show("w516")
    tb.GetPos(, , &tw)                                              ; the three tabs share the whole width
    SendMessage(0x1329, 0, (Round(24 * A_ScreenDPI / 96) << 16) | ((tw - 8) // 3), tb)      ; TCM_SETITEMSIZE
    ok.Focus()
}

; a read-only RichEdit box. boxed = white page with a border and a vertical scroll bar; otherwise it takes the window colour
AboutRich(g, opt, boxed) {
    style := " +0x4 +0x40 +0x800"                                   ; multi-line, auto-scroll, read-only
    if boxed
        style .= " +0x200000 +0x10000 +E0x200"                      ; vertical scroll bar, tab stop, sunken edge
    e := g.Add("Custom", "ClassRICHEDIT50W " . opt . style)
    SendMessage(0x443, 0, boxed ? 0xFFFFFF : DllCall("GetSysColor", "Int", 15, "UInt"), e)      ; EM_SETBKGNDCOLOR
    SendMessage(0xD3, 3, 10 | (10 << 16), e)                        ; EM_SETMARGINS: 10 px left and right
    return e
}

AboutSetRtf(ed, rtf) {
    n := StrPut(rtf, "CP1252")
    b := Buffer(n, 0)
    StrPut(rtf, b, n, "CP1252")
    st := Buffer(8, 0)                                              ; SETTEXTEX: flags = 0 (replace all), code page 1252
    NumPut("UInt", 0, st, 0)
    NumPut("UInt", 1252, st, 4)
    SendMessage(0x461, st.Ptr, b.Ptr, ed)                           ; EM_SETTEXTEX (the text is RTF)
    SendMessage(0xB1, 0, 0, ed)                                     ; nothing selected, shown from the top
}

; ---- tiny rich text writer: the text of each tab is a list of lines
;   "# Title"   a green heading      "* text"  a bullet      "1| text"  a numbered step      anything else  a paragraph
;   **word**    makes word bold
RtfOpen() {
    return "{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss\fcharset0 Segoe UI;}}"
        . "{\colortbl;\red0\green110\blue60;\red110\green110\blue110;}\f0\fs19 "
}

RtfEsc(s) {
    out := ""
    Loop Parse, s {
        c := Ord(A_LoopField)
        if (A_LoopField = "\" || A_LoopField = "{" || A_LoopField = "}")
            out .= "\" . A_LoopField
        else if (c > 127)
            out .= "\u" . (c > 32767 ? c - 65536 : c) . "?"
        else
            out .= A_LoopField
    }
    return out
}

RtfInline(s) {
    out := ""
    for i, part in StrSplit(s, "**")
        out .= (Mod(i, 2) = 0) ? "{\b " . RtfEsc(part) . "}" : RtfEsc(part)
    return out
}

RtfPage(lines) {
    r := RtfOpen()
    for ln in lines {
        txt := SubStr(ln, 3)
        if (SubStr(ln, 1, 2) = "# ")
            r .= "\pard\sb180\sa70\keepn{\b\fs22\cf1 " . RtfEsc(txt) . "}\par"
        else if (SubStr(ln, 1, 2) = "* ")
            r .= "\pard\li330\fi-220\sa50\tx330 \u8226?\tab " . RtfInline(txt) . "\par"
        else if RegExMatch(ln, "^(\d)\| (.*)$", &m)
            r .= "\pard\li330\fi-290\sa50\tx330 " . m[1] . ".\tab " . RtfInline(m[2]) . "\par"
        else
            r .= "\pard\sa80 " . RtfInline(ln) . "\par"
    }
    return r . "}"
}

AboutHeadRtf() {
    return RtfOpen()
        . "\pard\sa70{\b\fs36\cf1 Bangla Keyboard}{\fs20\cf2   Version " . RtfEsc(App.version) . "}\par"
        . "\pard\sa0 " . RtfInline("The idea of this application is inspired by existing Bangla keyboards, but its design, functionality and features are designed by **Sherlock Holmes** (nickname), with the assistance of AI.") . "\par}"
}

AboutRtfApp() {
    return RtfPage([
        "# What is Bangla Keyboard?",
        "A small, fast Bijoy-style typing tool for Windows. It lets you type Bangla in any program, stays out of your way as a thin bar and a tray icon, and needs no installer.",
        "# What it offers",
        "* **Type anywhere**: works in any Windows program, no clipboard needed.",
        "* **Three layouts**: Bijoy Classic, Bijoy Unicode and UniBijoy, plus any layout you add or build.",
        "* **Quick switching**: one click or a shortcut key toggles English and Bangla.",
        "* **Automatic fonts**: the font follows the layout in Word, Excel, PowerPoint, Outlook, WPS Office and LibreOffice Writer.",
        "* **Your own look**: eight bar styles, colour themes, adjustable icon size and a tray icon.",
        "* **Extra tools**: document and text converters, a layout builder and a small note editor (see the Tools tab).",
        "# Credits",
        "The idea is inspired by existing Bangla keyboards. The design, functionality and features are designed by **Sherlock Holmes** (nickname), with the assistance of AI.",
        "# Good to know",
        "* Free and open source (GNU GPL v3). It is not sold, so please do not sell or repackage it.",
        "* No paid or licensed fonts are included. Please get any fonts you need legally.",
        "* Skins and artwork are for personal, non-commercial use. All names and trademarks belong to their owners; this project is not affiliated with them.",
        "* Your settings are saved in %AppData%\Bangla Keyboard, so updates never erase them."
    ])
}

AboutRtfKeyboard() {
    return RtfPage([
        "# Getting started",
        "1| Pick a layout from the bar's drop-down list (or press its shortcut key) and start typing.",
        "2| Click the tray icon to switch between English and your last Bangla layout.",
        "3| Double-click the tray icon to show or hide the bar. Right-click it for layouts, tools, Settings, About and Exit.",
        "# Fonts",
        "* Bijoy Classic (ANSI) needs a matching ANSI font such as SutonnyMJ, which you must get yourself.",
        "* The Unicode layouts work with fonts like Nirmala UI, which comes with Windows.",
        "# Customize it (Settings, from the tray menu or the bar)",
        "* **General**: bar style, colour theme, icon size, start with Windows, always on top, splash screen, tray icon, close confirmation and the two extra tool buttons.",
        "* **Shortcuts**: give every layout and tool its own shortcut key, or restore the defaults.",
        "* **Fonts**: turn on automatic font change for Office programs, and set up to 10 manual font shortcuts.",
        "* **Mode switching**: one mode for all windows, or let each program remember its own.",
        "* Nothing is saved until you press Save. Each tab has its own Reset button.",
        "# Add more layouts",
        "Drop a .xml or .bkl layout file into the Layouts folder and restart, or build one with the Layout Builder. If a .bkl and a .xml share a name, the .bkl is used."
    ])
}

AboutRtfTools() {
    return RtfPage([
        "# Included tools",
        "They live in the Tools folder. Open them from the tray menu, or put them on the bar's extra buttons (Settings > General). Any .ahk or .exe you drop into Tools also appears in the tray menu.",
        "* **Docs Converter**: converts Word and PowerPoint documents (and text files) between older ANSI fonts such as Bijoy and Unicode. You choose which fonts to convert, and the original file is never changed.",
        "* **Text Converter**: two boxes. Type or paste in either one and the other updates at once.",
        "* **Layout Builder**: builds and edits keyboard layouts (.xml), with a Try it tab to test them.",
        "* **Quick Note**: a small rich-text editor for writing Bangla, with an automatic recovery draft.",
        "# Good to know",
        "* The converters read their mapping tables from Tools\Encodings (Bijoy V1, Bijoy V2 and Proshika)."
    ])
}

AboutClose(*) {
    try App.about.Destroy()
    App.about := ""
}

; ---- shortcut key box ---------------------------------------------------------
; Replaces Windows' own Hotkey control, which refuses some combinations (Ctrl+Alt+Z for one) and puts the old
; value back when the keys are released. While the box has the focus, every key combination is recorded the moment
; it is pressed and stays until another one is pressed. Backspace / Delete on their own clear it.
; Tab, Enter and Esc keep their normal job (moving around / closing the window), so they cannot be recorded.
class KeyBox {
    static ih := ""             ; the key recorder: it only exists while a box has the focus
    static cur := ""            ; the box that is recording
    hk := ""                    ; recorded shortcut in hotkey text, e.g. "^!z"
    ctl := ""
    onChange := ""              ; optional: called after a key was recorded or cleared by the person

    __New(g, opts) {
        this.ctl := g.Add("Edit", opts . " ReadOnly Center BackgroundWhite")
        this.ctl.OnEvent("Focus", KeyBoxBegin.Bind(this))
        this.ctl.OnEvent("LoseFocus", KeyBoxEnd.Bind(this))
    }

    Value {
        get => this.hk
        set {
            this.hk := value
            this.ctl.Value := (value = "") ? "" : PrettyHk(value)
        }
    }

    Enabled {
        get => this.ctl.Enabled
        set => this.ctl.Enabled := value
    }
}

KeyBoxBegin(box, *) {
    KeyBoxEnd()
    ih := InputHook()
    ih.KeyOpt("{All}", "NS")                                       ; see every key, and keep it away from the window
    ih.KeyOpt("{Tab}{Enter}{Esc}{LCtrl}{RCtrl}{LAlt}{RAlt}{LShift}{RShift}", "-S")   ; these must keep working normally
    ih.OnKeyDown := KeyBoxDown.Bind(box)
    ih.Start()
    KeyBox.ih := ih
    KeyBox.cur := box
}

; box = "" stops whichever box is recording; otherwise only that box
KeyBoxEnd(box := "", *) {
    if (IsObject(box) && !(IsObject(KeyBox.cur) && ObjPtr(KeyBox.cur) = ObjPtr(box)))
        return
    if IsObject(KeyBox.ih)
        try KeyBox.ih.Stop()
    KeyBox.ih := ""
    KeyBox.cur := ""
}

KeyBoxDown(box, ih, vk, sc) {
    if (vk = 0xE7 || (vk >= 0x10 && vk <= 0x12) || (vk >= 0xA0 && vk <= 0xA5) || vk = 0x5B || vk = 0x5C)
        return                                                     ; text typed by this program, or a modifier key on its own
    if !(IsObject(App.dlg) && WinActive("ahk_id " . App.dlg.Hwnd)) {
        KeyBoxEnd()                                                ; never keep the keyboard captured outside the Settings window
        return
    }
    if (vk = 0x09 || vk = 0x0D || vk = 0x1B)
        return
    mods := (GetKeyState("Ctrl", "P") ? "^" : "") . (GetKeyState("Alt", "P") ? "!" : "") . (GetKeyState("Shift", "P") ? "+" : "")
    if (mods = "" && (vk = 0x08 || vk = 0x2E))
        box.Value := ""                                            ; Backspace / Delete
    else
        box.Value := mods . KeyBoxName(vk, sc)
    if IsObject(box.onChange)
        try box.onChange.Call()
}

; letters and digits as themselves, named keys by name (F5, Insert ...), anything else as its key code
KeyBoxName(vk, sc) {
    n := GetKeyName(Format("vk{:X}sc{:03X}", vk, sc))
    if (n = "")
        return Format("vk{:X}", vk)
    if (StrLen(n) = 1)
        return RegExMatch(n, "i)^[a-z0-9]$") ? StrLower(n) : Format("vk{:X}", vk)
    return n
}

; ---- settings window (one page) ----------------------------------------------
ShowSettings(*) {
    if IsObject(App.dlg) {
        try App.dlg.Show()
        return
    }
    prev := WinExist("A")
    if !App.scrollHooked {                         ; the scroll bar of the Settings window (only used when the window is very tall)
        OnMessage(0x115, SettingsVScroll)          ; WM_VSCROLL
        OnMessage(0x20A, SettingsWheel)            ; WM_MOUSEWHEEL
        App.scrollHooked := true
    }
    UnregisterShortcuts()        ; so pressing a shortcut inside the key boxes records it instead of running it

    g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "Bangla Keyboard - Settings")
    g.SetFont("s9", "Segoe UI")
    g.MarginX := 6
    g.MarginY := 6
    st := {g: g, prev: prev, rows: [], saved: false, origTheme: App.theme, origStyle: App.style, origIconSize: App.iconSize, scrolling: false, sy: 0, vh: 0, content: 0, orig: Map(), pinned: Map(), barOn: false, origExt: [App.ext[1].on, App.ext[2].on]}

    ; three tabs: General | Shortcuts | Fonts - every tab is split into two sections (group boxes)
    acts := ActionList()
    nA := 0
    nR := 0
    for a in acts {
        if (SubStr(a.id, 1, 2) = "R:")
            nR++
        else
            nA++
    }
    g1 := 32                                                       ; top of the first section on every tab
    gh1 := 143                                                     ; General: section heights
    gh2 := 154
    gh3 := 56                                                      ; General: the two extra-button rows (only shown for the "Ext" styles)
    genEnd := g1 + gh1 + 4 + gh2 + 4 + gh3
    sh1 := 25 * nA + 17                                            ; Shortcuts: layouts + toggle | Tools folder
    sh2 := 25 * Max(1, nR) + 17
    scEnd := g1 + sh1 + 4 + sh2
    fh1 := 27 * (App.layouts.Length + 1) + 41                      ; Fonts: automatic change | manual shortcuts
    fh2 := 38                                                      ; Fonts: manual shortcuts section while only its check box shows (slots appear as they are used: see FontsLayout)
    fontEnd := g1 + fh1 + 4 + fh2
    tabBottom := Max(genEnd, scEnd, fontEnd) + 12
    tab := g.Add("Tab3", "x6 y6 w316 h" . (tabBottom - 12), ["General", "Shortcuts", "Fonts"])
    st.tab := tab
    st.g1 := g1
    st.fh1 := fh1
    st.baseEnd := tabBottom - 12                                   ; the tallest the window needs apart from the manual font slots
    st.bottom := tabBottom
    st.nVis := -1
    st.manualShown := ""

    ; ---------- General ----------
    tab.UseTab(1)
    g.Add("GroupBox", "x14 y" . g1 . " w300 h" . gh1)
    st.cbStart := g.Add("Checkbox", "x22 y" . (g1 + 10), "Start with Windows")
    st.cbStart.Value := IsAutoStart() ? 1 : 0
    st.cbTop := g.Add("Checkbox", "x22 y" . (g1 + 31), "Keep the bar on top of other windows")
    st.cbTop.Value := App.onTop ? 1 : 0
    st.cbMin := g.Add("Checkbox", "x22 y" . (g1 + 52), "Start with the top bar minimized (in the tray)")
    st.cbMin.Value := App.startMin ? 1 : 0
    st.cbConfirm := g.Add("Checkbox", "x22 y" . (g1 + 73), "Confirm before closing")
    st.cbConfirm.Value := App.confirmClose ? 1 : 0
    st.cbTray := g.Add("Checkbox", "x22 y" . (g1 + 94), "Always show the tray icon")
    st.cbTray.Value := App.trayAlways ? 1 : 0
    st.cbTips := g.Add("Checkbox", "x22 y" . (g1 + 115), "Show tooltips (a hint on every option)")
    st.cbTips.Value := App.tips ? 1 : 0

    g2 := g1 + gh1 + 4
    g.Add("GroupBox", "x14 y" . g2 . " w300 h" . gh2)
    st.cbSplash := g.Add("Checkbox", "x22 y" . (g2 + 14) . " w100 h22", "Splash screen:")    ; ticked = show the splash, unticked = off (and the time box is greyed out)
    st.cbSplash.Value := App.splashOn ? 1 : 0
    st.ddSplash := g.Add("DropDownList", "x122 y" . (g2 + 12) . " w182 Choose" . Min(5, Max(1, Round(App.splashMs / 1000))), ["1 second", "2 seconds", "3 seconds", "4 seconds", "5 seconds"])
    st.ddSplash.Enabled := (st.cbSplash.Value = 1)
    st.cbSplash.OnEvent("Click", (*) => st.ddSplash.Enabled := (st.cbSplash.Value = 1))

    g.Add("Text", "x22 y" . (g2 + 42) . " w100 h22 +0x200", "TopBar color:")
    st.ddTheme := g.Add("DropDownList", "x122 y" . (g2 + 40) . " w182", ThemeNames())
    try st.ddTheme.Choose(App.theme)
    st.ddTheme.OnEvent("Change", (*) => ApplyTheme(st.ddTheme.Text))      ; live preview, Cancel puts it back

    g.Add("Text", "x22 y" . (g2 + 70) . " w100 h22 +0x200", "TopBar style:")
    st.ddStyle := g.Add("DropDownList", "x122 y" . (g2 + 68) . " w182 Choose" . StyleIndex(App.style), StyleLabels())
    st.ddStyle.OnEvent("Change", (*) => PreviewStyle(st))             ; live preview, Cancel puts it back
    st.ddTheme.Enabled := UsesTheme(App.style)                        ; colours only apply to the Default styles

    g.Add("Text", "x22 y" . (g2 + 98) . " w100 h22 +0x200", "Mode switching:")
    st.ddMode := g.Add("DropDownList", "x122 y" . (g2 + 96) . " w182 Choose" . (App.perWin ? 2 : 1), ["Global (All Windows)", "Per Application/Window"])

    g.Add("Text", "x22 y" . (g2 + 126) . " w100 h22 +0x200", "Icon size:")
    st.ddIcon := g.Add("DropDownList", "x122 y" . (g2 + 124) . " w182 Choose" . App.iconSize, IconSizeLabels())
    st.ddIcon.OnEvent("Change", (*) => PreviewIconSize(st))           ; live preview, Cancel puts it back

    ; extra buttons: tick a button to show it on the bar, then pick which Tools program it starts, and its icon
    g3 := g2 + gh2 + 4
    st.ext := []
    st.extFiles := ToolFiles()
    exAct := ["(None)"]
    for f in st.extFiles
        exAct.Push(f.name)
    exIco := ExtIconNames()
    st.extDD := []
    Loop 2 {
        bn := A_Index
        ry := g3 + 4 + (bn - 1) * 26
        b := App.ext[bn]
        ia := 1
        for k, f in st.extFiles {
            if (f.full = b.act)
                ia := k + 1
        }
        ii := 1
        for k, nm in exIco {
            if (nm = b.icon)
                ii := k
        }
        cb := g.Add("Checkbox", "x22 y" . ry . " w74 h22", "Button " . bn . ":")
        cb.Value := b.on ? 1 : 0
        cb.OnEvent("Click", ToggleExt.Bind(st, bn))
        dA := g.Add("DropDownList", "x98 y" . ry . " w116 Choose" . ia, exAct)
        dI := g.Add("DropDownList", "x218 y" . ry . " w88 Choose" . ii, exIco)
        SendMessage(0x160, 170, 0, dI.Hwnd)          ; CB_SETDROPPEDWIDTH: the open list is wider than the box, so the names fit
        st.ext.Push(cb, dA, dI)
        st.extDD.Push({on: cb, act: dA, icon: dI})
    }
    SyncExtRows(st)

    ; ---------- Shortcuts ----------
    tab.UseTab(2)
    sg2 := g1 + sh1 + 4
    g.Add("GroupBox", "x14 y" . g1 . " w300 h" . sh1)
    g.Add("GroupBox", "x14 y" . sg2 . " w300 h" . sh2)
    yA := g1 + 12
    yR := sg2 + 12
    if (nR = 0)
        g.Add("Text", "x22 y" . (yR + 2) . " w284", "No .exe / .ahk files found in the Tools folder.")
    for a in acts {
        isR := (SubStr(a.id, 1, 2) = "R:")
        y := isR ? yR : yA
        row := {id: a.id, label: a.label, def: a.def, dshow: isR ? 0 : 1, cb: "", hk: "", clr: ""}
        g.Add("Text", "x22 y" . y . " w98 h22 +0x200", StrReplace(a.label, "&", "&&"))
        row.hk := KeyBox(g, "x122 y" . y . " w96 h22")
        row.cb := g.Add("Checkbox", "x224 y" . y . " w20 h22")           ; every row has a tick box: unticked = no shortcut
        row.cb.Value := App.shown.Get(a.id, !isR) ? 1 : 0
        row.clr := g.Add("Button", "x248 y" . y . " w56 h22", "Clear")
        LoadRow(row, App.shortcuts.Get(a.id, ""))
        row.clr.OnEvent("Click", ClearRow.Bind(row))
        row.cb.OnEvent("Click", SyncRow.Bind(row))
        SyncRow(row)
        st.rows.Push(row)
        if isR
            yR += 25
        else
            yA += 25
    }

    ; ---------- Fonts ----------
    tab.UseTab(3)
    g.Add("GroupBox", "x14 y" . g1 . " w300 h" . fh1)
    fg2 := g1 + fh1 + 4
    st.grp2 := g.Add("GroupBox", "x14 y" . fg2 . " w300 h" . fh2)
    st.cbFont := g.Add("Checkbox", "x22 y" . (g1 + 10) . " w282", "Change the font automatically (Office apps)")
    st.cbFont.Value := App.fontOn ? 1 : 0
    st.frows := []
    fl := []
    try fl := InstalledFonts()
    fy := g1 + 38
    fkeys := []
    for L in App.layouts
        fkeys.Push(L.name)
    fkeys.Push("English")
    for k in fkeys {
        c := App.fonts.Get(k)
        row := {key: k}
        row.cb := g.Add("Checkbox", "x22 y" . fy . " w98 h22", k)
        row.cb.Value := c.on ? 1 : 0
        row.font := g.Add("ComboBox", "x122 y" . (fy - 1) . " w132 r10", fl)
        row.font.Text := c.font
        row.size := g.Add("ComboBox", "x258 y" . (fy - 1) . " w52 r10", ["Auto", "8", "9", "10", "11", "12", "14", "16", "18", "20", "24", "28", "36"])
        row.size.Text := c.size ? c.size : "Auto"
        row.cb.OnEvent("Click", SyncFontRows.Bind(st))
        st.frows.Push(row)
        fy += 27
    }
    st.cbFont.OnEvent("Click", SyncFontRows.Bind(st))
    SyncFontRows(st)

    ; manual font shortcuts: tick the box, then give each slot its own key (Ctrl / Alt / Win + key), font and size.
    ; Only one slot shows at first; the next one appears when the last one is filled (up to FontSlotCount()).
    st.cbManual := g.Add("Checkbox", "x22 y" . (fg2 + 10) . " w282", "Manual font shortcuts (Office apps)")
    st.cbManual.Value := App.manualOn ? 1 : 0
    st.slots := []
    sy := fg2 + 36
    Loop FontSlotCount() {
        row := {}
        row.hk := KeyBox(g, "x22 y" . sy . " w84 h22")
        row.hk.onChange := SlotChanged.Bind(st)
        row.win := g.Add("Checkbox", "x110 y" . sy . " w42 h22", "Win")
        row.font := g.Add("ComboBox", "x154 y" . sy . " w100 r10", fl)
        SendMessage(0x160, 220, 0, row.font)               ; CB_SETDROPPEDWIDTH: the font list is wider than the box
        row.size := g.Add("ComboBox", "x258 y" . sy . " w52 r10", ["Auto", "8", "9", "10", "11", "12", "14", "16", "18", "20", "24", "28", "36"])
        row.font.OnEvent("Change", SlotChanged.Bind(st))
        LoadSlotRow(row, App.slots[A_Index])
        st.slots.Push(row)
        sy += 27
    }
    st.cbManual.OnEvent("Click", ManualToggle.Bind(st))
    SyncSlotRows(st)
    tab.OnEvent("Change", (*) => (tab.Value = 3) ? FontsLayout(st, false, true) : 0)   ; keep unused slots hidden after a tab switch

    tab.UseTab()                                  ; the buttons below belong to the window, not a tab
    by := tabBottom
    st.panel := g.Add("Text", "x0 y0 w1 h1 Hidden")         ; covers whatever scrolls behind the buttons while the scroll bar is on
    ; bottom-left: Reset (whichever tab is showing) | Save | Cancel; the window is exactly as wide as the tab (316)
    bReset := g.Add("Button", "x6 y" . by . " w100", "Reset")
    bReset.OnEvent("Click", ResetTab.Bind(st, tab))
    bSave := g.Add("Button", "x114 y" . by . " w100 Default", "Save")
    bCancel := g.Add("Button", "x222 y" . by . " w100", "Cancel")
    bSave.OnEvent("Click", SaveSettingsDlg.Bind(st))
    bCancel.OnEvent("Click", DlgClose.Bind(st))
    g.OnEvent("Close", DlgClose.Bind(st))
    g.OnEvent("Escape", DlgClose.Bind(st))
    st.bReset := bReset
    st.bSave := bSave
    st.bCancel := bCancel
    st.pinned := Map(st.panel.Hwnd, 1, bReset.Hwnd, 1, bSave.Hwnd, 1, bCancel.Hwnd, 1)    ; these stay in place when the rest scrolls
    FontsLayout(st, true)                          ; show only the manual font slots that are in use
    AddSettingsTips(st)                            ; hover hints (switched on / off by the "Show tooltips" box)
    SetTimer(TipPoll, 120)
    App.dlg := g
    App.dlgSt := st
    g.Show()

    ; make the three tabs split the full tab width equally (done after Show so the size sticks)
    tab.Opt("+0x400 -0x200")                                         ; TCS_FIXEDWIDTH on, TCS_MULTILINE off (so tabs never wrap into two rows)
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", tab.Hwnd, "Ptr", rc)
    tw := NumGet(rc, 8, "Int")
    ir := Buffer(16, 0)
    SendMessage(0x130A, 0, ir, tab)                                 ; TCM_GETITEMRECT: keep the current tab height
    th := NumGet(ir, 12, "Int") - NumGet(ir, 4, "Int")
    if (th < 10)
        th := 24
    ; the widest tab that still fits on one row, so the last tab ends right at the edge of the page
    ; (a fixed "minus 10" used to leave a small gap there); never narrower than that old size
    lo := (tw - 10) // 3
    w := tw // 3
    while (w > lo) {
        SendMessage(0x1329, 0, ((th & 0xFFFF) << 16) | (w & 0xFFFF), tab)     ; TCM_SETITEMSIZE
        DllCall("RedrawWindow", "Ptr", tab.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
        if TabRowFits(tab, tw)
            break
        w--
    }
    SendMessage(0x1329, 0, ((th & 0xFFFF) << 16) | (w & 0xFFFF), tab)
    tab.Redraw()
    SettingsFit(st)                                                  ; a scroll bar if the window is taller than 900 px / the screen
}

; true while the tabs fit on one row: the last tab ends inside the control and no scroll arrows have appeared
TabRowFits(tab, tw) {
    ir := Buffer(16, 0)
    SendMessage(0x130A, 2, ir, tab)                                 ; TCM_GETITEMRECT of the last tab
    if (NumGet(ir, 8, "Int") > tw)
        return false
    ud := DllCall("FindWindowEx", "Ptr", tab.Hwnd, "Ptr", 0, "Str", "msctls_updown32", "Ptr", 0, "Ptr")
    return !(ud && DllCall("IsWindowVisible", "Ptr", ud))
}

; ---- Fonts tab: the manual font slots show one at a time ----------------------------------------------------------
; Nothing shows until "Manual font shortcuts" is ticked. Slot 1 shows first; the next slot appears when the last
; visible one has both a shortcut and a font, up to FontSlotCount(). A slot with anything in it stays visible.
VisibleSlots(st) {
    last := 0
    done := 0
    for i, r in st.slots {
        k := (r.hk.Value != "")
        f := (Trim(r.font.Text) != "")
        if (k || f)
            last := i
        if (k && f)
            done := i
    }
    return Min(FontSlotCount(), Max(1, last, done + 1))
}

SlotChanged(st, *) {
    FontsLayout(st)
}

ManualToggle(st, *) {
    SyncSlotRows(st)
    FontsLayout(st)
}

; shows / hides the slots and makes the group box, the tab and the window just as tall as needed
FontsLayout(st, init := false, force := false) {
    on := (st.cbManual.Value = 1)
    n := on ? VisibleSlots(st) : 0
    if (!init && !force && n = st.nVis && on = st.manualShown)
        return
    st.nVis := n
    st.manualShown := on
    for i, r in st.slots {
        v := (i <= n)
        if (init && v)                                              ; the Fonts page is not showing yet: it shows these itself
            continue
        r.hk.ctl.Visible := v
        r.win.Visible := v
        r.font.Visible := v
        r.size.Visible := v
    }
    fh2 := on ? 27 * n + 39 : 38
    st.grp2.Move(, , , fh2)
    bottom := Max(st.baseEnd, st.g1 + st.fh1 + 4 + fh2) + 12
    if (bottom = st.bottom)
        return
    SettingsUnfit(st)                                ; back to the flat layout before anything is moved
    st.bottom := bottom
    st.tab.Move(, , , bottom - 12)
    st.bReset.Move(, bottom)
    st.bSave.Move(, bottom)
    st.bCancel.Move(, bottom)
    if !init
        SettingsFit(st)
}

; ---- scroll bar of the Settings window (it appears when the window would be taller than 900 px) ---------------------------------------
; The window is as tall as its content, but never taller than 900 px or than the screen. When the content needs more, the window gets a
; vertical scroll bar (mouse wheel works too): the tabs scroll, the Reset / Save / Cancel buttons stay in view at the bottom.
; (All sizes here are in the same units as the rest of the window code; only the scroll bar itself works in real screen pixels.)

; the tallest the window may be (client area), screen-aware
SettingsMaxHeight(g, dpi) {
    cap := 900
    try {
        hmon := DllCall("MonitorFromWindow", "ptr", g.Hwnd, "uint", 2, "ptr")
        mi := Buffer(40, 0)
        NumPut("uint", 40, mi, 0)
        DllCall("GetMonitorInfo", "ptr", hmon, "ptr", mi)
        waH := NumGet(mi, 32, "int") - NumGet(mi, 24, "int")                  ; height of the work area (without the task bar)
        frame := DllCall("GetSystemMetrics", "int", 4) + 2 * (DllCall("GetSystemMetrics", "int", 33) + DllCall("GetSystemMetrics", "int", 92)) + 12
        cap := Min(cap, (waH - frame) / dpi)
    }
    return Max(300, cap)
}

SettingsFit(st) {
    g := st.g
    SettingsUnfit(st)                                ; measure the flat layout first
    g.Show("AutoSize")
    g.GetClientPos(, , &cw, &ch)
    dpi := A_ScreenDPI / 96
    cap := SettingsMaxHeight(g, dpi)
    if (ch <= cap)
        return                                       ; fits: no scroll bar
    st.bReset.GetPos(, , , &bh)
    st.vh := cap - bh - 12                           ; the scrolling part; the buttons sit below it
    st.content := st.bottom
    st.orig := Map()
    for h, c in g {
        c.GetPos(&x, &y)
        st.orig[h] := [x, y]
    }
    st.panel.Move(0, st.vh, cw, cap - st.vh)
    st.panel.Visible := true
    for b in [st.bReset, st.bSave, st.bCancel]
        b.Move(, st.vh + 6)
    st.scrolling := true
    st.sy := 0
    SettingsBar(st, true)
    sbw := DllCall("GetSystemMetrics", "int", 2) / dpi                         ; the scroll bar takes room from the client area
    g.Show("Center w" . Round(cw + sbw) . " h" . Round(cap))
    SettingsClip(st)
    DllCall("RedrawWindow", "ptr", g.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x185)
}

; Cut every scrolled control off at the top of the button strip (with a window region), so nothing can paint over the buttons.
; clear = true puts every control back to its full shape.
SettingsClip(st, on := true) {
    g := st.g
    limit := Round(st.vh * A_ScreenDPI / 96)
    rc := Buffer(16, 0)
    for h, c in g {
        if st.pinned.Has(h)
            continue
        if !on {
            DllCall("SetWindowRgn", "ptr", h, "ptr", 0, "int", 0)
            continue
        }
        DllCall("GetWindowRect", "ptr", h, "ptr", rc)
        DllCall("MapWindowPoints", "ptr", 0, "ptr", g.Hwnd, "ptr", rc, "uint", 2)       ; the control's place in the window
        top := NumGet(rc, 4, "int")
        wd := NumGet(rc, 8, "int") - NumGet(rc, 0, "int")
        ht := NumGet(rc, 12, "int") - top
        room := limit - top                          ; how much of the control is above the button strip
        if (room >= ht) {
            DllCall("SetWindowRgn", "ptr", h, "ptr", 0, "int", 0)
        } else {
            rgn := DllCall("CreateRectRgn", "int", 0, "int", 0, "int", wd, "int", Max(0, room), "ptr")
            DllCall("SetWindowRgn", "ptr", h, "ptr", rgn, "int", 0)
        }
    }
}

; leave scrolling mode: everything back in its place, buttons below the tabs, no scroll bar
SettingsUnfit(st) {
    if !st.scrolling
        return
    SettingsScrollTo(st, 0, false)
    SettingsClip(st, false)
    SettingsBar(st, false)
    st.panel.Visible := false
    st.panel.Move(0, 0, 1, 1)
    for b in [st.bReset, st.bSave, st.bCancel]
        b.Move(, st.bottom)
    st.scrolling := false
}

SettingsBar(st, on) {
    hwnd := st.g.Hwnd
    if !on {
        DllCall("ShowScrollBar", "ptr", hwnd, "int", 1, "int", 0)
        st.barOn := false
        return
    }
    dpi := A_ScreenDPI / 96
    si := Buffer(28, 0)
    NumPut("uint", 28, "uint", 7, "int", 0, "int", Round(st.content * dpi) - 1, "uint", Round(st.vh * dpi), "int", Round(st.sy * dpi), si)   ; SIF_RANGE | SIF_PAGE | SIF_POS
    DllCall("SetScrollInfo", "ptr", hwnd, "int", 1, "ptr", si, "int", 1)
    if !st.barOn {
        DllCall("ShowScrollBar", "ptr", hwnd, "int", 1, "int", 1)
        st.barOn := true
    }
}

; scroll to y (0 = top). Every control is put at its original place minus y, so nothing drifts.
SettingsScrollTo(st, y, bar := true) {
    if !st.scrolling
        return
    y := Round(Max(0, Min(y, st.content - st.vh)))
    if (y = st.sy)
        return
    g := st.g
    SendMessage(0xB, 0, 0, g)                        ; WM_SETREDRAW off while moving
    for h, c in g {
        if (st.pinned.Has(h) || !st.orig.Has(h))
            continue
        o := st.orig[h]
        c.Move(o[1], o[2] - y)
    }
    SendMessage(0xB, 1, 0, g)
    SettingsClip(st)
    DllCall("RedrawWindow", "ptr", g.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x185)
    st.sy := y
    if bar
        SettingsBar(st, true)
}

SettingsVScroll(wParam, lParam, msg, hwnd) {
    st := App.dlgSt
    if (!IsObject(st) || !st.scrolling || hwnd != st.g.Hwnd || lParam != 0)
        return
    dpi := A_ScreenDPI / 96
    code := wParam & 0xFFFF
    n := st.sy
    bar := true
    switch code {
        case 0: n := st.sy - 24                      ; SB_LINEUP
        case 1: n := st.sy + 24                      ; SB_LINEDOWN
        case 2: n := st.sy - st.vh + 24              ; SB_PAGEUP
        case 3: n := st.sy + st.vh - 24              ; SB_PAGEDOWN
        case 4, 5:                                   ; thumb dragged / released
            si := Buffer(28, 0)
            NumPut("uint", 28, "uint", 0x10, si)     ; SIF_TRACKPOS
            DllCall("GetScrollInfo", "ptr", hwnd, "int", 1, "ptr", si)
            n := NumGet(si, 24, "int") / dpi
            bar := (code = 4)
        case 6: n := 0
        case 7: n := st.content
        default: return
    }
    SettingsScrollTo(st, n, bar)
    return 0
}

SettingsWheel(wParam, lParam, msg, hwnd) {
    st := App.dlgSt
    if (!IsObject(st) || !st.scrolling)
        return
    if (DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr") != st.g.Hwnd)    ; only for this window and its controls
        return
    delta := (wParam >> 16) & 0xFFFF
    if (delta > 32767)
        delta -= 65536
    SettingsScrollTo(st, st.sy - Round(delta / 120 * 48))
    return 0
}

; ---- "Reset": puts the tab that is showing back to its defaults (nothing is saved until you press Save) ----
ResetTab(st, tab, *) {
    if (tab.Value = 1)
        ResetGeneralTab(st)
    else if (tab.Value = 2)
        ResetShortcutRows(st)
    else
        ResetFontsTab(st)
}

ResetGeneralTab(st) {
    st.cbStart.Value := 0
    st.cbTop.Value := 1
    st.cbMin.Value := 0
    st.cbConfirm.Value := 1
    st.cbTray.Value := 1
    st.cbTips.Value := 1
    st.cbSplash.Value := 1
    st.ddSplash.Choose(2)
    st.ddSplash.Enabled := true
    st.ddMode.Choose(1)
    st.ddIcon.Choose(1)
    st.ddTheme.Choose("DarkGreen")
    st.ddStyle.Choose(StyleIndex("GreenBangla"))
    st.ddTheme.Enabled := UsesTheme("GreenBangla")
    for k, r in st.extDD {
        r.on.Value := (k = 1) ? 1 : 0                  ; default: button 1 on, button 2 off
        App.ext[k].on := (k = 1)
        r.act.Choose(1)
        r.icon.Choose(2)                               ; 1 = (None), 2 = App icon (the default)
    }
    SyncExtRows(st)
    App.theme := "DarkGreen"
    ApplyStyle("GreenBangla")                      ; live preview (Cancel puts the old look back)
}

ResetFontsTab(st) {
    st.cbFont.Value := 0
    for r in st.frows {
        isEng := (r.key = "English")
        r.cb.Value := isEng ? 1 : 0
        r.font.Text := isEng ? "Arial" : ""
        r.size.Text := "Auto"
    }
    SyncFontRows(st)
    st.cbManual.Value := 0
    for r in st.slots {
        r.hk.Value := ""
        r.win.Value := 0
        r.font.Text := ""
        r.size.Text := "Auto"
    }
    SyncSlotRows(st)
    FontsLayout(st)
}

; the extra-button rows are only there while an "Ext" style is picked
; ---------------------------------------------------------------------------
;  Hover hints for the Settings window: rest the mouse on an option and a small tooltip explains it.
;  Controls and their text are listed in AddSettingsTips; TipPoll shows the one under the mouse.
;  Turn them off with "Show tooltips" (General tab).
; ---------------------------------------------------------------------------
SetTip(st, ctl, text) {
    if IsObject(ctl)
        st.tips[ctl.Hwnd] := text
}

AddSettingsTips(st) {
    st.tips := Map()
    SetTip(st, st.cbStart, "Starts Bangla Keyboard by itself when you sign in to Windows.")
    SetTip(st, st.cbTop, "Keeps the top bar above other windows, so it is never hidden behind them.")
    SetTip(st, st.cbMin, "The program starts hidden in the tray instead of showing the top bar.`nClick the tray icon to bring the bar back.")
    SetTip(st, st.cbConfirm, "Asks `"are you sure?`" before the program closes.")
    SetTip(st, st.cbTray, "Keeps the tray icon visible all the time.`nUnticked, it only shows while the top bar is minimized.")
    SetTip(st, st.cbTips, "Shows a hint like this one when you rest the mouse on an option.`nUntick to turn the hints off.")
    SetTip(st, st.cbSplash, "Shows a picture when the program starts.`nPictures come from the Splash folder: Static Splash`nplus the Length(s) folder that matches the seconds set here.")
    SetTip(st, st.ddSplash, "How long the splash stays.`nOnly GIFs in the matching Length(s) folder (e.g. Length(s) 2)`nand pictures in Static Splash are used.")
    SetTip(st, st.ddTheme, "Colours of the top bar (Default styles only).`nYou see it at once; Cancel puts it back.")
    SetTip(st, st.ddStyle, "The look of the top bar.`nYou see it at once; Cancel puts it back.")
    SetTip(st, st.ddMode, "Global: one typing mode for every window.`nPer Application/Window: each window remembers its own mode.")
    SetTip(st, st.ddIcon, "Size of the icon on the top bar. You see it at once.`nCustom bar icon: put a .png or .ico in the Icons folder, named like`nthe layout (e.g. Unicode.png). A .png is used before a .ico.`nEnglish uses English.png / English.ico.")
    for k, r in st.extDD {
        onTip := "Tick to show extra button 2 on the top bar (Ext styles only)."
        if (k = 1)
            onTip := "Extra button 1 on the top bar (Ext styles only). It is always on."
        SetTip(st, r.on, onTip)
        SetTip(st, r.act, "The program or script from the Tools folder that button " . k . " starts.`nChoose (None) to leave the button empty.")
        SetTip(st, r.icon, "The icon of button " . k . ". Pick (None) for an empty button, a built-in symbol, or your own picture:`nput a .png / .ico / .jpg / .bmp / .gif in Skins\Button Icons,`nreopen Settings, then choose its file name here.")
    }
    for row in st.rows {
        lbl := StrReplace(row.label, "&", "")
        SetTip(st, row.hk.ctl, "Click here, then press the keys you want for `"" . lbl . "`".")
        SetTip(st, row.cb, "Tick to use this shortcut. Untick to switch it off.")
        SetTip(st, row.clr, "Removes the shortcut of `"" . lbl . "`".")
    }
    SetTip(st, st.cbFont, "Changes the font by itself in Office apps when you switch typing mode,`nusing the fonts chosen below.")
    for row in st.frows {
        SetTip(st, row.cb, "Use the font on this row when typing " . row.key . ".")
        SetTip(st, row.font, "Font for " . row.key . ". Pick one or type its name.")
        SetTip(st, row.size, "Font size for " . row.key . ", or Auto to leave the size as it is.")
    }
    SetTip(st, st.cbManual, "Your own keys that apply a chosen font and size in Office apps.`nTick it, then fill a slot: a key, the font and the size.")
    for row in st.slots {
        SetTip(st, row.hk.ctl, "Click here, then press the key you want for this font.")
        SetTip(st, row.win, "Tick to add the Windows key to this shortcut.")
        SetTip(st, row.font, "The font this key applies.")
        SetTip(st, row.size, "The size this key applies, or Auto to leave the size as it is.")
    }
    SetTip(st, st.bReset, "Puts the options of this tab back to their defaults.`nNothing is kept until you press Save.")
    SetTip(st, st.bSave, "Saves all changes and closes Settings.")
    SetTip(st, st.bCancel, "Closes Settings without saving. Live previews are undone.")
}

; runs while Settings is open: after the mouse rests ~0.6 s on an option with a hint, the hint shows next to the mouse
TipPoll() {
    static last := 0, since := 0, shown := false
    txt := ""
    st := App.dlgSt
    if (IsObject(st) && st.HasProp("tips") && st.cbTips.Value = 1) {
        MouseGetPos(, , &win, &ctl, 2)
        if (win = App.dlg.Hwnd) {
            h := IsInteger(ctl) ? ctl : 0
            Loop 3 {
                if (!h || h = win)
                    break
                if st.tips.Has(h) {
                    txt := st.tips[h]
                    break
                }
                h := DllCall("GetParent", "Ptr", h, "Ptr") || 0
            }
            if (h != last) {
                last := h
                since := A_TickCount
                if shown {
                    ToolTip(, , , 19)
                    shown := false
                }
            }
        } else
            last := 0
    }
    if (txt = "") {
        if shown {
            ToolTip(, , , 19)
            shown := false
        }
        if !IsObject(st)
            last := 0
        return
    }
    if (!shown && A_TickCount - since >= 600) {
        ToolTip(txt, , , 19)
        shown := true
    }
}

SyncExtRows(st) {
    on := IsExtStyle(StyleFromDD(st))
    for c in st.ext
        c.Visible := on
    for k, r in st.extDD {
        r.act.Enabled := (k = 1 || r.on.Value = 1)     ; button 2's boxes are greyed out until it is ticked
        r.icon.Enabled := (k = 1 || r.on.Value = 1)
    }
}

; the tick box of extra button i: the bar changes at once (Cancel puts it back)
ToggleExt(st, i, *) {
    if (i = 1) {                                       ; button 1 cannot be switched off
        st.extDD[1].on.Value := 1
        return
    }
    App.ext[i].on := (st.extDD[i].on.Value = 1)
    SyncExtRows(st)
    if IsExtStyle(App.style)
        RebuildBar()
}

; the "Icon size" box: the bar is drawn again at once (Cancel puts it back)
PreviewIconSize(st) {
    App.iconSize := Max(1, st.ddIcon.Value)
    RebuildBar()
}

StyleFromDD(st) {
    return StyleIds()[Max(1, st.ddStyle.Value)]
}

PreviewStyle(st) {
    ApplyStyle(StyleFromDD(st))
    st.ddTheme.Enabled := UsesTheme(App.style)
    SyncExtRows(st)
}

DlgClose(st, *) {
    SetTimer(TipPoll, 0)
    ToolTip(, , , 19)
    KeyBoxEnd()
    undoExt := false
    if !st.saved {
        for i, o in st.origExt {
            if (App.ext[i].on != o) {
                App.ext[i].on := o
                undoExt := true
            }
        }
    }
    if (!st.saved && App.iconSize != st.origIconSize) {
        App.iconSize := st.origIconSize                ; undo the live icon-size preview
        RebuildBar()
    }
    if (!st.saved && App.style != st.origStyle)
        ApplyStyle(st.origStyle)                       ; undo the live style preview
    if (!st.saved && App.theme != st.origTheme)
        ApplyTheme(st.origTheme)                       ; undo the live colour preview
    if (undoExt && IsExtStyle(App.style))
        RebuildBar()                                   ; undo the live extra-buttons preview
    try App.dlg.Destroy()
    App.dlg := ""
    App.dlgSt := ""
    ApplyShortcuts()
    GiveFocusBack(st.prev)
}

; one shortcut row <-> hotkey text
LoadRow(row, hk) {
    row.hk.Value := ""
    if (hk != "") {
        p := SplitHk(hk)
        row.hk.Value := StrReplace(p.mods, "#", "") . p.key
    }
}

ClearRow(row, *) {
    LoadRow(row, "")
}

; an unticked row is greyed out
SyncRow(row, *) {
    on := (!IsObject(row.cb) || row.cb.Value = 1)
    row.hk.Enabled := on
    row.clr.Enabled := on
}

RowHotkey(row) {
    return row.hk.Value
}

ResetShortcutRows(st, *) {
    for row in st.rows {
        LoadRow(row, row.def)
        if IsObject(row.cb) {
            row.cb.Value := row.dshow
            SyncRow(row)
        }
    }
}

; returns "" when fine, otherwise a message for the person
ValidateShortcuts(st, keys) {
    seen := Map()
    shownLayouts := 0
    for r in st.rows {
        if (SubStr(r.id, 1, 2) = "L:" && r.cb.Value = 1)
            shownLayouts++
    }
    if (shownLayouts = 0)
        return "Keep at least one Bangla layout ticked."
    for r in st.rows {
        if (IsObject(r.cb) && r.cb.Value = 0)
            continue                                  ; hidden items have no active shortcut
        hk := keys[r.id]
        if (hk = "")
            continue
        p := SplitHk(hk)
        if (!InStr(p.mods, "^") && !InStr(p.mods, "!")) {
            if !RegExMatch(p.key, "i)^(F\d+|Insert|AppsKey|PrintScreen)$")
                return r.label . ": " . PrettyHk(hk) . " would also be typed as a normal key.`nAdd Ctrl or Alt, or use an F-key."
        }
        k := StrLower(PrettyHk(hk))
        if seen.Has(k)
            return "The shortcut " . PrettyHk(hk) . " is used twice:`n" . seen[k] . "  and  " . r.label
        seen[k] := r.label
    }
    return ""
}

; ---- save ---------------------------------------------------------------------
SaveSettingsDlg(st, *) {
    newMap := Map()
    for r in st.rows
        newMap[r.id] := RowHotkey(r)
    err := ValidateShortcuts(st, newMap)
    if (err != "") {
        MsgBox(err, "Bangla Keyboard", "0x30 Owner" . st.g.Hwnd)
        return
    }

    err := ValidateFonts(st)
    if (err != "") {
        MsgBox(err, "Bangla Keyboard", "0x30 Owner" . st.g.Hwnd)
        return
    }

    err := ValidateManual(st, newMap)
    if (err != "") {
        MsgBox(err, "Bangla Keyboard", "0x30 Owner" . st.g.Hwnd)
        return
    }

    perWin := (st.ddMode.Value = 2)

    SetAutoStart(st.cbStart.Value)
    App.onTop := (st.cbTop.Value = 1)
    try App.bar.Opt(App.onTop ? "+AlwaysOnTop" : "-AlwaysOnTop")
    if App.onTop
        KeepOnTop()
    if (st.ddTheme.Text != App.theme)
        ApplyTheme(st.ddTheme.Text)
    SaveSetting("General", "AlwaysOnTop", App.onTop ? 1 : 0)
    SaveSetting("General", "Theme", App.theme)
    extChanged := false
    for k, r in st.extDD {
        on := (k = 1 || r.on.Value = 1)
        act := (r.act.Value <= 1) ? "" : st.extFiles[r.act.Value - 1].full
        ico := r.icon.Text
        if (on != App.ext[k].on || act != App.ext[k].act || ico != App.ext[k].icon)
            extChanged := true
        App.ext[k].on := on
        App.ext[k].act := act
        App.ext[k].icon := ico
        SaveSetting("ExtButtons", "Button" . k . ".Enabled", on ? 1 : 0)
        SaveSetting("ExtButtons", "Button" . k . ".Action", act)
        SaveSetting("ExtButtons", "Button" . k . ".Icon", ico)
    }
    if (Max(1, st.ddIcon.Value) != App.iconSize) {
        App.iconSize := Max(1, st.ddIcon.Value)
        RebuildBar()
    }
    SaveSetting("General", "IconPx", IconSizes()[App.iconSize])
    if (StyleFromDD(st) != App.style)
        ApplyStyle(StyleFromDD(st))
    else if (extChanged && IsExtStyle(App.style))
        RebuildBar()                                   ; the buttons of the bar changed
    SaveSetting("General", "BarStyle", App.style)
    App.splashOn := (st.cbSplash.Value = 1)
    SaveSetting("General", "ShowSplash", App.splashOn ? 1 : 0)
    App.splashMs := st.ddSplash.Value * 1000
    SaveSetting("General", "SplashSeconds", st.ddSplash.Value)
    App.startMin := (st.cbMin.Value = 1)
    SaveSetting("General", "StartMinimized", App.startMin ? 1 : 0)
    App.confirmClose := (st.cbConfirm.Value = 1)
    SaveSetting("General", "ConfirmClose", App.confirmClose ? 1 : 0)
    App.trayAlways := (st.cbTray.Value = 1)
    SaveSetting("General", "TrayAlways", App.trayAlways ? 1 : 0)
    App.tips := (st.cbTips.Value = 1)
    SaveSetting("General", "ShowTips", App.tips ? 1 : 0)
    SyncTray()

    if (perWin != App.perWin) {
        App.winModes := Map()
        if perWin {
            if IsBindable(st.prev)
                App.curWin := st.prev
            if App.curWin
                App.winModes[App.curWin] := App.cur      ; this window keeps its current mode
        }
        App.perWin := perWin
    }
    SaveSetting("General", "ModeSwitching", perWin ? "PerWindow" : "Global")
    if IsObject(App.eng)
        App.eng.Reset()

    wasOn := App.fontOn
    SaveFontSettings(st)
    SaveManualSettings(st)
    if (App.fontOn && !wasOn && !App.perWin) {        ; the Fonts feature was just switched on: this window and mode become the starting point
        if IsBindable(st.prev)
            App.curWin := st.prev
        if (App.curWin && IsFontApp(App.curWin))
            App.winModes[App.curWin] := App.cur
        else
            App.globMode := App.cur
    }
    if !App.fontOn
        App.fontCom := Map()

    App.shortcuts := newMap
    for id, hk in newMap
        SaveSetting("Shortcuts", IniKey(id), (hk = "") ? "none" : hk)

    newShown := Map()
    for r in st.rows
        newShown[r.id] := IsObject(r.cb) ? (r.cb.Value = 1) : true
    App.shown := newShown
    for id, v in newShown
        SaveSetting("Shown", IniKey(id), v ? 1 : 0)
    FixLastBn()
    BuildTrayMenu()
    if (App.cur > 0 && !IsShown("L:" . App.layouts[App.cur].name))
        SetLayout(0)                                  ; the layout in use was just hidden

    st.saved := true
    DlgClose(st)
    RefreshUI()
    if App.fontOn
        FontKick(300)                                 ; the window gets focus back first, then the font is checked
}

; ---------------------------------------------------------------------------
;  Fonts: automatic font change in Office apps (Settings > Fonts)
;  Nothing runs in the background. The font is checked only when you switch layout, switch to an Office window,
;  start typing after a pause, or move the cursor - and only while one of these apps is the active window:
;  Word / Excel / PowerPoint, Outlook (mail editor), WPS Office (Writer / Spreadsheets / Presentation) and
;  LibreOffice / OpenOffice Writer. They are driven through COM (LibreOffice through its UNO bridge);
;  the font is never changed while text is selected.
; ---------------------------------------------------------------------------
LoadFonts() {
    App.fontOn := (IniRead(App.ini, "Fonts", "Enabled", "0") = "1")
    App.fonts := Map()
    keys := []
    for L in App.layouts
        keys.Push(L.name)
    keys.Push("English")
    for k in keys {
        isEng := (k = "English")
        sz := IniRead(App.ini, "Fonts", k . ".Size", "0")
        App.fonts[k] := {on: (IniRead(App.ini, "Fonts", k . ".On", isEng ? "1" : "0") = "1")
            , font: IniRead(App.ini, "Fonts", k . ".Font", isEng ? "Arial" : "")
            , size: (IsInteger(sz) && sz >= 4 && sz <= 400) ? Integer(sz) : 0
            , keep: IniRead(App.ini, "Fonts", k . ".Keep", "")}      ; Keep = extra fonts to leave alone, e.g. Keep=SolaimanLipi, Nikosh
    }
}

ValidateFonts(st) {
    for r in st.frows {
        if (r.cb.Value != 1)
            continue
        if (Trim(r.font.Text) = "")
            return "Pick a font for " . r.key . ", or untick it."
        sz := Trim(r.size.Text)
        if (sz != "" && sz != "Auto" && !(IsInteger(sz) && sz >= 4 && sz <= 400))
            return "The size for " . r.key . " must be Auto or a number from 4 to 400."
    }
    return ""
}

SaveFontSettings(st) {
    App.fontOn := (st.cbFont.Value = 1)
    SaveSetting("Fonts", "Enabled", App.fontOn ? 1 : 0)
    for r in st.frows {
        sz := Trim(r.size.Text)
        c := App.fonts[r.key]
        c.on := (r.cb.Value = 1)
        c.font := Trim(r.font.Text)
        c.size := IsInteger(sz) ? Integer(sz) : 0
        SaveSetting("Fonts", r.key . ".On", c.on ? 1 : 0)
        SaveSetting("Fonts", r.key . ".Font", c.font)
        SaveSetting("Fonts", r.key . ".Size", c.size)
    }
}

SyncFontRows(st, *) {
    all := (st.cbFont.Value = 1)
    for r in st.frows {
        r.cb.Enabled := all
        e := all && r.cb.Value = 1
        r.font.Enabled := e
        r.size.Enabled := e
    }
}

; ---- manual font shortcuts (Settings > Fonts) --------------------------------
FontSlotCount() {
    return 10
}

LoadManualFonts() {
    App.manualOn := (IniRead(App.ini, "FontShortcuts", "Enabled", "0") = "1")
    App.slots := []
    Loop FontSlotCount() {
        n := "Slot" . A_Index
        sz := IniRead(App.ini, "FontShortcuts", n . ".Size", "0")
        App.slots.Push({key: IniRead(App.ini, "FontShortcuts", n . ".Key", "")
            , font: IniRead(App.ini, "FontShortcuts", n . ".Font", "")
            , size: (IsInteger(sz) && sz >= 4 && sz <= 400) ? Integer(sz) : 0})
    }
}

SaveManualSettings(st) {
    App.manualOn := (st.cbManual.Value = 1)
    SaveSetting("FontShortcuts", "Enabled", App.manualOn ? 1 : 0)
    for i, r in st.slots {
        sl := App.slots[i]
        sz := Trim(r.size.Text)
        sl.key := (r.hk.Value = "") ? "" : (r.win.Value = 1 ? "#" : "") . r.hk.Value
        sl.font := Trim(r.font.Text)
        sl.size := IsInteger(sz) ? Integer(sz) : 0
        SaveSetting("FontShortcuts", "Slot" . i . ".Key", sl.key)
        SaveSetting("FontShortcuts", "Slot" . i . ".Font", sl.font)
        SaveSetting("FontShortcuts", "Slot" . i . ".Size", sl.size)
    }
}

; returns "" when fine, otherwise a message for the person
ValidateManual(st, keys) {
    if (st.cbManual.Value != 1)
        return ""
    seen := Map()
    for r in st.rows {
        if (IsObject(r.cb) && r.cb.Value = 0)
            continue
        hk := keys[r.id]
        if (hk != "")
            seen[StrLower(PrettyHk(hk))] := r.label
    }
    for i, r in st.slots {
        label := "Font shortcut " . i
        fnt := Trim(r.font.Text)
        if (r.hk.Value = "") {
            if (fnt != "")
                return label . ": press a key in the shortcut box, or clear the font."
            continue
        }
        if (fnt = "")
            return label . ": pick a font, or clear the shortcut."
        sz := Trim(r.size.Text)
        if (sz != "" && sz != "Auto" && !(IsInteger(sz) && sz >= 4 && sz <= 400))
            return label . ": the size must be Auto or a number from 4 to 400."
        hk := (r.win.Value = 1 ? "#" : "") . r.hk.Value
        p := SplitHk(hk)
        if (!InStr(p.mods, "^") && !InStr(p.mods, "!") && !InStr(p.mods, "#")) {
            if !RegExMatch(p.key, "i)^(F\d+|Insert|AppsKey|PrintScreen)$")
                return label . ": " . PrettyHk(hk) . " would also be typed as a normal key.`nAdd Ctrl, Alt or Win, or use an F-key."
        }
        k := StrLower(PrettyHk(hk))
        if seen.Has(k)
            return "The shortcut " . PrettyHk(hk) . " is used twice:`n" . seen[k] . "  and  " . label
        seen[k] := label
    }
    return ""
}

LoadSlotRow(row, sl) {
    row.win.Value := InStr(sl.key, "#") ? 1 : 0
    row.hk.Value := ""
    p := SplitHk(sl.key)
    if (p.key != "")
        row.hk.Value := StrReplace(p.mods, "#", "") . p.key
    row.font.Text := sl.font
    row.size.Text := sl.size ? sl.size : "Auto"
}

SyncSlotRows(st, *) {
    on := (st.cbManual.Value = 1)
    for r in st.slots {
        r.hk.Enabled := on
        r.win.Enabled := on
        r.font.Enabled := on
        r.size.Enabled := on
    }
}

; The shortcut of a slot was pressed: put that font on the cursor / selection of the active Office window.
; Works whether or not the automatic font change is on.
FontManual(i, *) {
    sl := App.slots[i]
    if (sl.font = "")
        return
    hwnd := WinExist("A")
    if !hwnd
        return
    try p := StrLower(WinGetProcessName("ahk_id " . hwnd))
    catch
        return
    apps := FontApps()
    if !apps.Has(p)
        return
    ctx := {font: sl.font, size: sl.size, uni: FontHasBengali(sl.font)}
    done := false
    for pair in apps[p] {
        Loop 2 {                                         ; 2nd try = fresh connection
            try {
                office := FontCom(pair[1], A_Index = 2)
                if RegExMatch(pair[1], "i)^(Word|KWPS)\.")
                    done := FontSetWord(office, ctx)
                else if RegExMatch(pair[1], "i)^(Excel|KET)\.")
                    done := FontSetExcel(office, ctx)
                else if RegExMatch(pair[1], "i)^Outlook\.")
                    done := FontSetOutlook(office, ctx)
                else if RegExMatch(pair[1], "i)^com\.sun\.star\.")
                    done := FontSetLO(office, ctx)
                else
                    done := FontSetPpt(office, ctx)
                break
            } catch {
                if App.fontCom.Has(pair[1])
                    App.fontCom.Delete(pair[1])
            }
        }
        if done
            break
    }
    if done
        App.manualHold := hwnd
    if !App.fontOn
        App.fontCom := Map()                             ; nothing else needs the Office connection
}

FontSetWord(office, ctx) {
    f := office.Selection.Font
    f.Name := ctx.font
    try f.NameAscii := ctx.font
    try f.NameOther := ctx.font
    if ctx.uni
        try f.NameBi := ctx.font
    if ctx.size {
        f.Size := ctx.size
        if ctx.uni
            try f.SizeBi := ctx.size
    }
    return true
}

FontSetExcel(office, ctx) {
    f := office.Selection.Font
    f.Name := ctx.font
    if ctx.size
        f.Size := ctx.size
    return true
}

FontSetPpt(office, ctx) {
    sel := office.ActiveWindow.Selection
    if (sel.Type = 3)
        f := sel.TextRange.Font
    else if (sel.Type = 2)
        f := sel.ShapeRange.TextFrame.TextRange.Font
    else
        return false
    f.Name := ctx.font
    try f.NameAscii := ctx.font
    try f.NameOther := ctx.font
    if ctx.uni
        try f.NameComplexScript := ctx.font
    if ctx.size
        f.Size := ctx.size
    return true
}

; every installed font family (only built while the Settings window opens)
InstalledFonts() {
    seen := Map()
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    lf := Buffer(92, 0)                                 ; LOGFONTW
    NumPut("UChar", 1, lf, 23)                          ; DEFAULT_CHARSET = all families
    cb := CallbackCreate(FontEnumProc, , 4)
    try DllCall("gdi32\EnumFontFamiliesExW", "Ptr", hdc, "Ptr", lf, "Ptr", cb, "Ptr", ObjPtr(seen), "UInt", 0)
    CallbackFree(cb)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    s := ""
    for n in seen
        s .= n . "`n"
    return StrSplit(Sort(RTrim(s, "`n"), "U"), "`n")
}

FontEnumProc(lpelfe, lpntme, fontType, lParam) {
    seen := ObjFromPtrAddRef(lParam)
    n := StrGet(lpelfe + 28, 32, "UTF-16")              ; LOGFONTW.lfFaceName
    if (n != "" && SubStr(n, 1, 1) != "@")
        seen[n] := 1
    return 1
}

; does this font contain Bengali letters? (tests the letter KA) - tells Unicode fonts from ANSI ones
FontHasBengali(name) {
    static cache := Map()
    if cache.Has(name)
        return cache[name]
    ok := false
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    hf := DllCall("gdi32\CreateFontW", "Int", -16, "Int", 0, "Int", 0, "Int", 0, "Int", 400, "UInt", 0, "UInt", 0, "UInt", 0
        , "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 4, "UInt", 0, "WStr", name, "Ptr")
    if hf {
        old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hf, "Ptr")
        ch := Buffer(2, 0)
        NumPut("UShort", 0x0995, ch)
        gi := Buffer(2, 0)
        r := DllCall("gdi32\GetGlyphIndicesW", "Ptr", hdc, "Ptr", ch, "Int", 1, "Ptr", gi, "UInt", 1, "UInt")   ; 1 = mark missing glyphs
        ok := (r = 1 && NumGet(gi, 0, "UShort") != 0xFFFF)
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
        DllCall("DeleteObject", "Ptr", hf)
    }
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    cache[name] := ok
    return ok
}

; a layout whose keys type Bengali letters is a Unicode layout; otherwise it is an ANSI (Bijoy Classic style) layout
LayoutIsUnicode(L) {
    static cache := Map()
    if cache.Has(L.name)
        return cache[L.name]
    uni := false
    for m in [L.nor, L.sh] {
        for vk, t in m {
            if RegExMatch(t, "[\x{0980}-\x{09FF}]") {
                uni := true
                break
            }
        }
        if uni
            break
    }
    cache[L.name] := uni
    return uni
}

; process name -> [COM name, handler] list
FontApps() {
    static m := Map(
        "winword.exe", [["Word.Application", FontDoWord]],
        "excel.exe", [["Excel.Application", FontDoExcel]],
        "powerpnt.exe", [["PowerPoint.Application", FontDoPpt]],
        "outlook.exe", [["Outlook.Application", FontDoOutlook]],
        "wps.exe", [["KWPS.Application", FontDoWord], ["KET.Application", FontDoExcel], ["KWPP.Application", FontDoPpt]],
        "et.exe", [["KET.Application", FontDoExcel]],
        "wpp.exe", [["KWPP.Application", FontDoPpt]],
        "soffice.bin", [["com.sun.star.ServiceManager", FontDoLO]],
        "soffice.exe", [["com.sun.star.ServiceManager", FontDoLO]])
    return m
}

IsFontApp(hwnd) {
    if (!App.fontOn || !hwnd)
        return false
    try p := StrLower(WinGetProcessName("ahk_id " . hwnd))
    catch
        return false
    return FontApps().Has(p)
}

FontKick(ms := 80) {
    App.fontDirty := true
    SetTimer(FontApply, -ms)
}

FontApply(*) {
    Critical "On"
    App.fontDirty := false
    try FontApplyNow()                                   ; never let a font problem interrupt typing or show an error box
}

FontApplyNow() {
    if !App.fontOn
        return
    hwnd := WinExist("A")
    if !IsFontApp(hwnd)
        return
    if (hwnd = App.manualHold)                           ; a manual font shortcut was used here: keep that font
        return
    isEng := (App.cur = 0)
    cfg := App.fonts.Get(isEng ? "English" : App.layouts[App.cur].name, "")
    if (!IsObject(cfg) || !cfg.on)
        return
    key := isEng ? "English" : App.layouts[App.cur].name
    fnt := isEng ? cfg.font : App.userFont.Get(hwnd . "|" . key, cfg.font)      ; the font you were using here before wins over the default
    ctx := {cfg: cfg, eng: isEng, uni: (!isEng && LayoutIsUnicode(App.layouts[App.cur])), hwnd: hwnd, key: key
        , font: fnt, size: (fnt = cfg.font) ? cfg.size : 0}
    for pair in FontApps()[StrLower(WinGetProcessName("ahk_id " . hwnd))] {
        done := false
        Loop 2 {                                         ; 2nd try = fresh connection (the old one may be stale)
            try {
                office := FontCom(pair[1], A_Index = 2)
                done := pair[2](office, ctx)
                break
            } catch {
                if App.fontCom.Has(pair[1])
                    App.fontCom.Delete(pair[1])
            }
        }
        if done
            break
    }
}

FontCom(progid, fresh := false) {
    if (!fresh && App.fontCom.Has(progid))
        return App.fontCom[progid]
    o := RegExMatch(progid, "i)^com\.sun\.star\.") ? ComObject(progid) : ComObjActive(progid)     ; LibreOffice / OpenOffice: through the UNO bridge
    App.fontCom[progid] := o
    return o
}

FontAccepted(cur, ctx) {
    for f in StrSplit(ctx.cfg.keep, ",", " ") {
        if (f != "" && f = cur)
            return true
    }
    if ctx.eng
        return !RegExMatch(cur, "i)MJ$") && !App.ansiSeen.Has(cur)      ; English: anything except an ANSI font
    if ctx.uni
        return FontHasBengali(cur)                       ; Unicode: any font that has Bengali letters
    return RegExMatch(cur, "i)MJ$") ? true : false       ; ANSI: SutonnyMJ, SutonnyOMJ ...
}

; Is a font change needed? A font you picked yourself is left alone:
; it is only replaced when it is the document's default font (nothing chosen yet), or one this program set itself.
FontNeedsChange(ctx, cur, defFn) {
    cur := Trim(cur)
    if (cur != "" && (cur = ctx.font || FontAccepted(cur, ctx)))
        return FontKeep(ctx, cur)
    if (cur != "" && !ctx.eng && !FontIsOurs(cur) && !(!ctx.uni && FontHasBengali(cur))) {
        def := ""
        try def := Trim(defFn())
        if (cur != def && SubStr(cur, 1, 1) != "+")
            return FontKeep(ctx, cur)
    }
    return true
}

; remember what is in use for this layout in this window; returns false = nothing to change
FontKeep(ctx, cur) {
    if !ctx.eng {
        if (App.userFont.Count > 300)
            App.userFont := Map()
        App.userFont[ctx.hwnd . "|" . ctx.key] := cur
        if !ctx.uni
            App.ansiSeen[cur] := 1
    }
    return false
}

FontIsOurs(cur) {
    for k, c in App.fonts {
        if (c.on && c.font != "" && c.font = cur)
            return true
    }
    return false
}

FontDefWord(office, sel, ctx) {
    try {
        f := sel.Paragraphs.Item(1).Style.Font
        return ctx.uni ? f.NameBi : f.Name
    }
    f := office.ActiveDocument.Styles.Item(-1).Font
    return ctx.uni ? f.NameBi : f.Name
}

FontDefExcel(office) {
    return office.ActiveWorkbook.Styles.Item("Normal").Font.Name
}

FontDefPpt(office, ctx) {
    return office.ActivePresentation.SlideMaster.Theme.ThemeFontScheme.MinorFont.Item(ctx.uni ? 2 : 1).Name
}

; Word (and WPS Writer): only at a plain cursor, never over selected text.
; Bengali Unicode text uses Word's "complex script" font, ANSI text the normal one.
FontDoWord(office, ctx) {
    sel := office.Selection
    if (sel.Type != 1)                                   ; 1 = just a blinking cursor
        return false
    f := sel.Font
    if FontNeedsChange(ctx, ctx.uni ? f.NameBi : f.Name, () => FontDefWord(office, sel, ctx)) {
        n := ctx.font
        if ctx.uni {
            f.NameBi := n
            if ctx.size
                f.SizeBi := ctx.size
        } else {
            f.Name := n
            try f.NameAscii := n
            try f.NameOther := n
            if ctx.size
                f.Size := ctx.size
        }
    }
    return true
}

; Excel: only an empty single cell that is not being edited (existing cells are never reformatted)
FontDoExcel(office, ctx) {
    if (office.Selection.Cells.Count != 1)
        return false
    c := office.ActiveCell
    if (c.Value != "")
        return false
    f := c.Font
    if FontNeedsChange(ctx, f.Name, () => FontDefExcel(office)) {
        f.Name := ctx.font
        if ctx.size
            f.Size := ctx.size
    }
    return true
}

; PowerPoint: only at a plain cursor inside a text box
FontDoPpt(office, ctx) {
    sel := office.ActiveWindow.Selection
    if (sel.Type != 3)                                   ; 3 = text
        return false
    tr := sel.TextRange
    if (tr.Length != 0)
        return false
    f := tr.Font
    if FontNeedsChange(ctx, ctx.uni ? f.NameComplexScript : f.Name, () => FontDefPpt(office, ctx)) {
        n := ctx.font
        if ctx.uni {
            f.NameComplexScript := n
        } else {
            f.Name := n
            try f.NameAscii := n
            try f.NameOther := n
        }
        if ctx.size
            f.Size := ctx.size
    }
    return true
}

; Outlook: the mail editor is a Word document, so the Word handlers do the work (a message window, or an inline reply)
OutlookEditor(ol) {
    ed := ""
    try ed := ol.ActiveInspector.WordEditor
    if !IsObject(ed)
        try ed := ol.ActiveExplorer.ActiveInlineResponseWordEditor
    return IsObject(ed) ? ed.Application : ""
}

FontDoOutlook(ol, ctx) {
    wd := OutlookEditor(ol)
    if !IsObject(wd)
        return false
    return FontDoWord(wd, ctx)
}

FontSetOutlook(ol, ctx) {
    wd := OutlookEditor(ol)
    if !IsObject(wd)
        return false
    return FontSetWord(wd, ctx)
}

; LibreOffice / OpenOffice Writer: only at a plain cursor, never over selected text.
; Bengali Unicode text uses the "complex script" font of Writer, ANSI text the normal (Western) one.
FontDoLO(sm, ctx) {
    doc := sm.createInstance("com.sun.star.frame.Desktop").CurrentComponent
    if (!IsObject(doc) || !doc.supportsService("com.sun.star.text.TextDocument"))
        return false
    vc := doc.CurrentController.ViewCursor
    if !vc.isCollapsed()                                 ; text is selected: leave it
        return false
    cur := ctx.uni ? vc.CharFontNameComplex : vc.CharFontName
    if FontNeedsChange(ctx, cur, () => FontDefLO(doc, vc, ctx)) {
        if ctx.uni {
            vc.CharFontNameComplex := ctx.font
            if ctx.size
                vc.CharHeightComplex := ctx.size
        } else {
            vc.CharFontName := ctx.font
            if ctx.size
                vc.CharHeight := ctx.size
        }
    }
    return true
}

; the font of the paragraph style at the cursor (what "nothing chosen yet" means in Writer)
FontDefLO(doc, vc, ctx) {
    try {
        ps := doc.StyleFamilies.getByName("ParagraphStyles").getByName(vc.ParaStyleName)
        return ctx.uni ? ps.CharFontNameComplex : ps.CharFontName
    }
    return ""
}

; manual shortcut in Writer: the selection, or the cursor when nothing is selected
FontSetLO(sm, ctx) {
    doc := sm.createInstance("com.sun.star.frame.Desktop").CurrentComponent
    if (!IsObject(doc) || !doc.supportsService("com.sun.star.text.TextDocument"))
        return false
    vc := doc.CurrentController.ViewCursor
    if ctx.uni {
        vc.CharFontNameComplex := ctx.font
        if ctx.size
            vc.CharHeightComplex := ctx.size
    } else {
        vc.CharFontName := ctx.font
        if ctx.size
            vc.CharHeight := ctx.size
    }
    return true
}

; ---------------------------------------------------------------------------
;  Start
; ---------------------------------------------------------------------------
ReadyTip() {
    s := ""
    for a in ActionList() {
        hk := App.shortcuts.Get(a.id, "")
        if (hk != "" && (SubStr(a.id, 1, 2) = "L:" || a.id = "English"))
            s .= a.label . " = " . PrettyHk(hk) . ",  "
    }
    return (s = "") ? "Ready." : "Ready.  " . RTrim(s, ", ")
}

; ---------------------------------------------------------------------------
;  Splash screen: shows one random picture for a few seconds, taken from two folders only:
;    Splash\Static Splash       - .png / .jpg / .jpeg / .bmp, used whatever time is set
;    Splash\Length(s) 1 .. 5    - animated .gif files made for that time; only the folder matching
;                                 the seconds set in Settings is read
;  Pictures loose in Splash\ are not used. If both folders are empty or missing, no splash is shown.
;  Turn it off in Settings.
; ---------------------------------------------------------------------------
SplashImages() {
    list := []
    secs := Min(5, Max(1, Round(App.splashMs / 1000)))
    dirs := [[App.dir . "\Splash\Static Splash", "png|jpg|jpeg|bmp"]                ; static pictures: always used
           , [App.dir . "\Splash\Length(s) " . secs, "gif"]]                       ; GIFs made for the time set in Settings
    for d in dirs {
        if !DirExist(d[1])                                                           ; a missing folder is simply skipped
            continue
        Loop Files d[1] . "\*.*" {
            if RegExMatch(A_LoopFileExt, "i)^(" . d[2] . ")$")
                list.Push(A_LoopFileFullPath)
        }
    }
    return list
}

; one random picture from the folder (never the same one twice in a row when there are several)
PickSplash() {
    list := SplashImages()
    if (list.Length = 0)
        return ""
    if (list.Length = 1)
        return list[1]
    last := IniRead(App.ini, "General", "LastSplash", "")
    pool := []
    for p in list {
        if (p != last)
            pool.Push(p)                                  ; everything except the picture shown last time
    }
    f := pool[Random(1, pool.Length)]
    SaveSetting("General", "LastSplash", f)
    return f
}

; width / height of a GIF from its header
GifSize(f, &w, &h) {
    w := 0
    h := 0
    try {
        fh := FileOpen(f, "r")
        buf := Buffer(10, 0)
        n := fh.RawRead(buf, 10)
        fh.Close()
        if (n = 10 && NumGet(buf, 0, "UChar") = 0x47 && NumGet(buf, 1, "UChar") = 0x49 && NumGet(buf, 2, "UChar") = 0x46) {
            w := NumGet(buf, 6, "UShort")
            h := NumGet(buf, 8, "UShort")
        }
    }
    return (w > 0 && h > 0)
}

; very large picture: shrink to 80% of the screen at most
FitSize(&w, &h) {
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    k := Min(1, (r - l) * 0.8 / w, (b - t) * 0.8 / h)
    if (k < 1) {
        w := Max(1, Round(w * k))
        h := Max(1, Round(h * k))
    }
}

FileUrl(p) {
    p := StrReplace(p, "%", "%25")
    p := StrReplace(p, "#", "%23")
    p := StrReplace(p, " ", "%20")
    return "file:///" . StrReplace(p, "\", "/")
}

; Animated GIF: a Picture control only shows the first frame, so the GIF is played by a small
; embedded browser control (built into Windows) that shows nothing but the picture.
SplashGif(f) {
    if !GifSize(f, &w, &h)
        return ""
    FitSize(&w, &h)
    page := App.dataDir . "\splash.html"
    html := '<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="X-UA-Compatible" content="IE=edge">'
        . '<style>html,body{margin:0;padding:0;border:0;overflow:hidden;background:#000}img{display:block;border:0}</style></head>'
        . '<body scroll="no"><img src="' . FileUrl(f) . '" width="' . w . '" height="' . h . '"></body></html>'
    g := ""
    try {
        try FileDelete(page)
        FileAppend(html, page, "UTF-8-RAW")
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +Border -DPIScale")
        g.MarginX := 0
        g.MarginY := 0
        wb := g.Add("ActiveX", "x0 y0 w" . w . " h" . h, "Shell.Explorer").Value
        wb.Silent := true
        wb.Navigate(FileUrl(page))
        t0 := A_TickCount
        while (wb.ReadyState != 4 && A_TickCount - t0 < 2000)
            Sleep(15)
        g.Show("NoActivate Center w" . w . " h" . h)
        return g
    } catch {
        if IsObject(g)
            try g.Destroy()
        return ""
    }
}

SplashStatic(f) {
    g := ""
    try {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +Border -DPIScale")      ; plain pixels
        g.MarginX := 0
        g.MarginY := 0
        pic := g.Add("Picture", "x0 y0", f)
        pic.GetPos(, , &w, &h)
        ow := w
        oh := h
        FitSize(&w, &h)
        if (w != ow || h != oh)
            pic.Move(0, 0, w, h)
        g.Show("NoActivate Center w" . w . " h" . h)
        return g
    } catch {
        if IsObject(g)
            try g.Destroy()
        return ""
    }
}

ShowSplash() {
    if !App.splashOn
        return
    f := PickSplash()
    if (f = "")
        return
    g := ""
    if RegExMatch(f, "i)\.gif$")
        g := SplashGif(f)
    if !IsObject(g)
        g := SplashStatic(f)                                                 ; also the fallback if the GIF player is unavailable
    if !IsObject(g)
        return
    App.splash := g
    SetTimer(CloseSplash, -App.splashMs)
}

CloseSplash(*) {
    try App.splash.Destroy()
    App.splash := ""
}

PrepareDataDir()
LoadSettings()
ShowSplash()                      ; first thing, so it appears at once; the rest loads behind it
LoadLayouts()
LoadFonts()
LoadManualFonts()
LoadExtButtons()
LoadShortcuts()
LoadShown()
App.eng := Engine(App.layouts[1])
BuildTrayMenu()
RegisterTypingKeys()
ApplyShortcuts()
BuildBar()
if App.startMin
    App.bar.Hide()                ; start in the tray; double-click the tray icon to show the bar
SyncTray()                        ; bar visible = no tray icon, bar hidden = tray icon
InstallForegroundHook()
SetTimer(KeepOnTop, 250)
if IsBindable(WinExist("A"))
    App.curWin := WinExist("A")
SetLayout(0)
if (IniRead(App.ini, "General", "ReadyNotice", "0") = "1")      ; the "Ready ..." notification is off by default
    TrayTip(ReadyTip(), "Bangla Keyboard")
