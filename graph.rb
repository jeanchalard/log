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

require_relative 'util'
require_relative 'rules'
require_relative 'holidays'
require 'fileutils'
require 'rvg/rvg'
require 'erb'

DIAG = ARGV.include?("-d")
ARGV.delete("-d") if DIAG

ERRORS = []

EVERYTHING = 'Everything'
ZZZCAT = Category.new(ZZZ, nil)
ERRORCAT = Category.new("Error", nil)

LEGEND_WIDTH = 50
RIGHT_MARGIN = 10
TITLE_HEIGHT = 50
BOTTOMRULE_HEIGHT = 50
FOOTER_HEIGHT = 100
BASE_DAYWIDTH = 40
HOURHEIGHT = 25
MINUTE_HEIGHT = HOURHEIGHT.to_f / 60
FONT_SIZE = 18
ACTIVITY_OPACITY = 0.6

DAY_START_MINUTES = 5 * 60

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

class String
  def htmlize
    gsub('?', '__').gsub(/[\?!!@$%&\^\*\(\)\+=,\.\/';:"<>\[\]\\{}\|`# ]/) {|x| "__%X" % x.ord }
  end
end
class Category
  def htmlize
    self.name.htmlize
  end
end

class RulesException < Exception
end

def parseTime(time)
  return time if time.is_a? Numeric
  raise "Time format error in #{ARGF.file.lineno} : #{time}" unless time.match(/[0-3][0-9][0-5][0-9]/)
  60 * time[0..1].to_i + time[2..3].to_i
end

class Activity
  attr_reader :startTime, :endTime, :categories, :activity
  # startTime is what's really in the file and should be used for computation.
  # displayStartTime is what should be shown to the user.
  # They only differ on the first and last activity on the day. For those, start/endTime are what is
  # really in the file so they will be DAY_START_MINUTES and DAY_START_MINUTES + 24h, but displayStart/EndTime will
  # be adjusted to be the start/end time of the previous/next day last/first activity if it's identical.
  # Thus, considering day 1 and 2, last Zzz on day 1 may have startTime = 23:00/endTime = 29:00
  # and first Zzz of day 2 may have startTime = 05:00/endTime = 08:00, then both will have
  # displayStartTime = 23:00/displayEndTime = 08:00. Computing time from these is a little bit
  # annoying, so use displayDuration for that
  attr_accessor :displayStartTime, :displayEndTime

  def initialize(activity, startTime, categories)
    raise "|categories| must be an array" unless categories.is_a? Array
    categories.each do |c|
      raise RulesException.new("Each category must be a WeightedObj(Category, Float) (is #{c.inspect})") unless (c.is_a?(WeightedObj) && c.obj.is_a?(Category))
    end
    @activity = activity
    @startTime = startTime
    @endTime = nil
    @categories = categories
  end
  def endTime=(endTime)
    raise "Endtime already set in #{self} : #{@endTime}" if !@endTime.nil?
    @endTime = endTime
    @displayEndTime = endTime if @displayEndTime.nil?
  end
  def endTime
    if @endTime.nil? then DAY_START_MINUTES + 24 * 60 else @endTime end
  end
  def displayStartTime
    if @displayStartTime.nil? then @startTime else @displayStartTime end
  end
  def displayEndTime
    if @displayEndTime.nil? then @endTime else @displayEndTime end
  end
  def displayDuration
    endTime = self.displayEndTime
    endTime += 24 * 60 if endTime < self.displayStartTime
    endTime - self.displayStartTime
  end
  def to_s
    "Activity{#{@activity}[#{@categories}]}#{@startTime.to_hours_text}~#{self.endTime.to_hours_text}}"
  end
end
class Day
  include Enumerable
  attr_reader :date, :counters
  attr_accessor :sleepTime
  def initialize(year, date)
    @date = Time.local(year, date[0..1].to_i, date[3..4].to_i, 12, 0, 0)
    @activities = []
    @counters = {}
    @markers = []
    @closed = false
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
    g = @activities.find {|a| a.activity != ZZZ }
    if g then g.startTime else nil end
  end
  def addActivity(time, categories, activity)
    time = parseTime(time)
    time = DAY_START_MINUTES if time < DAY_START_MINUTES
    if (@activities.empty? && time > DAY_START_MINUTES)
      @activities << Activity.new(ZZZ, DAY_START_MINUTES, [WeightedObj.new(ZZZCAT, 1.0)])
    elsif (!@activities.empty? && time < @activities[-1].startTime)
      ERRORS << "Not ordered #{@date.strftime("%Y-%m-%d")} #{time.to_hours_text}"
      time = @activities[-1].startTime
    end
    @activities[-1].endTime = time unless @activities.empty?
    if (@activities.empty? || @activities[-1].activity != activity) # If not the same as previous (otherwise, doing nothing will merge them)
      @activities << Activity.new(activity, time, categories)
    end
  end
  def computeSleepBeforeGetup
    getup = self.getup
    return 0 if getup.nil?
    getup - DAY_START_MINUTES
  end
  def computeSleepAfterGetup
    getup = self.getup || 0
    sleep = 0
    each do |activity|
      sleep += activity.endTime - activity.startTime if activity.startTime > getup && activity.activity == ZZZ
    end
    sleep
  end
  def getBucketedTime(category)
    return @sleepTime if category.name == ZZZ
    t = 0
    self.each do |a|
      t += a.endTime - a.startTime if a.categories == category
    end
    t
  end
  def getExactTime(activity)
    return @sleepTime if activity == ZZZ
    t = 0
    self.each do |a|
      t += a.endTime - a.startTime if a.activity == activity
    end
    t
  end
  def endTime
    @activities[-1].startTime
  end
  def markers
    @markers
  end
  def close
    @activities[-1].endTime = DAY_START_MINUTES + 24 * 60
    @activities.each do |act|
      time = act.endTime - act.startTime
      act.categories.each do |c|
        if holiday?
          c.obj.addHolidayTime(c.weight * time)
        else
          c.obj.addWeekdayTime(c.weight * time)
        end
      end
    end
    @closed = true
  end
  def firstActivity
    @activities.first
  end
  def lastActivity
    @activities.last
  end
  def each(&block)
    raise "Day not closed" unless @closed
    @activities.each(&block)
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
AdhocDate = Struct.new(:date, :yearWasExplicit)

def parseAdhocDate(date, defaultYear)
  m = date.match(/(\d\d\d\d)?(\d\d)(\d\d)/)
  return AdhocDate.new(Time.local(if m[1].nil? then defaultYear else m[1].to_i end, m[2].to_i, m[3].to_i, 0, 0, 0), !m[1].nil?)
end

def parsePeriod(period, defaultYear)
  if (period.match?(/^(\d\d\d\d-)?(\d\d)-?(\d\d)$/))
    period = period + "~" + period
  end
  if (!period.include?('~')) then raise "Period must include ~ : ~06-12, 06-03~, or 06-03~06-12 (dashes optional)" end
  period = period.delete('-')
  period = '0101' + period if period[0] == '~'
  period = period + '1231' if period[-1] == '~'
  period = period.split('~')
  from = parseAdhocDate(period[0], defaultYear)
  to = parseAdhocDate(period[1], defaultYear)
  if (to.date < from.date)
    if (!from.yearWasExplicit && to.yearWasExplicit)
      from.date = Time.local(to.date.year - 1, from.date.month, from.date.day)
    elsif (!to.yearWasExplicit)
      # If neither were explicit (or from was) then take the default year for 'from' and move the 'to' one year forward
      to.date = Time.local(from.date.year + 1, to.date.month, to.date.day)
    end
  end
  to.date += 24 * 3600
  puts "Selected period : #{from.date} ~ #{to.date}"
  return [from.date, to.date]
end

def readData(rules, year)
  day = nil
  counters = Counters.new
  currentCounters = []
  sleepTimes = []
  data = []
  seenActivities = {}
  seenCategories = {}
  ARGV.each do |file|
    m = file.match(/(\D|\A)(\d\d\d\d)\D/)
    year = m[2].to_i unless m[2].nil?
    puts "Parsing #{file} with year #{year}"
    file = File.new(file)
    while l = file.gets
      l.chomp!
      l.tr!(' ', ' ') # Avoid considering ' ' and ' ' differently
      if l.match(/\d\d-\d\d([  ]:.*)?/)
        raise "Remaining currentCounter in line #{file.lineno} : #{l}" unless currentCounters.empty?
        day = Day.new(year, l)
        if (day.date < PERIOD[0] || day.date > PERIOD[1])
          day = 'ignored'
        else
          data << day
        end
        next
      elsif day == 'ignored'
        next
      elsif day.nil?
        raise "Day unknown in #{file.lineno} : #{l}"
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

      # Categories
      rule = rules.categorize(activity)
      categories = nil
      if rule.nil?
        ERRORS << "Unknown category for day #{"%02i" % day.date.month}-#{"%02i" % day.date.day} line #{ARGF.file.lineno} : #{activity}"
        categories = [WeightedObj.new(ERRORCAT, 1.0)]
      else
        categories = rule.categories
        if categories.size == 1 && activity.downcase != categories[0].obj.name.downcase
          if !seenCategories.has_key?(activity.downcase)
            seenCategories[activity.downcase] = Category.new(activity, categories[0].obj)
          end
          categories = [WeightedObj.new(seenCategories[activity.downcase], 1.0)]
        else
          categories.each do |c| seenCategories[c.obj.name] = c.obj end
        end
        if DIAG
          if seenActivities.has_key?(activity)
            seenActivities[activity] << file.lineno
          else
            seenActivities[activity] = [rule, file.lineno]
          end
        end
      end
      begin
        day.addActivity(time, categories, activity)
      rescue RulesException => e
        raise RulesException.new("Input line #{file.lineno} : \"#{l}\" => #{rules.categorize(activity)}")
      end
    end
  end
  prev = nil
  data.reverse_each do |d|
    d.close
    d.sleepTime = if prev.nil? then nil else d.computeSleepAfterGetup + prev.computeSleepBeforeGetup end
    unless prev.nil?
      if d.lastActivity.activity == prev.firstActivity.activity
        d.lastActivity.displayEndTime = prev.firstActivity.endTime
        prev.firstActivity.displayStartTime = d.lastActivity.startTime
      end
    end
    prev = d
  end
  if DIAG
    rAct = {}
    seenActivities.each do |activity, contents|
      rule = contents[0]
      rule.categories.each do |category|
        if rAct.has_key? category
          rAct[category] << activity
        else
          rAct[category] = [activity]
        end
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
    timeLegend = if Rules::Spec::MODE_CALENDAR == mode then (24 + DAY_START_MINUTES / 60) - hour else hour end
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

def generateLegend(rules, categories, width, height)
  colors = {}
  c = categories.map {|x| x.name }
  rules.colors.map do |activity, color|
    next unless c.include?(activity)
    colors[activity] = color
  end
  one = width.to_f / colors.length
  Magick::RVG.new(width, height) do |rvg|
    i = 0
    colors.map do |activity, color|
      group = rvg.rvg(one, FONT_SIZE, i * one, 0)
      group.rect(one * 5 / 6, FONT_SIZE, one / 12, 0).styles(:fill => color, :fill_opacity => ACTIVITY_OPACITY)
      group.text(one / 2, FONT_SIZE * 0.8, activity)
        .styles(:stroke => 'white', :fill => 'white', :stroke_opacity => 0.6, :fill_opacity => 1,
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
      rvg.use(hlineImg(rvg, i * one + one / 6, 2.5 * FONT_SIZE, rules.colors[marker]), i * one + one / 6, 2.5 * FONT_SIZE)
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
    (minute - DAY_START_MINUTES) * MINUTE_HEIGHT
  end

  image = Magick::RVG.new(width, height)

  day.each do |activity|
    from = toY(activity.startTime, height)
    to = toY(activity.endTime, height)
    color = rules.categoryColor(activity.categories)
    image.rect(DAYWIDTH, to - from, 0, from).styles(:fill => color, :fill_opacity => ACTIVITY_OPACITY, :stroke_width => 0)
  rescue => e
    puts "#{e} : #{day.date} #{activity}"
  end

  day.markers.each do |marker|
    time, activity = *marker
    hline(image, 0, toY(time, height), rules.colors[activity])
  end

  image
end

def generateDayHistogram(rules, categories, day, width, height)
  image = Magick::RVG.new(width, height)
  x = 0
  w = width / categories.size
  categories.each do |activity|
    color = rules.colors[activity]
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
    color = rules.colors[activity]
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
  attr_accessor :workDays, :holidays, :times, :detailedTimes
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
  def initialize
    @workDays = 0
    @holidays = 0
    @times = Hash.new {|c, k| c[k] = Times.new }
    @detailedTimes = Hash.new {|c, k| c[k] = Times.new }
  end
  def days
    @workDays + @holidays
  end
end
def getTotals(categories, data)
  totals = Totals.new
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
    day.each do |a|
      if day.holiday?
        totals.detailedTimes[a.activity].holidays += a.endTime - a.startTime
      else
        totals.detailedTimes[a.activity].workDays += a.endTime - a.startTime
      end
    end
  end
  if data.first.holiday?
    totals.times[ZZZCAT].holidays += data.first.computeSleepBeforeGetup
  else
    totals.times[ZZZCAT].workDays += data.first.computeSleepBeforeGetup
  end
  if data.last.holiday?
    totals.times[ZZZCAT].holidays += data.last.computeSleepAfterGetup
  else
    totals.times[ZZZCAT].workDays += data.last.computeSleepAfterGetup
  end
  totals
end

def filename(basename, specname, extension)
  FileUtils.mkdir_p('out')
  FileUtils.mkdir_p("out/#{specname}")
  f = "out/#{specname}/#{basename.downcase}.#{specname}.#{extension}"
  puts "Output file : #{f}"
  f
end

def imageFilename(basename, specname)
  filename(basename, specname, "png")
end

def htmlFilename(basename, specname)
  filename(basename, specname, "html")
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

def printCountOutputs(outputs)
  outputs = outputs.sort {|a,b| b[0] <=> a[0]}.map {|x| x[1..-1]} # Sort by total time descending and throw total time out
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

class DumpedCategory
  attr_reader :duration, :weekdayDuration, :holidayDuration
  def initialize(name, duration, weekdayDuration, holidayDuration, color)
    @name = name
    @duration = duration
    @weekdayDuration = weekdayDuration
    @holidayDuration = holidayDuration
    @color = color
    @children = []
  end
  def <<(cat)
    @children << cat
  end
  def to_json(indent)
    is = " " * (2 * indent)
    s  = "#{is}{\n"
    s += "#{is}  \"name\" : \"#{@name.gsub(',', '\,').gsub('"', '\"')}\",\n"
    s += "#{is}  \"duration\" : #{@duration},\n"
    s += "#{is}  \"weekdayDuration\" : #{@weekdayDuration},\n"
    s += "#{is}  \"holidayDuration\" : #{@holidayDuration},\n"
    s += "#{is}  \"color\" : \"#{@color}\",\n"
    unless @children.empty?
      s += "#{is}  \"children\" : [\n"
      s += @children.map{|c|c.to_json(indent + 1)}.join(",\n")
      s += "\n#{is}  ]\n"
    end
    s += "#{is}}"
  end
  def dump(indent)
    (" " * (2 * indent)) + "#{@name} #{@duration.to_hours_text}" + @children.map{|c|"\n" + c.dump(indent + 1)}.join
  end
end

def dumpCategory(c, rules)
  d = DumpedCategory.new(c.name, c.time, c.weekdayTime, c.holidayTime, rules.categoryColor(c))
  children = c.children
  remainingTime = c.time - children.sum {|x| x.time}
  if remainingTime > 0 && !children.empty?
    remainingCategory = Category.new(c.name, nil)
    remainingCategory.addWeekdayTime(remainingTime)
    children << remainingCategory
  end
  children.sort{|a,b|b.time <=> a.time}.each do |child|
    d << dumpCategory(child, rules) unless child.time <= 0
  end
  d
end

period = arg("-p", true) || '2000-01-01~2200-12-31'
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
YEAR = deduceYear(BASENAME)
PERIOD = parsePeriod(period, YEAR)

searchInputFilePath(ARGV)

data = readData(rules, YEAR)
if !ERRORS.empty?
  ERRORS.each do |e|
    puts e
  end

  unknowns = ERRORS.grep(/Unknown category/)
  unless unknowns.empty?
    puts
    unknowns.map {|e| e.sub(/[^:]+: (.*)/, "\\1") }.uniq.each do |task|
      suggestion = if task.match(/Se battre.*/) then "Se battre" else "Repos" end
      puts "#{task.gsub('+', '\\\+').gsub('?', '\\\?').gsub('(', '\\\(').gsub(')', '\\\)').gsub('$', '\\$')} = #{suggestion}"
    end
    puts
  end

  raise "Fix the above errors"
end

categories = data.days.flat_map do |day| day.flat_map do |a| a.categories.flat_map do |c| c.obj.hierarchy end end end.uniq.sort
rules.generateColors(categories)

if (Rules.isImageMode(rules.spec.mode))
  DAYWIDTH = if Rules::Spec::MODE_OCCUPATIONS == rules.spec.mode then 2 * BASE_DAYWIDTH else BASE_DAYWIDTH end
  height = 24 * HOURHEIGHT
  imageWidth = LEGEND_WIDTH + DAYWIDTH * data.days.length
  imageHeight = TITLE_HEIGHT + height + BOTTOMRULE_HEIGHT + FOOTER_HEIGHT
  image = Magick::RVG.new(imageWidth + RIGHT_MARGIN, imageHeight)
  image.background_fill = 'black'

  image.use(generateTitle(imageWidth, TITLE_HEIGHT), imageWidth / 2, TITLE_HEIGHT / 2, imageWidth, TITLE_HEIGHT)
  image.use(generateBottomRule(imageWidth, BOTTOMRULE_HEIGHT, data.days), LEGEND_WIDTH, BOTTOMRULE_HEIGHT + height)

  image.use(generateRuledBackground(imageWidth, height, data.days, rules.spec.mode), 0, TITLE_HEIGHT)
end

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
  if DIAG
    puts "Total days : #{totals.days} (#{totals.workDays} work + #{totals.holidays} holidays)"
    outputs = []
    totals.detailedTimes.each do |activity, times|
      outputs << [times.total, activity, times.total_s, (times.total.to_f.zdiv totals.days).to_hours_text,
                  times.workDays_s, (times.workDays.to_f.zdiv totals.workDays).to_hours_text,
                  times.holidays_s, (times.holidays.to_f.zdiv totals.holidays).to_hours_text]
    end
    printCountOutputs(outputs.map)
    puts
  end

  puts "Total days : #{totals.days} (#{totals.workDays} work + #{totals.holidays} holidays)"
  outputs = []
  totals.times.each do |category, times|
    outputs << [times.total, category.name, times.total_s, (times.total.to_f.zdiv totals.days).to_hours_text,
                times.workDays_s, (times.workDays.to_f.zdiv totals.workDays).to_hours_text,
                times.holidays_s, (times.holidays.to_f.zdiv totals.holidays).to_hours_text]
  end
  printCountOutputs(outputs)

when Rules::Spec::MODE_INTERACTIVE
  rootCategories = []
  categories.each do |c|
    c = c.parent until c.parent.nil?
    rootCategories << c unless rootCategories.include?(c)
  end
  dumpedCategories = rootCategories.sort{|a,b|b.time <=> a.time}.map do |c| dumpCategory(c, rules) end
  allCategories = DumpedCategory.new(EVERYTHING, dumpedCategories.sum{|c|c.duration}, dumpedCategories.sum{|c|c.holidayDuration}, dumpedCategories.sum{|c|c.holidayDuration}, "#000000")
  dumpedCategories.each do |c| allCategories << c end
  output = File.write(htmlFilename(BASENAME, rules.spec.name),
                      ERB.new(File.read('interactive.erb')).result_with_hash(
                        :data => data,
                        :rules => rules,
                        :categories => categories,
                        :dumpedCategories => allCategories,
                        :kDOW => DOW,
                        :kACTIVITY_OPACITY => ACTIVITY_OPACITY
                      ))
  puts dumpedCategories.map{|c|c.dump(0)}.join("\n")

  avgSleepTime = 0
  avgEndTime = 0
  sleepDays = if data.days.length == 1 then 1 else data.days.length - 1 end
  data.days.each do |day|
    avgSleepTime += day.sleepTime unless day.sleepTime.nil?
    avgEndTime += day.endTime
  end
  avgSleepTime /= sleepDays
  avgEndTime /= data.days.length

  semiDeviationEndTime = 0
  semiDeviationCount = 0
  deviationSleepTime = 0
  deviationEndTime = 0
  data.days.each do |day|
    deviationSleepTime += (day.sleepTime - avgSleepTime) ** 2 unless day.sleepTime.nil?
    deviationEndTime += (day.endTime - avgEndTime) ** 2
    if (day.endTime > avgEndTime)
      semiDeviationEndTime += (day.endTime - avgEndTime) ** 2
      semiDeviationCount += 1
    end
  end
  deviationSleepTime = Math.sqrt(deviationSleepTime / sleepDays)
  deviationEndTime = Math.sqrt(deviationEndTime / data.days.length)
  semiDeviationEndTime = if (0 == semiDeviationEndTime) then 0 else Math.sqrt(semiDeviationEndTime / semiDeviationCount) end
  puts "Average sleep length : #{avgSleepTime.to_hours_text} (deviation #{deviationSleepTime.to_hours_text})"
  puts "Average sleep hour : #{avgEndTime.to_hours_text} (deviation #{deviationEndTime.to_hours_text}, if counting only late #{semiDeviationEndTime.to_hours_text})"


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
