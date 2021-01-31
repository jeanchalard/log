#!/usr/bin/ruby

# Invocation : graph.rb [options] datafile...
#
# -r <rules file> : e.g. -r calendar.grc to specify calendar.grc as a rule file.
#                   rules files are searched in the current directory first, then in a rules/
#                   directory if not found. The script also tries to affix the '.grc' extension
#                   if no files with the specified name is found.
#                   The default rules file name is 'calendar.grc'. Only one rules file name
#                   can be specified, additional occurrences will be taken as data file names.
#
# -p <period> : specify a period to limit gathering data of data. Supported formats are :
#               <date> gather only for this day, e.g. -p 06-12 for restricting to June 12.
#               ~<date> gather up to this day, e.g. -p ~06-12 to restricting to dates up to June 12.
#               <date>~ gather from this day, e.g. -p 06-12~ to restricting to dates starting June 12.
#               <date>~<date> gather from this periode.g. 06-12~06-18 to specify June 12 to June 18.
#               Dashes are optional in all dates, so 0612 and 06-12 are equivalent.
#
# -o <output base> : e.g. -r out to specify out as a base file name for output files (for modes with
#                    output files). If the current mode outputs files, this option is required when
#                    multiple files are specified on the command line. If only one data file is
#                    specified, this is deduced from the input file name but this option can be given
#                    to override it.
#
# -d : show diagnostics. Still generates files as normal.
#      This outputs every line with the rule it matched within its category, to check that the
#      matched rule is the desired one. Output files are still generated (for modes that do).
#
# -c <regexp> : count occurrences and time spent at <regexp>. Multiple -c args may be supplied.
#               This is equivalent to adding the relevant rules under a [counters] section in
#               the rules file.
#
# -s <collapse rule> : collapse given category into target category. Multiple -s args can be given.
#                      Format is "Category = Category = ... = Target". This is equivalent to adding
#                      the relevant rules under a [collapse] section in the rules file.

require_relative 'rules'
require_relative 'holidays'
require 'fileutils'
require 'rvg/rvg'

YEAR = 2021

DIAG = ARGV.include?("-d")
ARGV.delete("-d") if DIAG

ERRORS = []

ZZZ = 'Zzz'

LEGEND_WIDTH = 50
RIGHT_MARGIN = 10
TITLE_HEIGHT = 50
BOTTOMRULE_HEIGHT = 50
FOOTER_HEIGHT = 100
BASE_DAYWIDTH = 40
HOURHEIGHT = 25
MINUTE_HEIGHT = HOURHEIGHT.to_f / 60
FONT_SIZE = 18

DAY_START = 5 * 60

DOW = ['日', '月', '火', '水', '木', '金', '土', '日']

class Integer
  def to_hours_text
    "%02d:%02d" % [self / 60, self % 60]
  end
end
class Float
  def to_hours_text
    self.to_i.to_hours_text + ("%.2f" % (self % 1).round(2))[1..-1]
  end
end

def parseTime(time)
  return time if time.is_a? Numeric
  raise "Time format error in #{ARGF.file.lineno} : #{time}" unless time.match(/[0-3][0-9][0-5][0-9]/)
  60 * time[0..1].to_i + time[2..3].to_i
end

