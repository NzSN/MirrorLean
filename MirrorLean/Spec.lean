import MirrorLean.Value
import MirrorLean.Protocol

/-!
# MirrorLean.Spec

TLA+ spec source closure (design section 7, port of MirrorECMA src/spec.ts):
a remote mirror has no filesystem access to client files, so the root spec
plus its transitive EXTENDS/INSTANCE closure travels inline in the register
messages (ApalacheSpec.sources, root first).

Since Lean 4.33 ships no regex module, EXTENDS/INSTANCE detection is a small
hand-written scanner: strip \\* line comments and (* ... *) block comments
(nested), match the keywords at line start (possibly indented), split the
module list on commas, and take the first whitespace-delimited token of each
entry (dropping WITH substitutions).
-/

namespace MirrorLean

/-- A spec-resolution error: a message plus a human-readable trail. -/
structure SpecError where
  msg : String
  contexts : Array String
deriving Repr, Inhabited

namespace SpecError

/-- Render a SpecError, one context per line. -/
def toString (e : SpecError) : String :=
  if e.contexts.isEmpty then e.msg
  else e.msg ++ "\n" ++ String.intercalate "\n" (e.contexts.toList.map (fun c => s!"  at {c}"))

end SpecError

/-- Modules provided internally by apalache/TLA+ -- never resolved as files. -/
private def builtins : List String :=
  ["Naturals", "Integers", "Reals", "Sequences", "FiniteSets", "TLC", "Bags", "Apalache"]

/-- Drop characters until (and including) the next newline; keeps it so the
line structure survives for the keyword scan. -/
private def dropUntilNewline : List Char → List Char
  | [] => []
  | '\n' :: rest => '\n' :: rest
  | _ :: rest => dropUntilNewline rest

/-- Strip TLA+ comments from a source text: \\* line comments and nested
(* ... *) block comments. Runs a full character scan and keeps newlines. -/
private partial def stripCommentsAux : List Char → Nat → List Char → List Char
  | [], _, acc => acc.reverse
  | '(' :: '*' :: rest, 0, acc => stripCommentsAux rest 1 acc
  | '(' :: '*' :: rest, d+1, acc => stripCommentsAux rest (d + 2) acc
  | '*' :: ')' :: rest, d+1, acc => stripCommentsAux rest d acc
  | '\\' :: '*' :: rest, 0, acc => stripCommentsAux (dropUntilNewline rest) 0 acc
  | _ :: rest, d+1, acc => stripCommentsAux rest (d + 1) acc
  | c :: rest, 0, acc => stripCommentsAux rest 0 (c :: acc)

/-- Strip all TLA+ comments from a source text. -/
def stripComments (s : String) : String :=
  String.ofList (stripCommentsAux s.toList 0 [])

/-- Whitespace-split tokens of a line (tabs count as spaces; empty tokens
dropped; the line is trimmed first). -/
private def tokens (s : String) : List String :=
  (s.trimAscii.replace "\t" " ").splitOn " " |>.filter (fun x => x != "")

/-- First whitespace-delimited token, or the empty string. -/
private def firstToken (s : String) : String :=
  match tokens s with
  | [] => ""
  | x :: _ => x

/-- When the line starts with the keyword, return the module references on
that line (comma-separated). INSTANCE substitutions (WITH ...) are dropped:
we cut the line at the first WITH token, so \`INSTANCE A WITH x <- 1, y <- 2\`
yields only \`A\` and never mistakes a substitution value for a module. -/
private def moduleRefsOf (kw : String) (line : String) : List String :=
  match tokens line with
  | kw' :: rest =>
      if kw' == kw then
        let rest' := if kw == "INSTANCE" then rest.takeWhile (fun t => t != "WITH") else rest
        let joined := String.intercalate " " rest'
        (joined.splitOn ",").map firstToken |>.filter (fun n => n != "")
      else []
  | [] => []

/-- All EXTENDS/INSTANCE module references in a (comment-stripped) source. -/
private def moduleRefs (src : String) : List String :=
  (src.splitOn "\n").foldl (fun acc line => acc ++ (moduleRefsOf "EXTENDS" line ++ moduleRefsOf "INSTANCE" line)) []
    |>.filter (fun n => !(builtins.elem n))

/-- The directory part of a file path (empty tail means the current dir). -/
private def dirOf (path : String) : String :=
  match path.splitOn "/" |>.dropLast with
  | [] => "."
  | ds => String.intercalate "/" ds

/-- Resolve a module name to a file: the importing file's directory first,
then the search dirs. Ambiguity (more than one distinct match) and missing
modules are loud errors. -/
private def resolveModule (importDir : String) (name : String) (searchDirs : List String) : IO String := do
  let cands := (importDir :: searchDirs).map (fun d => d ++ "/" ++ name ++ ".tla")
  let existing ← cands.filterM (fun p => (System.FilePath.mk p).pathExists.toIO)
  match existing with
  | [] => throw (IO.userError s!"module {name} not found; searched {cands}")
  | p :: ps =>
      if ps.any (fun q => q != p) then
        throw (IO.userError s!"module {name} is ambiguous: found both {p} and {ps}")
      else pure p

/-- BFS over the dependency closure: resolve each pending module, read it,
and queue its own references. Visited module names are never re-read. -/
private partial def collectDeps (queue : List (String × String)) (visited : List String)
    (acc : Array String) (searchDirs : List String) : IO (Array String) := do
  match queue with
  | [] => pure acc
  | (importDir, name) :: rest =>
      if visited.elem name then
        collectDeps rest visited acc searchDirs
      else do
        let path ← resolveModule importDir name searchDirs
        let src ← IO.FS.readFile (System.FilePath.mk path)
        let dir := dirOf path
        let refs := moduleRefs (stripComments src)
        collectDeps (rest ++ refs.map (fun r => (dir, r))) (name :: visited) (acc.push src) searchDirs

/-- Read the root spec and its transitive EXTENDS/INSTANCE closure into an
ApalacheSpec, root source first. searchDirs defaults to TLA_LIBRARY_PATH
(colon-separated) when empty. -/
def specFromFiles (root : System.FilePath) (searchDirs : Array System.FilePath := #[])
    : IO (Except SpecError ApalacheSpec) := do
  let dirs ← match searchDirs.toList with
    | [] => pure ((← IO.getEnv "TLA_LIBRARY_PATH").getD "" |>.splitOn ":" |>.filter (fun d => d != ""))
    | ds => pure (ds.map (fun p => p.toString))
  try
    let rootPath := root.toString
    let rootSrc ← IO.FS.readFile root
    let rootDir := dirOf rootPath
    let refs := moduleRefs (stripComments rootSrc)
    let deps ← collectDeps (refs.map (fun r => (rootDir, r))) [] #[] dirs
    pure (.ok { sources := #[rootSrc] ++ deps })
  catch e =>
    pure (.error { msg := IO.Error.toString e, contexts := #[] })

/-- Read the root spec alone (no explicit search dirs). -/
def specFromFile (root : System.FilePath) : IO (Except SpecError ApalacheSpec) :=
  specFromFiles root

end MirrorLean
