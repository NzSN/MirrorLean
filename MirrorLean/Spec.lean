import MirrorLean.Value
import MirrorLean.Protocol

/-!
# MirrorLean.Spec

TLA+ spec source closure (design section 7, port of MirrorECMA src/spec.ts):
a remote mirror has no filesystem access to client files, so the root spec
plus its transitive EXTENDS/INSTANCE closure travels inline in the register
messages (ApalacheSpec.sources, root first).

Since Lean 4.33 ships no regex module, EXTENDS/INSTANCE detection is a small
hand-written scanner. It skips \\* line comments, nested (* ... *) comments,
and strings, then tokenizes identifiers and commas. This recognizes continued
EXTENDS clauses and INSTANCE in top-level, LOCAL, and expression forms.
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

/-- Skip a quoted TLA+ string, including escaped characters. -/
private partial def skipString : List Char → List Char
  | [] => []
  | '\\' :: _ :: rest => skipString rest
  | '"' :: rest => rest
  | _ :: rest => skipString rest

/-- Identifier characters used for TLA+ module names and keywords. -/
private def identStart (c : Char) : Bool := c.isAlpha || c == '_'
private def identContinue (c : Char) : Bool := c.isAlphanum || c == '_'

/-- Tokenize identifiers and commas outside strings. Comments have already
been stripped by `stripComments`, including nested block comments. -/
private partial def dependencyTokens : List Char → List String
  | [] => []
  | '"' :: rest => dependencyTokens (skipString rest)
  | ',' :: rest => "," :: dependencyTokens rest
  | c :: rest =>
      if identStart c then
        let (suffix, tail) := rest.span identContinue
        String.ofList (c :: suffix) :: dependencyTokens tail
      else
        dependencyTokens rest

/-- Remaining names in an EXTENDS comma list after its first module. -/
private partial def extendsTail : List String → List String
  | "," :: name :: rest => name :: extendsTail rest
  | _ => []

/-- Extract EXTENDS and INSTANCE references from the token stream. -/
private partial def moduleRefsFromTokens : List String → List String
  | [] => []
  | "EXTENDS" :: name :: rest =>
      name :: (extendsTail rest ++ moduleRefsFromTokens rest)
  | "INSTANCE" :: name :: rest => name :: moduleRefsFromTokens rest
  | _ :: rest => moduleRefsFromTokens rest

/-- All EXTENDS/INSTANCE module references outside comments and strings. -/
private def moduleRefs (src : String) : List String :=
  moduleRefsFromTokens (dependencyTokens (stripComments src).toList)
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
  let canonical ← existing.mapM (fun p => (IO.FS.realPath (System.FilePath.mk p)).map (·.toString))
  let distinct := canonical.foldl (fun acc p => if acc.elem p then acc else acc ++ [p]) []
  match distinct with
  | [] => throw (IO.userError s!"module {name} not found; searched {cands}")
  | p :: ps =>
      if !ps.isEmpty then
        throw (IO.userError s!"module {name} is ambiguous: found both {p} and {ps}")
      else pure p

/-- BFS over the dependency closure: resolve each pending module, read it,
and queue its own references. Canonical paths are never re-read. -/
private partial def collectDeps (queue : List (String × String)) (visited : List String)
    (acc : Array String) (searchDirs : List String) : IO (Array String) := do
  match queue with
  | [] => pure acc
  | (importDir, name) :: rest =>
      let path ← resolveModule importDir name searchDirs
      if visited.elem path then
        collectDeps rest visited acc searchDirs
      else do
        let src ← IO.FS.readFile (System.FilePath.mk path)
        let dir := dirOf path
        let refs := moduleRefs src
        collectDeps (rest ++ refs.map (fun r => (dir, r))) (path :: visited) (acc.push src) searchDirs

/-- Read the root spec and its transitive EXTENDS/INSTANCE closure into an
ApalacheSpec, root source first. searchDirs defaults to TLA_LIBRARY_PATH
(colon-separated) when empty. -/
def specFromFiles (root : System.FilePath) (searchDirs : Array System.FilePath := #[])
    : IO (Except SpecError ApalacheSpec) := do
  let dirs ← match searchDirs.toList with
    | [] => pure ((← IO.getEnv "TLA_LIBRARY_PATH").getD "" |>.splitOn ":" |>.filter (fun d => d != ""))
    | ds => pure (ds.map (fun p => p.toString))
  try
    let rootCanonical ← IO.FS.realPath root
    let rootPath := rootCanonical.toString
    let rootSrc ← IO.FS.readFile rootCanonical
    let rootDir := dirOf rootPath
    let refs := moduleRefs rootSrc
    let deps ← collectDeps (refs.map (fun r => (rootDir, r))) [rootPath] #[] dirs
    pure (.ok { sources := #[rootSrc] ++ deps })
  catch e =>
    pure (.error { msg := IO.Error.toString e, contexts := #[] })

/-- Read the root spec alone (no explicit search dirs). -/
def specFromFile (root : System.FilePath) : IO (Except SpecError ApalacheSpec) :=
  specFromFiles root

end MirrorLean