class Day
  include Enumerable
  attr_reader :date, :counters
  attr_accessor :sleepTime
  def initialize(date)
    @date = Time.local(YEAR, date[0..1].to_i, date[3..4].to_i, 12, 0, 0)
    @activities = []
    @counters = {}
    @markers = []
  end
  def holiday?
    @date.wday == 0 || @date.wday >= 6 || HOLIDAYS.include?(@date.strftime("%Y-%m-%d"))
  end
  def addMarker(time, marker)
    @markers << [parseTime(time), marker]
  end
  def replaceMarker(time, marker)
    @markers.delete_if {|q| q[1] == marker }
    addMarker(time, marker)
  end
  def findMarker(marker)
    @markers.find {|q| q[1] == marker }
  end
  def getup
    g = @activities.find {|a| a[1] != ZZZ }
    if g then g[0] else nil end
  end
  def addActivity(time, activity)
    time = parseTime(time)
    time = DAY_START if time < DAY_START
    if (@activities.empty? && time > DAY_START)
      @activities << [DAY_START, ZZZ]
    elsif (!@activities.empty? && time < @activities[-1][0])
      ERRORS << "Not ordered #{@date.strftime("%Y-%m-%d")} #{time.to_hours_text}"
      time = @activities[-1][0]
    end
    if (@activities.empty? || @activities[-1][1] != activity) # If not the same as previous (otherwise, doing nothing will merge them)
      @activities << [time, activity]
    end
  end
  def computeSleepBeforeGetup
    getup = self.getup
    return 0 if getup.nil?
    getup - DAY_START
  end
  def computeSleepAfterGetup
    getup = self.getup || 0
    sleep = 0
    each do |from, to, activity|
      sleep += to - from if from > getup && activity == ZZZ
    end
    sleep
  end
  def getBucketedTime(activity)
    return @sleepTime if activity == ZZZ
    t = 0
    self.each do |from, to, a|
      t += to - from if a == activity
    end
    t
  end
  def markers
    @markers
  end
  def each(&block)
    iter = @activities.zip(@activities[1..-1] + [[DAY_START + 24 * 60, '']]).map do |pair| [pair[0][0], pair[1][0], pair[0][1]] end
    iter.each do |act|
      yield(act[0], act[1], act[2])
    end
  end
  def to_s
    "Day #{@date}\n" + @activities.map do |a| "%02i%02i %s" % [a[0] / 60, a[0] % 60, a[1]] end.join("\n")
  end
end

class Counters < Hash
  def count(category, count, time, description)
    counter = self[category] || [0, 0]
    counter[0] += count
    counter[1] += time
    counter << description unless description.nil?
    self[category] = counter
  end
end

LogData = Struct.new(:days, :counters)
CurrentCounter = Struct.new(:category, :startTime)

def parsePeriod(period)
  if (period.match?(/(\d\d)-?(\d\d)/))
    period = period + "~" + period
  end
  if (!period.include?('~')) then raise "Period must include ~ : ~06-12, 06-03~, or 06-03~06-12 (dashes optional)" end
  period = period.delete('-')
  period = '0101' + period if period[0] == '~'
  period = period + '1231' if period[-1] == '~'
  from = Time.local(YEAR, period[0..1].to_i, period[2..3].to_i, 0, 0, 0)
  to = Time.local(YEAR, period[5..6].to_i, period[7..8].to_i, 24, 0, 0)
  return [from, to]
end

def readData(rules)
  day = nil
  counters = Counters.new
  currentCounters = []
  sleepTimes = []
  data = []
  seenActivities = {}
  while l = gets
    l.chomp!
    if l.match(/\d\d-\d\d([  ]:.*)?/)
      raise "Remaining currentCounter in line #{ARGF.file.lineno} : #{l}" unless currentCounters.empty?
      day = Day.new(l)
      if (day.date < PERIOD[0] || day.date > PERIOD[1])
        day = 'ignored'
      else
        data << day
      end
      next
    elsif day == 'ignored'
      next
    elsif day.nil?
      raise "Day unknown in #{ARGF.file.lineno} : #{l}"
    end
    if !l.match(/\d{4} .*/)
      rules.matchCounter(l).each do |c|
        counters.count(c[0], c[1], 0, l)
      end
      next
    end

    # Parse the line
    time, *activity = l.split(' ')
    parsedTime = parseTime(time)
    activity = activity.join(' ')

    # Manage counters
    currentCounters.each do |current|
      counters.count(current.category, 0, parsedTime - current.startTime, nil)
    end
    currentCounters = []
    CHECKS.each do |check|
      next unless Regexp.new(check).match(activity)
      counters.count(check, 1, 0, activity)
      currentCounters << CurrentCounter.new(check, parseTime(time))
    end
    rules.matchCounter(l).each do |c|
      counters.count(c[0], c[1], 0, l)
      currentCounters << CurrentCounter.new(c[0], parseTime(time))
    end
    if currentCounters.map {|c| c.category }.uniq.length != currentCounters.length
      raise "Multiply-counted category in counters #{currentCounters}"
    end

    # Markers
    rules.eachMarker(activity) do |m, policy|
      case policy
      when Marker::EACH
        day.addMarker(time, m)
      when Marker::FIRST
        day.addMarker(time, m) unless day.findMarker(m)
      when Marker::LAST
        day.replaceMarker(time, m)
      end
    end
    rule = rules.categorize(activity)
    if rule.nil?
      ERRORS << "Unknown category for day #{"%02i" % day.date.month}-#{"%02i" % day.date.day} line #{ARGF.file.lineno} : #{activity}"
      category = "Error"
    else
      category = rule.category
      if DIAG
        if seenActivities.has_key?(activity)
          seenActivities[activity] << ARGF.file.lineno
        else
          seenActivities[activity] = [rule, ARGF.file.lineno]
        end
      end
    end
    day.addActivity(time, category)
  end
  prev = nil
  data.reverse_each do |d|
    d.sleepTime = if prev.nil? then nil else d.computeSleepAfterGetup + prev.computeSleepBeforeGetup end
    prev = d
  end
  if DIAG
    rAct = {}
    seenActivities.each do |activity, contents|
      rule = contents[0]
      if rAct.has_key? rule.category
        rAct[rule.category] << activity
      else
        rAct[rule.category] = [activity]
      end
    end
    rAct.each do |category, activities|
      puts "[31m#{category}[0m"
      activities.sort.each do |activity|
        rule, *lines = seenActivities[activity]
        puts " #{activity} [34m(#{rule.pattern})[0m : #{lines.join(', ')}"
      end
    end
  end
  LogData.new(data, counters)
