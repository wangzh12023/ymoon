// The Yjs sync protocol (y-protocols/sync.js) and the y-websocket message
// framing on top of it.
//
// A sync exchange between two peers:
//
//   A -> B : SyncStep1(state vector of A)
//   B -> A : SyncStep2(update containing everything A is missing)
//   ...    : Update(incremental update) whenever either side changes
//
// The message bytes are identical to the JavaScript implementation, so these
// helpers interoperate with y-websocket, Hocuspocus and any other Yjs provider.

///|
/// Sync protocol sub-message kinds.
pub(all) enum SyncMessage {
  /// `messageYjsSyncStep1`: the sender's encoded state vector.
  SyncStep1(Bytes)
  /// `messageYjsSyncStep2`: an update answering a step 1.
  SyncStep2(Bytes)
  /// `messageYjsUpdate`: an incremental update.
  Update(Bytes)
} derive(Eq, Debug)

///|
/// Wire tag of a sync sub-message.
fn SyncMessage::tag(self : SyncMessage) -> Int {
  match self {
    SyncStep1(_) => 0
    SyncStep2(_) => 1
    Update(_) => 2
  }
}

///|
/// Payload of a sync sub-message.
fn SyncMessage::payload(self : SyncMessage) -> Bytes {
  match self {
    SyncStep1(b) | SyncStep2(b) | Update(b) => b
  }
}

///|
/// Writes a sync sub-message (`writeSyncStep1` / `writeSyncStep2` /
/// `writeUpdate`).
pub fn SyncMessage::write(self : SyncMessage, enc : @lib0.Encoder) -> Unit {
  enc.write_var_uint(self.tag())
  enc.write_var_bytes(self.payload())
}

///|
/// Reads a sync sub-message.
pub fn SyncMessage::read(
  dec : @lib0.Decoder,
) -> SyncMessage raise @lib0.DecodeError {
  let pos = dec.pos()
  let tag = dec.read_var_uint()
  let payload = dec.read_var_bytes()
  match tag {
    0 => SyncStep1(payload)
    1 => SyncStep2(payload)
    2 => Update(payload)
    _ => raise UnknownTag(pos~, tag~)
  }
}

///|
/// Builds the step-1 message for `doc` (`writeSyncStep1`).
pub fn sync_step1(doc : @ymoon.Doc) -> SyncMessage {
  SyncStep1(doc.encode_state_vector())
}

///|
/// Builds the step-2 answer to a peer's state vector (`writeSyncStep2`).
pub fn sync_step2(
  doc : @ymoon.Doc,
  remote_state_vector : BytesView,
) -> SyncMessage raise @lib0.DecodeError {
  let sv = @ymoon.StateVector::decode(remote_state_vector)
  SyncStep2(doc.encode_state_as_update(target=sv))
}

///|
/// Handles an incoming sync sub-message (`readSyncMessage`): a step 1 yields
/// the step-2 reply to send back; steps 2 and updates are applied to `doc`.
pub fn handle_sync_message(
  doc : @ymoon.Doc,
  msg : SyncMessage,
  origin? : String = "remote",
) -> SyncMessage? raise @lib0.DecodeError {
  match msg {
    SyncStep1(sv) => Some(sync_step2(doc, sv))
    SyncStep2(update) | Update(update) => {
      doc.apply_update(update, origin~)
      None
    }
  }
}

///|
/// Top-level message kinds used by y-websocket.
pub(all) enum Message {
  /// `messageSync` (0) carrying a sync sub-message.
  Sync(SyncMessage)
  /// `messageAwareness` (1) carrying an encoded awareness update.
  AwarenessUpdate(Bytes)
  /// `messageAuth` (2): permission denied with a reason.
  AuthPermissionDenied(String)
  /// `messageQueryAwareness` (3): ask peers to resend their awareness.
  QueryAwareness
} derive(Eq, Debug)

///|
/// Encodes a y-websocket message.
pub fn Message::encode(self : Message) -> Bytes {
  let enc = @lib0.Encoder()
  match self {
    Sync(m) => {
      enc.write_var_uint(0)
      m.write(enc)
    }
    AwarenessUpdate(update) => {
      enc.write_var_uint(1)
      enc.write_var_bytes(update)
    }
    AuthPermissionDenied(reason) => {
      enc.write_var_uint(2)
      enc.write_var_uint(0)
      enc.write_var_string(reason)
    }
    QueryAwareness => enc.write_var_uint(3)
  }
  enc.to_bytes()
}

///|
/// Decodes a y-websocket message.
pub fn Message::decode(data : BytesView) -> Message raise @lib0.DecodeError {
  let dec = @lib0.Decoder(data)
  let pos = dec.pos()
  let tag = dec.read_var_uint()
  match tag {
    0 => Sync(SyncMessage::read(dec))
    1 => AwarenessUpdate(dec.read_var_bytes())
    2 => {
      let auth_tag = dec.read_var_uint()
      guard auth_tag == 0 else { raise UnknownTag(pos~, tag=auth_tag) }
      AuthPermissionDenied(dec.read_var_string())
    }
    3 => QueryAwareness
    _ => raise UnknownTag(pos~, tag~)
  }
}
