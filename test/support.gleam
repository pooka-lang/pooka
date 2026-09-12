//// Keep the test tools predictable, then leave the evidence readable.
////
//// Shared helpers create temporary projects, parse source, execute BEAM
//// modules and render stable diagnostic output. Normalization removes selected
//// volatile timings and echo locations only where tests request it. It must
//// not hide program values or replace the lower-level tests of those details.
////
//// ```gleam
//// use directory <- support.with_directory("example")
//// support.write(directory <> "/src/main.pooka", "module main\n")
//// ```

import cli/cli
import cli/command
import compiler/codegen/beam
import compiler/compiler
import compiler/lexer/lexer
import compiler/lexer/token
import compiler/parser/ast
import compiler/parser/parse_error
import compiler/parser/parser
import diagnostics/diagnostic.{type Diagnostic}
import diagnostics/render
import gleam/dict
import gleam/list
import gleam/string
import pooka
import pprint
import simplifile
import utilities/colour
import utilities/location.{type Span}

pub const path = "src/main.pooka"

/// Prepare a named temporary room, pass it to the test, then remove it on
/// normal return. A failed assertion may leave the directory behind as
/// evidence; the next invocation clears the old room before starting.
///
/// ```gleam
/// use directory <- support.with_directory("my_case")
/// support.write(directory <> "/note.txt", "hello")
/// ```
pub fn with_directory(name: String, body: fn(String) -> a) -> a {
  let assert Ok(working_directory) = simplifile.current_directory()
  let directory = working_directory <> "/build/test_tmp/" <> name
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let result = body(directory)
  let _ = simplifile.delete(directory)
  result
}

/// Write a fixture after creating its parent directories. Tests declare only
/// the files they need rather than maintaining a shared project that another
/// test could accidentally change.
pub fn write(path: String, contents: String) -> Nil {
  let parent = case list.reverse(string.split(path, "/")) {
    [_, ..rest] -> string.join(list.reverse(rest), "/")
    [] -> "."
  }
  let assert Ok(Nil) = simplifile.create_directory_all(parent)
  let assert Ok(Nil) = simplifile.write(path, contents)
  Nil
}

