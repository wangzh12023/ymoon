// `ymoon` command line tool: inspect, merge, diff and render Yjs v1 updates.
//
// The command logic is pure (bytes in, text/bytes out) so it can be tested
// and reused; file IO lives in `cmd/ymoon`.

///|
/// Result of running a command.
pub(all) enum Output {
  /// Text to print on stdout.
  Text(String)
  /// Binary data to write to the output file.
  Binary(Bytes)
}

///|
/// The argparse definition of the CLI.
pub fn command() -> @argparse.Command {
  let file = @argparse.PositionArg(
    "files",
    about="Yjs v1 update files (binary)",
    num_args=@argparse.ValueRange(lower=1),
  )
  @argparse.Command(
    "ymoon",
    about="Inspect and transform Yjs documents (yjs v1 update format)",
    version="0.1.0",
    subcommands=[
      @argparse.Command(
        "inspect",
        about="Decode updates: structs, delete set and statistics",
        positionals=[file],
        flags=[
          @argparse.FlagArg(
            "json",
            long="json",
            about="Machine readable output",
          ),
        ],
      ),
      @argparse.Command(
        "dump",
        about="Load updates into a document and print its content as JSON",
        positionals=[file],
      ),
      @argparse.Command(
        "merge",
        about="Merge updates into one (Y.mergeUpdates)",
        positionals=[file],
        options=[
          @argparse.OptionArg(
            "output",
            short='o',
            about="Output file",
            required=true,
          ),
        ],
      ),
      @argparse.Command(
        "compact",
        about="Load updates and re-encode the state (garbage collected)",
        positionals=[file],
        options=[
          @argparse.OptionArg(
            "output",
            short='o',
            about="Output file",
            required=true,
          ),
        ],
      ),
      @argparse.Command(
        "diff",
        about="Changes in UPDATE that a peer holding BASE is missing",
        positionals=[
          @argparse.PositionArg("base", about="Update the peer already has"),
          @argparse.PositionArg("update", about="Newer update"),
        ],
        options=[
          @argparse.OptionArg(
            "output",
            short='o',
            about="Output file",
            required=true,
          ),
        ],
      ),
      @argparse.Command("sv", about="Print the state vector of updates", positionals=[
        file,
      ]),
    ],
    subcommand_required=true,
  )
}

///|
/// A parsed invocation.
pub(all) struct Invocation {
  /// Subcommand name.
  name : String
  /// Input file paths, in order.
  inputs : Array[String]
  /// Output path for commands producing binary data.
  output : String?
  /// `--json` flag.
  json : Bool
}

///|
/// Parses command line arguments (without the program name).
pub fn parse_args(argv : ArrayView[String]) -> Invocation raise {
  let m = @argparse.parse(command(), argv~)
  guard m.subcommand is Some((name, sub)) else { fail("missing subcommand") }
  let inputs = match name {
    "diff" =>
      [
        sub.values.get("base").unwrap_or([]),
        sub.values.get("update").unwrap_or([]),
      ].flatten()
    _ => sub.values.get("files").unwrap_or([])
  }
  let output = match sub.values.get("output") {
    Some([o, ..]) => Some(o)
    _ => None
  }
  let json = sub.flags.get("json").unwrap_or(false)
  { name, inputs, output, json, }
}

///|
/// Runs a parsed invocation on already loaded input files.
pub fn run(inv : Invocation, inputs : Array[Bytes]) -> Output raise {
  match inv.name {
    "inspect" => Text(inspect_updates(inputs, json=inv.json))
    "dump" => {
      let doc = load(inputs)
      Text(doc_to_json(doc).stringify(indent=2))
    }
    "merge" => Binary(@ymoon.merge_updates(inputs))
    "compact" => Binary(load(inputs).encode_state_as_update())
    "diff" => {
      guard inputs is [base, update] else { fail("diff needs two files") }
      let sv = @ymoon.encode_state_vector_from_update(base)
      Binary(@ymoon.diff_update(update, sv))
    }
    "sv" => {
      let doc = load(inputs)
      let entries = doc
        .state_vector()
        .entries()
        .map(e => "  client \{e.0}: clock \{e.1}")
      Text("state vector (\{entries.length()} clients)\n" + entries.join("\n"))
    }
    other => fail("unknown command \{other}")
  }
}

