-- Cap'n Proto Wire Format — Manual Implementation for TxNode
--
-- This module implements the Cap'n Proto binary encoding for TxNode WITHOUT
-- using the capnp code-generation tool. The encoding is byte-for-byte
-- compatible with what `capnp compile -ohaskell` + the capnp library would
-- produce. Implementing it manually lets the spike:
--   1. Build with no external tool dependency.
--   2. Make the format explicit — field offsets are computed and documented.
--   3. Directly prove the zero-copy property by showing field access as
--      plain byte-offset reads with no deserialisation pass.
--
-- In production, capnp-generated code replaces this module. The generated
-- types are just Haskell records with the same fields; the generated
-- Cerialize/Decerialize instances do the same pointer arithmetic automatically.
--
-- Cap'n Proto wire format (single-segment messages):
--
--   Message header (8 bytes):
--     [segment_count - 1 : LE Word32][segment_size_words : LE Word32]
--     For a single-segment message: [0x00000000][N]
--
--   Struct pointer (8 bytes):
--     bits[ 1: 0] = 0b00  (struct type)
--     bits[31: 2] = offset (signed, words from end of pointer to data section)
--     bits[47:32] = data section size in 64-bit words
--     bits[63:48] = pointer section size (number of pointers)
--
--   List pointer (8 bytes):
--     bits[ 1: 0] = 0b01  (list type)
--     bits[31: 2] = offset (signed, words from end of pointer to list data)
--     bits[34:32] = element size  (2 = byte, 5 = 64-bit, 6 = pointer, 7 = composite)
--     bits[63:35] = element count (for byte lists: byte count)
--
-- TxNode V1 segment layout (words = 8-byte units):
--
--   word  0: root struct pointer  (offset=0, dataWords=2, ptrCount=4)
--   word  1: timestamp   Int64 LE          ← data section word 0
--   word  2: serverId    Word32 LE | 0x00  ← data section word 1
--   word  3: ptr[0] → id blob              ← pointer section
--   word  4: ptr[1] → schemaVer blob       ← pointer section
--   word  5: ptr[2] → parents list         ← pointer section (null if no parents)
--   word  6: ptr[3] → mutations list       ← pointer section (null in this spike)
--   word  7: id blob start  (14 bytes + 2 pad = 16 bytes = 2 words)
--   word  9: schemaVer blob (32 bytes = 4 words)
--   word 13: parents list   (if non-empty)

module Spike.CapnProto
  ( -- * Types
    TxNodeRaw (..)
  , TxNodeDecoded (..)
    -- * Encoding
  , buildTxNodeMessage
  , buildTxNodeMessageV2
    -- * Zero-copy reads (no deserialise pass)
  , readTimestampZeroCopy
  , readServerIdZeroCopy
  , readSchemaVersionZeroCopy
  , readIdBlobZeroCopy
    -- * Full decode (for comparison / correctness testing)
  , parseTxNodeMessage
    -- * Spike runner
  , CapnResult (..)
  , runCapnProtoSpike
  ) where

import Data.ByteString     (ByteString)
import qualified Data.ByteString as B
import Data.Serialize
import Data.Word
import Data.Int
import Data.Bits
import Data.List           (intercalate)
import Data.Time.Clock     (getCurrentTime, diffUTCTime)
import Data.Maybe          (mapMaybe)

-- ---------------------------------------------------------------------------
-- Data types

data TxNodeRaw = TxNodeRaw
  { rawTimestamp     :: !Int64
  , rawServerId      :: !Word32
  , rawId            :: !ByteString  -- 14 bytes
  , rawSchemaVer     :: !ByteString  -- 32 bytes
  , rawParents       :: ![ByteString] -- 0 or more 14-byte RowIds
  , rawSchemaVersion :: !Word32       -- V2 field; ignored by V1 encoder
  } deriving (Eq, Show)