end

def generateTitle(width, height)
  Magick::RVG::Text.new.tspan(BASENAME.capitalize)
    .styles(:stroke => 'white', :fill => 'white', :stroke_opacity => 0.9, :fill_opacity => 0.9,
            :font_family => 'Noto Sans CJK JP', :text_anchor => 'middle', :font_size => FONT_SIZE, :font_weight => 100)
end

def generateRuledBackground(width, height, data, mode)
  scale = Magick::RVG.new(width, height)
  # Guidelines : the main grid
  (0..data.length).each do |day|
    x = LEGEND_WIDTH + day * DAYWIDTH
    scale.line(x, 0, x, height).styles(:stroke => 'white', :stroke_opacity => 0.3)
  end
  # Legend
  (0..24).each do |hour|
    y = height - hour * MINUTE_HEIGHT * 60
    timeLegend = if Rules::Spec::MODE_CALENDAR == mode then (24 + DAY_START / 60) - hour else hour end
    if timeLegend % 2 == 0
      scale.line(LEGEND_WIDTH, y, width, y).styles(:stroke => 'white', :stroke_opacity => if timeLegend == 24 then 0.8 else 0.3 end)
      text = Magick::RVG::Text.new.tspan("%02i" % timeLegend)
               .styles(:stroke => 'white', :fill => 'white', :stroke_opacity => 0.6, :fill_opacity => 0.6,
                       :font_family => 'Noto Sans CJK JP', :text_anchor => 'middle', :font_size => FONT_SIZE, :font_weight => 100)
      scale.use(text, LEGEND_WIDTH / 2, y + FONT_SIZE / 2)
    else
      # On odd hours, only show a dashed line
      scale.line(LEGEND_WIDTH, y, width, y).styles(:stroke => 'white', :stroke_opacity => 0.1, :stroke_dasharray => [3, 5])
    end
  end
  scale
end

def generateBottomRule(width, height, data)
  scale = Magick::RVG.new(width, height)
  i = 0
  data.each do |day|
    x = LEGEND_WIDTH + i * DAYWIDTH
    color = if day.holiday? then '#FFAFAF' else 'white' end
    text = Magick::RVG::Text.new.tspan("%02i\n%s" % [day.date.day, DOW[day.date.wday]])
             .styles(:stroke => color, :fill => color, :stroke_opacity => 0.6, :fill_opacity => 0.6,
                     :font_family => 'Noto Sans CJK JP',
                     :text_anchor => 'middle', :font_size => FONT_SIZE, :font_weight => 100)
    scale.use(text, DAYWIDTH * i + DAYWIDTH / 2, FONT_SIZE + 2)
    i += 1
  end
  scale
end

def generateLegend(rules, activities, width, height)
  one = width.to_f / activities.length
  Magick::RVG.new(width, height) do |rvg|
    i = 0
    activities.map do |activity|
      color = rules.color(activity)
      group = rvg.rvg(one, FONT_SIZE, i * one, 0)
      group.rect(one * 2 / 3, FONT_SIZE, one / 6, 0).styles(:fill => color, :fill_opacity => 0.8)
      group.text(one / 2, FONT_SIZE * 0.8, activity)
        .styles(:stroke => 'black', :fill => 'black', :stroke_opacity => 0.6, :fill_opacity => 0.6,
                :font_family => 'Noto Sans CJK JP',
                :text_anchor => 'middle', :font_size => FONT_SIZE * 0.8, :font_weight => 100)
      i += 1
    end
  end
