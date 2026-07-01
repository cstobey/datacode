@0xa93fc509624c72d9;

# DataCode Transaction Log — Cap'n Proto schema (reference; not compiled in this spike)
#
# This schema describes what the production binary format would look like.
# Key properties that make Cap'n Proto the right choice over cereal/protobuf:
#
#   Zero-copy: log files can be mmap'd; field access requires no deserialization.
#   The bytes on disk ARE the in-memory representation — analogous to Erlang/Mnesia
#   storing raw BEAM terms. Cap'n Proto calls this "time-zero overhead."
#
#   Schema evolution: adding fields to any struct is automatically backward compatible.
#   Old readers see defaults for new fields; new readers see absent values for old-format
#   messages. No version byte, no migration code, no branching.
#
#   Pointer compression: variable-length fields (Text, List, Data) stored by pointer
#   within the message segment. Fixed-width fields (integers) are inline. A reader
#   that only needs txNodeId never pays the cost of deserializing txMutations.
#
# Usage in production:
#   capnp compile -ohaskell schema/datacode.capnp
#   -- generates Capnp/Gen/Datacode.hs with typed Haskell accessors

struct RowId {
  # Uniquely identifies a row version across all shards.
  # 14 bytes when extracted to bytes for LMDB keys (big-endian each field).
  # Big-endian encoding: lexicographic order = numeric order,
  # so LMDB range scans over a shard's transactions are contiguous.
  shardId @0 :UInt32;   # which shard (4 bytes)
  txSeq   @1 :UInt64;   # monotonic transaction sequence within shard (8 bytes)
  rowPos  @2 :UInt16;   # row position within the transaction (2 bytes)
}

struct Value {
  # Typed schema value. Cap'n Proto discriminant is 2 bytes inline in the struct.
  # Only the active branch is stored — absent branches cost nothing.
  union {
    int       @0 :Int64;
    text      @1 :Text;
    bool      @2 :Bool;
    uuid      @3 :Data;     # 16 bytes raw
    decimal   @4 :Data;     # big-endian binary-coded decimal
    timestamp @5 :Int64;    # microseconds since Unix epoch
    absent    @6 :Void;     # NOT_FOUND / NULL analog
  }
}

struct Field {
  name  @0 :Text;
  value @1 :Value;
}

struct Row {
  # One immutable row version.
  id        @0 :RowId;
  tableRef  @1 :Text;        # "app.commerce.orders"
  fields    @2 :List(Field);
}

struct Mutation {
  union {
    insert @0 :Row;    # new row version written
    delete @1 :RowId;  # tombstone: this version is superseded
  }
}

struct TxNode {
  # One node in the transaction DAG. Written sequentially to the append log.
  # New fields added here are automatically backward compatible — old readers
  # see the default value (zero / empty) without any code change.
  id          @0 :RowId;
  schemaVer   @1 :Data;         # 32-byte hash of current schema graph node
  timestamp   @2 :Int64;        # microseconds since Unix epoch
  serverId    @3 :UInt32;       # which server committed this transaction
  parents     @4 :List(RowId);  # parent TxNode IDs (1 normally; 2 on merge)
  mutations   @5 :List(Mutation);
  # Fields added in future versions appear here; old writers omit them;
  # old readers see their default values. No migration needed.
}
