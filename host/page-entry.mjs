// page-entry.mjs -- what the page takes from CodeMirror 6, bundled by
// esbuild into one IIFE that leaves it in window.CM (host/build.sh).
//
// No keymap, no history, no closeBrackets: the Emacs layer is the keymap
// and the Lisp-side mirror the history (specs/clamacs-host.md, "Keys go to
// Lisp first").  What is here is the view, the state and the decoration
// machinery the colouring is painted with.

import {EditorView, Decoration, lineNumbers, drawSelection, highlightActiveLine}
  from "@codemirror/view";
import {EditorState, StateField, StateEffect, RangeSetBuilder}
  from "@codemirror/state";

window.CM = {EditorView, EditorState, Decoration, StateField, StateEffect,
             RangeSetBuilder, lineNumbers, drawSelection, highlightActiveLine};
