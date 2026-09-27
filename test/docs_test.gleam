//// Publish the guide only after its pages are ready.
////
//// Generate documentation from checked public interfaces, module comments and
//// configured guides. Inspect links, Markdown, highlighting and offline
//// assets. Unsafe markup must not become active content, and a failed
//// generation must preserve the previous documentation tree.

import birdie
import builder/docs
import cli/cli
import cli/command
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pooka
import simplifile
import support
import tools/docgen/code
import tools/docgen/markdown

fn project(directory: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"docs_example\"\nversion = \"1.2.3\"\n",
  )
  support.write(
    directory <> "/README.md",
    "# Example package\n\nUse [types.Config] to configure a port.\n\n```pooka\nmake(7000)\n```\n",
  )
  support.write(
    directory <> "/src/types.pooka",
    "//// Configuration values.\nmodule types\n\n/// A public port configuration.\nclass Config {\n  /// Configured port.\n  let port: Int\n  let _secret: Int = 1\n  /// Construct a configuration.\n  new(port) { self.port = port }\n  /// Read the port.\n  value() { port }\n}\n\n/// A display contract.\ninterface Show {\n  /// Format the value.\n  show() -> String\n}\n\n/// An actor with an independent counter.\nactor Counter {\n  var count: Int = 0\n  value() { count }\n}\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "//// Construct [Settings] values.\nmodule main\nimport types.{Config as Settings}\n\n/// Make a [Settings] for the given port.\nmake(port: Int) -> Settings { Settings(port) }\n\n_hidden() { 42 }\n\n/// OTP arithmetic.\nexternal Math from erlang \"erlang\" {\n  /// Absolute value.\n  abs(value: Int) -> Int\n}\n",
  )
}

pub fn checked_public_api_includes_inferred_types_members_and_links_test() {
  use directory <- support.with_directory("docs_public_api")
  project(directory)

  support.write(
    directory <> "/test/invalid.spec.pooka",
    "this is not valid Pooka",
  )
  let assert Ok(report) = docs.generate(directory)
  assert report.modules == 2
  assert report.directory == directory <> "/build/dev/docs/docs_example"
  let assert Ok(main) = simplifile.read(report.directory <> "/module-main.html")
  assert string.contains(main, "fn(Int) -&gt;")
  assert string.contains(main, "href=\"module-types.html#symbol-Config\"")
  assert !string.contains(main, "_hidden")
  let assert Ok(types) =
    simplifile.read(report.directory <> "/module-types.html")
  assert string.contains(types, "symbol-Config.port")
  assert string.contains(types, "symbol-Config.new")
  assert string.contains(types, "symbol-Config.value")
  assert string.contains(types, "symbol-Show.show")
  assert string.contains(types, "symbol-Counter.value")
  assert !string.contains(types, "_secret")
  assert string.contains(main, "symbol-Math.abs")
  assert simplifile.is_file(
      directory
      <> "/build/dev/erlang/docs_example/ebin/pooka@docs_example@main.beam",
    )
    == Ok(False)
  let assert Ok(index) = simplifile.read(report.directory <> "/index.html")
  assert string.contains(index, "1.2.3")
  assert string.contains(index, "Example package</h1>")
  assert string.contains(index, "class=\"language-pooka\"")
  assert string.contains(index, "syntax-number\">7000</span>")
  birdie.snap(main, "documentation public API module")
}

// Do not replace yesterday's readable guide with half of today's failed
// attempt. Only a successful generation may publish new pages and prune
// obsolete ones.
pub fn invalid_projects_preserve_previous_docs_and_success_prunes_stale_pages_test() {
  use directory <- support.with_directory("docs_transaction")
  project(directory)
  let assert Ok(first) = docs.generate(directory)
  let assert Ok(original) =
    simplifile.read(first.directory <> "/module-main.html")
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmake() { missing() }\n",
  )
  let assert Error(_) = docs.generate(directory)
  assert simplifile.read(first.directory <> "/module-main.html") == Ok(original)
  support.write(directory <> "/src/main.pooka", "module main\nmake() { 42 }\n")
  let assert Ok(Nil) = simplifile.delete_file(directory <> "/src/types.pooka")
  let assert Ok(second) = docs.generate(directory)
  assert second.modules == 1
  assert simplifile.is_file(second.directory <> "/module-types.html")
    == Ok(False)
}

