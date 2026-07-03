@0xdeadbeef12345678;

# DataCode binary format — Cap'n Proto schema
#
# This file is the authoritative definition of the on-disk binary format.
# Code generation: capnp compile -ohaskell --src-prefix=. datacode.capnp
# Requires capnproto tool: apt install capnproto / brew install capnproto
#
# Row identifier: ShardId:Word32 + TxSeq:Word64 + RowPos:Word16 = 14 bytes.
# Stored as raw Data blobs — Cap'n Proto treats them as opaque bytes.

struct Value {
  # Typed field value. VAbsent maps to NOT_FOUND — the DataCode typed null.
  union {
    int    @0 :Int64;
    text   @1 :Text;
    bool   @2 :Bool;
    uuid   @3 :Data;   # exactly 16 bytes
    absent @4 :Void;   # NOT_FOUND
  }
}

struct Field {
  name  @0 :Text;
  value @1 :Value;
}

struct Row {
  id     @0 :Data;         # 14-byte RowId (ShardId:Word32 + TxSeq:Word64 + RowPos:Word16)
  table  @1 :Text;         # fully-qualified namespace.table name
  fields @2 :List(Field);
}

struct Mutation {
  union {
    insert @0 :Row;
    delete @1 :Data;       # 14-byte RowId (tombstone)
  }
}

struct TxNode {
  # V1 fields — @0 through @5.
  id         @0 :Data;             # 14-byte RowId of this transaction node
  schemaVer  @1 :Data;             # 32-byte SHA-256 of schema graph node
  timestamp  @2 :Int64;            # µs since Unix epoch
  serverId   @3 :UInt32;
  parents    @4 :List(Data);       # parent TxNode RowIds (1 normally; 2 on merge)
  mutations  @5 :List(Mutation);

  # V2 addition: schema version sequence number.
  # Old writers omit this field; old readers ignore it.
  # New readers see 0 (the default) when reading V1 data — no migration needed.
  # schemaVersion @6 :UInt32 = 0;
}