end

def generateFooter(rules, categories, width, height)
  Magick::RVG.new(width, height) do |rvg|
    rvg.use(generateLegend(rules, categories, width, height), 0, 0)
    markers = rules.markers.map{|m|m.name}.uniq.sort
    one = width.to_f / markers.length
    i = 0
    markers.each do |marker, policy|
      # For some reason, ellipse() (used by hline) crashes when used with large numbers. Instead make a new
      # image with the right coordinates so that the numbers passed to ellipse() are small.
      rvg.use(hlineImg(rvg, i * one + one / 6, 2.5 * FONT_SIZE, rules.color(marker)), i * one + one / 6, 2.5 * FONT_SIZE)
      rvg.text(i * one + one / 3 + DAYWIDTH, 2.8 * FONT_SIZE, marker)
        .styles(:stroke => 'white', :fill => 'white', :stroke_opacity => 0.6, :fill_opacity => 0.6,
                :font_family => 'Noto Sans CJK JP',
                :text_anchor => 'start', :font_size => FONT_SIZE * 0.8, :font_weight => 100)
      i += 1
    end
  end
end

def hlineImg(image, x, y, color)
  Magick::RVG.new(DAYWIDTH, 6) do |rvg|
    hline(rvg, 0, 3, color)
  end
end

def hline(image, x, y, color)
  image.line(x, y, x + DAYWIDTH, y).styles(:stroke => color, :stroke_opacity => 1.0, :stroke_width => 2)
  image.ellipse(3, 3, x + DAYWIDTH / 2, y).styles(:stroke => color, :stroke_opacity => 1.0, :stroke_width => 2)
end

def generateDay(rules, day, width, height)
  def toY(minute, height)
    (minute - DAY_START) * MINUTE_HEIGHT
  end

  image = Magick::RVG.new(width, height)

  day.each do |from, to, activity|
    from = toY(from, height)
    to = toY(to, height)
    color = rules.color(activity)
    image.rect(DAYWIDTH, to - from, 0, from).styles(:fill => color, :fill_opacity => 0.4, :stroke_width => 0)
  rescue => e
    puts "#{e} : #{day.date} #{from} #{to} #{activity}"
  end

  day.markers.each do |marker|
    time, activity = *marker
    hline(image, 0, toY(time, height), rules.color(activity))
  end

  image
end

def generateDayHistogram(rules, categories, day, width, height)
  image = Magick::RVG.new(width, height)
  x = 0
  w = width / categories.size
  categories.each do |activity|
    color = rules.color(activity)
    minutes = day.getBucketedTime(activity)
    unless minutes.nil?
      h = minutes * MINUTE_HEIGHT
      image.rect(w, h, x, height - h).styles(:fill => color, :fill_opacity => 0.8)
      if (minutes != 0)
        image.text(x + w, height - h - 3, minutes.to_hours_text)
          .rotate(270)
          .styles(:stroke => 'none', :fill => 'white', :fill_opacity => 1,
                  :font_family => 'DejaVu Sans',
                  :text_anchor => 'start', :font_size => w, :font_weight => 500)
      end
    end
    x += w
  end

  image
end

def generateDayStack(rules, categories, day, width, height)
  image = Magick::RVG.new(width, height)
  x = 0
  y = 0
  w = width
  categories.each do |activity|
    color = rules.color(activity)
    minutes = day.getBucketedTime(activity)
    unless minutes.nil?
      h = minutes * MINUTE_HEIGHT
      image.rect(w, h, x, height - h + y).styles(:fill => color, :fill_opacity => 0.8)
      y -= h
    end
  end

  image
end

class Numeric
  def zdiv(denom)
    if 0 == denom then 0 else self / denom end
  end
end
class Totals
  attr_accessor :workDays, :holidays, :times
  class Times
    attr_accessor :workDays, :holidays
    def initialize
      @workDays = 0
      @holidays = 0
    end
    def total
      @workDays + @holidays
    end
    def total_s
      self.total.to_hours_text
    end
    def workDays_s
      @workDays.to_hours_text
    end
    def holidays_s
      @holidays.to_hours_text
    end
  end
  def initialize(categories)
    @workDays = 0
    @holidays = 0
    @times = {}
    categories.each do |c| @times[c] = Times.new end
  end
  def days
    @workDays + @holidays
  end
