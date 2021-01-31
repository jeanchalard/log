#!/usr/bin/ruby -w

# Invocation : stitch.rb [options] [srcdir]
#
# srcdir : if present, read from that directory. Else, read from img/.
#
# -n : Do not move files to the img_done directory after they have been processed.

require 'fileutils'
require 'rmagick'
include Magick

DRYRUN = ARGV.include?("-n")
DONEDIR = 'img_done/'

DIR = if ARGV[0] then ARGV[0] else 'img' end

FILES = {}
PREFIXES = {}
Dir["#{DIR}/*"].each do |f|
  m = f.match(/#{DIR}\/([^_]+)_(\d{8}_\d{4}).(jpg|png)/)
  prefix = m[1]
  date = m[2]
  PREFIXES[prefix] = true
  FILES[date] = {} unless FILES.has_key?(date)
  FILES[date][prefix] = f
end

def generate(date)
  dst = "out/img/#{date}.jpg"
  day = FILES[date]
  if day.size == 1
    file = day.values.first
    FileUtils.copy(file, dst)
    FileUtils.move(file, DONEDIR)
    return
  end
  files = day.keys.sort.map {|f| ImageList.new(FILES[date][f]).first }
  FILES.delete(date)
  y = 0
  width = files.max {|a,b| a.columns <=> b.columns }.columns
  height = files.sum {|f| f.rows }
  img = Image.new(width, height) { self.background_color = 'black' }
  files.each do |file|
    w = file.columns
    x = (width - w) / 2
    img.composite!(file, x, y, CompositeOperator::CopyCompositeOp)
    y += file.rows
    FileUtils.move(file.filename, DONEDIR)
    file.destroy!
  end
  img.write(dst)
  img.destroy!
end

total = FILES.length.to_f
done = 0.to_f
puts
FILES.keys.sort.each do |k|
  puts("[A%.02f%% %s %s             " % [100 * done / total, k, FILES[k].keys])
  generate(k)
  done += 1
end
puts("[A100%                                         ")
