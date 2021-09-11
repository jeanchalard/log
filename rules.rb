#!/usr/bin/ruby -w

Rule = Struct.new(:pattern, :categories)
WeightedObj = Struct.new(:obj, :weight)
LocalRandom = Random.new(1)

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
    rules.each do |r|
      r.categories.each do |c|
        dest = c.obj
        dest = collapse[dest] until collapse[dest].nil? || collapse[dest] == dest
        c.obj = dest unless dest.nil?
      end
    end
    @rules = rules
  end

  def generateColors(activities)
    activities.each do |activity|
      @colors[activity] = "#%06X" % (LocalRandom.rand * 65536) unless @colors.has_key?(activity)
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

def findFile(filename)
  [filename, "#{filename}.grc", "rules/#{filename}", "rules/#{filename}.grc"].each do |name|
    return name if File.exists?(name)
  end
  raise "File not found #{filename}"
end

def readRulesInternal(filename)
  mode = nil
  spec = Rules::Spec.new("unnamed", Rules::Spec::MODE_CALENDAR)
  colors = {}
  counters = []
  markers = []
  rules = []
  collapse = {}
  caseInsensitive = true
  f = File.new(findFile(filename))
  while l = f.gets
    l = l.chomp
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