///|
fn load(inputs : Array[Bytes]) -> @ymoon.Doc raise {
  let doc = @ymoon.Doc(client_id=0)
  for u in inputs {
    doc.apply_update(u)
  }
  doc
}

///|
/// JSON content of every root type of a document, roots sorted by name.
pub fn doc_to_json(doc : @ymoon.Doc) -> Json {
  let out : Map[String, Json] = Map([])
  // deterministic output regardless of the order roots were discovered in
  let names = doc.root_names()
  names.sort_by((a, b) => a.lexical_compare(b))
  for name in names {
    match doc.root(name) {
      Some(b) => out[name] = b.to_json()
      None => ()
    }
  }
  Json::object(out)
}

///|
/// Human readable or JSON description of updates.
pub fn inspect_updates(
  inputs : Array[Bytes],
  json~ : Bool = false,
) -> String raise {
  let sb = StringBuilder()
  let reports : Array[Json] = []
  for idx, u in inputs {
    let (structs, ds) = @ymoon.decode_update(u)
    let mut items = 0
    let mut gcs = 0
    let mut skips = 0
    let mut units = 0
    let clients : Map[UInt32, Int32] = Map([])
    for s in structs {
      match s {
        GC(client~, len~, ..) => {
          gcs += 1
          units += len
          clients[client] = clients.get(client).unwrap_or(0) + len
        }
        Skip(len~, ..) => {
          skips += 1
          ignore(len)
        }
        Item(client~, len~, ..) => {
          items += 1
          units += len
          clients[client] = clients.get(client).unwrap_or(0) + len
        }
      }
    }
    let mut deleted = 0
    let mut ranges = 0
    for c in ds.clients() {
      for r in ds.ranges(c) {
        deleted += r.len
        ranges += 1
      }
    }
    if json {
      reports.push(
        Json::object({
          "bytes": Json::number(u.length().to_double()),
          "items": Json::number(items.to_double()),
          "gc": Json::number(gcs.to_double()),
          "skips": Json::number(skips.to_double()),
          "clockUnits": Json::number(units.to_double()),
          "clients": Json::number(clients.length().to_double()),
          "deletedUnits": Json::number(deleted.to_double()),
          "deleteRanges": Json::number(ranges.to_double()),
        }),
      )
    } else {
      sb.write_string(
        "update #\{idx}: \{u.length()} bytes, \{items} items, \{gcs} gc, \{skips} skip, \{units} clock units, \{clients.length()} clients, \{deleted} deleted units in \{ranges} ranges\n",
      )
      let shown = @cmp.minimum(structs.length(), 20)
      for i in 0..<shown {
        sb.write_string("  \{describe(structs[i])}\n")
      }
      if structs.length() > shown {
        sb.write_string("  ... \{structs.length() - shown} more\n")
      }
    }
  }
  if json {
    Json::array(reports).stringify(indent=2)
  } else {
    sb.to_string()
  }
}

///|
fn describe(s : @ymoon.DecodedStruct) -> String {
  match s {
    GC(client~, clock~, len~) => "GC    \{client}:\{clock} len=\{len}"
    Skip(client~, clock~, len~) => "Skip  \{client}:\{clock} len=\{len}"
    Item(
      client~,
      clock~,
      len~,
      origin~,
      right_origin~,
      parent~,
      parent_sub~,
      content~
    ) => {
      let o = match origin {
        Some(id) => " origin=\{id.client}:\{id.clock}"
        None => ""
      }
      let r = match right_origin {
        Some(id) => " right=\{id.client}:\{id.clock}"
        None => ""
      }
      let p = match parent {
        Some(name) => " parent=\{name}"
        None => ""
      }
      let k = match parent_sub {
        Some(key) => " key=\{key}"
        None => ""
      }
      "Item  \{client}:\{clock} len=\{len}\{o}\{r}\{p}\{k} \{content}"
    }
  }
}
