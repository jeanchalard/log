#!/usr/bin/ruby -w

require 'timeout'
require 'tempfile'

FREQ = 300
TOLERANCE = 60
PREFIX = ARGV[0]
CAM_PREFIX = 'cam'
DEST = ARGV[1]

nxt = Time.now
begin
  now = Time.now
  nxt = now + FREQ - now.to_i % FREQ
  if (now - nxt < TOLERANCE) # don't capture on non-boundary time, this happens after device sleeps
    date = now.strftime("%Y%m%d_%H%M").sub(/(\d\d)_(0[0-4])/){|m| "\%02d_\%02d" % [$1.to_i-1, $2.to_i+24]}
    file = "#{DEST}/#{PREFIX}_#{date}.jpg"
    athome = `qdbus org.kde.kdeconnect /modules/kdeconnect/devices/f4e95886c71b4c2087fadd747a2d4fa2 org.kde.kdeconnect.device.isReachable`
    athome.chomp!
    $stderr.puts "Capture #{file} #{Time.now}"
    begin
      # Sometimes spectacle crashes, and it takes like 90 minutes (!) to finish crashing during which the script is blocked.
      Timeout.timeout(10) {
        `spectacle -fbn -o #{file}`
      }
    rescue Timeout::Error
      `ps -eo pid,cmd | grep spectacle | grep -v grep | cut -d \  -f 2 | xargs kill -9`
    end
    file = "#{DEST}/#{CAM_PREFIX}_#{date}.jpg"
    $stderr.puts "Snap #{file} #{Time.now}"
    suppressed = false
    if athome == 'false'
      # Note that this command requires the user to be in the 'adm' or 'systemd-journal' group.
      last = `journalctl -n4 -u sleep.target -o short-unix | grep --color=never 'Stopped target sleep.target' | tail -n 1`
      last.match(/^(\d+)/)
      last = $1.to_i # If no entry was found, last is '', match doesn't match, $1 is nil and $1.to_i is 0.
      now = Time.now.to_i
      # kdeconnect can't find the device, suppress the screenshot unless last wake up from sleep is less than 30 minutes ago
      suppressed = true unless (now - last < 30 * 60)
    end
    if suppressed
      $stderr.puts "Sorti"
      `convert -font 'DejaVu-Sans' -background black -fill white -pointsize 128 'label: Sorti #{date}' #{file}`
    else
      Tempfile.create("sc") do |f|
        `v4lctl snap jpeg full #{f.path}`
        `convert #{f.path} -rotate 270 #{file}`
      end
    end
  end
  delay = nxt.to_i - Time.now.to_i
  $stderr.puts "Delay #{delay} #{Time.now}"
  sleep(if delay > 0 then delay else 0 end)
  $stderr.puts "Slept #{Time.now}"
end while true