pub fn doc_comments_escape_html_and_reject_active_links_test() {
  let html =
    markdown.render(
      "# <script>alert(1)</script>\n\n[unsafe](javascript:alert) and [safe](https://example.org) and `Config`.",
      fn(name) {
        case name {
          "Config" -> Some("module-types.html#symbol-Config")
          _ -> None
        }
      },
    )
  assert !string.contains(html, "<script>")
  assert !string.contains(html, "href=\"javascript:")
  assert string.contains(html, "&lt;script&gt;")
  assert string.contains(html, "href=\"https://example.org\"")
  assert string.contains(
    html,
    "<code><a href=\"module-types.html#symbol-Config\">Config</a></code>",
  )
}

pub fn docs_command_reports_generation_and_validates_arguments_test() {
  use directory <- support.with_directory("docs_cli")
  project(directory)
  let env = command.plain(directory)
  let generated = cli.main(["docs"], pooka.version, env)
  assert generated.status == 0
  assert generated.stdout
    == "Documentation written to build/dev/docs/docs_example/index.html\n"
  assert string.contains(
    generated.stderr,
    "Generating docs_example documentation",
  )
  assert string.contains(generated.stderr, "Generated 2 modules in ")
  assert cli.main(["docs", "extra"], pooka.version, env).status == 1
}

pub fn nested_module_names_and_index_modules_have_distinct_pages_test() {
  use directory <- support.with_directory("docs_nested_modules")
  support.write(
    directory <> "/pooka.toml",
    "name = \"api\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/index.pooka",
    "module index\nidentity(value) { value }\n",
  )
  support.write(
    directory <> "/src/http/client.pooka",
    "//// The HTTP client.\nmodule client\nget() { 42 }\n",
  )
  let assert Ok(report) = docs.generate(directory)
  let assert Ok(index) = simplifile.read(report.directory <> "/index.html")
  assert string.contains(index, "Package API documentation.")
  assert string.contains(index, "href=\"module-http@client.html\"")
  assert string.contains(index, "href=\"module-index.html\"")
  let assert Ok(module_page) =
    simplifile.read(report.directory <> "/module-index.html")
  assert string.contains(module_page, "fn(a) -&gt; a")
  assert string.contains(module_page, "src/index.pooka:2")
}

pub fn markdown_supports_structured_comments_and_scoped_heading_links_test() {
  let html =
    markdown.render_scoped(
      "## Examples\n\n**Bold**, *emphasis*, and ~~removed~~.\n\n> A useful note.\n\n- One\n  - Nested\n- Two\n\n1. First\n2. Second\n\n| Name | Type |\n| --- | --- |\n| port | Int |\n\n[Jump](#examples)\n",
      fn(_) { None },
      "function-one-",
    )
  assert string.contains(html, "<strong>Bold</strong>")
  assert string.contains(html, "<em>emphasis</em>")
  assert string.contains(html, "<blockquote>")
  assert string.contains(html, "<table>")
  assert string.contains(html, "<ol>")
  assert string.contains(html, "Nested</li>")
  assert string.contains(html, "id=\"function-one-0-examples\"")
  assert string.contains(html, "href=\"#function-one-0-examples\"")
  let second =
    markdown.render_scoped("## Examples\n", fn(_) { None }, "function-two-")
  assert !string.contains(second, "function-one-")
}

