
// ---- the Clamacs side of the page: everything above is CodeMirror 6 ----
const {EditorView, basicSetup} = window.CM;

const status = document.getElementById("status");
const echo = document.getElementById("echo");

// Called by Lisp through webview_eval.
window.showEcho = (text) => { echo.textContent = text; };
window.showStatus = (text) => { status.textContent = text; };
window.cmInsert = (text) => {
  const pos = view.state.selection.main.head;
  view.dispatch({changes: {from: pos, insert: text},
                 selection: {anchor: pos + text.length}});
};
window.cmPoint = () => view.state.selection.main.head;
window.cmText = () => view.state.doc.toString();
window.simulateKey = (key, mods) => {
  const ev = new KeyboardEvent("keydown", Object.assign({key, bubbles: true, cancelable: true}, mods || {}));
  view.contentDOM.dispatchEvent(ev);
};

// Every key goes to Lisp first (the Emacs layer); a true reply means
// Lisp took it, else CodeMirror handles it as usual.
function keyToLisp(ev) {
  const head = view.state.selection.main.head;
  clamacsKey(ev.key, ev.ctrlKey, ev.altKey, ev.metaKey, ev.shiftKey,
             head, view.state.doc.length)
    .then((taken) => { if (taken) { /* already handled by Lisp */ } })
    .catch((e) => showEcho("bind error: " + e));
  if (ev.ctrlKey || ev.altKey) ev.preventDefault();  // Emacs keys never reach the widget
}

const view = new EditorView({
  doc: "(defun hello (name)\n  (format t \"Hello, ~a!~%\" name))\n",
  extensions: [basicSetup,
               EditorView.domEventHandlers({keydown: (ev) => { keyToLisp(ev); return false; }}),
               EditorView.updateListener.of((u) => {
                 if (u.docChanged || u.selectionSet) {
                   clamacsUpdate(u.state.selection.main.head, u.state.doc.length);
                 }
               })],
  parent: document.getElementById("editor")
});
view.focus();
clamacsReady(navigator.userAgent).then((greeting) => showEcho(greeting));
</script>
</body>
</html>
