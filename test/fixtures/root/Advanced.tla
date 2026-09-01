---- MODULE Advanced ----
EXTENDS
  DepA,
  DepB

Text == "EXTENDS FakeString INSTANCE FakeString2"
(* outer comment
   EXTENDS FakeComment
   (* INSTANCE FakeNested *)
*)
\* INSTANCE FakeLine
Op == INSTANCE DepC WITH x <- 1
====