end
def getTotals(categories, data)
  totals = Totals.new(categories)
  data.each do |day|
    if day.holiday?
      totals.holidays += 1
    else
      totals.workDays += 1
    end
    categories.each do |c|
      if day.holiday?
        totals.times[c].holidays += day.getBucketedTime(c) || 0
      else
        totals.times[c].workDays += day.getBucketedTime(c) || 0
      end
    end
  end
  if data.first.holiday?
    totals.times[ZZZ].holidays += data.first.computeSleepBeforeGetup
  else
    totals.times[ZZZ].workDays += data.first.computeSleepBeforeGetup
  end
  if data.last.holiday?
    totals.times[ZZZ].holidays += data.last.computeSleepAfterGetup
  else
    totals.times[ZZZ].workDays += data.last.computeSleepAfterGetup
  end
  totals
end

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

def imageFilename(basename, specname)
  FileUtils.mkdir_p('out')
  FileUtils.mkdir_p("out/#{specname}")
  "out/#{specname}/#{basename.downcase}.#{specname}.png"
end

def searchInputFilePath(files)
  files.each_with_index do |filename, i|
    [filename, "#{filename}.log", "data/#{filename}", "data/#{filename}.log"].each do |resolved|
      if (File.exists?(resolved))
        files[i] = resolved
        break
      end
    end
  end
end

PERIOD = parsePeriod(arg("-p", true) || '01-01~12-31')
CHECKS = []
while (check = arg("-c", true)) do
  CHECKS << check
end
collapses = {}
while (collapse = arg("-s", true)) do
  c = collapse.split('=').map{|s|s.strip}
  target = c.pop
  raise "Unrecognized collapse rule on the command line : #{collapse}" if c.empty?
  c.each do |source|
    collapses[source] = target
  end
end
rules = readRules(arg("-r", true) || "calendar.grc", collapses)
outArg = arg("-o", true)
if outArg.nil? && ARGV.length > 1 && rules.spec.mode != Rules::Spec::MODE_COUNT
  raise "Multiple files but no output name given"
end
BASENAME = outArg || File.basename(ARGV[0]).gsub(/.log$/, '')

searchInputFilePath(ARGV)

data = readData(rules)
if !ERRORS.empty?
  ERRORS.each do |e|
    puts e
  end

  unknowns = ERRORS.grep(/Unknown category/)
  unless unknowns.empty?
    puts
    unknowns.map {|e| e.sub(/[^:]+: (.*)/, "\\1") }.uniq.each do |task|
      puts "#{task.gsub('+', '\\\+').gsub('?', '\\\?').gsub('(', '\\\(').gsub(')', '\\\)')} = Repos"
    end
    puts
  end

  raise "Fix the above errors"
end

categories = data.days.flat_map do |day| day.map do |startTime, endTime, category| category end end.uniq.sort

DAYWIDTH = if Rules::Spec::MODE_OCCUPATIONS == rules.spec.mode then 2 * BASE_DAYWIDTH else BASE_DAYWIDTH end
height = 24 * HOURHEIGHT
imageWidth = LEGEND_WIDTH + DAYWIDTH * data.days.length
imageHeight = TITLE_HEIGHT + height + BOTTOMRULE_HEIGHT + FOOTER_HEIGHT
image = Magick::RVG.new(imageWidth + RIGHT_MARGIN, imageHeight)
image.background_fill = 'black'

image.use(generateTitle(imageWidth, TITLE_HEIGHT), imageWidth / 2, TITLE_HEIGHT / 2, imageWidth, TITLE_HEIGHT)
image.use(generateBottomRule(imageWidth, BOTTOMRULE_HEIGHT, data.days), LEGEND_WIDTH, BOTTOMRULE_HEIGHT + height)

image.use(generateRuledBackground(imageWidth, height, data.days, rules.spec.mode), 0, TITLE_HEIGHT)