/// Locate the first exact occurrence of a fixture fragment using byte offsets.
/// Unicode needles therefore need their byte size rather than a character
/// count.
///
/// ```gleam
/// let span = support.span_of("α = 1", "1")
/// assert support.text_at("α = 1", span) == "1"
/// ```
pub fn span_of(source: String, needle: String) -> Span {
  let assert Ok(#(before, _)) = string.split_once(source, needle)
  let start = string.byte_size(before)
  location.span(source, start, start + string.byte_size(needle))
}

/// Read the original source slice covered by a span. This is useful when a
/// diagnostic must underline only a name rather than its surrounding pattern
/// or type arguments.
pub fn text_at(source: String, span: Span) -> String {
  location.text(source, span)
}

/// Keep significant token values while discarding trivia, spans and EOF. Use
/// the lexer snapshot helpers when those discarded details are the subject of
/// the test.
///
/// ```gleam
/// assert support.tokens("1 + 2") == [token.Int("1"), token.Plus, token.Int("2")]
/// ```
pub fn tokens(source: String) -> List(token.Token) {
  lexer.lex(source).tokens
  |> lexer.significant
  |> list.map(fn(lexeme) { lexeme.token })
  |> list.filter(fn(found) { found != token.EndOfFile })
}

/// Parse a complete source fixture and require no parser errors. Tests of
/// malformed input use the error-preserving helpers instead, so recovery is
/// not mistaken for successful syntax.
pub fn parse(source: String) -> ast.Module {
  let output = parser.parse(lexer.lex(source).tokens)
  assert output.errors == []
  output.module
}

/// Keep the recovered module even when parsing reports errors. This helper is
/// for assertions about what survived recovery, not proof that the source was
/// accepted.
pub fn parse_module_with_errors(source: String) -> ast.Module {
  parser.parse(lexer.lex(source).tokens).module
}

/// Return parser errors directly, leaving lexical-error assertions to the
/// lexer suites. Callers can inspect constructors and source spans without
/// rendering a whole diagnostic frame.
pub fn parse_errors(source: String) -> List(parse_error.ParseError) {
  parser.parse(lexer.lex(source).tokens).errors
}

/// Run the public single-source checker at the conventional fixture path and
/// keep its diagnostic IDs. This tests front-end integration rather than one
/// analysis in isolation.
pub fn diagnostic_ids(source: String) -> List(String) {
  compiler.check_source(path, source).diagnostics
  |> list.map(fn(diagnostic) { diagnostic.id })
}

/// Place a statement fragment inside a small function and require that wrapper
/// to parse. The wrapper intentionally gives fragment tests a real callable
/// body and its source offsets.
pub fn parse_body(body: String) -> List(ast.Statement) {
  let module = parse("module main\n\nexample() {\n" <> body <> "\n}\n")
  let assert [ast.FunctionDeclaration(function)] = module.declarations
  function.body.statements
}

/// Require one expression statement from the wrapped fragment. An accidental
/// second statement should fail the helper rather than be silently dropped.
///
/// ```gleam
/// let tree = support.expression("1 + 2 * 3")
/// ```
pub fn expression(source: String) -> ast.Expression {
  let assert [ast.ExpressionStatement(expression)] = parse_body(source)
  expression
}

/// Render structured values without terminal styling, preserving labels and
/// bit arrays. AST snapshots use this representation so their shape remains
/// visible in ordinary text diffs.
pub fn pretty(value: a) -> String {
  pprint.with_config(
    value,
    pprint.Config(pprint.Unstyled, pprint.KeepBitArrays, pprint.Labels),
  )
}

/// Include the source beside its checked diagnostics. Keeping both in a
/// snapshot gives a reader the original question as well as the compiler's
/// answer.
pub fn rendered(source: String) -> String {
  let diagnostics = compiler.check_source(path, source).diagnostics
  "Source:\n" <> source <> "\n---\n" <> render_all(diagnostics, source)
}

/// Render a diagnostic list against the conventional fixture source with
/// verbose notices and plain text. Colour-specific tests choose their renderer
/// explicitly instead.
pub fn render_all(diagnostics: List(Diagnostic), source: String) -> String {
  render.render_all(
    diagnostics,
    dict.from_list([#(path, source)]),
    colour.PlainText,
    diagnostic.Verbose,
  )
}

/// Make ESC visible without stripping the styling information. Snapshots can
/// then distinguish a missing reset from a correctly closed colour sequence.
///
/// ```gleam
/// assert support.show_escapes("\u{001b}[0m") == "<ESC>[0m"
/// ```
pub fn show_escapes(text: String) -> String {
  string.replace(text, "\u{001b}", "<ESC>")
}

const activity_labels = [
  "Compiling", "Compiled", "Running", "Checking", "Checked", "Formatted",
]

/// Remove known activity lines from captured stderr when a test wants only the
/// diagnostic body. Tests of the activity log itself must inspect the original
/// stream.
pub fn diagnostics(stderr: String) -> String {
  stderr
  |> string.split("\n")
  |> list.filter(fn(line) {
    case string.split_once(string.trim_start(line), " ") {
      Ok(#(label, _)) -> !list.contains(activity_labels, label)
      Error(Nil) -> line != ""
    }
  })
  |> string.join("\n")
}

/// Remove recognized echo location lines while keeping their printed values.
/// This is a fixture-output convenience, not the path for tests of echo
/// locations or terminal style.
pub fn debug_values(output: String) -> String {
  output
  |> string.split("\n")
  |> list.filter(fn(line) {
    case string.split_once(colour.strip(line), ".pooka:") {
      Ok(#(path, number)) -> {
        !{
          {
            string.starts_with(path, "src/")
            || string.starts_with(path, "test/")
            || string.starts_with(path, "$package/")
          }
          && number != ""
          && list.all(string.to_graphemes(number), fn(c) {
            string.contains("0123456789", c)
          })
        }
      }
      Error(_) -> True
    }
  })
  |> string.join("\n")
}

/// Run the CLI with the supplied environment, normalizing selected stdout
/// timing and echo-location details. The Outcome still carries the real status
/// and stderr for assertions.
pub fn cli_main(
  arguments: List(String),
  env: command.Environment,
) -> command.Outcome {
  let result = cli.main(arguments, pooka.version, env)
  command.Outcome(..result, stdout: durations(debug_values(result.stdout)))
}

/// Replace parenthesized duration-shaped text with a stable zero duration.
/// Ordinary parenthesized words stay intact, so output normalization does not
/// erase unrelated program text.
///
/// ```gleam
/// assert support.durations("case (12.4ms)") == "case (0µs)"
/// ```
pub fn durations(text: String) -> String {
  case string.split(text, "(") {
    [] -> text
    [first, ..rest] ->
      list.fold(rest, first, fn(kept, piece) {
        case string.split_once(piece, ")") {
          Ok(#(inside, after)) ->
            case is_duration(inside) {
              True -> kept <> "(0µs)" <> after
              False -> kept <> "(" <> piece
            }
          Error(Nil) -> kept <> "(" <> piece
        }
      })
  }
}

/// Recognize only the narrow numeric-and-unit shape accepted by the snapshot
/// normalizer. This deliberately does not parse arbitrary human-readable time
/// expressions.
fn is_duration(text: String) -> Bool {
  let number =
    ["µs", "ms", "s"]
    |> list.find_map(fn(unit) {
      case string.ends_with(text, unit) {
        True -> Ok(string.drop_end(text, string.length(unit)))
        False -> Error(Nil)
      }
    })
  case number {
    Ok(digits) if digits != "" ->
      string.to_graphemes(digits)
      |> list.all(fn(c) { string.contains("0123456789.", c) })
    _ -> False
  }
}

/// Execute a compiled module with runtime colour disabled, then normalize echo
/// locations only on success. Return execution failures unchanged so tests can
/// inspect the real failure report.
pub fn execute(
  directory: String,
  module: String,
  arguments: List(String),
) -> Result(String, String) {
  case beam.execute(directory, module, arguments, False) {
    Ok(output) -> Ok(debug_values(output))
    Error(error) -> Error(error)
  }
}
