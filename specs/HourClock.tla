---------------- MODULE HourClock ---------------------
EXTENDS Naturals
VARIABLE
  \* @type: Int;
  hr,
  \* @type: Int;
  latest_hr,
  \* @type: Bool;
  ticked,
  \* @type: Str;
  action_taken,
  \* @type: { start_hr: Int, start_latest_hr: Int };
  nondet_picks,
  \* @type: Int;
  step_count


\* @type: () => Bool;
HCinit ==
  hr \in (1..12) /\
  latest_hr \in (1..12) /\
  ticked = FALSE /\
  action_taken = "init" /\
  nondet_picks = [start_hr |-> hr, start_latest_hr |-> latest_hr] /\
  step_count = 0

\* @type: () => Bool;
HCnext ==
  (ticked' = TRUE) /\
  (hr' = IF hr # 12 THEN hr + 1 ELSE 1) /\
  (latest_hr' = hr) /\
  (action_taken' = "tick") /\
  (nondet_picks' = nondet_picks) /\
  (step_count' = step_count + 1)

Init == HCinit
Next == HCnext
Inv == IF ticked
        THEN IF hr # 1
                THEN hr = latest_hr + 1
                ELSE latest_hr = 12
        ELSE TRUE

\* Becomes FALSE once the trace has taken 13 or more ticks.
\* 13 guarantees at least one full wrap-around regardless of the
\* initial hr (worst case: init at 1, wraps at tick 12, proven at tick 13).
\* Apalache treats the violation as a counterexample = the test trace.
TraceComplete == step_count < 13

HC == HCinit /\ [][HCnext]_hr
=======================================================
