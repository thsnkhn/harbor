#!/usr/bin/ruby
# Harbor native messaging host (Chrome-family + Firefox), bundled in Harbor.app.
# Receives a URL from the browser and opens it with Harbor via harbor://download.
# Protocol: 4-byte length (native byte order) + UTF-8 JSON, in both directions.
# Uses only Ruby's standard library and macOS's built-in /usr/bin/ruby.

require "json"
require "open3"

MAX_IN = 1024 * 1024
# Firefox passes the manifest path / add-on id, Chrome passes chrome-extension://...
HOST_NAME = ARGV.any? { |a| a =~ /firefox|mozilla/i } ? "com.harbor.firefox" : "com.harbor.chrome"

$stdin.binmode
$stdout.binmode
$stdout.sync = true

def read_msg
  header = $stdin.read(4)
  return nil if header.nil? || header.bytesize < 4
  length = header.unpack1("L")
  raise "Message too large" if length > MAX_IN
  body = length.zero? ? "" : $stdin.read(length)
  raise "Incomplete message" if body.nil? || body.bytesize < length
  JSON.parse(body.force_encoding("UTF-8"))
end

def write_msg(obj)
  data = JSON.generate(obj)
  $stdout.write([data.bytesize].pack("L") + data)
end

def usable_url(value)
  return "" unless value.is_a?(String)
  value.match?(%r{\Ahttps?://[^\s/?#]+}i) ? value : ""
end

# Percent-encode every byte except unreserved characters (same as Python's quote(safe="")).
def encode(value)
  value.b.gsub(/[^A-Za-z0-9\-._~]/n) { |c| format("%%%02X", c.ord) }
end

def scheme_url(url, referrer)
  out = "harbor://download?url=" + encode(url)
  ref = usable_url(referrer)
  out += "&referrer=" + encode(ref) unless ref.empty?
  out
end

def handle(msg)
  return { "ok" => false, "error" => "Expected a JSON object." } unless msg.is_a?(Hash)
  action = msg["action"] || "download"
  return { "ok" => true, "host" => HOST_NAME } if action == "ping"
  return { "ok" => false, "error" => "Unknown action." } unless action == "download"

  url = usable_url(msg["url"])
  return { "ok" => false, "error" => "Only valid HTTP/HTTPS URLs are accepted." } if url.empty?

  begin
    _out, err, status = Open3.capture3("/usr/bin/open", scheme_url(url, msg["referrer"]))
  rescue StandardError => e
    return { "ok" => false, "error" => "Could not open Harbor: #{e.message[0, 150]}" }
  end
  return { "ok" => true } if status.success?

  detail = err.to_s.strip[0, 180]
  { "ok" => false, "error" => "Could not open Harbor. Is it installed?" + (detail.empty? ? "" : " #{detail}") }
end

loop do
  begin
    msg = read_msg
    break if msg.nil?
    write_msg(handle(msg))
  rescue StandardError => e
    begin
      write_msg({ "ok" => false, "error" => e.message[0, 280] })
    rescue StandardError
      break
    end
  end
end
