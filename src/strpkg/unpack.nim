import streams
import msgpack4nim
export msgpack4nim
import strformat
import hts/bam
import strutils

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


proc unpack_file*(fs:FileStream, expected_format_version:int16=0): tuple[targets: seq[Target], fragment_distribution: array[4096, uint32], reads: seq[tread]] =

  var str = fs.readStr(3)
  doAssert str == "STR", "[strling] expected bin file to start with \"STR\""

  var fmtVersion:int16
  fs.read(fmtVersion)
  var softVersion: array[9, char]
  fs.read(softVersion)

  var softVersionString = softVersion.join()
  stderr.write_line &"[strling] read format version {fmtVersion} from software version {softVersionString}"

  var proportion_repeat: float32
  fs.read(proportion_repeat)
  var min_mapq: uint8
  fs.read(min_mapq)
  stderr.write_line &"[strling] proportion_repeat {proportion_repeat:.3f} and min mapping quality {min_mapq}"

  fs.read(result.fragment_distribution)

  var header_length: int32
  fs.read(header_length)

  var header = fs.readStr(header_length)

  var h = Header()
  h.from_string(header)

  result.targets = h.targets
  var n_reads:int32
  fs.read(n_reads)
  stderr.write_line &"[strling] reading {n_reads} STR reads from bin file"

  while not fs.atEnd:
    var t:tread
    fs.unpack_type(t)
    result.reads.add(t)

  doAssert result.reads.len == n_reads, &"[strling] expected {n_reads} got {result.reads.len}"

when isMainModule:
  import os
  let bin = paramStr(1)

  var fs = newFileStream(bin, fmRead)
  var x = fs.unpack_file()
  fs.close()