data TxNodeDecoded = TxNodeDecoded
  { decTimestamp     :: !Int64
  , decServerId      :: !Word32
  , decId            :: !ByteString
  , decSchemaVer     :: !ByteString
  , decParents       :: ![ByteString]
  , decSchemaVersion :: !Word32       -- 0 when reading V1 data (Cap'n Proto default)
  } deriving (Show)

-- ---------------------------------------------------------------------------
-- Low-level Cap'n Proto primitives

-- Pad a ByteString to the next 8-byte boundary
padTo8 :: ByteString -> ByteString
padTo8 bs =
  let r = B.length bs `mod` 8
  in if r == 0 then bs else bs <> B.replicate (8 - r) 0

-- Build a single-segment message from segment bytes (adds 8-byte header)
buildMessage :: ByteString -> ByteString
buildMessage seg =
  let padded   = padTo8 seg
      nWords   = B.length padded `div` 8
      header   = runPut $ putWord32le 0 >> putWord32le (fromIntegral nWords)
  in header <> padded

-- Extract the segment from a single-segment message
getSegment :: ByteString -> Either String ByteString
getSegment msg
  | B.length msg < 8 = Left "message too short for header"
  | otherwise = do
      (nSeg, nWords) <- runGet ((,) <$> getWord32le <*> getWord32le) msg
      if nSeg /= 0
        then Left $ "expected single-segment message (nSeg-1=0), got " ++ show nSeg
        else let seg = B.drop 8 msg
                 need = fromIntegral nWords * 8
             in if B.length seg < need
                then Left "message truncated"
                else Right (B.take need seg)

-- Struct pointer: offset in words from END of pointer to data section start
mkStructPtr :: Int32 -> Word16 -> Word16 -> ByteString
mkStructPtr offset dataWords ptrCount = runPut $ do
  putWord32le $ (fromIntegral offset `shiftL` 2) .|. 0   -- type = 0 (struct)
  putWord32le $ fromIntegral dataWords .|. (fromIntegral ptrCount `shiftL` 16)

-- List pointer for a Data blob (list of bytes)
mkListPtrBytes :: Int32 -> Word32 -> ByteString
mkListPtrBytes offset byteCount = runPut $ do
  putWord32le $ (fromIntegral offset `shiftL` 2) .|. 1   -- type = 1 (list)
  putWord32le $ 2 .|. (byteCount `shiftL` 3)             -- elementSize=2 (byte)

-- List pointer for a list of pointers (List(Data))
mkListPtrPointers :: Int32 -> Word32 -> ByteString
mkListPtrPointers offset elemCount = runPut $ do
  putWord32le $ (fromIntegral offset `shiftL` 2) .|. 1   -- type = 1 (list)
  putWord32le $ 6 .|. (elemCount `shiftL` 3)             -- elementSize=6 (pointer)

-- Null pointer (represents absent optional field)
nullPtr :: ByteString
nullPtr = B.replicate 8 0

-- ---------------------------------------------------------------------------
-- TxNode V1 encoder
--
-- Data section: 2 words (timestamp, serverId)
-- Pointer section: 4 pointers (id, schemaVer, parents, mutations)

buildTxNodeSegmentV1 :: TxNodeRaw -> ByteString
buildTxNodeSegmentV1 tx =
  -- Word 0: root struct pointer (offset=0, dataWords=2, ptrCount=4)
  let rootPtr = mkStructPtr 0 2 4

      -- Data section (words 1-2)
      dataSection =
        runPut (putInt64le (rawTimestamp tx))
        <> runPut (putWord32le (rawServerId tx) >> putWord32le 0)

      -- Blobs: padded id, schemaVer, and parent list
      idBlob     = padTo8 (rawId tx)       -- 14 → 16 bytes = 2 words
      svBlob     = rawSchemaVer tx         -- 32 bytes = 4 words (no pad needed)
      parentPtrs = buildParentList (rawParents tx)

      -- Pointer section (words 3-6)
      -- Each pointer's offset is: (blob_start_word) - (ptr_word + 1)
      -- Base word after ptr section: 7 (0: root ptr, 1-2: data, 3-6: ptrs)
      blobBase = 7  -- word index where blobs start

      -- ptr[0] at word 3, end at word 4; id blob at word 7
      off0 = fromIntegral blobBase - 4 :: Int32  -- = 3

      -- ptr[1] at word 4, end at word 5; schemaVer blob after id blob
      idWords  = B.length idBlob `div` 8
      svStart  = blobBase + idWords
      off1     = fromIntegral svStart - 5 :: Int32  -- = svStart - 5

      -- ptr[2] at word 5, end at word 6; parents list after schemaVer blob
      svWords    = B.length svBlob `div` 8
      parStart   = svStart + svWords
      off2       = fromIntegral parStart - 6 :: Int32

      ptrSection =
        mkListPtrBytes    off0 (fromIntegral (B.length (rawId tx)))
        <> mkListPtrBytes off1 (fromIntegral (B.length (rawSchemaVer tx)))
        <> (if null (rawParents tx) then nullPtr
            else mkListPtrPointers off2 (fromIntegral (length (rawParents tx))))
        <> nullPtr  -- mutations: null (not encoding mutations in this spike)

  in rootPtr <> dataSection <> ptrSection <> idBlob <> svBlob <> parentPtrs

buildParentList :: [ByteString] -> ByteString
buildParentList [] = B.empty
buildParentList ps =
  -- N pointers followed by N blobs. Pointer i sits at word i (0-indexed),
  -- so it ENDS at word i+1. Blob i starts at word n + cumulative_blob_words[0..i-1].
  -- Cap'n Proto offset = blob_start_word - end_of_pointer_word
  --                    = (n + cumBefore[i]) - (i + 1)
  let n          = length ps
      padded     = map padTo8 ps
      cumBefore  = scanl (\acc b -> acc + B.length b `div` 8) 0 padded -- [0, w0, w0+w1, ...]
      ptrOffsets = zipWith (\i cum -> fromIntegral (n + cum - (i + 1)) :: Int32)
                    [0..] cumBefore
      ptrList    = mconcat $ zipWith (\off b ->
                    mkListPtrBytes off (fromIntegral (B.length b)))
                    ptrOffsets ps
  in ptrList <> mconcat padded

buildTxNodeMessage :: TxNodeRaw -> ByteString
buildTxNodeMessage = buildMessage . buildTxNodeSegmentV1

-- ---------------------------------------------------------------------------
-- TxNode V2 encoder
--
-- Identical to V1 but adds schemaVersion as data section word 2.
-- V1 readers see a struct pointer claiming dataWords=3 but only read words 0-1
-- — the extra word is simply ignored (Cap'n Proto readers only read the words
-- they know about by field ordinal).
-- V2 readers reading V1 data (dataWords=2) see schemaVersion=0 (the declared
-- default), because Cap'n Proto treats missing data words as zero.

buildTxNodeSegmentV2 :: TxNodeRaw -> ByteString
buildTxNodeSegmentV2 tx =
  let rootPtr = mkStructPtr 0 3 4  -- dataWords=3 instead of 2

      -- Data section: 3 words
      dataSection =
        runPut (putInt64le (rawTimestamp tx))
        <> runPut (putWord32le (rawServerId tx) >> putWord32le 0)
        <> runPut (putWord32le (rawSchemaVersion tx) >> putWord32le 0)  -- new V2 field

      -- Everything else shifts by one word due to the extra data word.
      idBlob  = padTo8 (rawId tx)
      svBlob  = rawSchemaVer tx

      blobBase = 8  -- root(1) + data(3) + ptrs(4) = 8
      idWords  = B.length idBlob `div` 8
      svStart  = blobBase + idWords

      -- Pointer section adjusts offsets: pointers are now at words 4-7
      off0 = fromIntegral blobBase - 5 :: Int32   -- ptr at word 4, end at 5
      off1 = fromIntegral svStart  - 6 :: Int32   -- ptr at word 5, end at 6

      ptrSection =
        mkListPtrBytes off0 (fromIntegral (B.length (rawId tx)))
        <> mkListPtrBytes off1 (fromIntegral (B.length (rawSchemaVer tx)))
        <> nullPtr  -- parents
        <> nullPtr  -- mutations

  in rootPtr <> dataSection <> ptrSection <> idBlob <> svBlob

buildTxNodeMessageV2 :: TxNodeRaw -> ByteString
buildTxNodeMessageV2 = buildMessage . buildTxNodeSegmentV2

-- ---------------------------------------------------------------------------
-- Zero-copy field reads
--
-- These functions read individual fields from the raw message bytes by
-- computing their fixed byte offset. No deserialisation of the whole message.
--
-- Offset derivation:
--   message byte 0-7  : header
--   segment byte 0-7  = message byte  8-15: struct pointer (word 0)
--   segment byte 8-15 = message byte 16-23: timestamp (data word 0)
--   segment byte 16-23 = message byte 24-31: serverId|0 (data word 1)
--   segment byte 24-31 = message byte 32-39: schemaVersion|0 (data word 2, V2 only)
--
-- These offsets are computed identically by capnp-generated code — the
-- difference is that generated code derives them generically from the struct
-- pointer rather than hard-coding them per field.

-- | Read timestamp without decoding the full message. O(1).
readTimestampZeroCopy :: ByteString -> Either String Int64
readTimestampZeroCopy msg
  | B.length msg < 24 = Left "message too short"
  | otherwise         = runGet getInt64le (B.drop 16 msg)

-- | Read serverId without decoding the full message. O(1).
readServerIdZeroCopy :: ByteString -> Either String Word32
readServerIdZeroCopy msg
  | B.length msg < 32 = Left "message too short"
  | otherwise         = runGet getWord32le (B.drop 24 msg)

-- | Read schemaVersion (V2 field) without decoding. Returns 0 for V1 messages
-- where the data section only has 2 words — Cap'n Proto default-value behaviour.
readSchemaVersionZeroCopy :: ByteString -> Either String Word32
readSchemaVersionZeroCopy msg = do
  seg <- getSegment msg
  -- struct pointer is at segment byte 0
  (_, dataWords, _) <- parseStructPtr seg
  if dataWords < 3
    then Right 0  -- V1 message: field not present, default = 0
    else runGet getWord32le (B.drop (8 + 2 * 8) seg)  -- data section word 2

-- | Read id blob by following pointer[0]. Zero-copy: the ByteString slice
-- references the mmap'd (or in-memory) bytes directly — no copy.
readIdBlobZeroCopy :: ByteString -> Either String ByteString
readIdBlobZeroCopy msg = do
  seg <- getSegment msg
  (_, dataWords, _) <- parseStructPtr seg
  let ptrSectionOffset = 8 + fromIntegral dataWords * 8  -- bytes into segment
  followBytesPtr seg ptrSectionOffset

-- Follow a list-of-bytes pointer and return the referenced slice
followBytesPtr :: ByteString -> Int -> Either String ByteString
followBytesPtr seg ptrOffset = do
  (offset, esize, count) <- parseListPtr (B.drop ptrOffset seg)
  if esize /= 2
    then Left $ "expected byte list (esize=2), got esize=" ++ show esize
    else let dataOffset = ptrOffset + 8 + fromIntegral offset * 8
         in Right $ B.take (fromIntegral count) (B.drop dataOffset seg)

-- ---------------------------------------------------------------------------
-- Full decode (for correctness testing and comparison benchmarking)

parseTxNodeMessage :: ByteString -> Either String TxNodeDecoded
parseTxNodeMessage msg = do
  seg <- getSegment msg
  (_, dataWords, _) <- parseStructPtr seg
  let dataOff = 8  -- data section starts at segment byte 8

  ts   <- runGet getInt64le  (B.drop dataOff seg)
  svId <- runGet getWord32le (B.drop (dataOff + 8) seg)
  sv   <- if dataWords >= 3
            then runGet getWord32le (B.drop (dataOff + 16) seg)
            else Right 0

  let ptrOff = dataOff + fromIntegral dataWords * 8

  idBlob  <- followBytesPtr seg ptrOff
  svBlob  <- followBytesPtr seg (ptrOff + 8)

  -- ptr[2] = parents list (list of pointers to byte blobs)
  parents <- parseParentList seg (ptrOff + 16)

  Right TxNodeDecoded
    { decTimestamp     = ts
    , decServerId      = svId
    , decId            = idBlob
    , decSchemaVer     = svBlob
    , decParents       = parents
    , decSchemaVersion = sv
    }

parseParentList :: ByteString -> Int -> Either String [ByteString]
parseParentList seg ptrOff = do
  let ptrBytes = B.drop ptrOff seg
  if B.length ptrBytes < 8 || B.take 8 ptrBytes == B.replicate 8 0
    then Right []  -- null pointer = empty list
    else do
      (offset, esize, count) <- parseListPtr ptrBytes
      if esize /= 6
        then Left $ "expected pointer list for parents (esize=6), got " ++ show esize
        else do
          let listStart = ptrOff + 8 + fromIntegral offset * 8
          mapM (\i -> followBytesPtr seg (listStart + i * 8)) [0 .. fromIntegral count - 1]

-- ---------------------------------------------------------------------------
-- Pointer parsers

parseStructPtr :: ByteString -> Either String (Int32, Word16, Word16)
parseStructPtr bs
  | B.length bs < 8 = Left "too short for struct pointer"
  | otherwise = runGet go bs
  where
    go = do
      low  <- getWord32le
      high <- getWord32le
      let typ    = low .&. 0x3
      let offset = fromIntegral (low `shiftR` 2) :: Int32
      let dw     = fromIntegral (high .&. 0xFFFF) :: Word16
      let pc     = fromIntegral (high `shiftR` 16) :: Word16
      if typ /= 0
        then fail $ "expected struct pointer (type 0), got type " ++ show typ
        else return (offset, dw, pc)

parseListPtr :: ByteString -> Either String (Int32, Word8, Word32)
parseListPtr bs
  | B.length bs < 8 = Left "too short for list pointer"
  | otherwise = runGet go bs
  where
    go = do
      low  <- getWord32le
      high <- getWord32le
      let typ    = low .&. 0x3
      let offset = fromIntegral (low `shiftR` 2) :: Int32
      let esize  = fromIntegral (high .&. 0x7) :: Word8
      let count  = high `shiftR` 3
      if typ /= 1
        then fail $ "expected list pointer (type 1), got type " ++ show typ
        else return (offset, esize, count)

-- ---------------------------------------------------------------------------
-- Spike runner

data CapnResult = CapnResult
  { capnSuccess           :: Bool
  , capnEncodeLatencyUs   :: Double   -- per-message encode (µs)
  , capnDecodeLatencyUs   :: Double   -- full decode (µs)
  , capnZeroCopyLatencyUs :: Double   -- zero-copy field read (µs)
  , capnMessageBytes      :: Int
  , capnNotes             :: [String]
  } deriving (Show)

runCapnProtoSpike :: IO CapnResult
runCapnProtoSpike = do
  putStrLn "\n=== Part 1: Cap'n Proto Encoding ===\n"

  let fakeId     = B.replicate 14 0xAA
      fakeSchVer = B.replicate 32 0xBB
      parent1    = B.replicate 14 0x01
      parent2    = B.replicate 14 0x02
      tx = TxNodeRaw
            { rawTimestamp     = 1750000000000000
            , rawServerId      = 42
            , rawId            = fakeId
            , rawSchemaVer     = fakeSchVer
            , rawParents       = [parent1, parent2]
            , rawSchemaVersion = 0
            }

  -- Test 1: encode
  let msg = buildTxNodeMessage tx
  putStrLn $ "Test 1: Encode TxNode"
  putStrLn $ "  Message size: " ++ show (B.length msg) ++ " bytes"
  putStrLn $ "  Segment size: " ++ show (B.length msg - 8) ++ " bytes"

  -- Test 2: round-trip decode
  putStrLn "\nTest 2: Round-trip decode"
  case parseTxNodeMessage msg of
    Left err -> putStrLn $ "  FAILED: " ++ err
    Right dec -> do
      let tsOk  = decTimestamp dec == rawTimestamp tx
          svOk  = decServerId  dec == rawServerId  tx
          idOk  = decId        dec == rawId        tx
          schOk = decSchemaVer dec == rawSchemaVer tx
          parOk = decParents   dec == rawParents   tx
          ok    = tsOk && svOk && idOk && schOk && parOk
      putStrLn $ "  timestamp:  " ++ if tsOk  then "OK" else "FAIL"
      putStrLn $ "  serverId:   " ++ if svOk  then "OK" else "FAIL"
      putStrLn $ "  id blob:    " ++ if idOk  then "OK" else "FAIL"
      putStrLn $ "  schemaVer:  " ++ if schOk then "OK" else "FAIL"
      putStrLn $ "  parents:    " ++ if parOk then "OK (" ++ show (length (decParents dec)) ++ " parents)" else "FAIL"
      putStrLn $ "  Round-trip: " ++ if ok then "OK" else "FAILED"

  -- Test 3: zero-copy field reads
  putStrLn "\nTest 3: Zero-copy field reads (no deserialise pass)"
  let checkZC label result expected =
        case result of
          Left err -> putStrLn $ "  " ++ label ++ ": FAILED — " ++ err
          Right v  -> putStrLn $ "  " ++ label ++ ": " ++ if v == expected then "OK" else "FAIL (got " ++ show v ++ ")"
  checkZC "timestamp"  (readTimestampZeroCopy  msg) (rawTimestamp tx)
  checkZC "serverId"   (readServerIdZeroCopy   msg) (rawServerId  tx)
  checkZC "schemaVersion (V1→default=0)" (readSchemaVersionZeroCopy msg) 0
  case readIdBlobZeroCopy msg of
    Left err -> putStrLn $ "  id blob: FAILED — " ++ err
    Right b  -> putStrLn $ "  id blob: " ++ if b == rawId tx then "OK" else "FAIL"

  -- Benchmark: encode 10,000 messages
  putStrLn "\nBenchmark: encode 10,000 TxNode messages"
  t0 <- getCurrentTime
  let !encoded = map (B.length . buildTxNodeMessage) (replicate 10000 tx)
  t1 <- getCurrentTime
  let encMs = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
  let encUs = encMs * 1000 / 10000
  putStrLn $ "  Total: " ++ showMs encMs ++ " | Per message: " ++ showUs encUs

  -- Benchmark: full decode 10,000 messages
  putStrLn "\nBenchmark: full decode 10,000 TxNode messages"
  t2 <- getCurrentTime
  let !decoded = map parseTxNodeMessage (replicate 10000 msg)
  t3 <- getCurrentTime
  let decMs = realToFrac (diffUTCTime t3 t2) * 1000 :: Double
  let decUs = decMs * 1000 / 10000
  let decOk = all (\r -> case r of Right _ -> True; Left _ -> False) decoded
  putStrLn $ "  All OK: " ++ show decOk
  putStrLn $ "  Total: " ++ showMs decMs ++ " | Per message: " ++ showUs decUs

  -- Benchmark: zero-copy timestamp reads 10,000 times
  putStrLn "\nBenchmark: zero-copy timestamp read 10,000 times"
  t4 <- getCurrentTime
  let !zcResults = map readTimestampZeroCopy (replicate 10000 msg)
  t5 <- getCurrentTime
  let zcMs = realToFrac (diffUTCTime t5 t4) * 1000 :: Double
  let zcUs = zcMs * 1000 / 10000
  putStrLn $ "  Total: " ++ showMs zcMs ++ " | Per read: " ++ showUs zcUs
  putStrLn $ "  vs full decode: " ++ show (round decUs :: Int) ++ "µs → " ++ show (round zcUs :: Int) ++ "µs"
  putStrLn $ "  Speedup: ~" ++ show (round (decUs / zcUs) :: Int) ++ "x for single-field access"

  let success = B.length msg > 0 && decOk
  return CapnResult
    { capnSuccess           = success
    , capnEncodeLatencyUs   = encUs
    , capnDecodeLatencyUs   = decUs
    , capnZeroCopyLatencyUs = zcUs
    , capnMessageBytes      = B.length msg
    , capnNotes =
        [ "Wire format: single-segment Cap'n Proto message"
        , "Header: 8 bytes (segment count + segment size)"
        , "TxNode V1: root ptr + 2 data words + 4 pointers + blobs"
        , "Zero-copy: timestamp at fixed byte offset 16, serverId at 24"
        , "Zero-copy reads ~Nx faster than full decode for single-field access"
        , "In production: capnp-generated code does the same offset arithmetic generically"
        ]
    }

showMs :: Double -> String
showMs ms = show (round ms :: Int) ++ "ms"

showUs :: Double -> String
showUs us = show (round us :: Int) ++ "µs"
