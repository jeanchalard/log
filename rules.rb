#!/usr/bin/ruby -w

Rule = Struct.new(:pattern, :categories)
WeightedObj = Struct.new(:obj, :weight)
LocalRandom = Random.new(1)
class Category < Struct.new(:name, :parent)
  attr_reader :time, :weekdayTime, :holidayTime, :children
  def initialize(name, parent)
    super(name, parent)
    parent.children << self unless parent.nil?
    @children = []
    @time = 0
    @weekdayTime = 0
    @holidayTime = 0
  end
  def <=>(other)
    name <=> other.name
  end
  def hierarchy
    if parent.nil?
      [self]
    else
      [self] + parent.hierarchy
    end
  end
  def each_parent(&block)
    block.call(self)
    parent.each_parent(&block) unless parent.nil?
  end
  def addWeekdayTime(time)
    @weekdayTime += time
    @time += time
    parent.addWeekdayTime(time) unless parent.nil?
  end
  def addHolidayTime(time)
    @holidayTime += time
    @time += time
    parent.addHolidayTime(time) unless parent.nil?
  end
end

class Counter
  attr_reader :pattern
  def initialize(pattern, contribution, category)
    @pattern = pattern
    @contribution = contribution
    @category = category
  end

  def match(line)
    m = pattern.match(line)
    return nil if m.nil?
    contrib = @contribution
    while contrib.index(/\$(\d+)/)
      contrib = contrib.sub('$' + $1, m[$1.to_i])
    end
    cat = @category
    while cat.index(/\$(\d+)/)
      cat = cat.sub('$' + $1, m[$1.to_i])
    end
    [cat, contrib.to_i]
  end
end

class Rules
  class Spec < Struct.new(:name, :mode)
    # Image modes
    MODE_CALENDAR = 1
    MODE_OCCUPATIONS = 2
    MODE_COUNT = 3
    MODE_STACK = 4
    # Interactive modes
    MODE_INTERACTIVE = 5
  end
  def self.isImageMode(mode)
    return mode < Spec::MODE_INTERACTIVE
  end

  attr_reader :spec, :colors

  def initialize(spec, colors, counters, markers, rules, collapse)
    @spec = spec
    @colors = colors
    @counters = counters
    @markers = markers
    categories = rules.flat_map {|r| r.categories.map {|c| c.obj } }.uniq
    cache = { nil => nil, ZZZ => ZZZCAT }
    categories = categories.map {|c| getCategory(c, collapse, cache) }
    rules.each do |r|
      r.categories.each do |c|
        c.obj = cache[c.obj]
      end
    end
    @rules = rules
  end

  def getCategory(c, collapse, cache)
    if cache.has_key?(c) # nil is seeded to nil in the cache
      cache[c]
    else
      cache[c] = Category.new(c, getCategory(collapse[c], collapse, cache))
      cache[c]
    end
  end
  private :getCategory

  def generateColors(categories)
    categories.each do |category|
      next if @colors.has_key? category.name
      color = categoryColor(category)
      # Generate a color only for those activities that don't find one recursively.
      # If they have one recursively it will be looked up at generation time with
      # categoryColor. This is essential to distinguish what must be displayed in
      # the legend, because a category that gets its color from its parent should
      # not be shown in the legend.
      @colors[category.name] = "#%06X" % (LocalRandom.rand * 65536) if color.nil?
    end
  end

  def categoryColor(category)
    if category.nil?
      nil
    elsif @colors.has_key? category.name
      @colors[category.name]
    else
      categoryColor(category.parent)
    end
  end

  def markers
    @markers
  end

  def eachMarker(activity)
    @markers.each {|m|
      if m.regexp.match(activity) then yield(m.name, m.policy) end
    }
  end

  def matchCounter(description)
    matches = []
    @counters.each do |c|
      m = c.match(description)
      matches << m unless m.nil?
    end
    matches
  end

  def categorize(activity)
    @rules.each do |rule|
      return rule if rule.pattern.match(activity)
    end
    nil
  end
end

class Marker
  attr_accessor :regexp, :policy, :name
  FIRST = 1
  LAST = 2
  EACH = 3
  def initialize(regexp, policy, name)
    self.regexp = regexp
    self.policy = if policy.is_a? String then policy.toMarkerPolicy else policy end
    self.name = name
  end
