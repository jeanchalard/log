#!/usr/bin/ruby -w

# This script counts how many times a given regexp appears in
# the given files, but will only count once for a given day. The
# regexp is case insensitive.
# E.g. $0 '.*du pain.*' data/*
# ...will count how many days have at least one line matching
# that regexp.

regexp = Regexp.new(ARGV.shift, true)
dayR = /^\d\d-\d\d/

class String
  def toMinutes
    throw "Bug : expected line at format `\\d\\d\\d\\d <activity>` : #{self}" unless self.match(/(\d\d)(\d\d)/)
    hours, minutes = $1.to_i, $2.to_i
    hours * 60 + minutes
  end
end

class Integer
  def renderTime
    if self < 60
      "#{self}min"
    else
      "%dh%02d" % [self / 60, self % 60]
    end
  end
end

day = nil
done = true
totalCount = 0
dayCount = 0
totalTime = 0
todayTime = 0
last = nil
while l = gets
  l.chomp!
  if l.match(dayR)
    day = l
    done = false
    puts "        ..." + todayTime.renderTime unless todayTime <= 0
    todayTime = 0
    raise "Not implemented : can't count time for last activity of the day" unless last.nil?
  elsif !last.nil?
    elapsed = l.toMinutes - last
    puts " : #{elapsed.renderTime}"
    todayTime += elapsed
    totalTime += elapsed
    last = nil
  end
  if l.match(regexp)
    if !done
      print "#{day} : #{l}"
      done = true
      dayCount += 1
    else
      print "     ...#{l}"
    end
    last = l.toMinutes
    totalCount += 1
  end
end

puts "Last item matched regexp, not counted in spent time" unless last.nil?
puts "Total : #{totalCount} times over #{dayCount} days and #{totalTime.renderTime}"
