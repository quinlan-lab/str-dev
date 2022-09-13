import streams
import msgpack4nim
export msgpack4nim
import strformat
import hts/bam
import strutils
import version
import tables

import ./extract

proc `==`(a, b:Target): bool =
  return a.tid == b.tid and a.length == b.length and a.name == b.name

proc same*(a:seq[Target], b:seq[Target]): bool =
  if a.len != b.len:
    return false
  for i, aa in a:
    if aa != b[i]:
      return false
  return true

proc same_lengths*(a: seq[Target], b:seq[Target]): seq[Target] =
  var btbl = newTable[string, Target]()
  for bt in b:
    btbl[bt.name] = bt

  for at in a:
    if at.name notin btbl:
      continue
    let bt = btbl[at.name]
    if at.length != bt.length:
      raise newException(KeyError, "differing lengths for chromosome " & at.name)
    result.add(at)

proc unpack_type[ByteStream](s: ByteStream, x: var tread) =
  s.unpack(x.tid)
  s.unpack(x.position)
  s.unpack(x.repeat)
  var f:uint16
  s.unpack(f)
  x.flag = Flag(f)
  var split:uint8
  s.unpack(split)
  x.split = Soft(split)
  s.unpack(x.mapping_quality)
  s.unpack(x.repeat_count)
  s.unpack(x.align_length)
  var L:uint32 = 0
  var qname: string
  s.unpack(L)
  qname = newString(L)
  if L > 0'u32:
    s.unpack(qname)
  x.qname = qname


proc unpack_file*(fs:FileStream, expected_format_version:int16=0, drop_unplaced:bool=false, verbose:bool=false, targets:seq[Target] = @[], requested_tid: int32=int32.low): tuple[targets: seq[Target], fragment_distribution: array[4096, uint32], reads: seq[tread]] =
  doAssert fs != nil, "[strling] got nil fileStream in unpack_file. check given file-path"

  var str = fs.readStr(3)
  doAssert str == "STR", "[strling] expected bin file to start with \"STR\". This may indicate that this bin file was generated by an old version of STRling. Please re-run the extract step with this version."

  var fmtVersion:int16
  fs.read(fmtVersion)
  doAssert fmtVersion == thisFmtVersion, &"[strling] this bin file was generated using a different format. Please re-run the extract step with the same version of STRling."

  var softVersion: array[9, char]
  fs.read(softVersion)

  var softVersionString = softVersion.join()
  if verbose:
    stderr.write_line &"[strling] read format version {fmtVersion} from software version {softVersionString}"
    if softVersion != strlingVersion.asArray9():
      stderr.write_line &"[strling] WARNING: this bin file was generated by a different version of STRling: {softVersionString}. Current version is: {strlingVersion}. Run in verbose mode for more information."

  var proportion_repeat: float32
  fs.read(proportion_repeat)
  var min_mapq: uint8
  fs.read(min_mapq)
  if verbose:
    stderr.write_line &"[strling] proportion_repeat {proportion_repeat:.3f} and min mapping quality {min_mapq}"

  fs.read(result.fragment_distribution)

  var header_length: int32
  fs.read(header_length)

  var header = fs.readStr(header_length)

  var h = Header()
  h.from_string(header)

  # map from bin target tids to the expected target tids
  var tidmap:Table[int,int]

  result.targets = h.targets
  if targets.len > 0:
    if targets.len != result.targets.len or not result.targets.same(targets):
      tidmap = initTable[int, int]()
      tidmap[-1] = -1
      var tmap = newTable[string, Target]()
      for t in targets: tmap[t.name] = t
      for i, bt in result.targets:
        var ot = tmap.getOrDefault(bt.name, Target(tid: -1))
        tidmap[bt.tid] = ot.tid
      result.targets = targets

  var n_reads:int32
  fs.read(n_reads)
  if verbose:
    stderr.write_line &"[strling] reading {n_reads} STR reads from bin file"
  if requested_tid == int32.low:
    result.reads = newSeqOfCap[tread](nreads)
  else:
    result.reads = newSeqOfCap[tread](128)

  while not fs.atEnd:
    var t = tread()
    fs.unpack_type(t)

    if tidmap.len > 0:
      t.tid = tidmap[t.tid].int32

    if requested_tid != int32.low and t.tid != requested_tid: continue

    if drop_unplaced and t.tid < 0: continue
    result.reads.add(t)

  if not drop_unplaced and requested_tid == int32.low:
    doAssert result.reads.len == n_reads, &"[strling] expected {n_reads} got {result.reads.len}"
  else:
    doAssert result.reads.len <= n_reads, &"[strling] expected <{n_reads} got {result.reads.len}"

when isMainModule:
  import os
  let bin = paramStr(1)

  var fs = newFileStream(bin, fmRead)
  var x = fs.unpack_file()
  fs.close()
