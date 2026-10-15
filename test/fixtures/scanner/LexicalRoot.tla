---- MODULE LexicalRoot ----
OpeningMarker == "(* INSTANCE MissingQuoted"
ClosingMarker == "*) EXTENDS MissingQuoted"
LineMarker == "\\* INSTANCE MissingQuoted"
EscapedQuote == "escaped \" (* INSTANCE MissingQuoted"
EscapedBackslash == "escaped \\ (* EXTENDS MissingQuoted"
(* Outer " (* nested EXTENDS MissingComment *) " INSTANCE MissingComment *)
\* EXTENDS MissingLine
EXTENDS
  LexicalA,
  LexicalB
LOCAL Real == INSTANCE(* outer (* nested *) *)LexicalA
====
