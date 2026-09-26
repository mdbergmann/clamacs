
// page-app.js -- the Clamacs side of the page: CK, what Lisp calls
// through webview_eval, and the callers of the bindings Lisp registered
// with webview_bind (specs/clamacs-host.md, "The interface between the
// page and the Lisp").  Everything above this line in page.html is the
// CodeMirror bundle (window.CM, host/page-entry.mjs).
//
// Phase H1: one CodeMirror view per document in a tab, the colours as
// decorations Lisp paints through CK.colour, the status line, the echo
// row with the input line, every key sent to Lisp first.  Phase H3: the
// dock below the splitter -- the tool buffers (the REPL, a description,
// ...) as tabs of their own, and the three panels (Diagnostics, Debugger,
// Inspector) whose lists and buttons hand a row number or a line back to
// Lisp; the page tells Lisp what the panels show (clamacsPanels) after
// every change, so a script can check the page did what it was told.
// Phase H4: the menu bar, drawn here from the table of menu.lisp, its
// enable states and the Buffers menu, reported the same way.

(() => {
  const {EditorView, EditorState, Decoration, StateField, StateEffect,
         lineNumbers, drawSelection, highlightActiveLine} = window.CM;

  const $ = (id) => document.getElementById(id);
  const menubar = $("menubar");
  const sourceTabs = $("source-tabs"), views = $("views");
  const dockEl = $("dock"), splitter = $("splitter"), dockTabs = $("dock-tabs"), dockViews = $("dock-views");
  const status = $("status"), message = $("message");
  const miniLabel = $("mini-label"), mini = $("mini");

  // A binding may not exist yet while the page loads (Lisp registers them
  // before webview_set_html, but a stub never hurts): call it when there.
  const lisp = (name, ...args) => {
    const fn = window[name];
    return fn ? fn(...args).catch((e) => showMessage("bind error in " + name + ": " + e))
              : Promise.resolve(undefined);
  };
  const showMessage = (text) => { message.textContent = text; };

  // ---- colours -----------------------------------------------------------
  //
  // The colours are mark decorations in a StateField, which CodeMirror
  // maps through every change, so they travel with the text as the MUI
  // widget's SetBlock colours do.  Lisp paints with CK.colour(id, records):
  // a record [y, runs] replaces line y's decorations with runs ([x0, x1,
  // kind] triples); a record [y, x0, x1, kind] paints one run over what is
  // there (kind false clears), clipping the runs it overlaps.

  const colourEffect = StateEffect.define();
  const marks = {};
  const markFor = (kind) => marks[kind] || (marks[kind] = Decoration.mark({class: "ck-" + kind}));

  function applyColours(set, doc, records) {
    for (const r of records) {
      const y = r[0];
      if (y < 0 || y >= doc.lines) continue;
      const line = doc.line(y + 1);
      const add = [];
      let a = line.from, b = line.to;
      if (r.length === 2) {
        for (const [x0, x1, kind] of r[1]) {
          const from = line.from + x0, to = Math.min(line.from + x1, line.to);
          if (kind && to > from) add.push(markFor(kind).range(from, to));
        }
      } else {
        const [, x0, x1, kind] = r;
        a = line.from + x0; b = Math.min(line.from + x1, line.to);
        if (b <= a) continue;
        set.between(a, b, (from, to, value) => {
          if (from >= b || to <= a) return;
          if (from < a) add.push(value.range(from, a));
          if (to > b) add.push(value.range(b, to));
        });
        if (kind) add.push(markFor(kind).range(a, b));
      }
      set = set.update({filterFrom: a, filterTo: b,
                        filter: (from, to) => to <= a || from >= b,
                        add, sort: true});
    }
    return set;
  }

  const colourField = StateField.define({
    create: () => Decoration.none,
    update(set, tr) {
      set = set.map(tr.changes);
      for (const e of tr.effects) if (e.is(colourEffect)) set = applyColours(set, tr.state.doc, e.value);
      return set;
    },
    provide: (f) => EditorView.decorations.from(f)
  });

  // ---- the two regions and their tabs --------------------------------------
  //
  // The source documents live on top, the tool documents and the panels
  // in the dock.  Each region displays one item (`shown'); the item that
  // holds the keyboard (`active') is one of the two.  The dock is collapsed
  // while it displays nothing.

  const docs = new Map();      // id -> {id, name, kind, dock, tab, holder, view, applying}
  const dockItems = new Map(); // name -> {name, tab, el, kind: "doc" | "panel", open, label}
  let activeId = null;         // the document with the keyboard
  let shownSource = null;      // the source document displayed on top
  let dockShown = null;        // the dock item displayed, or null: collapsed

  function refreshTabs() {
    for (const d of docs.values()) {
      if (d.dock) continue;
      d.holder.classList.toggle("active", d.id === shownSource);
      d.tab.classList.toggle("shown", d.id === shownSource);
      d.tab.classList.toggle("active", d.id === activeId);
    }
    for (const item of dockItems.values()) {
      item.el.classList.toggle("active", item.name === dockShown);
      item.tab.classList.toggle("shown", item.name === dockShown);
      item.tab.classList.toggle("active", item.name === activeId);
      item.tab.style.display = item.open ? "" : "none";
    }
    const open = dockShown !== null;
    dockEl.classList.toggle("open", open);
    splitter.classList.toggle("open", open);
  }

  function showSource(id) {
    shownSource = id;
    refreshTabs();
  }

  // Display NAME in the dock, opening the dock; the keyboard is not moved.
  function dockShow(name) {
    const item = dockItems.get(name);
    if (!item) return;
    item.open = true;
    dockShown = name;
    refreshTabs();
    reportPanels();
  }

  // Take NAME out of the dock's tab bar; when it was displayed, the next
  // open item is, or the dock collapses.
  function dockHide(name) {
    const item = dockItems.get(name);
    if (!item) return;
    item.open = false;
    if (dockShown === name) {
      dockShown = null;
      for (const other of dockItems.values()) {
        if (other.open) { dockShown = other.name; break; }
      }
    }
    refreshTabs();
    reportPanels();
  }

  function makeTab(bar, label, onPick, onClose) {
    const tab = document.createElement("div");
    tab.className = "tab";
    const name = document.createElement("span");
    name.textContent = label;
    const close = document.createElement("span");
    close.className = "close";
    close.textContent = "\u00d7";
    close.title = "Close";
    tab.appendChild(name);
    tab.appendChild(close);
    tab.addEventListener("mousedown", (ev) => {
      ev.preventDefault();
      if (ev.target === close) onClose(); else onPick();
    });
    bar.appendChild(tab);
    tab.nameSpan = name;
    return tab;
  }

  // ---- documents -------------------------------------------------------

  // A bare modifier press is nobody's key; IME composition and a dead key
  // stay with the widget (the composed character comes back through
  // clamacsUpdate) -- except under Alt, where macOS reports Option-N/E/I/U/`
  // as "Dead" and the decoder reads the letter from `code' (M-n); a key with
  // the Command key is the OS's and the widget's (Cmd-C/V/X/A/Z are native).
  // Everything else goes to Lisp.
  const MODIFIERS = ["Shift", "Control", "Alt", "Meta", "CapsLock"];
  function keyToLisp(doc, ev, target) {
    if (ev.isComposing || ev.metaKey || (ev.key === "Dead" && !ev.altKey)) return;
    if (MODIFIERS.includes(ev.key)) return;
    ev.preventDefault();
    lisp("clamacsKey", doc.id, ev.key, ev.code, ev.ctrlKey, ev.altKey, ev.metaKey, ev.shiftKey, target);
  }

  function makeView(doc) {
    const view = new EditorView({
      state: EditorState.create({
        doc: "",
        extensions: [
          lineNumbers(), drawSelection(), highlightActiveLine(), colourField,
          EditorView.domEventHandlers({
            keydown: (ev) => { keyToLisp(doc, ev, "text"); return false; },
            focus: () => { if (activeId !== doc.id) lisp("clamacsActivate", doc.id); return false; }
          }),
          EditorView.updateListener.of((u) => {
            if (doc.applying) return;
            if (u.docChanged) {
              const changes = [];
              u.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
                changes.push([fromA, toA, inserted.toString()]);
              });
              lisp("clamacsUpdate", doc.id, changes, u.state.selection.main.head);
            } else if (u.selectionSet) {
              const sel = u.state.selection.main;
              lisp("clamacsCursor", doc.id, sel.head, sel.anchor);
            }
          })
        ]
      }),
      parent: doc.holder
    });
    return view;
  }

  // Run FN with the document's own updates silenced: a change made at
  // Lisp's request is not reported back.
  function applying(doc, fn) {
    doc.applying = true;
    try { fn(); } finally { doc.applying = false; }
  }

  // ---- lists -------------------------------------------------------------
  //
  // A panel list: rows of text, one selected.  A click selects and tells
  // ONSELECT, a double-click (or Enter) tells ONOPEN, the arrows move the
  // selection; a selection Lisp makes (select with SILENT) tells nobody,
  // as MUI's List does under MUIA_List_Quiet.

  function makeList(el, onSelect, onOpen) {
    const list = {el, rows: [], selected: null};
    list.fill = (rows) => {
      list.rows = rows.slice();
      list.selected = null;
      el.textContent = "";
      rows.forEach((text, n) => {
        const row = document.createElement("div");
        row.className = "row";
        row.textContent = text;
        row.addEventListener("mousedown", (ev) => {
          ev.preventDefault();
          el.focus();
          list.select(n, false);
        });
        row.addEventListener("dblclick", () => { if (onOpen) onOpen(n); });
        el.appendChild(row);
      });
    };
    list.select = (n, silent) => {
      if (n === null || n === undefined || n === false || n < 0 || n >= list.rows.length) n = null;
      const changed = n !== list.selected;
      list.selected = n;
      Array.from(el.children).forEach((row, i) => row.classList.toggle("selected", i === n));
      if (n !== null) el.children[n].scrollIntoView({block: "nearest"});
      if (changed && !silent && onSelect) onSelect(n);
      reportPanels();
    };
    el.addEventListener("keydown", (ev) => {
      if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
        ev.preventDefault();
        if (list.rows.length === 0) return;
        const n = list.selected === null ? 0
                : Math.max(0, Math.min(list.rows.length - 1, list.selected + (ev.key === "ArrowDown" ? 1 : -1)));
        list.select(n, false);
      } else if (ev.key === "Enter") {
        ev.preventDefault();
        if (onOpen && list.selected !== null) onOpen(list.selected);
      }
    });
    return list;
  }

  // ---- the panels ----------------------------------------------------------

  const panels = {
    diagnostics: {open: false},
    debugger: {open: false, level: 0, condition: "", hasContinue: false},
    inspector: {open: false, type: "", depth: 0, object: ""}
  };

  function makePanel(name, label) {
    const el = $("panel-" + name);
    // A tab picked by the user is told to Lisp, whose dock follows the page;
    // when Lisp shows a panel (CK.dbgOpen and friends) it knows already.
    const tab = makeTab(dockTabs, label,
                        () => { dockShow(name); lisp("clamacsDockShown", name); },
                        () => { dockHide(name); lisp("clamacsPanelClose", name); });
    const item = {name, tab, el, kind: "panel", open: false};
    dockItems.set(name, item);
    return item;
  }
  const diagItem = makePanel("diagnostics", "Diagnostics");
  const dbgItem = makePanel("debugger", "Debugger");
  const inspItem = makePanel("inspector", "Inspector");

  const diagList = makeList($("diag-list"), (n) => lisp("clamacsDiagPick", n), null);
  const dbgRestarts = makeList($("dbg-restarts"), null, (n) => lisp("clamacsDbgRestart", n));
  const dbgFrames = makeList($("dbg-frames"), (n) => lisp("clamacsDbgFrame", n),
                             (n) => lisp("clamacsDbgFrameOpen", n));
  const dbgLocals = makeList($("dbg-locals"), null, null);
  const inspParts = makeList($("insp-parts"), null, (n) => lisp("clamacsInspPart", n));
  const dbgCondition = $("dbg-condition"), dbgEval = $("dbg-eval");
  const dbgInvoke = $("dbg-invoke"), dbgContinue = $("dbg-continue"), dbgAbort = $("dbg-abort");
  const inspHead = $("insp-head"), inspObject = $("insp-object");
  const inspPart = $("insp-part"), inspBack = $("insp-back");

  dbgInvoke.addEventListener("click", () => lisp("clamacsDbgRestart", dbgRestarts.selected));
  dbgContinue.addEventListener("click", () => lisp("clamacsDbgButton", "continue"));
  dbgAbort.addEventListener("click", () => lisp("clamacsDbgButton", "abort"));
  dbgEval.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") {
      ev.preventDefault();
      const text = dbgEval.value;
      dbgEval.value = "";
      lisp("clamacsDbgEval", text);
    }
  });
  inspPart.addEventListener("click", () => lisp("clamacsInspPart", inspParts.selected));
  inspBack.addEventListener("click", () => lisp("clamacsInspBack"));

  // ---- the menu bar ----------------------------------------------------------
  //
  // The menu strip of menu.lisp, drawn here: webview has no API for a
  // native one.  CK.setMenus hands the table over, one [kind, title, keys]
  // per entry, indexed as Lisp indexes it; a pick is told to Lisp as that
  // index (clamacsMenu), which runs the command on the active document as
  // MUI's MenuAction does, and CK.menuEnable dims an item.  The Buffers
  // menu (the entry of kind "buffers") holds what CK.setBuffers last gave
  // -- "-" for a bar, [label, ticked] for a buffer -- and a pick there is
  // the item's position (clamacsBuffers).  A title opens on a click and the
  // open menu follows the mouse along the bar; a click anywhere else or
  // Escape closes it, and none of it moves the keyboard off the view.

  const menuItems = new Map();   // table index -> item element
  let buffersPopup = null;       // the Buffers menu's popup
  let buffersLines = [];         // what it shows, spelled as Lisp's BUFFERS verb spells it
  let openMenu = null;           // the title element whose popup is open

  function menuClose() {
    if (openMenu) { openMenu.classList.remove("open"); openMenu = null; }
  }
  function menuOpen(title) {
    if (openMenu === title) return;
    menuClose();
    openMenu = title;
    title.classList.add("open");
  }
  function makeMenuItem(popup, label, keys, onPick) {
    const item = document.createElement("div");
    item.className = "menu-item";
    const left = document.createElement("span");
    const tick = document.createElement("span");
    tick.className = "tick";
    const text = document.createElement("span");
    text.textContent = label;
    left.appendChild(tick);
    left.appendChild(text);
    const right = document.createElement("span");
    right.className = "keys";
    right.textContent = keys || "";
    item.appendChild(left);
    item.appendChild(right);
    item.addEventListener("mousedown", (ev) => ev.preventDefault());
    item.addEventListener("click", (ev) => {
      ev.preventDefault();
      if (item.classList.contains("disabled")) return;
      menuClose();
      onPick();
    });
    popup.appendChild(item);
    item.tick = tick;
    return item;
  }
  function makeMenuSep(popup) {
    const sep = document.createElement("div");
    sep.className = "menu-sep";
    popup.appendChild(sep);
  }
  function makeMenuTitle(label) {
    const title = document.createElement("div");
    title.className = "menu-title";
    const name = document.createElement("span");
    name.textContent = label;
    const popup = document.createElement("div");
    popup.className = "menu-popup";
    title.appendChild(name);
    title.appendChild(popup);
    title.addEventListener("mousedown", (ev) => {
      // Inside the popup the item's own handler applies.
      if (ev.target !== name && ev.target !== title) return;
      ev.preventDefault();
      if (openMenu === title) menuClose(); else menuOpen(title);
    });
    title.addEventListener("mouseenter", () => { if (openMenu && openMenu !== title) menuOpen(title); });
    menubar.appendChild(title);
    return popup;
  }
  function fillBuffers(lines) {
    buffersLines = [];
    if (!buffersPopup) return;
    buffersPopup.textContent = "";
    lines.forEach((line, n) => {
      if (line === "-") {
        makeMenuSep(buffersPopup);
        buffersLines.push("-");
        return;
      }
      const [label, ticked] = line;
      const item = makeMenuItem(buffersPopup, label, "", () => lisp("clamacsBuffers", n));
      item.tick.textContent = ticked ? "\u2713" : "";
      buffersLines.push((ticked ? "> " : "  ") + label);
    });
  }
  document.addEventListener("mousedown", (ev) => {
    if (openMenu && !menubar.contains(ev.target)) menuClose();
  });
  document.addEventListener("keydown", (ev) => {
    if (openMenu && ev.key === "Escape") {
      ev.preventDefault();
      ev.stopPropagation();
      menuClose();
    }
  }, true);
  function menuState() {
    const disabled = [];
    for (const [index, item] of menuItems) if (item.classList.contains("disabled")) disabled.push(index);
    disabled.sort((a, b) => a - b);
    return {items: menuItems.size, disabled, buffers: buffersLines};
  }

  // What the menu bar, the dock and the panels show, told to Lisp once per
  // change (a batch of changes is one report): what a script checks
  // through the port.
  let reportPending = false;
  function panelState() {
    return {
      menu: menuState(),
      dock: {open: dockShown !== null, shown: dockShown, height: dockEl.offsetHeight || parseInt(dockEl.style.height) || 0},
      diagnostics: {open: diagItem.open, rows: diagList.rows.length, selected: diagList.selected},
      debugger: {open: dbgItem.open, level: panels.debugger.level, condition: panels.debugger.condition,
                 restarts: dbgRestarts.rows.length, hasContinue: panels.debugger.hasContinue,
                 frames: dbgFrames.rows.length, frame: dbgFrames.selected, locals: dbgLocals.rows.length},
      inspector: {open: inspItem.open, type: panels.inspector.type, depth: panels.inspector.depth,
                  object: panels.inspector.object, parts: inspParts.rows.length, part: inspParts.selected}
    };
  }
  function reportPanels() {
    if (reportPending) return;
    reportPending = true;
    setTimeout(() => {
      reportPending = false;
      lisp("clamacsPanels", JSON.stringify(panelState()));
    }, 0);
  }

  // ---- the splitter ----------------------------------------------------------

  splitter.addEventListener("mousedown", (ev) => {
    ev.preventDefault();
    const startY = ev.clientY, startHeight = dockEl.offsetHeight;
    const limit = Math.max(40, document.body.clientHeight - 150);
    let height = startHeight;
    const move = (e) => {
      height = Math.max(40, Math.min(limit, startHeight + (startY - e.clientY)));
      dockEl.style.height = height + "px";
    };
    const up = () => {
      document.removeEventListener("mousemove", move);
      document.removeEventListener("mouseup", up);
      lisp("clamacsDockResized", Math.round(height));
      reportPanels();
    };
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
  });

  // ---- CK: what Lisp calls -------------------------------------------------------

  const CK = {
    makeDoc(id, name, kind) {
      if (docs.has(id)) return;
      const doc = {id, name, kind, dock: kind === "tool", applying: false};
      doc.holder = document.createElement("div");
      doc.holder.className = "view";
      (doc.dock ? dockViews : views).appendChild(doc.holder);
      doc.tab = makeTab(doc.dock ? dockTabs : sourceTabs, name,
                        () => lisp("clamacsActivate", id),
                        () => lisp("clamacsCloseTab", id));
      doc.nameSpan = doc.tab.nameSpan;
      doc.view = makeView(doc);
      docs.set(id, doc);
      if (doc.dock) dockItems.set(id, {name: id, tab: doc.tab, el: doc.holder, kind: "doc", open: true});
      if (activeId === null) CK.activateDoc(id);
    },
    removeDoc(id) {
      const doc = docs.get(id);
      if (!doc) return;
      doc.view.destroy();
      doc.holder.remove();
      doc.tab.remove();
      docs.delete(id);
      if (doc.dock) {
        dockHide(id);
        dockItems.delete(id);
      } else if (shownSource === id) {
        shownSource = null;
        for (const d of docs.values()) if (!d.dock) { shownSource = d.id; break; }
      }
      if (activeId === id) {
        activeId = null;
        const next = shownSource || dockShown;
        if (next && docs.has(next)) CK.activateDoc(next);
      }
      refreshTabs();
    },
    activateDoc(id) {
      const doc = docs.get(id);
      if (!doc) return;
      activeId = id;
      if (doc.dock) dockShow(id); else showSource(id);
      document.title = doc.name;
      if (!mini.classList.contains("open")) doc.view.focus();
    },
    setText(id, text) {
      const doc = docs.get(id);
      if (!doc) return;
      applying(doc, () => doc.view.dispatch({
        changes: {from: 0, to: doc.view.state.doc.length, insert: text},
        selection: {anchor: 0}
      }));
    },
    applyEdit(id, from, to, text, head) {
      const doc = docs.get(id);
      if (!doc) return;
      applying(doc, () => doc.view.dispatch({
        changes: {from, to, insert: text},
        selection: {anchor: head},
        scrollIntoView: true
      }));
    },
    setPoint(id, head, anchor) {
      const doc = docs.get(id);
      if (!doc) return;
      applying(doc, () => doc.view.dispatch({
        selection: {anchor: anchor === undefined || anchor === null ? head : anchor, head},
        scrollIntoView: true
      }));
    },
    colour(id, records) {
      const doc = docs.get(id);
      if (!doc) return;
      applying(doc, () => doc.view.dispatch({effects: colourEffect.of(records)}));
    },
    setTitle(id, title) {
      const doc = docs.get(id);
      if (!doc) return;
      doc.name = title;
      doc.nameSpan.textContent = title;
      if (activeId === id) document.title = title;
    },
    setModified(id, flag) {
      const doc = docs.get(id);
      if (doc) doc.tab.classList.toggle("modified", !!flag);
    },
    setStatus(text) { status.textContent = text; },
    setEcho(text) { showMessage(text); },
    openMini(label, text) {
      miniLabel.textContent = label;
      mini.value = text;
      mini.classList.add("open");
      message.textContent = "";
      mini.focus();
    },
    closeMini() {
      mini.classList.remove("open");
      miniLabel.textContent = "";
      mini.value = "";
      const doc = docs.get(activeId);
      if (doc) doc.view.focus();
    },
    setMiniText(text) { mini.value = text; },
    setMiniLabel(label) { miniLabel.textContent = label; },

    // The menu bar.  ENTRIES is the table of menu.lisp: [kind, title,
    // keys] per entry, kind "title", "item", "bar" or "buffers".
    setMenus(entries) {
      menuClose();
      menubar.textContent = "";
      menuItems.clear();
      buffersPopup = null;
      let popup = null;
      entries.forEach((e, index) => {
        const [kind, title, keys] = e;
        if (kind === "title") popup = makeMenuTitle(title);
        else if (!popup) return;
        else if (kind === "bar") makeMenuSep(popup);
        else if (kind === "buffers") buffersPopup = popup;
        else if (kind === "item")
          menuItems.set(index, makeMenuItem(popup, title, keys, () => lisp("clamacsMenu", index)));
      });
      fillBuffers([]);
      reportPanels();
    },
    menuEnable(index, flag) {
      const item = menuItems.get(index);
      if (item) item.classList.toggle("disabled", !flag);
      reportPanels();
    },
    setBuffers(lines) {
      fillBuffers(lines);
      reportPanels();
    },

    // The dock and the panels.  A panel opens without taking the keyboard
    // unless said otherwise (dbgRaise, inspOpen): the debugger arrives
    // while the user may be typing.
    setDock(height) {
      if (height > 0) dockEl.style.height = height + "px";
    },
    showDiagnostics(rows, open) {
      diagList.fill(rows);
      diagList.select(null, true);
      if (open || rows.length > 0) dockShow("diagnostics");
      else reportPanels();
    },
    selectDiagnostic(row) { diagList.select(row, true); },
    dbgOpen(level, condition, restarts, hasContinue) {
      panels.debugger.level = level;
      panels.debugger.condition = condition;
      panels.debugger.hasContinue = !!hasContinue;
      dbgCondition.textContent = condition;
      dbgRestarts.fill(restarts);
      dbgFrames.fill([]);
      dbgLocals.fill([]);
      dbgContinue.disabled = !hasContinue;
      dbgItem.tab.nameSpan.textContent = "Debugger (level " + level + ")";
      dockShow("debugger");
    },
    dbgClose() {
      dbgItem.tab.nameSpan.textContent = "Debugger";
      dockHide("debugger");
    },
    dbgRaise() {
      dockShow("debugger");
      dbgFrames.el.focus();
    },
    dbgFrames(rows) { dbgFrames.fill(rows); dbgFrames.select(null, true); },
    dbgSelectFrame(n) { dbgFrames.select(n, true); },
    dbgLocals(rows) { dbgLocals.fill(rows); reportPanels(); },
    inspOpen(type, depth, object, parts) {
      panels.inspector.type = type;
      panels.inspector.depth = depth;
      panels.inspector.object = object;
      inspHead.textContent = type + "  (depth " + depth + ")";
      inspObject.textContent = object;
      inspParts.fill(parts);
      inspParts.select(null, true);
      inspBack.disabled = depth <= 1;
      dockShow("inspector");
      inspParts.el.focus();
    },
    terminate() { /* the page asks nothing further */ },

    // Diagnostics for the smoke run and the tests: what the page holds,
    // and the colour runs of one line as [x0, x1, kind] triples.
    state() {
      const doc = docs.get(activeId);
      return {docs: [...docs.keys()], active: activeId,
              text: doc ? doc.view.state.doc.toString() : null,
              head: doc ? doc.view.state.selection.main.head : null,
              status: status.textContent, message: message.textContent,
              mini: mini.classList.contains("open") ? miniLabel.textContent + mini.value : null,
              panels: panelState()};
    },
    lineColours(id, y) {
      const doc = docs.get(id);
      if (!doc) return null;
      const line = doc.view.state.doc.line(y + 1), runs = [];
      doc.view.state.field(colourField).between(line.from, line.to, (from, to, value) => {
        if (from < line.to && to > line.from)
          runs.push([Math.max(from, line.from) - line.from, Math.min(to, line.to) - line.from,
                     value.spec.class.replace(/^ck-/, "")]);
      });
      return runs;
    }
  };
  window.CK = CK;
  refreshTabs();

  // A synthetic key for the harness (verify/host/host-keys.sh): the same
  // path a real one takes, into the input line while a prompt is open.
  window.simulateKey = (key, mods) => {
    const doc = docs.get(activeId);
    const target = mini.classList.contains("open") ? mini : (doc ? doc.view.contentDOM : document.body);
    const ev = new KeyboardEvent("keydown", Object.assign({key, bubbles: true, cancelable: true}, mods || {}));
    target.dispatchEvent(ev);
  };

  // The input line edits itself, as the MUI String does, and reports its
  // contents (clamacsMiniInput); the keys that may be the minibuffer's --
  // Control, Alt, Escape, Tab, Enter -- go to Lisp first.  A synthetic key
  // goes to Lisp too, since dispatching it types nothing natively.
  const MINI_KEYS = ["Escape", "Tab", "Enter"];
  mini.addEventListener("keydown", (ev) => {
    const doc = docs.get(activeId);
    if (!doc) return;
    if (!ev.isTrusted || ev.ctrlKey || ev.altKey || MINI_KEYS.includes(ev.key)) keyToLisp(doc, ev, "mini");
  });
  mini.addEventListener("input", () => lisp("clamacsMiniInput", mini.value));

  setInterval(() => lisp("clamacsTick"), 300);

  lisp("clamacsReady", navigator.userAgent);
})();
</script>
</body>
</html>
