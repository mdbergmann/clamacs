
// page-app.js -- the Clamacs side of the page: CK, what Lisp calls
// through webview_eval, and the callers of the bindings Lisp registered
// with webview_bind (specs/clamacs-host.md, "The interface between the
// page and the Lisp").  Everything above this line in page.html is the
// CodeMirror bundle (window.CM, host/page-entry.mjs).
//
// Phase H1: one CodeMirror view per document in a tab, the colours as
// decorations Lisp paints through CK.colour, the status line, the echo
// row with the input line, every key sent to Lisp first; the dock and
// the panels come with phase H3, the menu bar with H4.

(() => {
  const {EditorView, EditorState, Decoration, StateField, StateEffect,
         lineNumbers, drawSelection, highlightActiveLine} = window.CM;

  const $ = (id) => document.getElementById(id);
  const sourceTabs = $("source-tabs"), views = $("views");
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

  // ---- documents -------------------------------------------------------

  const docs = new Map();      // id -> {id, name, kind, tab, holder, view, applying}
  let activeId = null;

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

  function makeTab(doc) {
    const tab = document.createElement("div");
    tab.className = "tab";
    const name = document.createElement("span");
    name.textContent = doc.name;
    const close = document.createElement("span");
    close.className = "close";
    close.textContent = "\u00d7";
    close.title = "Close";
    tab.appendChild(name);
    tab.appendChild(close);
    tab.addEventListener("mousedown", (ev) => {
      ev.preventDefault();
      if (ev.target === close) lisp("clamacsCloseTab", doc.id);
      else lisp("clamacsActivate", doc.id);
    });
    doc.nameSpan = name;
    return tab;
  }

  // Run FN with the document's own updates silenced: a change made at
  // Lisp's request is not reported back.
  function applying(doc, fn) {
    doc.applying = true;
    try { fn(); } finally { doc.applying = false; }
  }

  const CK = {
    makeDoc(id, name, kind) {
      if (docs.has(id)) return;
      const doc = {id, name, kind, applying: false};
      doc.holder = document.createElement("div");
      doc.holder.className = "view";
      views.appendChild(doc.holder);
      doc.tab = makeTab(doc);
      sourceTabs.appendChild(doc.tab);
      doc.view = makeView(doc);
      docs.set(id, doc);
      if (activeId === null) CK.activateDoc(id);
    },
    removeDoc(id) {
      const doc = docs.get(id);
      if (!doc) return;
      doc.view.destroy();
      doc.holder.remove();
      doc.tab.remove();
      docs.delete(id);
      if (activeId === id) {
        activeId = null;
        const next = docs.keys().next();
        if (!next.done) CK.activateDoc(next.value);
      }
    },
    activateDoc(id) {
      const doc = docs.get(id);
      if (!doc) return;
      for (const d of docs.values()) {
        d.holder.classList.toggle("active", d === doc);
        d.tab.classList.toggle("active", d === doc);
      }
      activeId = id;
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
    terminate() { /* the page asks nothing further */ },

    // Diagnostics for the smoke run and the tests: what the page holds,
    // and the colour runs of one line as [x0, x1, kind] triples.
    state() {
      const doc = docs.get(activeId);
      return {docs: [...docs.keys()], active: activeId,
              text: doc ? doc.view.state.doc.toString() : null,
              head: doc ? doc.view.state.selection.main.head : null,
              status: status.textContent, message: message.textContent,
              mini: mini.classList.contains("open") ? miniLabel.textContent + mini.value : null};
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