case rules.spec.mode
when Rules::Spec::MODE_CALENDAR
  image.use(generateFooter(rules, categories, imageWidth, FOOTER_HEIGHT), 0, TITLE_HEIGHT + height + BOTTOMRULE_HEIGHT + 20)
  day = 0
  data.days.each do |d|
    image.use(generateDay(rules, d, DAYWIDTH, height), LEGEND_WIDTH + day * DAYWIDTH, TITLE_HEIGHT, DAYWIDTH, height)
    day += 1
  end
  image.draw.write(imageFilename(BASENAME, rules.spec.name))

when Rules::Spec::MODE_OCCUPATIONS, Rules::Spec::MODE_STACK
  image.use(generateLegend(rules, categories, imageWidth, FOOTER_HEIGHT), 0, TITLE_HEIGHT + height + BOTTOMRULE_HEIGHT + 20)
  day = 0
  data.days.each do |d|
    if rules.spec.mode == Rules::Spec::MODE_STACK
      image.use(generateDayStack(rules, categories, d, DAYWIDTH, height), LEGEND_WIDTH + day * DAYWIDTH, TITLE_HEIGHT, DAYWIDTH, height)
    else
      image.use(generateDayHistogram(rules, categories, d, DAYWIDTH, height), LEGEND_WIDTH + day * DAYWIDTH, TITLE_HEIGHT, DAYWIDTH, height)
    end
    day += 1
  end
  image.draw.write(imageFilename(BASENAME, rules.spec.name))

when Rules::Spec::MODE_COUNT
  totals = getTotals(categories, data.days)
  puts "Total days : #{totals.days} (#{totals.workDays} work + #{totals.holidays} holidays)"
  outputs = []
  totals.times.each do |category, times|
    outputs << [category, times.total_s, (times.total.to_f.zdiv totals.days).to_hours_text,
                times.workDays_s, (times.workDays.to_f.zdiv totals.workDays).to_hours_text,
                times.holidays_s, (times.holidays.to_f.zdiv totals.holidays).to_hours_text]
  end
  maxs = []
  outputs.each do |row|
    row.each_with_index do |e, i|
      if maxs[i].nil? || e.length > maxs[i] then maxs[i] = e.length end
    end
  end
  outputs.each do |row|
    row.each_with_index do |e, i|
      if i == 0
        row[i] = e.ljust(maxs[i])
      else
        row[i] = e.rjust(maxs[i])
      end
    end
  end
  outputs.each do |row|
    puts "%s : %s (%s/d) (%s (%s/d) + %s (%s/d))" % row
  end
end

unless data.counters.empty?
  Report = Struct.new(:name, :count, :icount, :time, :itime, :average)
  reports = []
  data.counters.keys.sort.each do |k|
    count = data.counters[k][0]
    time = data.counters[k][1]
    avg = time.to_f / count
    reports << Report.new(k, "%02d" % count, count, time.to_hours_text, time, avg.to_hours_text)
  end
  maxNameLen = reports.max_by {|o| o.name.length }.name.length
  maxCountLen = reports.max_by {|o| o.count.length }.count.length
  maxTimeLen = reports.max_by {|o| o.time.length }.time.length

  puts
  puts "Counters by [31mname[0m :"
  reports.sort_by(&:name).each do |c|
    if c.time == 0
      puts " #{c.name.ljust(maxNameLen)} #{c.count.rjust(maxCountLen)}"
    else
      puts " #{c.name.ljust(maxNameLen)} #{c.count.rjust(maxCountLen)} #{c.time.rjust(maxTimeLen)} (#{c.average} avg)"
    end
  end

  puts
  puts "By [31maverage time[0m :"
  reports.sort_by(&:average).reverse.each do |c|
    puts " #{c.average} #{c.name.rjust(maxNameLen)} #{c.time.rjust(maxTimeLen)} #{c.count.rjust(maxCountLen)}" unless c.time == 0
  end

  puts
  puts "By [31mtotal time[0m :"
  reports.sort_by(&:itime).reverse.each do |c|
    puts " #{c.time.rjust(maxTimeLen)} #{c.name.rjust(maxNameLen)} (#{c.average} avg) #{c.count.rjust(maxCountLen)}" unless c.time == 0
  end

  puts
  puts "By [31mcount[0m :"
  reports.sort_by(&:icount).reverse.each do |c|
    puts " #{c.count.rjust(maxCountLen)} #{c.name.rjust(maxNameLen)} (#{c.time.rjust(maxTimeLen)}, avg #{c.average})"
  end

end
