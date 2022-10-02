#!/usr/bin/ruby

DAY_START_SEC = 5 * 3600
ZZZ = 'Zzz'

# Returns the argument of the passed switch, or null if the switch is not present
def arg(arg, takesArg)
  if ARGV.include?(arg)
    i = ARGV.index(arg)
    ARGV.delete_at(i)
    return true if !takesArg
    ARGV.delete_at(i)
  else
    nil
  end
end

# Finds a file by filename in the current directory. If none, finds a file in the current directory
# by filename + extension. If none, search for the same 2 patterns in a rules/ directory.
def findRuleFile(filename, extension)
  [filename, "#{filename}#{extension}", "rules/#{filename}", "rules/#{filename}#{extension}"].each do |name|
    return name if File.exist?(name)
  end
  raise "File not found #{filename}"
end


def deduceYear(f) # File
  m = File.absolute_path(f).match(/\D(20\d\d)(?!.*20\d\d)/) # last occurrence of 20\d\d in the absolute path
  if m.nil? then Time.now.year else m[1].to_i end
end

class LogFile
  def initialize(f) # File
    @f = f
    @year = deduceYear(f)
    date = '#'
    date = f.gets while (!date.nil?) && date.match(/^\s*#/)
    raise "Invalid file containing no data" if date.nil?
    @date = parseDate(date)
  end

  def gets
    @next = getNext() if @next.nil?
    return nil if @next.nil?
    nxt = getNext()
    if nxt.nil?
      r = [@next[0], @date + DAY_START_SEC + 24 * 3600, @next[1].strip]
    else
      r = [@next[0], nxt[0], @next[1].strip]
    end
    @next = nxt
    r
  end

  def getNext
    nxt = '#'
    nxt = @f.gets&.chomp while (!nxt.nil?) && nxt.match(/^\s*#/) # next is a keyword
    if nxt&.match(/^(\d\d\d\d-)?(\d\d)-(\d\d)( : .*)?$/)
      @date = parseDate(nxt)
      nxt = '#'
      nxt = @f.gets while (!nxt.nil?) && nxt.match(/^\s*#/) # next is a keyword
    end
    return nil if nxt.nil?
    m = nxt.match(/^(\d\d)(\d\d) (.*)$/)
    raise "Invalid format #{@f.path}:#{@f.lineno} : \"#{nxt}\" ; expected \d\d\d\d <activity>" if m.nil?
    [@date + m[1].to_i * 3600 + m[2].to_i * 60, m[3]]
  end

  def parseDate(s)
    date = s.match(/^(\d\d\d\d-)?(\d\d)-(\d\d).*/)
    raise "Invalid date #{f}:#{f.lineno} (must match (\d\d\d\d-)?\d\d-\d\d) : \"#{date}\"" if date.nil?
    y = date[1]&.to_i || @year
    m = date[2].to_i
    d = date[3].to_i
    Time.local(y, m, d, 0, 0, 0)
  end

  def time(s) # String, 4-digits HHMM with no limit on range. Returns Time where @date 00:00 JST + HH*3600 + MM*60
    m = s.match(/^(\d\d)(\d\d)$/) || (raise "Incorrect format in \"#{s}\", expected \d\d\d\d (HHMM)")
    h = m[1].to_i
    m = m[2].to_i
    @date + h * 3600 + m * 60
  end

  def startTime
    if @startTime.nil?
      pos = @f.pos
      @f.pos = 0
      first = self.gets
      @next = nil
      @f.pos = pos
      @startTime = first[0]
    end
    @startTime
  end

  def findNextFile
    p = File.absolute_path(@f)
    p.match(/\D(20\d\d})(?!.*20\d\d)/)
  end

  private :getNext, :parseDate, :time
end

class Logs
  def initialize(filenames)
    @files = filenames.map {|f| LogFile.new(File.new(f)) }.sort {|a,b| a.startTime <=> b.startTime }
    @next = [@files.first.gets]
  end

  def gets
    return nil if @next.empty?
    s = @files.first.gets
    unless s.nil?
      @next << s
      return @next.shift
    end
    @files.shift
    return @next.shift if @files.empty?
    s = @files.first.gets
    raise "Two files covering the same period" if (s[0] < @next.first[1])
    if s[0] > @next.first[1] + 86400
      @next << [@next.first[1], s[0], "?"]
    else
      @next.first[1] = s[0]
    end
    @next << s
    return @next.shift
  end
end
