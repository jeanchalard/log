#!/usr/bin/ruby -w

# This script counts how many times a given regexp appears in
# the given files, but will only count once for a given day. The
# regexp is case insensitive.
# E.g. $0 '.*du pain.*' data/*
# ...will count how many days have at least one line matching
# that regexp.

regexp = Regexp.new(ARGV.shift, true)
dayR = /^\d\d-\d\d/

day = nil
done = true
count = 0
while l = gets
  l.chomp!
  case l
  when dayR
    day = l
    done = false
  when regexp
    if !done
      puts "#{day} : #{l}"
      done = true
      count += 1
    end
  end
end

puts "Total : #{count}"
