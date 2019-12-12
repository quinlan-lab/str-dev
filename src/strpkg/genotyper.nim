import cluster
import collect
import utils
import tables
import math
import strformat
import hts/bam

type Event = enum
  Insertion
  Deletion

type Evidence = object
  class: string # class of support e.g. "spanning reads"
  repeat: string
  # allele sizes in bp relative to the reference
  allele1_bp: float
  allele2_bp: float
  # total allele sizes in repeat units
  allele1_ru: float
  allele2_ru: float

  allele1_reads: uint
  allele2_reads: uint
  supporting_reads: uint
  sum_str_counts: uint
 
type Call* = object
  chrom: string
  start: uint
  stop: uint
  # and confidence intervals around position
  repeat: string # repeat unit
  # total allele sizes in repeat units
  allele1: float
  allele2: float
  # and confidence intervals around the allele size esimates
  quality: float #XXX currently not in use
  # Number of supporting reads in each class
  overlapping_reads: uint
  spanning_reads: uint
  spanning_pairs: uint
  left_clips: uint
  right_clips: uint
  unplaced_reads: int # only used for genotypes with unique repeat units
  depth: float #median depth in region
  sum_str_counts: uint
  # ...

const gt_header* = "#chrom\tleft\tright\trepeatunit\tallele1_est\tallele2_est\toverlapping_reads\tspanning_reads\tspanning_pairs\tleft_clips\tright_clips\tunplaced_pairs\tdepth\tsum_str_counts"

proc tostring*(c: Call): string =
  return &"{c.chrom}\t{c.start}\t{c.stop}\t{c.repeat}\t{c.allele1:.2f}\t{c.allele2:.2f}\t{c.overlapping_reads}\t{c.spanning_reads}\t{c.spanning_pairs}\t{c.left_clips}\t{c.right_clips}\t{c.unplaced_reads}\t{c.depth}\t{c.sum_str_counts}"

# Estimate the size of the smaller allele 
# from reads that span the locus
proc spanning_read_est(reads: seq[Support]): Evidence =
  result.class = "spanning reads"
  result.repeat = reads[0].repeat #XXX unnecessary?
  var 
    allele1_bp = NaN
    allele2_bp = NaN
    allele1_ru = NaN
    allele2_ru = NaN
    RepeatCounts: CountTable[uint8]
    Indels: CountTable[int8]

  for read in reads:
    if read.Type == SupportType.SpanningRead:
      RepeatCounts.inc(read.SpanningReadRepeatCount)
      Indels.inc(int8(read.SpanningReadCigarInsertionLen) - int8(read.SpanningReadCigarDeletionLen))
      result.supporting_reads += 1

  if len(RepeatCounts) >= 2:
    var topRepeatCounts = most_frequent(RepeatCounts, 2)
    allele1_ru = float(topRepeatCounts[0])
    allele2_ru = float(topRepeatCounts[1])
  elif len(RepeatCounts) == 1:
    allele1_ru = float(RepeatCounts.largest[0])
  result.allele1_ru = allele1_ru
  result.allele2_ru = allele2_ru

  if len(Indels) >= 2:
    var topIndels = most_frequent(Indels, 2)
    allele1_bp = float(topIndels[0])
    allele2_bp = float(topIndels[1])
  elif len(Indels) == 1:
    allele1_bp = float(Indels.largest[0])
  result.allele1_bp = allele1_bp
  result.allele2_bp = allele2_bp

# Estimate the size of both alleles
# from read pairs that span the locus
proc spanning_pairs_est(reads: seq[Support]): Evidence =
  result.class = "spanning pairs"
  result.repeat = reads[0].repeat #XXX unnecessary?
  var 
    allele1_bp = NaN
    allele2_bp = NaN
    allele1_ru = NaN
    allele2_ru = NaN
    FragmentSizes: CountTable[uint32]

  for read in reads:
    if read.Type == SupportType.SpanningFragment:
      FragmentSizes.inc(read.SpanningFragmentLength)
      result.supporting_reads += 1

# Use a linear model to estimate allele size in bp from sum
# of counts of str repeat units in the anchored reads
# result is in bp insertion from the reference
proc anchored_lm(sum_str_counts: uint, depth: float): float =
  #XXX These estimates are from the HTT simulation linear model, would be nice to generalize
  var intercept = 4.35
  var cofficient = 0.9209
  var y = log2(float(sum_str_counts)/depth + 1) * cofficient + intercept
  return pow(2,y)

proc sum_str_est(reads: seq[tread], depth: float): Evidence =
  # Estimate size in bp using repeat content of anchored and overlapping reads
  result.supporting_reads = uint(len(reads))
  for tread in reads:
    result.sum_str_counts += tread.repeat_count
    result.supporting_reads += 1
  result.allele2_bp = anchored_lm(result.sum_str_counts, depth)

# Use a linear model to estimate allele size in bp the number of unplaced reads
# result is in bp insertion from the reference
proc unplaced_est(unplaced_count: int, depth: float): float =
  # Estimate size in bp using number of unplaced reads
  var intercept = 8.358
  var cofficient = 0.803
  var y = log2(float(unplaced_count)/depth + 1) * cofficient + intercept
  result = pow(2,y)

proc genotype*(b:Bounds, tandems: seq[tread], spanners: seq[Support],
              targets: seq[Target], depth: float): Call =
  result.chrom = get_chrom(b.tid, targets)
  result.start = b.left
  result.stop = b.right
  result.left_clips = b.n_left
  result.right_clips = b.n_right
  result.repeat = b.repeat
  result.depth = depth
  var RUlen = len(result.repeat)

  # Check for spanning reads - indicates a short allele
  if spanners.len == 0:
    result.allele1 = NaN
  else:
    var spanning_read_est = spanning_read_est(spanners)
    result.allele1 = spanning_read_est.allele1_bp/float(max(1, RUlen))
    result.spanning_reads = spanning_read_est.supporting_reads

    var spanning_pairs_est = spanning_pairs_est(spanners)
    result.spanning_pairs = spanning_pairs_est.supporting_reads

  # Use anchored reads to estimate long allele
  var sum_str_est = sum_str_est(tandems, depth)
  result.overlapping_reads = sum_str_est.supporting_reads
  result.sum_str_counts = sum_str_est.sum_str_counts
  var large_allele_bp = sum_str_est.allele2_bp
  result.allele2 = large_allele_bp/float(max(1, RUlen))

  # Revise allele esimates using spanning pairs

  # Revise allele esimates using unplaced reads
  # (probably can't be done until all loci are genotyped)
proc update_genotype*(call: var Call, unplaced_reads: int) =
  var RUlen = len(call.repeat)
  call.unplaced_reads = unplaced_reads
  if unplaced_reads > 2:
    call.allele2 = unplaced_est(unplaced_reads, call.depth)/float(RUlen)
