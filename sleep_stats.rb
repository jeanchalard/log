#!/usr/bin/ruby -w

# This script will gather sleep times (duration and hour), average them over a number of
# days, and output a graph "sleep_stats.png" with both curves.
# The -l argument is used to set on how many days to average. Use 7 to average on
# weeks, 30 to average on ~months (it will average on 30 exact days), or any other
# value. The script will throw away all data before the first Monday and after the last
# Sunday, which is nice for weeks and not much of a problem for other periods.

# Possible improvements include : only throw out incomplete weeks when averaging
# over weeks, have a smoothed out curve instead of straight lines (as long as dots
# are still shown), show numeric values close to each point on the graph

require_relative 'util'

PERIOD_LENGTH = arg('-l', true).to_i
raise "Invocation : #{$0} -l <numbers of days to average on> files..." if PERIOD_LENGTH == 0


DATE_START = 5 * 60 # Day starts at 5 in the morning
NIGHT_START = 19 * 60 # The first Zzz after this time will be the sleep time for the day

class DayRecord < Struct.new(:date, :hour, :duration)
  def date_string
    "%04d-%02d-%02d" % [date.year, date.month, date.mday]
  end
end
records = []

logs = Logs.new(ARGV)
date = nil
duration = 0
hour = nil
while a = logs.gets
  next unless a.activity == "Zzz" || a.activity == "Sieste"
  d = a.date(DATE_START)
  if d != date
    unless date.nil? || hour.nil?
      records << DayRecord.new(date, hour, duration)
    end
    date = d
    duration = 0
    hour = nil
  end
  duration += a.duration_minutes
  start_minute = a.start_minutes_from_day_start(DATE_START)
  if start_minute > NIGHT_START && hour.nil?
    hour = start_minute
  end
end
unless date.nil? || hour.nil?
  records << DayRecord.new(date, hour, duration)
end

last = records.max_by{|x|x.hour}.hour

$stderr.puts "Latest sleep hour %02d:%02d" % [last / 60, last % 60]

records = records.drop_while {|d| !d.date.monday? }
begin
  l = records.pop
end until l.date.monday?

# Fill in gaps with empty lines
filled = []
date = records[0].date - 86400
records.each do |r|
  date += 86400
  while date < r.date
    filled << DayRecord.new(date, nil, nil)
    date += 86400
  end
  filled << r
end

stats = []
filled.each_slice(PERIOD_LENGTH) do |d|
  # Note that nil.to_i gives 0, so empty lines don't contribute
  hour = d.sum {|x| x.hour.to_i }.to_f
  duration = d.sum {|x| x.duration.to_i }.to_f
  day_count = d.count {|x| !x.hour.nil? }
  stats << DayRecord.new(d[0].date, hour / day_count, (duration / day_count) / 60.0)
end

data = ""
stats.each do |d|
  data += "#{d.date_string}\t#{d.hour}\t#{d.duration}\n"
end

bottom = stats.min_by {|x|x.hour}.hour.to_i
top = stats.max_by {|x|x.hour}.hour.to_i

# A bit of a cheat but on the y1 axis time is output in minutes, but taken as seconds
# by gnuplot, and therefore printed as minutes:seconds, which works because there
# are as many seconds in one minute as there are minutes in one hour and there are
# more than 30 minutes to the hour
commands = <<EOF
set terminal png size 2560,1440 background rgb 'black';
set output "sleep_stats.png";
set border lc rgb 'white';
set key tc rgb 'white';
set xdata time;
set timefmt "%Y-%m-%d";

set xlabel font "DejaVu-Sans, 20";
set xtics font "DejaVu-Sans, 20";
set xlabel "Date";

set yrange [#{top + 50}:#{bottom - 300}]
set ylabel font "DejaVu-Sans, 20";
set ytics font "DejaVu-Sans, 20";
set ytics time tc lt 1;
set ytics format "%M:%S" time;
set ylabel "Sleep hour" tc lt 1;

set y2range [0:12]
set y2label font "DejaVu-Sans, 20";
set y2tics font "DejaVu-Sans, 20" tc lt 2;
set y2label "Sleep duration" tc lt 2;

plot "sleep_stats.txt" using 1:2 with linespoints title "Hour" linestyle 1 linewidth 3 axes x1y1, "sleep_stats.txt" using 1:3 with linespoints title "Duration" linestyle 2 linewidth 3 axes x1y2;
EOF

File.open('sleep_stats.txt', File::WRONLY | File::TRUNC) do |f| f.write(data) end
File.open('sleep_stats.gnuplot', File::WRONLY | File::TRUNC) do |f| f.write(commands) end
`gnuplot -c sleep_stats.gnuplot`