// Code fences must keep their indentation and highlighting without borrowing
// a network asset at page-view time. Inspect the generated files, not just
// Markdown input.
pub fn generated_comment_examples_preserve_indentation_and_ship_offline_assets_test() {
  use directory <- support.with_directory("docs_comment_examples")
  support.write(
    directory <> "/pooka.toml",
    "name = \"api\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\n/// # Example\n///\n/// ```pooka\n/// let read = fn() {\n///   echo \"Pooka\"\n/// }\n/// ```\n///\n/// - A parent\n///   - A child\nanswer() { 42 }\n",
  )
  let assert Ok(report) = docs.generate(directory)
  let assert Ok(page) = simplifile.read(report.directory <> "/module-main.html")
  assert string.contains(page, "data-copy-code")
  assert string.contains(page, "\n  <span class=\"syntax-keyword\">echo</span>")
  assert string.contains(
    page,
    "class=\"syntax-string\">&quot;Pooka&quot;</span>",
  )
  assert string.contains(page, "<ul>\n<li>A child</li>")
  assert string.contains(page, "data-theme-toggle")
  assert !string.contains(page, "brand-mark")
  assert !string.contains(page, "Objects belong")
  assert string.contains(page, "project-heading")
  assert string.contains(page, "data-nav-search")
  assert string.contains(page, "aria-label=\"On this page\"")
  assert string.contains(page, "symbol-group\">Functions</h3>")
  assert string.contains(page, "src=\"docs.js\"")
  let assert Ok(css) = simplifile.read(report.directory <> "/style.css")
  assert string.contains(css, "--lantern-orange: #ff891f")
  assert string.contains(css, "--midnight: #211c1b")
  assert string.contains(css, "--cream: #fff6e9")
  assert string.contains(css, "--forest: #30463d")
  assert string.contains(css, "--magic-violet: #75618e")
  assert string.contains(css, "prefers-color-scheme: dark")
  let assert Ok(script) = simplifile.read(report.directory <> "/docs.js")
  assert string.contains(script, "localStorage.setItem('pooka-docs-theme'")
  assert !string.contains(page, "https://cdn.")
  birdie.snap(page, "documentation code examples and navigation")
}

// Escaping raw tags is not enough if an encoded link can still become active
// content. Exercise those spellings inside richer Markdown structures too.
pub fn markdown_sanitizes_encoded_links_and_raw_html_inside_rich_content_test() {
  let html =
    markdown.render(
      "**[unsafe](javascript:alert)**\n\n[encoded](javascript&colon;alert)\n\n> <img src=x onerror=alert(1)>\n\n~~~pooka\nlet value = \"<script>\"\n~~~\n",
      fn(_) { None },
    )
  assert !string.contains(html, "href=\"javascript:")
  assert !string.contains(html, "<img src=x")
  assert string.contains(html, "&lt;script&gt;")
  assert string.contains(html, "code-example")
  assert code.highlight("let café = \"Pooka\"\n  echo café\n")
    |> string.contains("\n  <span class=\"syntax-keyword\">echo</span>")
}

