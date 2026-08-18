---------------- MODULE Counter ----------------
EXTENDS Integers

CONSTANTS
  \* @type: Set(Int);
  STRIDES

VARIABLE
  \* @type: Int;
  count,
  \* @type: { stride: Int };
  parameters,
  \* @type: Str;
  action_taken

Init ==
  count = 0 /\
  parameters = [stride |-> 0] /\
  action_taken = "init"

\* @type: () => Bool;
CInit == STRIDES = {2, 3}

TICK(S) ==
  S \in STRIDES /\
  count' = count + S /\
  parameters' = [stride |-> S] /\
  action_taken' = "tick"

Next ==
  \E S \in STRIDES: TICK(S)

View == count

\* Apalache treats a violated invariant as a counterexample = the test trace.
TraceComplete == count < 12

Spec == Init /\ [][Next]_<<count, parameters>>
========================================================
