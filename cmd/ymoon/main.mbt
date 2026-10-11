///|
/// `ymoon` command line entry point.
///
///   moon run cmd/ymoon -- inspect doc.ybin
///   moon run cmd/ymoon -- merge a.ybin b.ybin -o merged.ybin
fn main {
  let args = @env.args()
  // skip the program name (and the script path on the JS backend)
  let argv = match args.search_by(a => a.has_suffix(".js")) {
    Some(i) => args[i + 1:]
    None => args[1:]
  }
  run_cli(argv) catch {
    e => println("error: \{e}")
  }
}

///|
fn run_cli(argv : ArrayView[String]) -> Unit raise {
  let inv = @cli.parse_args(argv) catch {
    e => {
      println("\{e}")
      println(@cli.command().render_help())
      return
    }
  }
  let inputs : Array[Bytes] = []
  for path in inv.inputs {
    inputs.push(
      @fs.read_file_to_bytes(path) catch {
        e => fail("cannot read \{path}: \{Repr(e)}")
      },
    )
  }
  match @cli.run(inv, inputs) {
    Text(s) => println(s)
    Binary(b) =>
      match inv.output {
        Some(path) => {
          @fs.write_bytes_to_file(path, b) catch {
            e => fail("cannot write \{path}: \{Repr(e)}")
          }
          println("wrote \{b.length()} bytes to \{path}")
        }
        None => fail("missing --output")
      }
  }
}