pub fn configured_links_and_markdown_guides_appear_on_every_page_test() {
  use directory <- support.with_directory("docs_configured_navigation")
  project(directory)
  support.write(
    directory <> "/pooka.toml",
    "name = \"docs_example\"\nversion = \"1.2.3\"\nlinks = [{title = \"Sponsor <Pooka>\", href = \"https://example.org/?a=1&b=2\"}]\n[repository]\ntype = \"github\"\nuser = \"example\"\nrepo = \"package\"\n[[documentation.pages]]\ntitle = \"Getting started\"\npath = \"getting-started.html\"\nsource = \"docs/start.md\"\n",
  )
  support.write(
    directory <> "/docs/start.md",
    "# Welcome\n\nSee [types.Config].\n\n```pooka\nlet port = 7000\n```\n",
  )
  let assert Ok(report) = docs.generate(directory)
  let assert Ok(index) = simplifile.read(report.directory <> "/index.html")
  let assert Ok(main) = simplifile.read(report.directory <> "/module-main.html")
  let assert Ok(guide) =
    simplifile.read(report.directory <> "/getting-started.html")
  assert string.contains(index, "href=\"getting-started.html\"")
  assert string.contains(main, "href=\"https://github.com/example/package\"")
  assert string.contains(guide, "Sponsor &lt;Pooka&gt;")
  assert string.contains(guide, "https://example.org/?a=1&amp;b=2")
  assert string.contains(
    guide,
    "href=\"getting-started.html\" aria-current=\"page\"",
  )
  assert !string.contains(guide, "href=\"index.html\" aria-current=\"page\"")
  assert string.contains(guide, "href=\"module-types.html#symbol-Config\"")
  assert string.contains(guide, "syntax-number\">7000</span>")
  let assert Ok(#(_, navigation)) =
    string.split_once(guide, "<nav class=\"nav-scroll\"")
  let assert Ok(#(navigation, _)) = string.split_once(navigation, "</nav>")
  birdie.snap(navigation, "documentation configurable navigation")
}

pub fn missing_guide_preserves_docs_and_removed_guide_is_pruned_test() {
  use directory <- support.with_directory("docs_guide_transaction")
  project(directory)
  let assert Ok(manifest) = simplifile.read(directory <> "/pooka.toml")
  support.write(
    directory <> "/pooka.toml",
    manifest
      <> "[[documentation.pages]]\ntitle = \"Guide\"\npath = \"guide.html\"\nsource = \"guide.md\"\n",
  )
  support.write(directory <> "/guide.md", "# A guide\n")
  let assert Ok(report) = docs.generate(directory)
  let assert Ok(original) = simplifile.read(report.directory <> "/guide.html")
  let assert Ok(Nil) = simplifile.delete_file(directory <> "/guide.md")
  let assert Error(_) = docs.generate(directory)
  assert simplifile.read(report.directory <> "/guide.html") == Ok(original)
  support.write(directory <> "/pooka.toml", manifest)
  let assert Ok(_) = docs.generate(directory)
  assert simplifile.is_file(report.directory <> "/guide.html") == Ok(False)
}

// Keep image paths unchanged. The same README should work in its repository,
// the local site and a versioned HexDocs directory without link rewriting.
pub fn readme_assets_are_copied_to_local_docs_and_pruned_on_regeneration_test() {
  use directory <- support.with_directory("docs_readme_assets")
  project(directory)
  support.write(
    directory <> "/README.md",
    "# Images\n\n![Plot](assets/nested/plot.png)\n\n<img src=\"assets/logo.svg\" alt=\"Logo\" />\n",
  )
  support.write(directory <> "/assets/logo.svg", "<svg></svg>")
  support.write(directory <> "/assets/.hidden", "not an asset")
  support.write(directory <> "/assets/nested/placeholder", "")
  let image = <<0, 255, 1, 128, 10>>
  let assert Ok(Nil) =
    simplifile.write_bits(directory <> "/assets/nested/plot.png", image)
  let assert Ok(report) = docs.generate(directory)
  assert simplifile.read_bits(report.directory <> "/assets/nested/plot.png")
    == Ok(image)
  assert simplifile.read(report.directory <> "/assets/logo.svg")
    == Ok("<svg></svg>")
  assert simplifile.is_file(report.directory <> "/assets/.hidden") == Ok(False)
  let assert Ok(index) = simplifile.read(report.directory <> "/index.html")
  assert string.contains(index, "src=\"assets/nested/plot.png\"")
  assert string.contains(index, "src=\"assets/logo.svg\"")
  let assert Ok(Nil) = simplifile.delete_file(directory <> "/assets/logo.svg")
  let assert Ok(again) = docs.generate(directory)
  assert simplifile.is_file(again.directory <> "/assets/logo.svg") == Ok(False)
}

pub fn unsafe_asset_links_preserve_the_previous_documentation_test() {
  use directory <- support.with_directory("docs_asset_symlink")
  project(directory)
  support.write(directory <> "/assets/logo.svg", "<svg></svg>")
  let assert Ok(first) = docs.generate(directory)
  support.write(directory <> "/outside", "not a documentation asset")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      directory <> "/outside",
      directory <> "/assets/link.png",
    )
  let assert Error(_) = docs.generate(directory)
  assert simplifile.read(first.directory <> "/assets/logo.svg")
    == Ok("<svg></svg>")
  assert simplifile.is_file(first.directory <> "/assets/link.png") == Ok(False)
}

pub fn centered_readme_images_allow_only_safe_attributes_test() {
  let rendered =
    markdown.render(
      "<p align=\"center\">\n<img src=\"assets/noxy.png\" alt=\"Pooka\" width=\"280\" />\n</p>",
      fn(_) { None },
    )
  assert string.contains(rendered, "<p align=\"center\">")
  assert string.contains(rendered, "src=\"assets/noxy.png\"")
  assert string.contains(rendered, "width=\"280\"")
  list.each(
    [
      "<img src=\"assets/x.png\" onerror=\"alert(1)\" />",
      "<img src=\"javascript:alert(1)\" />",
      "<img src=\"javascript&#58;alert(1)\" />",
      "<img src=\"assets/x.png\" style=\"background:url(javascript:x)\" />",
      "<p onclick=\"alert(1)\"><img src=\"assets/x.png\" /></p>",
    ],
    fn(source) {
      let rendered = markdown.render(source, fn(_) { None })
      assert !string.contains(rendered, "<img")
      assert !string.contains(rendered, "<p onclick")
    },
  )
}

pub fn generated_pages_include_a_progressively_enhanced_version_selector_test() {
  use directory <- support.with_directory("docs_version_selector")
  project(directory)
  let assert Ok(report) = docs.generate(directory)
  list.each(["index.html", "module-main.html", "module-types.html"], fn(file) {
    let assert Ok(page) = simplifile.read(report.directory <> "/" <> file)
    assert string.contains(page, "data-version=\"1.2.3\"")
    assert string.contains(
      page,
      "data-docs-url=\"https://docs-example.hexdocs.pm/\"",
    )
    assert string.contains(page, "data-version-current>v1.2.3</span>")
    assert string.contains(page, "aria-label=\"Documentation version\" hidden")
    assert !string.contains(page, "src=\"https://")
  })
  let assert Ok(script) = simplifile.read(report.directory <> "/docs.js")
  assert string.contains(script, "/docs_config.js")
  assert string.contains(script, "window.versionNodes")
}

// Authors are credited on the overview, in manifest order, as escaped text.
// Packages without authors keep the overview free of an empty byline.
pub fn authors_are_credited_on_the_overview_test() {
  use directory <- support.with_directory("docs_authors")
  project(directory)
  support.write(
    directory <> "/pooka.toml",
    "name = \"docs_example\"\nversion = \"1.2.3\"\nauthors = [\"Peregrine Finch\", \"Ada <ada@example.org>\"]\n",
  )
  let assert Ok(report) = docs.generate(directory)
  let assert Ok(index) = simplifile.read(report.directory <> "/index.html")
  assert string.contains(
    index,
    "<p class=\"package-authors\">By Peregrine Finch, Ada &lt;ada@example.org&gt;</p>",
  )
  let assert Ok(main) = simplifile.read(report.directory <> "/module-main.html")
  assert !string.contains(main, "package-authors\">")
  support.write(
    directory <> "/pooka.toml",
    "name = \"docs_example\"\nversion = \"1.2.3\"\n",
  )
  let assert Ok(report) = docs.generate(directory)
  let assert Ok(index) = simplifile.read(report.directory <> "/index.html")
  assert !string.contains(index, "package-authors\">")
}