end

class String
  def toMarkerPolicy
    case self
    when 'First' then Marker::FIRST
    when 'Last' then Marker::LAST
    when 'Each' then Marker::EACH
    else raise "Unknown marker style #{self}"
    end
  end
  def toSpecMode
    case self
    when 'calendar' then Rules::Spec::MODE_CALENDAR
    when 'occupation' then Rules::Spec::MODE_OCCUPATIONS
    when 'stack' then Rules::Spec::MODE_STACK
    when 'count' then Rules::Spec::MODE_COUNT
    when 'interactive' then Rules::Spec::MODE_INTERACTIVE
    end
  end
end

def readRulesInternal(filename)
  mode = ""
  spec = Rules::Spec.new("unnamed", Rules::Spec::MODE_CALENDAR)
  colors = {}
  counters = []
  markers = []
  rules = []
  collapse = {}
  caseInsensitive = true
  f = File.new(findRuleFile(filename, '.grc'))
  while l = f.gets
    l = l.chomp
    l = l.gsub(/([^#]*)#.*/, "\\1") unless mode.match(/colors/i)
    case l
    when /^\s*#/, /^$/ then # nothing, it's a comment or an empty line
    when /^\[([^\]\/]+)(\/i)?\]$/i
      mode = $1
      caseInsensitive = ! $2.nil?
    else
      case mode
      when /general/i
        case l
        when /include (.+)/
          breakdown = readRulesInternal($1)
          colors.merge!(breakdown[1])
          counters += breakdown[2]
          markers += breakdown[3]
          rules += breakdown[4]
          collapse.merge!(breakdown[5])
        when /name = (.+)/
          spec.name = $1
        when /mode = (.+)/
          spec.mode = $1.toSpecMode
        end
      when /colors/i
        if l.match(/([^=]+) = ([^=]+)/)
          colors[$1] = $2
        else
          raise "Unrecognized color in #{f.lineno} : #{l}"
        end
      when /collapse/i
        c = l.split('=').map{|s|s.strip}
        target = c.pop
        raise "Unrecognized collapse rule in #{f.lineno} : #{l}" if c.empty?
        c.each do |source|
          collapse[source] = target
        end
      when /counters/i
        if l.match(/([^=]+) = ([^=]+) = ([^=]+)/)
          counters << Counter.new(Regexp.new("^" + $1 + "$", caseInsensitive), $2, $3)
        else
          raise "Unrecognized counter in #{f.lineno} : #{l}"
        end
      when /markers/i
        if l.match(/([^=]+) = ([^=]+) = ([^=]+)/)
          markers << Marker.new(Regexp.new("^" + $1 + "$", caseInsensitive), $2.toMarkerPolicy, $3)
        else
          raise "Unrecognized marker in #{f.lineno} : #{l}"
        end
      when /rules/i
        if l.match(/(.+) = (.+)/)
          matcher = $1
          category = $2
          if category.match(/^\d+%(\s+\d+%)*$/)
            percents = category.scan(/\d+%/)
            cats = matcher.split("\\+")
            raise "Can only omit category names when regexp is '+'-separated list of the same size : #{l}" if percents.size != cats.size
            category = percents.zip(cats).map {|x| "#{x[0]} #{x[1]}" }.join(" ")
          end
          categoryList = category.scan(/(\d+% .*?)(?= \d+%|$)/)
          categories = []
          if categoryList.empty?
            categories << WeightedObj.new(category, 1.0)
          else
            total = 0
            categoryList.each do |c|
              c[0].match(/(\d+)% (.*)/)
              total += $1.to_i
              categories << WeightedObj.new($2, $1.to_f / 100)
            end
            raise "Doesn't add up to 100% : #{l}" if total != 100
          end
          rules << Rule.new(Regexp.new("^" + matcher + "$", caseInsensitive), categories)
        else
          raise "Unrecognized rule in #{f.lineno} : #{l}"
        end
      else raise "Unknown section in #{f.lineno} : #{mode}"
      end
    end
  end
  f.close
  return [spec, colors, counters, markers, rules, collapse]
end

def readRules(filename, additionalCollapses)
  breakdown = readRulesInternal(filename)
  breakdown[5].merge!(additionalCollapses) if additionalCollapses
  return Rules.new(*breakdown)
end
